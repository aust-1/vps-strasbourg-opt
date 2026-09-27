#!/usr/bin/env bash
# Met /opt à jour depuis le dépôt distant : git pull + sous-modules, puis permissions et routes.
# C'est LE point d'entrée d'une mise à jour : « un simple git pull » + ce script.
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<'EOF'
Usage : scripts/update.sh [--deploy] [--no-routes] [--force] [--dry-run] [-h]

Enchaîne : contrôle de l'arbre git -> git pull --ff-only -> git submodule sync/update
-> résumé des commits reçus par chaque sous-module -> fix-perms -> routes-sync.
Ne redéploie AUCUNE app sans --deploy (sinon il indique quoi lancer).

Options :
  --deploy      redéploie (app-deploy.sh) les apps dont le sous-module a changé
  --no-routes   ne lance pas routes-sync.sh
  --force       n'exige pas un arbre propre ni la branche main (le pull reste --ff-only)
  --dry-run     affiche les commandes sans les exécuter
  -h, --help    cette aide

Codes de sortie : 0 succès ; 1 erreur ; 2 usage ; 3 prérequis ; 4 arbre sale / mauvaise branche.
EOF
}

# Toute la logique est dans une fonction : bash la lit en entier avant de l'exécuter, donc
# le pull peut réécrire ce fichier sans corrompre l'exécution en cours.
main() {
  local deploy=0 routes=1 force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --deploy)
        deploy=1
        shift
        ;;
      --no-routes)
        routes=0
        shift
        ;;
      --force)
        force=1
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

  # Options transmises aux scripts enfants (jamais de ${DRY_RUN:+…} : DRY_RUN vaut « 0 » par défaut).
  local -a dry=()
  if [[ "$DRY_RUN" == "1" ]]; then dry=(--dry-run); fi

  require_repo
  cd "$OPT_ROOT"

  local branch
  branch="$(git rev-parse --abbrev-ref HEAD)"
  if [[ "$force" == "0" ]]; then
    [[ "$branch" == "main" ]] || die "branche « $branch » : main attendu (--force pour passer outre)" 4
    if [[ -n "$(git status --porcelain)" ]]; then
      git status --short >&2
      die "l'arbre git n'est pas propre : commit/stash requis (--force pour passer outre)" 4
    fi
  fi

  # Sous-modules déclarés : « chemin » par ligne.
  local -a paths=()
  if [[ -f .gitmodules ]]; then
    while IFS= read -r line; do
      paths+=("${line#* }")
    done < <(git config -f .gitmodules --get-regexp '\.path$')
  fi

  local -A before=()
  local p
  for p in ${paths[@]+"${paths[@]}"}; do
    before[$p]="$(git -C "$p" rev-parse HEAD 2>/dev/null || echo none)"
  done

  local head_before
  head_before="$(git rev-parse --short HEAD)"
  run git pull --ff-only
  log "dépôt opt : $head_before -> $(git rev-parse --short HEAD)"

  run git submodule sync --recursive
  run git submodule update --init --recursive

  # Nouvelle liste (le pull a pu ajouter/retirer des sous-modules).
  paths=()
  if [[ -f .gitmodules ]]; then
    while IFS= read -r line; do
      paths+=("${line#* }")
    done < <(git config -f .gitmodules --get-regexp '\.path$')
  fi

  local -a changed=()
  local after old
  for p in ${paths[@]+"${paths[@]}"}; do
    after="$(git -C "$p" rev-parse HEAD 2>/dev/null || echo none)"
    old="${before[$p]:-none}"
    [[ "$after" == "$old" ]] && continue
    changed+=("$p")
    if [[ "$old" == "none" ]]; then
      log "$p : nouveau sous-module (${after:0:7})"
    else
      log "$p : ${old:0:7} -> ${after:0:7}"
      git -C "$p" log --oneline "$old..$after" 2>/dev/null | sed 's/^/    /' || true
    fi
  done

  "$OPT_ROOT/scripts/fix-perms.sh" ${dry[@]+"${dry[@]}"}
  if [[ "$routes" == "1" ]]; then
    "$OPT_ROOT/scripts/routes-sync.sh" ${dry[@]+"${dry[@]}"}
  fi

  if [[ ${#changed[@]} -eq 0 ]]; then
    log "aucun sous-module modifié"
    return 0
  fi

  local unit name
  for unit in "${changed[@]}"; do
    [[ "$unit" == apps/* ]] || continue
    name="$(basename "$unit")"
    if [[ "$deploy" == "1" ]]; then
      "$OPT_ROOT/scripts/app-deploy.sh" ${dry[@]+"${dry[@]}"} "$name"
    else
      log "à redéployer : scripts/app-deploy.sh $name"
    fi
  done
}

main "$@"
exit $?
