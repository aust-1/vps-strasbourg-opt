#!/usr/bin/env bash
# Restaure des volumes Docker (et optionnellement les .env) depuis une archive de backup.sh.
# DESTRUCTIF : le contenu actuel de chaque volume restauré est remplacé.
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<'EOF'
Usage : scripts/restore.sh [--only VOLUME]... [--with-env] [--yes] [--dry-run] <archive.tar.gz>

Vérifie la somme de contrôle (<archive>.sha256), affiche le manifeste, puis remplace le contenu
de chaque volume par celui de l'archive. Refuse si un conteneur utilise encore le volume
(arrêter d'abord : cd apps/<nom> && docker compose stop).

Options :
  --only V      ne restaure que ce volume (répétable) ; sans option, tous ceux de l'archive
  --with-env    restaure aussi les .env (l'existant est conservé en .env.bak-<horodatage>)
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
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)
      [[ $# -ge 2 ]] || usage_error "--only attend un nom de volume"
      ONLY+=("$2")
      shift 2
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
[[ -n "$ARCHIVE" ]] || usage_error "archive manquante"
[[ -f "$ARCHIVE" ]] || die "archive introuvable : $ARCHIVE" 2

require_docker
require_cmd tar sha256sum
umask 077

ARCHIVE="$(cd "$(dirname "$ARCHIVE")" && pwd -P)/$(basename "$ARCHIVE")"
if [[ -f "$ARCHIVE.sha256" ]]; then
  (cd "$(dirname "$ARCHIVE")" && sha256sum -c --quiet "$(basename "$ARCHIVE").sha256") \
    || die "somme de contrôle invalide : archive corrompue ou modifiée"
  log "somme de contrôle valide"
else
  die "$ARCHIVE.sha256 introuvable : refus de restaurer une archive non vérifiable" 2
fi

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
  run docker volume create "$v" >/dev/null
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
