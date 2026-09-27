#!/usr/bin/env bash
# Déploie (ou redéploie) une app, un service, ou le proxy avec docker compose, puis attend
# que tous ses conteneurs soient sains. Ne touche jamais au dépôt git (c'est update.sh).
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<'EOF'
Usage : scripts/app-deploy.sh [--no-pull] [--no-build] [--timeout SECONDES] [--dry-run] <nom>
        scripts/app-deploy.sh [options] --all

<nom> : nom d'un dossier de apps/ ou services/, ou « proxy ».
--all : proxy, puis chaque service, puis chaque app.

Étapes par unité : contrôle (.env, réseau, compose valide) -> pull des images ->
build (si le compose en définit) -> up -d --remove-orphans -> attente des healthchecks ->
routes-sync -> nettoyage des images orphelines.

Options :
  --no-pull        ne récupère pas les images distantes
  --no-build       ne reconstruit pas les images locales
  --timeout N      attente maximale des conteneurs sains, en secondes (défaut 120)
  --dry-run        affiche les commandes sans les exécuter
  -h, --help       cette aide

Codes de sortie : 0 succès ; 1 conteneur non sain ou erreur ; 2 usage ;
                  3 prérequis (Docker, réseau, .env manquant).
EOF
}

PULL=1
BUILD=1
TIMEOUT=120
ALL=0
TARGET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-pull)
      PULL=0
      shift
      ;;
    --no-build)
      BUILD=0
      shift
      ;;
    --timeout)
      [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || usage_error "--timeout attend un nombre de secondes"
      TIMEOUT="$2"
      shift 2
      ;;
    --all)
      ALL=1
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
      [[ -z "$TARGET" ]] || usage_error "un seul nom attendu (ou --all)"
      TARGET="$1"
      shift
      ;;
  esac
done
if [[ "$ALL" == "1" && -n "$TARGET" ]] || [[ "$ALL" == "0" && -z "$TARGET" ]]; then
  usage_error "indiquer un nom OU --all"
fi

# container_state <id> : « healthy » | « unhealthy » | « starting » | « running » | « exited:<code> » | …
container_state() {
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}:{{.State.ExitCode}}' "$1"
}

# wait_healthy <dossier> : attend que tous les conteneurs du projet soient sains.
wait_healthy() {
  local dir="$1" deadline=$((SECONDS + TIMEOUT)) pending id st code all_ok
  local -a ids=()
  while :; do
    mapfile -t ids < <(cd "$dir" && docker compose ps -a -q)
    [[ ${#ids[@]} -gt 0 ]] || die "aucun conteneur pour $(basename "$dir") après le démarrage"
    all_ok=1
    pending=""
    for id in "${ids[@]}"; do
      st="$(container_state "$id")"
      code="${st#*:}"
      st="${st%%:*}"
      case "$st" in
        healthy | running) ;;
        exited) [[ "$code" == "0" ]] || {
          all_ok=0
          pending+=" $(docker inspect -f '{{.Name}}' "$id")($st:$code)"
        } ;;
        *)
          all_ok=0
          pending+=" $(docker inspect -f '{{.Name}}' "$id")($st)"
          ;;
      esac
    done
    if [[ "$all_ok" == "1" ]]; then
      # Conteneurs sans healthcheck : « running » ne prouve rien tout de suite ; on revérifie
      # après quelques secondes pour attraper un plantage au démarrage (boucle de redémarrage).
      sleep 5
      for id in "${ids[@]}"; do
        st="$(container_state "$id")"
        [[ "${st%%:*}" =~ ^(healthy|running|exited)$ ]] || all_ok=0
      done
      [[ "$all_ok" == "1" ]] && return 0
    fi
    if ((SECONDS >= deadline)); then
      err "conteneurs non sains après ${TIMEOUT}s :$pending"
      (cd "$dir" && docker compose logs --tail=50) >&2 || true
      return 1
    fi
    sleep 2
  done
}

deploy_one() {
  local name="$1" dir
  if [[ "$name" == "proxy" ]]; then
    dir="$PROXY_DIR"
  else
    valid_name "$name" || die "nom invalide : $name" 2
    dir="$(unit_dir "$name")"
    [[ -n "$dir" ]] || die "ni apps/$name ni services/$name n'existe" 2
  fi
  [[ -f "$dir/docker-compose.yml" ]] || die "$dir/docker-compose.yml introuvable (sous-module non initialisé ? scripts/update.sh)" 3
  if [[ -f "$dir/.env.example" && ! -f "$dir/.env" ]]; then
    die "$dir/.env manquant : cp ${dir#"$OPT_ROOT"/}/.env.example ${dir#"$OPT_ROOT"/}/.env puis le compléter" 3
  fi

  log "=== déploiement de $name ==="
  (cd "$dir" && docker compose config -q) || die "compose invalide pour $name"

  if [[ "$PULL" == "1" ]]; then
    (cd "$dir" && run docker compose pull --ignore-buildable)
  fi
  # Pas de « docker compose config | grep -q » : grep quitte tôt, SIGPIPE + pipefail = faux négatif.
  local rendered
  rendered="$(cd "$dir" && docker compose config)"
  if [[ "$BUILD" == "1" ]] && grep -qE '^\s+build:' <<<"$rendered"; then
    (cd "$dir" && run docker compose build --pull)
  fi
  (cd "$dir" && run docker compose up -d --remove-orphans)

  if [[ "$DRY_RUN" == "1" ]]; then
    log "attente des conteneurs sains ignorée"
  else
    wait_healthy "$dir" || die "déploiement de $name en échec"
    log "$name : tous les conteneurs sont sains"
  fi
}

require_docker
require_network

declare -a TARGETS=()
if [[ "$ALL" == "1" ]]; then
  TARGETS+=(proxy)
  while IFS= read -r dir; do
    [[ "$dir" == "$SERVICES_DIR"/* ]] && TARGETS+=("$(basename "$dir")")
  done < <(list_units)
  while IFS= read -r dir; do
    TARGETS+=("$(basename "$dir")")
  done < <(list_apps)
else
  TARGETS+=("$TARGET")
fi

for t in "${TARGETS[@]}"; do
  deploy_one "$t"
done

# Les Caddyfile ont pu changer avec le code déployé : on republie les routes.
declare -a dry=()
if [[ "$DRY_RUN" == "1" ]]; then dry=(--dry-run); fi

if [[ "$ALL" == "1" || "$TARGET" != "proxy" ]]; then
  "$OPT_ROOT/scripts/routes-sync.sh" ${dry[@]+"${dry[@]}"}
fi

if [[ "$DRY_RUN" == "1" ]]; then
  run docker image prune -f
else
  docker image prune -f >/dev/null
fi
