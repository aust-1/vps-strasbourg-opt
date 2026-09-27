#!/usr/bin/env bash
# Avance le pointeur d'un sous-module (apps/<nom>) vers un commit, et enregistre ce
# déplacement dans le dépôt opt. Ne déploie rien : voir scripts/app-deploy.sh.
#
# Utilité : le déploiement automatique d'une app (CI -> webhook/SSH -> app-deploy.sh) fait
# tourner son conteneur sur un commit que git-submodule ne connaît PAS encore. Ce script
# fait rattraper au dépôt opt le commit réellement déployé, pour que « git submodule status »
# et scripts/status.sh reflètent la réalité — sans jamais lancer de build ni de redémarrage.
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat << 'EOF'
Usage : scripts/app-bump.sh [--to RÉFÉRENCE] [--no-commit] [--dry-run] <nom>

Sans --to : récupère (fetch) et avance jusqu'au dernier commit de la branche suivie par le
sous-module. Avec --to : avance jusqu'à cette référence (commit, tag, branche) après fetch.
Refuse si apps/<nom> a des modifications non commitées (fichiers suivis par SON dépôt).

Options :
  --to RÉFÉRENCE  commit, tag ou branche cible (résolu après un fetch --all --tags)
  --no-commit     laisse le déplacement en attente dans l'index de opt, sans le commiter
  --dry-run       affiche ce qui serait fait sans rien modifier
  -h, --help      cette aide

Codes de sortie : 0 succès (y compris « déjà à jour ») ; 1 erreur ; 2 usage ;
                  3 prérequis (sous-module non initialisé) ; 4 apps/<nom> a des modifications locales.
EOF
}

TO=""
DO_COMMIT=1
NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --to)
      [[ $# -ge 2 ]] || usage_error "--to attend une référence"
      TO="$2"
      shift 2
      ;;
    --no-commit)
      DO_COMMIT=0
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
cd "$OPT_ROOT"

REL="apps/$NAME"
[[ -e "$REL/.git" ]] || die "$REL n'est pas un sous-module initialisé (scripts/update.sh)" 3

if [[ -n "$(git -C "$REL" status --porcelain)" ]]; then
  git -C "$REL" status --short >&2
  die "$REL a des modifications non commitées : à résoudre dans son propre dépôt d'abord" 4
fi

before="$(git -C "$REL" rev-parse --short HEAD)"
run git -C "$REL" fetch --all --tags --quiet

if [[ -n "$TO" ]]; then
  target="$TO"
else
  branch="$(git -C "$REL" rev-parse --abbrev-ref HEAD)"
  if [[ "$branch" == "HEAD" ]]; then
    die "$REL est en HEAD détachée sans --to : indiquer une référence explicite" 2
  fi
  target="origin/$branch"
fi

resolved="$(git -C "$REL" rev-parse --short "$target" 2> /dev/null)" \
  || die "référence introuvable dans $REL : $target"

if [[ "$resolved" == "$before" ]]; then
  log "$NAME : déjà à $before"
  exit 0
fi

log "$NAME : $before -> $resolved ($target)"
git -C "$REL" log --oneline "$before..$resolved" 2> /dev/null | sed 's/^/    /' || true
run git -C "$REL" checkout --quiet "$resolved"

run git add -- "$REL"
if [[ "$DO_COMMIT" == "1" ]]; then
  # git commit sans pathspec engloberait tout ce qui était déjà indexé par ailleurs :
  # on refuse plutôt que de committer autre chose que ce déplacement.
  if [[ "$DRY_RUN" == "0" ]]; then
    unexpected="$(git diff --cached --name-only | grep -vF -- "$REL" || true)"
    [[ -z "$unexpected" ]] || die "l'index contient d'autres changements (${unexpected//$'\n'/, }) : commit non créé, --no-commit pour les laisser en attente" 4
  fi
  run git commit -q -m "chore(apps): $NAME suit $resolved (déploiement)" -- "$REL"
  log "commit créé (pas de push)"
else
  log "déplacement laissé dans l'index (git commit à faire)"
fi
