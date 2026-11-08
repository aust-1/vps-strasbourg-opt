#!/usr/bin/env bash
# Point d'entrée UNIQUE et privilégié des déploiements automatiques (CI des apps).
#
# Ce fichier est un MODÈLE : scripts/deploy-install.sh l'installe en /usr/local/sbin/opt-deploy
# (root:root, 0755), hors de tout dépôt git. Un déploiement ne peut donc jamais réécrire le code
# qui s'exécute en root : seul root, en relançant deploy-install.sh, le met à jour.
#
# Appelé par le compte gh-deploy via une clé SSH bridée (authorized_keys : command="sudo -n
# /usr/local/sbin/opt-deploy <app>"), ou à la main : sudo opt-deploy <app>.
#
# Séquence fixe, sans option : validation du nom -> verrou -> refus si l'arbre de l'app est
# modifié -> fetch + checkout de origin/main -> scripts/app-deploy.sh <app> (build ou pull,
# démarrage, attente des healthchecks, routes) -> scripts/app-bump.sh (pointeur du sous-module).
#
# Codes de sortie : 0 succès ; 1 échec du déploiement ; 2 usage ; 3 installation ou prérequis ;
#                   4 refus de sécurité (modifications locales dans l'app).
set -euo pipefail
umask 022
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Remplacé à l'installation par le chemin réel du dépôt opt.
readonly OPT_ROOT="@OPT_ROOT@"
readonly LOG=/var/log/opt-deploy.log
readonly LOCK=/run/lock/opt-deploy.lock
readonly BRANCH=main

die() {
  printf 'opt-deploy : %s\n' "$1" >&2
  exit "${2:-1}"
}

[[ "$OPT_ROOT" != "@"* ]] || die "modèle non installé : utiliser scripts/deploy-install.sh" 3
[[ "$EUID" -eq 0 ]] || die "à lancer en root : sudo opt-deploy <app>" 3
[[ $# -eq 1 ]] || die "usage : opt-deploy <app>" 2

app="$1"
[[ "$app" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "nom d'app invalide" 2
dir="$OPT_ROOT/apps/$app"
[[ -e "$dir/.git" && -f "$dir/docker-compose.yml" ]] || die "app inconnue : $app" 2

# Un seul déploiement à la fois sur le serveur (routes et proxy sont partagés).
exec 9> "$LOCK"
flock -w 900 9 || die "un autre déploiement est toujours en cours" 1

exec > >(tee -a "$LOG") 2>&1
echo "== $(date -Is) $app : début (demandé par ${SUDO_USER:-root})"

cd "$dir"
# Ne jamais écraser un correctif fait à la main sur le serveur : on refuse, on ne devine pas.
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  git status --short --untracked-files=no
  die "$app a des modifications locales : les committer dans son dépôt ou les annuler" 4
fi

git fetch --quiet origin "$BRANCH"
git checkout --quiet --detach "origin/$BRANCH"
commit="$(git rev-parse --short HEAD)"
echo "-- $app : $(git log -1 --format='%h %s')"

"$OPT_ROOT/scripts/app-deploy.sh" "$app"

# Le dépôt opt enregistre le commit réellement déployé (commit local, jamais poussé).
"$OPT_ROOT/scripts/app-bump.sh" --to "$commit" "$app" \
  || echo "avertissement : pointeur du sous-module non aligné dans opt (scripts/app-bump.sh $app)"

echo "== $(date -Is) $app : déployé ($commit)"
