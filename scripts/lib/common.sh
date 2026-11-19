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

# Verrou du serveur, partagé par opt-deploy (chemin inscrit à l'installation, voir
# render_opt_deploy), update.sh, backup.sh, restore.sh, app-deploy.sh, app-bump.sh et
# routes-sync.sh : une seule opération à la fois touche aux apps, au dépôt et au proxy.
# Surchargeable pour les tests uniquement.
OPT_LOCK="${OPT_LOCK:-/run/lock/opt-deploy.lock}"
OPT_LOCK_TIMEOUT="${OPT_LOCK_TIMEOUT:-900}"

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
    command -v "$cmd" > /dev/null 2>&1 || die "commande requise introuvable : $cmd" 3
  done
}

require_docker() {
  require_cmd docker
  docker compose version > /dev/null 2>&1 || die "« docker compose » (plugin v2) est requis" 3
  docker info > /dev/null 2>&1 || die "le démon Docker ne répond pas (droits du groupe docker ? service arrêté ?)" 3
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "ce script doit être exécuté en root (sudo)" 3
}

require_repo() {
  require_cmd git
  local top
  top="$(git -C "$OPT_ROOT" rev-parse --show-toplevel 2> /dev/null || true)"
  [[ -n "$top" ]] || die "$OPT_ROOT n'est pas un dépôt git" 3
  [[ "$(cd "$top" && pwd -P)" == "$OPT_ROOT" ]] \
    || die "le dépôt git englobant est $top, attendu : $OPT_ROOT" 3
}

require_network() {
  docker network inspect "$PROXY_NETWORK" > /dev/null 2>&1 && return 0
  # En dry-run le réseau n'a pas été créé pour de vrai : on l'accepte, sans le taire.
  if [[ "$DRY_RUN" == "1" ]]; then
    warn "le réseau Docker « $PROXY_NETWORK » n'existe pas (normal en dry-run)"
    return 0
  fi
  die "le réseau Docker « $PROXY_NETWORK » n'existe pas (scripts/network-create.sh)" 3
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

# --- Verrou -----------------------------------------------------------------

# acquire_lock : prend le verrou exclusif du serveur sur le descripteur 9, pour toute la durée du
# script (libéré à sa sortie). Attend au plus OPT_LOCK_TIMEOUT secondes, puis échoue (code 1).
# Un script lancé par un autre qui détient déjà le verrou (opt-deploy -> app-deploy.sh,
# update.sh -> routes-sync.sh…) ne se bloque pas lui-même : il hérite du descripteur 9 ouvert
# sur le fichier du verrou, et flock sur ce descripteur hérité réussit aussitôt.
# Rien n'est verrouillé en --dry-run (rien n'est modifié).
acquire_lock() {
  [[ "$DRY_RUN" == "1" ]] && return 0
  require_cmd flock
  local target
  target="$(readlink -f "$OPT_LOCK" 2> /dev/null || echo "$OPT_LOCK")"
  if [[ "$(readlink /proc/self/fd/9 2> /dev/null)" == "$target" ]] && flock -n 9; then
    return 0
  fi
  # Fichier existant : ouvert sans O_CREAT. Dans /run/lock (répertoire « sticky »),
  # fs.protected_regular refuse même à root un O_CREAT sur le fichier d'un autre compte.
  if [[ -e "$OPT_LOCK" ]]; then
    exec 9< "$OPT_LOCK" || die "verrou illisible : $OPT_LOCK" 3
  else
    exec 9>> "$OPT_LOCK" || die "impossible de créer le verrou $OPT_LOCK (droits ?)" 3
  fi
  if ! flock -n 9; then
    log "une autre opération (déploiement, mise à jour, sauvegarde…) est en cours : attente du verrou (${OPT_LOCK_TIMEOUT}s au plus)"
    flock -w "$OPT_LOCK_TIMEOUT" 9 \
      || die "verrou $OPT_LOCK toujours pris après ${OPT_LOCK_TIMEOUT}s : réessayer plus tard (qui le tient : fuser -v $OPT_LOCK)" 1
    log "verrou obtenu"
  fi
}

# render_opt_deploy : le modèle scripts/opt-deploy.sh avec le chemin du dépôt et du verrou, tel
# qu'installé en /usr/local/sbin/opt-deploy (deploy-install.sh) et comparé (check.sh).
render_opt_deploy() {
  sed -e "s|@OPT_ROOT@|$OPT_ROOT|" -e "s|@OPT_LOCK@|$OPT_LOCK|" "$OPT_ROOT/scripts/opt-deploy.sh"
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
