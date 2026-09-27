# shellcheck shell=bash
# shellcheck disable=SC2034  # variables consommées par les scripts qui sourcent cette bibliothèque
# Bibliothèque commune des scripts de /opt. À SOURCER, jamais à exécuter.
#
# Codes de sortie communs à tous les scripts :
#   0  succès
#   1  erreur d'exécution
#   2  usage incorrect (option ou argument invalide)
#   3  prérequis manquant (commande, démon Docker, réseau…)
#   4  refus de sécurité (arbre git sale, confirmation refusée…)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "lib/common.sh se source, il ne s'exécute pas." >&2
  exit 2
fi

OPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly OPT_ROOT
readonly APPS_DIR="$OPT_ROOT/apps"
readonly SERVICES_DIR="$OPT_ROOT/services"
readonly PROXY_DIR="$OPT_ROOT/proxy"
readonly PROXY_SITES_DIR="$PROXY_DIR/sites"
readonly PROXY_COMPOSE="$PROXY_DIR/docker-compose.yml"
readonly BACKUP_ROOT_DEFAULT="/var/backups/vps-opt"

# Nom du réseau Docker partagé entre le proxy et les services exposés.
PROXY_NETWORK="${PROXY_NETWORK:-proxy}"

# Positionnés par les scripts selon leurs options.
DRY_RUN="${DRY_RUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"

# --- Journalisation --------------------------------------------------------

# En --dry-run, tout message d'action est préfixé pour ne jamais laisser croire qu'il a été fait.
log() {
  local prefix=""
  if [[ "$DRY_RUN" == "1" ]]; then prefix="(dry-run) "; fi
  printf '[%s] %s%s\n' "$(date +%H:%M:%S)" "$prefix" "$*"
}
warn() { printf '[%s] ATTENTION : %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
err() { printf '[%s] ERREUR : %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# die <message> [code]
die() {
  err "$1"
  exit "${2:-1}"
}

# --- Prérequis -------------------------------------------------------------

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "commande requise introuvable : $cmd" 3
  done
}

require_docker() {
  require_cmd docker
  docker compose version >/dev/null 2>&1 || die "« docker compose » (plugin v2) est requis" 3
  docker info >/dev/null 2>&1 || die "le démon Docker ne répond pas (droits du groupe docker ? service arrêté ?)" 3
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "ce script doit être exécuté en root (sudo)" 3
}

require_repo() {
  require_cmd git
  local top
  top="$(git -C "$OPT_ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$top" ]] || die "$OPT_ROOT n'est pas un dépôt git" 3
  [[ "$(cd "$top" && pwd -P)" == "$OPT_ROOT" ]] \
    || die "le dépôt git englobant est $top, attendu : $OPT_ROOT" 3
}

require_network() {
  docker network inspect "$PROXY_NETWORK" >/dev/null 2>&1 \
    || die "le réseau Docker « $PROXY_NETWORK » n'existe pas (scripts/network-create.sh)" 3
}

# --- Exécution -------------------------------------------------------------

# run <commande…> : exécute, ou affiche seulement en mode --dry-run.
run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

# confirm <question> : refuse (code 4) sans « oui », sauf --yes.
confirm() {
  [[ "$ASSUME_YES" == "1" || "$DRY_RUN" == "1" ]] && return 0
  [[ -t 0 ]] || die "confirmation requise mais l'entrée n'est pas interactive (utiliser --yes)" 4
  local answer
  read -r -p "$1 [oui/N] " answer
  [[ "$answer" == "oui" ]] || die "abandon (confirmation refusée)" 4
}

# --- Noms et découverte ----------------------------------------------------

# Un nom d'app/service devient un nom de dossier, de projet compose et de route.
valid_name() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]]
}

# Dossier d'une app ou d'un service par son nom ; vide si inconnu.
unit_dir() {
  local name="$1"
  if [[ -d "$APPS_DIR/$name" ]]; then
    echo "$APPS_DIR/$name"
  elif [[ -d "$SERVICES_DIR/$name" ]]; then
    echo "$SERVICES_DIR/$name"
  fi
}

# Dossiers (chemins absolus) des apps, puis des services, contenant un compose.
list_units() {
  local d
  for d in "$APPS_DIR"/*/ "$SERVICES_DIR"/*/; do
    [[ -f "${d}docker-compose.yml" ]] && printf '%s\n' "${d%/}"
  done
}

list_apps() {
  local d
  for d in "$APPS_DIR"/*/; do
    [[ -f "${d}docker-compose.yml" ]] && printf '%s\n' "${d%/}"
  done
}

# --- Divers ----------------------------------------------------------------

# Refuse les arguments inconnus de façon uniforme.
usage_error() {
  err "$1"
  usage >&2
  exit 2
}

# Horodatage stable pour les noms de fichiers.
stamp() { date +%Y%m%d-%H%M%S; }
