#!/usr/bin/env bash
# Applique les permissions attendues sur /opt (règles : scripts/lib/perms.sh).
# Idempotent : une seconde exécution ne change rien.
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/perms.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/perms.sh"

usage() {
  cat <<'EOF'
Usage : scripts/fix-perms.sh [--owner UTILISATEUR[:GROUPE]] [--dry-run] [-h]

Applique les permissions (chmod) définies dans scripts/lib/perms.sh :
scripts 755, lib 644, .env 600, proxy/sites 755/644, sauvegardes 700.

Options :
  --owner U[:G]  change aussi le propriétaire des fichiers .env, de proxy/sites
                 et des dossiers de sauvegarde (nécessite root)
  --dry-run      affiche les commandes sans rien modifier
  -h, --help     cette aide

Codes de sortie : 0 succès ; 2 usage ; 3 prérequis (root pour --owner).
EOF
}

OWNER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner)
      [[ $# -ge 2 ]] || usage_error "--owner attend une valeur"
      OWNER="$2"
      shift 2
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

perms_process apply

if [[ -n "$OWNER" ]]; then
  require_root
  while IFS= read -r f; do
    run chown "$OWNER" "$f"
  done < <(perms_env_files)
  run chown -R "$OWNER" "$PROXY_SITES_DIR"
  [[ -d "$OPT_ROOT/backups" ]] && run chown -R "$OWNER" "$OPT_ROOT/backups"
  if [[ -n "${BACKUP_DIR:-}" && -d "$BACKUP_DIR" ]]; then
    run chown -R "$OWNER" "$BACKUP_DIR"
  fi
fi

log "permissions : $PERMS_FIXED correction(s)"
