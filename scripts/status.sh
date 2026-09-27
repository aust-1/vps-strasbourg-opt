#!/usr/bin/env bash
# État d'ensemble : dépôt, réseau, proxy, et pour chaque app/service : commit, conteneurs,
# .env, route. Code de sortie non nul dès qu'un point est anormal (utilisable en supervision).
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<'EOF'
Usage : scripts/status.sh [-h]

Affiche le dépôt (commit, branche, arbre propre ?), le réseau proxy, l'état de Caddy, puis une
ligne par app/service : commit du sous-module, conteneurs sains/total, .env présent, route
publiée et à jour.

Codes de sortie : 0 tout va bien ; 1 au moins une anomalie ; 3 prérequis (Docker).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    *) usage_error "option inconnue : $1" ;;
  esac
done

require_repo
require_docker
cd "$OPT_ROOT"

PROBLEMS=0
problem() {
  PROBLEMS=$((PROBLEMS + 1))
}

container_state() {
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}:{{.State.ExitCode}}' "$1"
}

# compose_health <dossier> : « <sains>/<total> » sur stdout ; code 0 si tous sains et total > 0.
compose_health() {
  local dir="$1" id st total=0 good=0
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    total=$((total + 1))
    st="$(container_state "$id")"
    case "${st%%:*}" in
      healthy | running) good=$((good + 1)) ;;
      exited) [[ "${st#*:}" == "0" ]] && good=$((good + 1)) ;;
      *) ;;
    esac
  done < <(cd "$dir" && docker compose ps -a -q)
  echo "$good/$total"
  [[ "$total" -gt 0 && "$good" -eq "$total" ]]
}

branch="$(git rev-parse --abbrev-ref HEAD)"
dirty="propre"
if [[ -n "$(git status --porcelain)" ]]; then
  dirty="MODIFIÉ"
  problem
fi
log "dépôt : $(git rev-parse --short HEAD) sur $branch, arbre $dirty"

if docker network inspect "$PROXY_NETWORK" >/dev/null 2>&1; then
  log "réseau $PROXY_NETWORK : présent"
else
  log "réseau $PROXY_NETWORK : ABSENT (scripts/network-create.sh)"
  problem
fi

if proxy_health="$(compose_health "$PROXY_DIR")"; then
  log "proxy (caddy) : sain ($proxy_health)"
else
  log "proxy (caddy) : ANORMAL ($proxy_health)"
  problem
fi

printf '\n%-18s %-8s %-9s %-9s %-6s %s\n' UNITÉ TYPE COMMIT CONTENEURS ENV ROUTE
while IFS= read -r unit; do
  name="$(basename "$unit")"
  kind="service"
  commit="(dépôt)"
  if [[ "$unit" == "$APPS_DIR"/* ]]; then
    kind="app"
    if [[ -e "$unit/.git" ]]; then
      commit="$(git -C "$unit" rev-parse --short HEAD)"
    else
      commit="ABSENT"
      problem
    fi
  fi

  if health="$(compose_health "$unit")"; then :; else problem; fi

  env_state="ok"
  if [[ -f "$unit/.env.example" && ! -f "$unit/.env" ]]; then
    env_state="MANQUE"
    problem
  fi

  route="-"
  if [[ -f "$unit/Caddyfile" ]]; then
    if [[ ! -f "$PROXY_SITES_DIR/$name.caddy" ]]; then
      route="ABSENTE"
      problem
    elif ! cmp -s "$unit/Caddyfile" "$PROXY_SITES_DIR/$name.caddy"; then
      route="OBSOLÈTE"
      problem
    else
      route="ok"
    fi
  fi
  printf '%-18s %-8s %-9s %-9s %-6s %s\n' "$name" "$kind" "$commit" "$health" "$env_state" "$route"
done < <(list_units)

for f in "$PROXY_SITES_DIR"/*.caddy; do
  [[ -e "$f" ]] || continue
  n="$(basename "$f" .caddy)"
  if [[ -z "$(unit_dir "$n")" ]]; then
    warn "route orpheline : $n (scripts/routes-sync.sh)"
    problem
  fi
done

echo
if [[ "$PROBLEMS" -eq 0 ]]; then
  log "tout est en ordre"
else
  err "$PROBLEMS anomalie(s)"
  exit 1
fi
