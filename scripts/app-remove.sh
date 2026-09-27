#!/usr/bin/env bash
# Retire une app : arrêt des conteneurs, sauvegarde de son .env, désinscription du sous-module,
# retrait de sa route. Ne supprime JAMAIS les volumes sans --purge-volumes.
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<'EOF'
Usage : scripts/app-remove.sh [--purge-volumes] [--yes] [--commit] [--dry-run] <nom>

Étapes : docker compose down -> copie du .env dans backups/removed/ -> git submodule deinit
+ git rm + nettoyage de .git/modules -> routes-sync (retire la route, recharge Caddy).

Options :
  --purge-volumes   supprime AUSSI les volumes Docker de l'app (irréversible)
  --yes             ne demande pas de confirmation
  --commit          commit local « feat(apps): retire <nom> » (jamais de push)
  --dry-run         affiche les étapes sans rien modifier
  -h, --help        cette aide

Les services de services/ ne se retirent pas avec ce script (ce sont des fichiers du dépôt :
git rm -r services/<nom>).

Codes de sortie : 0 succès ; 1 erreur ; 2 usage ; 3 prérequis ; 4 confirmation refusée.
EOF
}

PURGE=0
COMMIT=0
NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge-volumes)
      PURGE=1
      shift
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --commit)
      COMMIT=1
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
      [[ -z "$NAME" ]] || usage_error "un seul nom attendu"
      NAME="$1"
      shift
      ;;
  esac
done
[[ -n "$NAME" ]] || usage_error "nom de l'app manquant"
valid_name "$NAME" || usage_error "nom invalide : $NAME"

require_repo
require_docker
cd "$OPT_ROOT"

REL="apps/$NAME"
[[ -d "$REL" ]] || die "$REL n'existe pas" 2

if [[ "$PURGE" == "1" ]]; then
  confirm "Retirer $NAME ET supprimer ses volumes Docker (irréversible) ?"
else
  confirm "Retirer $NAME (les volumes Docker sont conservés) ?"
fi

if [[ -f "$REL/docker-compose.yml" ]]; then
  down=(docker compose down --remove-orphans)
  [[ "$PURGE" == "0" ]] || down+=(--volumes)
  (cd "$REL" && run "${down[@]}")
fi

if [[ -f "$REL/.env" ]]; then
  backup_dir="$OPT_ROOT/backups/removed"
  run mkdir -p "$backup_dir"
  run chmod 700 "$OPT_ROOT/backups" "$backup_dir"
  target="$backup_dir/$NAME.env.$(stamp)"
  (umask 077 && run cp "$REL/.env" "$target")
  log ".env sauvegardé : ${target#"$OPT_ROOT"/}"
fi

run git submodule deinit -f -- "$REL"
run git rm -f -q -- "$REL"
run rm -rf -- "$OPT_ROOT/.git/modules/$REL" "${OPT_ROOT:?}/$REL"

sync_args=(--force-reload)
if [[ "$DRY_RUN" == "1" ]]; then sync_args=(--dry-run); fi
"$OPT_ROOT/scripts/routes-sync.sh" "${sync_args[@]}"

if [[ "$COMMIT" == "1" && "$DRY_RUN" == "0" ]]; then
  # On ne committe que si l'index ne contient RIEN d'autre que le retrait de cette app.
  unexpected="$(git diff --cached --name-only | grep -vE "^(\.gitmodules|$REL)(/|$)" || true)"
  [[ -z "$unexpected" ]] || die "l'index contient d'autres changements (${unexpected//$'\n'/, }) : commit non créé" 4
  git commit -q -m "feat(apps): retire $NAME"
  log "commit créé (pas de push)"
fi

if [[ "$PURGE" == "0" ]]; then
  vols="$(docker volume ls -q --filter "label=com.docker.compose.project=$NAME" | tr '\n' ' ')"
  [[ -z "$vols" ]] || log "volumes conservés : $vols (suppression : docker volume rm …)"
fi
log "app $NAME retirée"
