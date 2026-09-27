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

Options :
  --dest D       dossier de destination (défaut : $BACKUP_DIR ou /var/backups/vps-opt)
  --keep-days N  supprime les sauvegardes opt-*.tar.gz de plus de N jours (défaut 14 ; 0 = jamais)
  --stop         arrête les apps/services (pas le proxy) pendant la copie des volumes, puis les
                 redémarre : sauvegarde cohérente des bases SQLite (uptime-kuma)
  --dry-run      affiche le plan sans rien écrire
  -h, --help     cette aide

Codes de sortie : 0 succès ; 1 erreur (archive invalide) ; 2 usage ; 3 prérequis.
EOF
}

DEST="${BACKUP_DIR:-$BACKUP_ROOT_DEFAULT}"
KEEP_DAYS=14
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

if [[ "$KEEP_DAYS" -gt 0 ]]; then
  find "$DEST" -maxdepth 1 -name 'opt-*.tar.gz*' -mtime "+$KEEP_DAYS" -delete
fi

log "sauvegarde OK : $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
