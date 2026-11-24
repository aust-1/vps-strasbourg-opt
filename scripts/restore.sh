#!/usr/bin/env bash
# Restaure des volumes Docker (et optionnellement les .env) depuis une archive de backup.sh.
# DESTRUCTIF : le contenu actuel de chaque volume restauré est remplacé.
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat << 'EOF'
Usage : scripts/restore.sh [--only VOLUME]... [--with-env] [--yes] [--dry-run] <archive.tar.gz>
        scripts/restore.sh [options] --from-remote <instantané|latest>
        scripts/restore.sh --list-remote

Vérifie la somme de contrôle (<archive>.sha256), affiche le manifeste, puis remplace le contenu
de chaque volume par celui de l'archive. Un volume absent est créé avec les labels de compose
(projet et clé, déduits de son nom <unité>_<clé>) ; un volume existant sans ces labels est
recréé avec. Refuse si un conteneur utilise encore le volume (arrêter d'abord :
cd apps/<nom> && docker compose stop).

Options :
  --only V      ne restaure que ce volume (répétable) ; sans option, tous ceux de l'archive
  --with-env    restaure aussi les .env (l'existant est conservé en .env.bak-<horodatage>)
  --from-remote S  récupère l'archive de l'instantané S (« latest » : le plus récent) de la copie
                hors du VPS (restic, /etc/vps-opt/offsite.env) dans /var/backups/vps-opt/distant-*,
                puis la restaure comme une archive locale (téléchargée même en --dry-run)
  --list-remote liste les instantanés de la copie hors du VPS, puis s'arrête
  --yes         ne demande pas de confirmation
  --dry-run     affiche le plan sans rien modifier
  -h, --help    cette aide

Codes de sortie : 0 succès ; 1 erreur (archive corrompue…) ; 2 usage ; 3 prérequis ;
                  4 volume en cours d'utilisation ou confirmation refusée.
EOF
}

readonly HELPER_IMAGE="alpine:3"
WITH_ENV=0
declare -a ONLY=()
ARCHIVE=""
FROM_REMOTE=""
LIST_REMOTE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)
      [[ $# -ge 2 ]] || usage_error "--only attend un nom de volume"
      ONLY+=("$2")
      shift 2
      ;;
    --from-remote)
      [[ $# -ge 2 && "$2" =~ ^(latest|[0-9a-f]{8,64})$ ]] \
        || usage_error "--from-remote attend un identifiant d'instantané ou « latest »"
      FROM_REMOTE="$2"
      shift 2
      ;;
    --list-remote)
      LIST_REMOTE=1
      shift
      ;;
    --with-env)
      WITH_ENV=1
      shift
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) usage_error "option inconnue : $1" ;;
    *)
      [[ -z "$ARCHIVE" ]] || usage_error "une seule archive attendue"
      ARCHIVE="$1"
      shift
      ;;
  esac
done
if [[ -n "$FROM_REMOTE" || "$LIST_REMOTE" == "1" ]]; then
  [[ -z "$ARCHIVE" ]] || usage_error "une archive locale OU --from-remote / --list-remote"
else
  [[ -n "$ARCHIVE" ]] || usage_error "archive manquante"
  [[ -f "$ARCHIVE" ]] || die "archive introuvable : $ARCHIVE" 2
fi

require_docker
require_cmd tar sha256sum
umask 077

# Copie hors du VPS : liste, ou récupération de l'archive (et de son .sha256) d'un instantané.
if [[ "$LIST_REMOTE" == "1" ]]; then
  offsite_configured || die "$OFFSITE_ENV absent : copie hors du VPS non configurée" 3
  offsite_restic snapshots --tag "$OFFSITE_TAG"
  exit 0
fi
if [[ -n "$FROM_REMOTE" ]]; then
  offsite_configured || die "$OFFSITE_ENV absent : copie hors du VPS non configurée (docs/runbook.md)" 3
  DOWNLOAD="${BACKUP_DIR:-$BACKUP_ROOT_DEFAULT}/distant-$(stamp)"
  mkdir -p "$DOWNLOAD"
  chmod 700 "$DOWNLOAD" "$(dirname "$DOWNLOAD")"
  log "récupération de l'instantané $FROM_REMOTE dans $DOWNLOAD"
  offsite_restic restore "$FROM_REMOTE" --tag "$OFFSITE_TAG" --target "$DOWNLOAD" \
    || die "récupération de la copie distante en échec"
  mapfile -t FOUND < <(find "$DOWNLOAD" -type f -name 'opt-*.tar.gz')
  [[ ${#FOUND[@]} -eq 1 ]] || die "instantané inattendu : ${#FOUND[@]} archive(s) opt-*.tar.gz dans $DOWNLOAD"
  ARCHIVE="${FOUND[0]}"
  log "archive récupérée : $ARCHIVE (à supprimer une fois la restauration vérifiée)"
fi

ARCHIVE="$(cd "$(dirname "$ARCHIVE")" && pwd -P)/$(basename "$ARCHIVE")"
if [[ -f "$ARCHIVE.sha256" ]]; then
  (cd "$(dirname "$ARCHIVE")" && sha256sum -c --quiet "$(basename "$ARCHIVE").sha256") \
    || die "somme de contrôle invalide : archive corrompue ou modifiée"
  log "somme de contrôle valide"
else
  die "$ARCHIVE.sha256 introuvable : refus de restaurer une archive non vérifiable" 2
fi

# volume_labels <volume> : options « --label » qu'aurait posées docker compose en créant ce volume.
# Le nom suit la convention <projet>_<clé>, et le projet est le nom du dossier de l'unité (contrat
# contrôlé par check.sh) : pas besoin de rendre le compose, donc pas besoin de son .env. Vide si
# aucune unité connue (proxy, apps/*, services/*) ne correspond.
volume_labels() {
  local v="$1" unit best=""
  for unit in proxy $(list_units | xargs -r -n 1 basename); do
    if [[ "$v" == "${unit}_"?* && ${#unit} -gt ${#best} ]]; then best="$unit"; fi
  done
  [[ -n "$best" ]] || return 0
  printf '%s\n' --label "com.docker.compose.project=$best" \
    --label "com.docker.compose.volume=${v#"${best}_"}" \
    --label "com.docker.compose.version=$(docker compose version --short 2> /dev/null || echo inconnue)"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
tar xzf "$ARCHIVE" -C "$WORK"
[[ -f "$WORK/manifest.txt" ]] || die "manifest.txt absent : ce n'est pas une archive de backup.sh"
echo "--- manifeste ---"
cat "$WORK/manifest.txt"
echo "-----------------"

declare -a TO_RESTORE=()
for f in "$WORK"/volumes/*.tar.gz; do
  [[ -e "$f" ]] || continue
  v="$(basename "$f" .tar.gz)"
  # Le nom finit dans une commande shell : on n'accepte que des noms de volume Docker valides.
  [[ "$v" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "nom de volume suspect dans l'archive : $v"
  if [[ ${#ONLY[@]} -gt 0 ]]; then
    keep=0
    for o in "${ONLY[@]}"; do [[ "$o" == "$v" ]] && keep=1; done
    [[ "$keep" == "1" ]] || continue
  fi
  TO_RESTORE+=("$v")
done
for o in ${ONLY[@]+"${ONLY[@]}"}; do
  [[ -f "$WORK/volumes/$o.tar.gz" ]] || die "le volume « $o » n'est pas dans l'archive" 2
done

for v in ${TO_RESTORE[@]+"${TO_RESTORE[@]}"}; do
  users="$(docker ps -q --filter "volume=$v")"
  [[ -z "$users" ]] || die "le volume $v est utilisé par un conteneur en marche : l'arrêter d'abord" 4
done

log "volumes à restaurer (contenu actuel REMPLACÉ) : ${TO_RESTORE[*]:-(aucun)}"
[[ "$WITH_ENV" == "0" ]] || log "les .env seront restaurés aussi"
confirm "Confirmer la restauration ?"

for v in ${TO_RESTORE[@]+"${TO_RESTORE[@]}"}; do
  log "restauration de $v"
  # Volume créé avec les labels de compose : sinon compose le réutilise sans jamais les ajouter,
  # et backup.sh ne le retrouve plus par le label de son projet.
  mapfile -t labels < <(volume_labels "$v")
  if [[ ${#labels[@]} -eq 0 ]]; then
    warn "$v : aucune unité connue ne le déclare, créé sans label compose"
  fi
  if docker volume inspect "$v" > /dev/null 2>&1; then
    have="$(docker volume inspect -f '{{index .Labels "com.docker.compose.project"}}' "$v")"
    if [[ ${#labels[@]} -gt 0 && "${labels[1]}" != "com.docker.compose.project=$have" ]]; then
      # Son contenu va être remplacé : on peut le recréer, cette fois avec les labels.
      if run docker volume rm "$v" > /dev/null; then
        log "$v : existait sans les labels de compose, recréé avec"
      else
        warn "$v : impossible de le recréer avec les labels (conteneur arrêté qui l'utilise ? docker compose down dans son unité, puis relancer) ; contenu restauré quand même"
      fi
    fi
  fi
  run docker volume create ${labels[@]+"${labels[@]}"} "$v" > /dev/null
  run docker run --rm -v "$v":/data -v "$WORK/volumes":/in:ro "$HELPER_IMAGE" \
    sh -c "find /data -mindepth 1 -delete && tar xzf /in/$v.tar.gz -C /data"
done

if [[ "$WITH_ENV" == "1" ]]; then
  for f in "$WORK"/env/*.env; do
    [[ -e "$f" ]] || continue
    unit="$(basename "$f" .env)"
    dir="$(unit_dir "$unit")"
    if [[ -z "$dir" ]]; then
      warn ".env de « $unit » ignoré : ni apps/$unit ni services/$unit n'existe"
      continue
    fi
    if [[ -f "$dir/.env" ]]; then
      run cp -p "$dir/.env" "$dir/.env.bak-$(stamp)"
    fi
    run install -m 600 "$f" "$dir/.env"
    log ".env restauré : ${dir#"$OPT_ROOT"/}"
  done
fi

log "restauration terminée. Redémarrer : scripts/app-deploy.sh --all"
