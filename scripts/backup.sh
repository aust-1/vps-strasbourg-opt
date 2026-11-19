#!/usr/bin/env bash
# Sauvegarde de l'état de /opt qui n'est PAS dans git : volumes Docker (certificats Caddy,
# données d'uptime-kuma…) et fichiers .env. Les données métier d'une app (base externe…)
# restent sous la responsabilité de l'app (ex. apps/bourse-tracker/infra/backup.sh).
#
# Sortie : <dest>/opt-<horodatage>.tar.gz + .sha256, mode 600 (contient des secrets).
# Cron (root) : 30 2 * * *  /opt/scripts/backup.sh --stop >> /var/log/vps-opt-backup.log 2>&1
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/perms.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/perms.sh"

usage() {
  cat << 'EOF'
Usage : scripts/backup.sh [--dest DOSSIER] [--keep-days N] [--stop] [--dry-run] [-h]

Contenu de l'archive : un tar.gz par volume Docker des projets compose (proxy, services, apps),
les fichiers .env, et manifest.txt (date, commit, sous-modules, volumes).

Copie hors du VPS : si /etc/vps-opt/offsite.env existe (aucune destination par défaut), l'archive
et son .sha256 sont envoyés, chiffrés, dans le dépôt restic qu'il décrit, puis les copies
distantes de plus de --remote-keep-days jours sont purgées. Un échec d'envoi est une erreur
(code 1), l'archive locale restant intacte. Mise en route : docs/runbook.md.

Options :
  --dest D       dossier de destination (défaut : $BACKUP_DIR ou /var/backups/vps-opt)
  --keep-days N  supprime les sauvegardes opt-*.tar.gz de plus de N jours (défaut 14 ; 0 = jamais)
  --remote-keep-days N
                 copies distantes conservées N jours (défaut : REMOTE_KEEP_DAYS de offsite.env,
                 sinon 30 ; 0 = jamais purgées)
  --stop         arrête les apps/services (pas le proxy) pendant la copie des volumes, puis les
                 redémarre : sauvegarde cohérente des bases SQLite (uptime-kuma)
  --dry-run      affiche le plan sans rien écrire
  -h, --help     cette aide

Codes de sortie : 0 succès ; 1 erreur (archive invalide) ; 2 usage ; 3 prérequis.
EOF
}

DEST="${BACKUP_DIR:-$BACKUP_ROOT_DEFAULT}"
KEEP_DAYS=14
REMOTE_KEEP_DAYS=""
STOP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest)
      [[ $# -ge 2 ]] || usage_error "--dest attend une valeur"
      DEST="$2"
      shift 2
      ;;
    --keep-days)
      [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || usage_error "--keep-days attend un nombre"
      KEEP_DAYS="$2"
      shift 2
      ;;
    --remote-keep-days)
      [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || usage_error "--remote-keep-days attend un nombre"
      REMOTE_KEEP_DAYS="$2"
      shift 2
      ;;
    --stop)
      STOP=1
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
    *) usage_error "option inconnue : $1" ;;
  esac
done

require_repo
require_docker
require_cmd tar sha256sum
umask 077

readonly HELPER_IMAGE="alpine:3"
STAMP="$(stamp)"
ARCHIVE="$DEST/opt-$STAMP.tar.gz"
WORK="$(mktemp -d)"
declare -a STOPPED=()

restart_stopped() {
  local dir
  for dir in ${STOPPED[@]+"${STOPPED[@]}"}; do
    (cd "$dir" && docker compose start > /dev/null) || warn "redémarrage impossible : $dir (docker compose start)"
  done
  STOPPED=()
}
cleanup() {
  restart_stopped
  rm -rf "$WORK"
}
trap cleanup EXIT

# project_name <dossier> : nom de projet compose (clé « name: » du compose).
project_name() {
  (cd "$1" && docker compose config | awk '/^name:/ {print $2; exit}')
}

declare -a UNIT_DIRS=("$PROXY_DIR")
while IFS= read -r u; do UNIT_DIRS+=("$u"); done < <(list_units)

declare -a VOLUMES=()
for dir in "${UNIT_DIRS[@]}"; do
  proj="$(project_name "$dir")"
  [[ -n "$proj" ]] || die "nom de projet compose introuvable pour $dir"
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    VOLUMES+=("$v")
  done < <(docker volume ls -q --filter "label=com.docker.compose.project=$proj")
done

if [[ "$DRY_RUN" == "1" ]]; then
  log "archive prévue : $ARCHIVE"
  log "volumes : ${VOLUMES[*]:-(aucun)}"
  log ".env : $(perms_env_files | wc -l) fichier(s)"
  if offsite_configured; then log "copie distante : restic ($OFFSITE_ENV)"; else log "copie distante : non configurée"; fi
  [[ "$STOP" == "0" ]] || log "apps/services arrêtés pendant la copie, puis redémarrés"
  exit 0
fi

mkdir -p "$DEST"
chmod 700 "$DEST"
mkdir -p "$WORK/volumes" "$WORK/env"

if [[ "$STOP" == "1" ]]; then
  for dir in "${UNIT_DIRS[@]}"; do
    [[ "$dir" != "$PROXY_DIR" ]] || continue
    if [[ -n "$(cd "$dir" && docker compose ps -q --status running)" ]]; then
      (cd "$dir" && docker compose stop > /dev/null)
      STOPPED+=("$dir")
      log "arrêté pendant la sauvegarde : $(basename "$dir")"
    fi
  done
fi

for v in ${VOLUMES[@]+"${VOLUMES[@]}"}; do
  log "volume $v"
  docker run --rm -v "$v":/data:ro -v "$WORK/volumes":/out "$HELPER_IMAGE" \
    tar czf "/out/$v.tar.gz" -C /data .
done

restart_stopped

for dir in "${UNIT_DIRS[@]}"; do
  if [[ -f "$dir/.env" ]]; then
    cp "$dir/.env" "$WORK/env/$(basename "$dir").env"
  fi
done

{
  echo "date: $(date -Is)"
  echo "hôte: $(hostname)"
  echo "opt: $(git -C "$OPT_ROOT" rev-parse HEAD)"
  git -C "$OPT_ROOT" submodule status 2> /dev/null | sed 's/^/sous-module: /' || true
  for v in ${VOLUMES[@]+"${VOLUMES[@]}"}; do echo "volume: $v"; done
} > "$WORK/manifest.txt"

tar czf "$ARCHIVE.tmp" -C "$WORK" .
tar tzf "$ARCHIVE.tmp" > /dev/null || die "archive illisible, sauvegarde abandonnée"
mv "$ARCHIVE.tmp" "$ARCHIVE"
(cd "$DEST" && sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")

# Copie hors du VPS : une perte du disque ou du serveur n'emporte pas aussi les sauvegardes.
# restic chiffre côté client (l'archive contient tous les .env) avant tout envoi.
if offsite_configured; then
  if [[ -z "$REMOTE_KEEP_DAYS" ]]; then REMOTE_KEEP_DAYS="$(offsite_value REMOTE_KEEP_DAYS)"; fi
  [[ "${REMOTE_KEEP_DAYS:=30}" =~ ^[0-9]+$ ]] || die "REMOTE_KEEP_DAYS invalide dans $OFFSITE_ENV : $REMOTE_KEEP_DAYS" 2
  log "copie distante (restic, chiffrée) : $(basename "$ARCHIVE")"
  offsite_restic backup --quiet --tag "$OFFSITE_TAG" "$ARCHIVE" "$ARCHIVE.sha256" \
    || die "copie distante en échec ; l'archive locale est intacte : $ARCHIVE"
  if [[ "$REMOTE_KEEP_DAYS" -gt 0 ]]; then
    # --group-by tags : chaque archive a un nom (donc un chemin) différent ; sans regroupement,
    # restic verrait autant de groupes que d'instantanés et n'en oublierait aucun.
    offsite_restic forget --quiet --tag "$OFFSITE_TAG" --group-by tags \
      --keep-within "${REMOTE_KEEP_DAYS}d" --prune \
      || die "purge des copies distantes de plus de $REMOTE_KEEP_DAYS jours en échec"
  fi
  log "copie distante OK (conservée $REMOTE_KEEP_DAYS jour(s) ; 0 = sans limite)"
else
  log "copie distante non configurée ($OFFSITE_ENV absent) : l'archive ne quitte pas le VPS"
fi

if [[ "$KEEP_DAYS" -gt 0 ]]; then
  find "$DEST" -maxdepth 1 -name 'opt-*.tar.gz*' -mtime "+$KEEP_DAYS" -delete
fi

log "sauvegarde OK : $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
