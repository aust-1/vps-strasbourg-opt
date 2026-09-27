#!/usr/bin/env bash
# Crée le réseau Docker partagé entre le proxy Caddy et les services exposés.
# Idempotent : ne fait rien si le réseau existe déjà.
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<'EOF'
Usage : scripts/network-create.sh [--dry-run] [-h]

Crée le réseau Docker externe « proxy » (variable PROXY_NETWORK pour changer le nom).
Chaque app y attache uniquement son service exposé, avec un alias unique.

Codes de sortie : 0 succès (créé ou déjà présent) ; 2 usage ; 3 Docker indisponible.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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

require_docker

if docker network inspect "$PROXY_NETWORK" >/dev/null 2>&1; then
  driver="$(docker network inspect -f '{{.Driver}}' "$PROXY_NETWORK")"
  [[ "$driver" == "bridge" ]] || die "le réseau « $PROXY_NETWORK » existe mais son driver est « $driver » (bridge attendu)"
  log "réseau « $PROXY_NETWORK » déjà présent"
else
  if [[ "$DRY_RUN" == "1" ]]; then
    run docker network create --driver bridge "$PROXY_NETWORK"
    log "réseau « $PROXY_NETWORK » à créer (dry-run : rien n'a été fait)"
  else
    docker network create --driver bridge "$PROXY_NETWORK" >/dev/null
    log "réseau « $PROXY_NETWORK » créé"
  fi
fi
