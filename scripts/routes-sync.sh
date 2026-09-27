#!/usr/bin/env bash
# Assemble les Caddyfile des apps et services dans proxy/sites/, les valide, puis recharge Caddy.
#
# Garanties :
#  - la configuration est validée (caddy validate) dans un dossier temporaire AVANT toute
#    modification de proxy/sites/ : une config invalide ne remplace jamais une config valide ;
#  - on COPIE (pas de lien symbolique : ils cassent dans un montage de conteneur) ;
#  - les routes orphelines (app supprimée) sont retirées ;
#  - rechargement à chaud (caddy reload) uniquement si quelque chose a changé.
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<'EOF'
Usage : scripts/routes-sync.sh [--validate-only] [--check] [--no-reload] [--force-reload] [--dry-run] [-h]

Sources : apps/<nom>/Caddyfile et services/<nom>/Caddyfile  ->  proxy/sites/<nom>.caddy

Options :
  --validate-only  valide seulement les Caddyfile assemblés ; ne compare ni ne modifie rien
  --check         valide et signale un écart entre sources et proxy/sites, sans rien modifier
                  (code 1 s'il y a un écart)
  --no-reload     ne recharge pas Caddy après la copie
  --force-reload  recharge Caddy même sans changement
  --dry-run       affiche ce qui serait fait sans modifier proxy/sites ni recharger
  -h, --help      cette aide

Codes de sortie : 0 succès ; 1 config invalide, rechargement en échec ou écart (--check) ;
                  2 usage ; 3 prérequis (Docker).
EOF
}

CHECK=0
VALIDATE_ONLY=0
RELOAD=1
FORCE_RELOAD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --validate-only)
      VALIDATE_ONLY=1
      shift
      ;;
    --check)
      CHECK=1
      shift
      ;;
    --no-reload)
      RELOAD=0
      shift
      ;;
    --force-reload)
      FORCE_RELOAD=1
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

require_docker
[[ -f "$PROXY_COMPOSE" ]] || die "compose du proxy introuvable : $PROXY_COMPOSE" 3

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/sites"

# --- 1. Collecte des sources ------------------------------------------------
declare -A SOURCE_OF=()
while IFS= read -r unit; do
  name="$(basename "$unit")"
  if [[ ! -f "$unit/Caddyfile" ]]; then
    warn "$name n'a pas de Caddyfile : aucune route publiée pour lui"
    continue
  fi
  if [[ -n "${SOURCE_OF[$name]:-}" ]]; then
    die "nom en double « $name » : ${SOURCE_OF[$name]} et $unit"
  fi
  SOURCE_OF[$name]="$unit"
  cp "$unit/Caddyfile" "$STAGE/sites/$name.caddy"
done < <(list_units)

# --- 2. Validation dans le dossier temporaire ------------------------------
IMAGE="$(docker compose -f "$PROXY_COMPOSE" config --images | head -n 1)"
[[ -n "$IMAGE" ]] || die "image Caddy introuvable dans $PROXY_COMPOSE"

log "validation de ${#SOURCE_OF[@]} route(s) avec $IMAGE"
if ! VALIDATION="$(docker run --rm \
  -v "$PROXY_DIR/Caddyfile:/etc/caddy/Caddyfile:ro" \
  -v "$STAGE/sites:/etc/caddy/sites:ro" \
  "$IMAGE" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1)"; then
  printf '%s\n' "$VALIDATION" >&2
  die "configuration Caddy invalide : proxy/sites n'a pas été modifié"
fi

if [[ "$VALIDATE_ONLY" == "1" ]]; then
  log "configuration valide"
  exit 0
fi

# --- 3. Écarts entre sources validées et proxy/sites -----------------------
declare -a CHANGED=() ORPHANS=()
for name in "${!SOURCE_OF[@]}"; do
  if ! cmp -s "$STAGE/sites/$name.caddy" "$PROXY_SITES_DIR/$name.caddy" 2>/dev/null; then
    CHANGED+=("$name")
  fi
done
for f in "$PROXY_SITES_DIR"/*.caddy; do
  [[ -e "$f" ]] || continue
  name="$(basename "$f" .caddy)"
  [[ -n "${SOURCE_OF[$name]:-}" ]] || ORPHANS+=("$name")
done

if [[ "$CHECK" == "1" ]]; then
  if [[ ${#CHANGED[@]} -eq 0 && ${#ORPHANS[@]} -eq 0 ]]; then
    log "proxy/sites est à jour"
    exit 0
  fi
  [[ ${#CHANGED[@]} -gt 0 ]] && err "à synchroniser : ${CHANGED[*]}"
  [[ ${#ORPHANS[@]} -gt 0 ]] && err "orphelines : ${ORPHANS[*]}"
  exit 1
fi

# --- 4. Application --------------------------------------------------------
run mkdir -p "$PROXY_SITES_DIR"
for name in ${CHANGED[@]+"${CHANGED[@]}"}; do
  run install -m 644 "$STAGE/sites/$name.caddy" "$PROXY_SITES_DIR/$name.caddy"
  log "route mise à jour : $name"
done
for name in ${ORPHANS[@]+"${ORPHANS[@]}"}; do
  run rm -f "$PROXY_SITES_DIR/$name.caddy"
  log "route orpheline retirée : $name"
done

# --- 5. Rechargement -------------------------------------------------------
NB_CHANGES=$((${#CHANGED[@]} + ${#ORPHANS[@]}))
if [[ "$RELOAD" == "0" ]]; then
  log "rechargement ignoré (--no-reload)"
elif [[ "$NB_CHANGES" -eq 0 && "$FORCE_RELOAD" == "0" ]]; then
  log "aucun changement : pas de rechargement"
elif [[ "$DRY_RUN" == "1" ]]; then
  run docker compose -f "$PROXY_COMPOSE" exec -T caddy caddy reload --config /etc/caddy/Caddyfile
elif [[ -z "$(docker compose -f "$PROXY_COMPOSE" ps --status running -q caddy)" ]]; then
  warn "le proxy ne tourne pas : rien à recharger (démarrage : docker compose -f proxy/docker-compose.yml up -d)"
else
  if docker compose -f "$PROXY_COMPOSE" exec -T caddy caddy reload --config /etc/caddy/Caddyfile; then
    log "Caddy rechargé"
  else
    die "rechargement refusé : Caddy conserve son ancienne configuration (voir les messages ci-dessus)"
  fi
fi
