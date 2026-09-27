#!/usr/bin/env bash
# Ajoute une app : sous-module git dans apps/<nom> (la racine du dépôt de l'app EST apps/<nom>,
# jamais apps/<nom>/<nom>), contrôle du contrat, .env, permissions et routes.
# Si le contrat n'est pas respecté, tout est annulé (aucun résidu dans git ni sur le disque).
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<'EOF'
Usage : scripts/app-add.sh [--branch BRANCHE] [--no-route] [--commit] [--dry-run] <nom> <url-git>

<nom>      minuscules, chiffres et tirets (devient le dossier, le projet compose et la route)
<url-git>  https://…, ssh://…, git@hôte:…  (file://… pour les tests)

Contrat de l'app (voir docs/add-a-service.md) : docker-compose.yml, Caddyfile, .env.example
à la racine de son dépôt, et un .gitignore qui ignore .env.

Options :
  --branch B   suit la branche B (défaut : branche par défaut du dépôt de l'app)
  --no-route   app sans site public : le Caddyfile n'est pas exigé
  --commit     commit local « feat(apps): ajoute <nom> » (jamais de push)
  --dry-run    affiche les étapes sans rien modifier
  -h, --help   cette aide

Codes de sortie : 0 succès ; 1 échec (annulé) ; 2 usage ; 3 prérequis ; 4 refus (déjà présent).
EOF
}

BRANCH=""
ROUTE=1
COMMIT=0
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)
      [[ $# -ge 2 ]] || usage_error "--branch attend une valeur"
      BRANCH="$2"
      shift 2
      ;;
    --no-route)
      ROUTE=0
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
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done
[[ ${#POSITIONAL[@]} -eq 2 ]] || usage_error "attendu : <nom> <url-git>"
NAME="${POSITIONAL[0]}"
URL="${POSITIONAL[1]}"

valid_name "$NAME" || usage_error "nom invalide « $NAME » (minuscules, chiffres, tirets)"
[[ "$NAME" != "proxy" ]] || usage_error "« proxy » est réservé"
[[ "$URL" =~ ^(https://|ssh://|git@|file://) ]] || usage_error "URL non reconnue : $URL"

require_repo
require_docker
cd "$OPT_ROOT"

REL="apps/$NAME"
[[ ! -e "$REL" ]] || die "$REL existe déjà" 4
[[ ! -e "services/$NAME" ]] || die "services/$NAME existe déjà : le nom est pris" 4
if [[ -f .gitmodules ]] && git config -f .gitmodules --get "submodule.$REL.path" >/dev/null 2>&1; then
  die "$REL est déjà déclaré dans .gitmodules" 4
fi

if [[ "$DRY_RUN" == "1" ]]; then
  log "git submodule add ${BRANCH:+-b $BRANCH }-- $URL $REL"
  log "contrôle du contrat, création de .env depuis .env.example, fix-perms, routes-sync"
  if [[ "$COMMIT" == "1" ]]; then log "puis commit local"; fi
  exit 0
fi

# rollback : ramène git et le disque à l'état d'avant, quoi qu'il se soit passé.
rollback() {
  warn "annulation de l'ajout de $NAME"
  git submodule deinit -f -- "$REL" >/dev/null 2>&1 || true
  git rm -f -q -- "$REL" >/dev/null 2>&1 || true
  rm -rf -- "$OPT_ROOT/.git/modules/$REL" "${OPT_ROOT:?}/$REL"
  if [[ -f .gitmodules && ! -s .gitmodules ]]; then git rm -f -q -- .gitmodules 2>/dev/null || true; fi
  "$OPT_ROOT/scripts/routes-sync.sh" --no-reload >/dev/null 2>&1 || true
}

args=(submodule add)
[[ -z "$BRANCH" ]] || args+=(-b "$BRANCH")
git "${args[@]}" -- "$URL" "$REL"

missing=()
for f in docker-compose.yml .env.example; do
  [[ -f "$REL/$f" ]] || missing+=("$f")
done
if [[ "$ROUTE" == "1" && ! -f "$REL/Caddyfile" ]]; then missing+=("Caddyfile"); fi
if [[ ${#missing[@]} -gt 0 ]]; then
  err "le dépôt de l'app ne respecte pas le contrat : manque ${missing[*]} (à la racine du dépôt)"
  rollback
  exit 1
fi

if ! (cd "$REL" && docker compose config -q >/dev/null 2>&1) \
  && ! (cd "$REL" && docker compose --env-file .env.example config -q >/dev/null 2>&1); then
  warn "docker compose config échoue même avec .env.example : à vérifier après avoir rempli .env"
fi

if [[ ! -f "$REL/.env" ]]; then
  (umask 077 && cp "$REL/.env.example" "$REL/.env")
  log ".env créé depuis .env.example : à compléter"
fi

# Un .env non ignoré rendrait le sous-module « modifié » en permanence (update.sh refuserait
# de tourner) et exposerait les secrets à un « git add » accidentel.
if ! git -C "$REL" check-ignore -q .env; then
  err "le .gitignore de l'app doit ignorer .env (contrat : docs/add-a-service.md)"
  rollback
  exit 1
fi

"$OPT_ROOT/scripts/fix-perms.sh"
if ! "$OPT_ROOT/scripts/routes-sync.sh" --no-reload; then
  err "le Caddyfile de l'app est invalide"
  rollback
  exit 1
fi

if [[ "$COMMIT" == "1" ]]; then
  git commit -q -m "feat(apps): ajoute $NAME" -- .gitmodules "$REL"
  log "commit créé (pas de push)"
fi

log "app $NAME ajoutée. Suite :"
log "  1. compléter $REL/.env"
log "  2. scripts/app-deploy.sh $NAME"
