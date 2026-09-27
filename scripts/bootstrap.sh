#!/usr/bin/env bash
# Première mise en place de /opt sur un VPS : à lancer UNE fois après avoir récupéré le dépôt
# (docs/deploy.md). Idempotent : relançable sans risque.
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<'EOF'
Usage : scripts/bootstrap.sh [--deploy-all] [--skip-check] [--dry-run] [-h]

Étapes : prérequis -> réseau proxy -> sous-modules -> création des .env manquants ->
permissions -> contrôle (check.sh) -> routes -> démarrage du proxy -> état (status.sh).

Options :
  --deploy-all   démarre aussi tous les services et apps (échoue proprement si un .env est
                 encore à compléter) ; sans cette option, seul le proxy est démarré
  --skip-check   saute check.sh (déconseillé)
  --dry-run      affiche les étapes sans rien modifier
  -h, --help     cette aide

Codes de sortie : 0 succès ; 1 échec d'une étape ; 2 usage ; 3 prérequis.
EOF
}

DEPLOY_ALL=0
SKIP_CHECK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --deploy-all)
      DEPLOY_ALL=1
      shift
      ;;
    --skip-check)
      SKIP_CHECK=1
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

declare -a dry=()
if [[ "$DRY_RUN" == "1" ]]; then dry=(--dry-run); fi

log "=== 1/8 prérequis ==="
require_cmd git tar sha256sum awk
require_docker
require_repo
log "docker $(docker version --format '{{.Server.Version}}'), $(docker compose version --short), git $(git --version | awk '{print $3}')"

log "=== 2/8 réseau ==="
"$OPT_ROOT/scripts/network-create.sh" ${dry[@]+"${dry[@]}"}

log "=== 3/8 sous-modules ==="
cd "$OPT_ROOT"
run git submodule sync --recursive
run git submodule update --init --recursive

log "=== 4/8 fichiers .env ==="
declare -a TO_FILL=()
while IFS= read -r unit; do
  if [[ -f "$unit/.env.example" && ! -f "$unit/.env" ]]; then
    (umask 077 && run cp "$unit/.env.example" "$unit/.env")
    if grep -qvE '^\s*(#|$)' "$unit/.env.example"; then TO_FILL+=("${unit#"$OPT_ROOT"/}"); fi
    log ".env créé : ${unit#"$OPT_ROOT"/}"
  fi
done < <(list_units)

log "=== 5/8 permissions ==="
"$OPT_ROOT/scripts/fix-perms.sh" ${dry[@]+"${dry[@]}"}

log "=== 6/8 contrôle ==="
if [[ "$SKIP_CHECK" == "1" ]]; then
  warn "check.sh sauté (--skip-check)"
elif [[ "$DRY_RUN" == "1" ]]; then
  log "(dry-run) scripts/check.sh --skip-shellcheck"
else
  "$OPT_ROOT/scripts/check.sh" --skip-shellcheck || die "check.sh a échoué : corriger avant de démarrer (aucun service démarré)"
fi

log "=== 7/8 routes et démarrage ==="
"$OPT_ROOT/scripts/routes-sync.sh" --no-reload ${dry[@]+"${dry[@]}"}
if [[ "$DEPLOY_ALL" == "1" ]]; then
  "$OPT_ROOT/scripts/app-deploy.sh" --all ${dry[@]+"${dry[@]}"}
else
  "$OPT_ROOT/scripts/app-deploy.sh" proxy ${dry[@]+"${dry[@]}"}
fi

log "=== 8/8 état ==="
if [[ "$DRY_RUN" == "1" ]]; then
  log "(dry-run) scripts/status.sh"
else
  "$OPT_ROOT/scripts/status.sh" || warn "status.sh signale des anomalies (normal tant que les apps ne sont pas déployées)"
fi

if [[ ${#TO_FILL[@]} -gt 0 ]]; then
  warn "à compléter avant de déployer : ${TO_FILL[*]/%//.env}"
fi
if [[ "$DEPLOY_ALL" == "0" ]]; then
  log "suite : compléter les .env puis scripts/app-deploy.sh --all (ou <nom>)"
fi
