#!/usr/bin/env bash
# Met /opt à jour depuis le dépôt distant : git fetch + avance rapide (en réconciliant les commits
# locaux des déploiements automatiques), sous-modules, puis permissions et routes.
# C'est LE point d'entrée d'une mise à jour.
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat << 'EOF'
Usage : scripts/update.sh [--deploy] [--no-routes] [--force] [--dry-run] [-h]

Enchaîne : verrou du serveur -> contrôle de l'arbre git -> git fetch -> avance rapide sur la
branche amont -> git submodule sync/update -> résumé des commits reçus par chaque sous-module
-> fix-perms -> routes-sync -> réinstallation de /usr/local/sbin/opt-deploy (si le déploiement
automatique est installé). Ne redéploie AUCUNE app sans --deploy (sinon il indique quoi lancer).

Commits locaux (ceux de app-bump.sh à chaque déploiement automatique, jamais poussés) :
  - s'ils ne déplacent que des pointeurs apps/*, l'historique local est refait sur la branche
    amont, puis chaque sous-module est réaligné sur le plus récent des deux commits (déployé ou
    amont) ; l'ancien HEAD reste dans refs/opt-update/avant-<horodatage> ;
  - sinon (ou si les deux commits d'une app n'ont pas d'historique commun) : arrêt, code 4,
    rien n'est modifié (procédure : docs/runbook.md, « Mettre à jour depuis le dépôt »).

Options :
  --deploy      redéploie (app-deploy.sh) les apps dont le sous-module a changé
  --no-routes   ne lance pas routes-sync.sh
  --force       n'exige pas un arbre propre ni la branche main (jamais de fusion ni de rebase)
  --dry-run     affiche les commandes sans les exécuter (seul le git fetch est réellement fait)
  -h, --help    cette aide

Codes de sortie : 0 succès ; 1 erreur ; 2 usage ; 3 prérequis (pas de branche amont…) ;
                  4 arbre sale, mauvaise branche, ou commits locaux impossibles à réconcilier.
EOF
}

# submodule_head <chemin> : commit extrait du sous-module, « none » s'il n'est pas initialisé.
# (Sans le test de .git, « git -C » sur un dossier vide interrogerait le dépôt parent.)
submodule_head() {
  if [[ -e "$1/.git" ]]; then git -C "$1" rev-parse HEAD 2> /dev/null || echo none; else echo none; fi
}

# apps_bumps_only <plage> : vrai si les commits de la plage ne font que déplacer des pointeurs de
# sous-modules apps/<nom> (lignes « --raw » de la forme « :160000 160000 <a> <b> M<TAB>apps/<nom> »).
apps_bumps_only() {
  local line meta path
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    meta="${line%%$'\t'*}"
    path="${line#*$'\t'}"
    [[ "$meta" == ":160000 160000 "*" M" && "$path" =~ ^apps/[a-z0-9][a-z0-9-]*$ ]] || return 1
  done < <(git log --format= --raw --no-renames "$1")
}

# newest_commit <sous-module> <a> <b> : le plus récent des deux commits, si l'un descend de
# l'autre ; code 1 sinon (historiques sans lien, sous-module absent, commit introuvable).
newest_commit() {
  local path="$1" a="$2" b="$3" c
  [[ "$a" == "$b" ]] && {
    echo "$a"
    return 0
  }
  [[ -e "$path/.git" ]] || return 1
  for c in "$a" "$b"; do
    git -C "$path" cat-file -e "$c^{commit}" 2> /dev/null || git -C "$path" fetch --quiet origin || return 1
    git -C "$path" cat-file -e "$c^{commit}" 2> /dev/null || return 1
  done
  if git -C "$path" merge-base --is-ancestor "$a" "$b"; then
    echo "$b"
  elif git -C "$path" merge-base --is-ancestor "$b" "$a"; then
    echo "$a"
  else
    return 1
  fi
}

# sync_with_upstream : amène la branche courante sur sa branche amont, sans fusion ni rebase.
# Les commits locaux qui ne déplacent que des pointeurs apps/* (déploiements automatiques) sont
# réconciliés ; tout autre commit local arrête le script (code 4) avant toute modification.
sync_with_upstream() {
  local upstream behind ahead
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2> /dev/null)" \
    || die "la branche $(git rev-parse --abbrev-ref HEAD) n'a pas de branche amont (git branch -u origin/main)" 3
  # Fait même en --dry-run : ne touche qu'aux références distantes, et le plan en dépend.
  git fetch --quiet || die "git fetch impossible (réseau ? accès au dépôt ?)" 1
  read -r behind ahead < <(git rev-list --left-right --count "$upstream...HEAD")

  if [[ "$behind" -eq 0 ]]; then
    if [[ "$ahead" -gt 0 ]]; then
      log "rien à récupérer de $upstream ; $ahead commit(s) local(aux) non poussé(s) (déploiements)"
    else
      log "déjà à jour avec $upstream"
    fi
    return 0
  fi
  if [[ "$ahead" -eq 0 ]]; then
    run git merge --ff-only --quiet "$upstream"
    return 0
  fi

  # Historiques divergents : $ahead commit(s) local(aux), $behind sur la branche amont.
  log "$ahead commit(s) local(aux) absent(s) de $upstream, qui en a $behind de plus :"
  git log --format='    %h %s' "$upstream..HEAD"
  if ! apps_bumps_only "$upstream..HEAD"; then
    err "des commits locaux modifient autre chose que des pointeurs apps/* : réconciliation manuelle"
    die "rien n'a été modifié ; procédure : docs/runbook.md, « Mettre à jour depuis le dépôt »" 4
  fi
  if [[ -n "$(git status --porcelain)" ]]; then
    die "arbre git modifié : réconciliation impossible, rien n'a été modifié (commit ou stash d'abord)" 4
  fi

  # Pour chaque app déplacée localement : le plus récent entre le commit déployé et l'amont.
  local path deployed theirs keep
  local -a paths=() realign=()
  local -A keep_of=()
  mapfile -t paths < <(git log --format= --name-only --no-renames "$upstream..HEAD" | sort -u)
  for path in "${paths[@]}"; do
    [[ -n "$path" ]] || continue
    deployed="$(git rev-parse "HEAD:$path")"
    if ! theirs="$(git rev-parse --verify --quiet "$upstream:$path")"; then
      log "$path : retiré de $upstream, le pointeur local est abandonné"
      continue
    fi
    keep="$(newest_commit "$path" "$deployed" "$theirs")" \
      || die "$path : le commit déployé (${deployed:0:7}) et celui de $upstream (${theirs:0:7}) n'ont pas d'historique commun ; rien n'a été modifié, procédure : docs/runbook.md, « Mettre à jour depuis le dépôt »" 4
    if [[ "$keep" == "$theirs" ]]; then
      log "$path : $upstream (${theirs:0:7}) est à jour ou plus récent que le déployé (${deployed:0:7})"
    else
      log "$path : le déployé (${deployed:0:7}) est plus récent que $upstream (${theirs:0:7}), il est conservé"
      realign+=("$path")
      keep_of[$path]="$keep"
    fi
  done

  local backup
  backup="refs/opt-update/avant-$(stamp)"
  run git update-ref "$backup" HEAD
  log "ancien HEAD conservé : $backup ($(git rev-parse --short HEAD))"
  run git reset --quiet --keep "$upstream"
  for path in ${realign[@]+"${realign[@]}"}; do
    keep="${keep_of[$path]}"
    run git update-index --cacheinfo "160000,$keep,$path"
    run git commit -q -m "chore(apps): $(basename "$path") suit ${keep:0:7} (déploiement)"
  done
  log "historique local refait sur $upstream (${#realign[@]} pointeur(s) réaligné(s) sur le déployé)"
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
  # Pas de déploiement (git checkout / commit dans le même dépôt) pendant la mise à jour.
  acquire_lock

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
    before[$p]="$(submodule_head "$p")"
  done

  local head_before
  head_before="$(git rev-parse --short HEAD)"
  sync_with_upstream
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
    after="$(submodule_head "$p")"
    old="${before[$p]:-none}"
    [[ "$after" == "$old" ]] && continue
    changed+=("$p")
    if [[ "$old" == "none" ]]; then
      log "$p : nouveau sous-module (${after:0:7})"
    else
      log "$p : ${old:0:7} -> ${after:0:7}"
      git -C "$p" log --oneline "$old..$after" 2> /dev/null | sed 's/^/    /' || true
    fi
  done

  "$OPT_ROOT/scripts/fix-perms.sh" ${dry[@]+"${dry[@]}"}
  if [[ "$routes" == "1" ]]; then
    "$OPT_ROOT/scripts/routes-sync.sh" ${dry[@]+"${dry[@]}"}
  fi
  # opt-deploy est une copie hors dépôt : on la réaligne sur scripts/opt-deploy.sh, et le
  # sudoers sur la liste des apps (idempotent, ne touche pas aux clés).
  if id gh-deploy > /dev/null 2>&1; then
    "$OPT_ROOT/scripts/deploy-install.sh" ${dry[@]+"${dry[@]}"}
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
