#!/usr/bin/env bash
# Bascule Traefik -> Caddy, sur le VPS. À lancer depuis le NOUVEAU /opt (ce dépôt, déjà cloné et
# bootstrappé : scripts/bootstrap.sh, avec les .env remplis), l'ANCIEN /opt étant conservé de côté
# (convention : /opt.old, voir docs/migration.md) SANS y toucher au préalable.
#
# Étapes (par défaut) : sauvegarde de TOUS les volumes Docker existants -> arrêt de l'ancienne
# pile (trouvée sous --old-opt) -> réseau proxy -> démarrage de la nouvelle pile -> vérification
# des domaines. Le retour arrière (--rollback) arrête la nouvelle pile et relance l'ancienne,
# telle quelle (rien n'est supprimé par ce script : ni images, ni volumes, ni --old-opt).
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat << 'EOF'
Usage : scripts/migrate-traefik-to-caddy.sh [--old-opt CHEMIN] [--skip-backup] [--yes] [--dry-run]
        scripts/migrate-traefik-to-caddy.sh --rollback [--old-opt CHEMIN] [--yes] [--dry-run]

Options :
  --old-opt CHEMIN  ancien /opt, non touché par la bascule (défaut : /opt.old)
  --skip-backup     saute la sauvegarde des volumes avant la bascule (déconseillé)
  --rollback        arrête la nouvelle pile et relance l'ancienne (aucune suppression)
  --yes             ne demande pas de confirmation
  --dry-run         affiche les étapes sans rien modifier
  -h, --help        cette aide

Codes de sortie : 0 succès ; 1 échec d'une étape ; 2 usage ; 3 prérequis ;
                  4 --old-opt introuvable ou confirmation refusée.
EOF
}

OLD_OPT="/opt.old"
SKIP_BACKUP=0
ROLLBACK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --old-opt)
      [[ $# -ge 2 ]] || usage_error "--old-opt attend un chemin"
      OLD_OPT="$2"
      shift 2
      ;;
    --skip-backup)
      SKIP_BACKUP=1
      shift
      ;;
    --rollback)
      ROLLBACK=1
      shift
      ;;
    --yes)
      ASSUME_YES=1
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

require_repo
require_docker
cd "$OPT_ROOT"
[[ -d "$OLD_OPT" ]] || die "--old-opt introuvable : $OLD_OPT" 4
[[ -f "$OLD_OPT/traefik/docker-compose.yml" || -f "$OLD_OPT/legacy/traefik/docker-compose.yml" ]] \
  || warn "$OLD_OPT ne contient pas de traefik/docker-compose.yml : est-ce bien l'ancien /opt ?"

# compose_dirs <racine> : chemins des dossiers contenant un docker-compose.yml, sous <racine>.
compose_dirs() {
  find "$1" -mindepth 1 -maxdepth 3 -name docker-compose.yml -exec dirname {} \; | sort
}

stack_down() {
  local root="$1" dir
  while IFS= read -r dir; do
    [[ -n "$(cd "$dir" && docker compose ps -q 2> /dev/null)" ]] || continue
    log "arrêt : $dir"
    (cd "$dir" && run docker compose down --remove-orphans)
  done < <(compose_dirs "$root")
}

stack_up() {
  local root="$1" dir
  while IFS= read -r dir; do
    [[ -f "$dir/.env" || ! -f "$dir/.env.example" ]] || {
      warn "$dir/.env manquant : ignoré"
      continue
    }
    log "démarrage : $dir"
    (cd "$dir" && run docker compose up -d --remove-orphans)
  done < <(compose_dirs "$root")
}

# project_name <dossier> : nom de projet compose (clé « name: » du compose).
project_name() {
  (cd "$1" && docker compose config 2> /dev/null | awk '/^name:/ {print $2; exit}')
}

# migration_volumes : volumes des projets concernés (ancienne ET nouvelle pile) uniquement —
# jamais « docker volume ls » brut, qui embarquerait aussi des volumes d'autres projets du même hôte.
migration_volumes() {
  local dir proj
  while IFS= read -r dir; do
    proj="$(project_name "$dir")"
    [[ -n "$proj" ]] || continue
    docker volume ls -q --filter "label=com.docker.compose.project=$proj"
  done < <(
    compose_dirs "$OLD_OPT"
    compose_dirs "$OPT_ROOT"
  ) | sort -u
}

backup_migration_volumes() {
  local dest v
  dest="$OPT_ROOT/backups/pre-migration-$(stamp)"
  run mkdir -p "$dest"
  run chmod 700 "$OPT_ROOT/backups" "$dest"
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    log "sauvegarde du volume $v"
    run docker run --rm -v "$v":/data:ro -v "$dest":/out alpine:3 tar czf "/out/$v.tar.gz" -C /data .
  done < <(migration_volumes)
  log "sauvegarde : $dest"
}

# wait_domain_ok <hôte> : jusqu'à 90s. Au démarrage, Caddy obtient ses certificats ACME pour
# tous les domaines déclarés (une dizaine de secondes chacun, en série) : un premier essai
# immédiatement après app-deploy.sh tomberait souvent dans cette fenêtre et donnerait une
# fausse alerte (code 000, alors que tout finit par fonctionner quelques secondes plus tard).
wait_domain_ok() {
  local host="$1" deadline=$((SECONDS + 90)) code
  while :; do
    # curl écrit %{http_code} même en cas d'échec (souvent « 000 ») ; le premier || garde
    # l'affectation à un code de sortie 0 (set -e ferait sinon échouer tout le script sur un
    # simple 000, alors que c'est justement le cas que cette boucle doit gérer, pas subir) ;
    # le second couvre les rares cas où rien n'est écrit du tout (échec de résolution DNS).
    code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 10 "https://$host/" 2>/dev/null || true)"
    [[ -n "$code" ]] || code="000"
    [[ "$code" =~ ^(2|3) ]] && {
      echo "$code"
      return 0
    }
    ((SECONDS >= deadline)) && {
      echo "$code"
      return 1
    }
    sleep 3
  done
}

# domains_to_check : chaque nom d'hôte de chaque bloc de site des Caddyfile assemblés.
# (pas seulement la première ligne : un Caddyfile peut commencer par un commentaire, ou
# déclarer plusieurs domaines dans un même bloc, ex. « www -> apex » de portfolio.)
domains_to_check() {
  local f
  for f in "$PROXY_SITES_DIR"/*.caddy; do
    [[ -e "$f" ]] || continue
    # en-tête de bloc de site : en colonne 0, hors commentaire, se terminant par « { »
    grep -E '^[^[:space:]#].*\{[[:space:]]*$' "$f" \
      | sed -E 's/[[:space:]]*\{[[:space:]]*$//' \
      | tr ',' '\n' \
      | awk '{for (i = 1; i <= NF; i++) print $i}'
  done
}

if [[ "$ROLLBACK" == "1" ]]; then
  confirm "Revenir à l'ancienne pile (Traefik) depuis $OLD_OPT ?"
  log "=== arrêt de la nouvelle pile ==="
  stack_down "$OPT_ROOT"
  log "=== redémarrage de l'ancienne pile ==="
  stack_up "$OLD_OPT"
  log "retour arrière effectué. Vérifier : docker ps, puis les domaines habituels."
  exit 0
fi

log "=== bascule Traefik -> Caddy ==="
log "ancien /opt : $OLD_OPT"
confirm "Sauvegarder les volumes, arrêter Traefik et l'ancienne pile, puis démarrer Caddy et les apps ?"

if [[ "$SKIP_BACKUP" == "1" ]]; then
  warn "sauvegarde sautée (--skip-backup)"
else
  log "=== 1/4 sauvegarde des volumes de l'ancienne et de la nouvelle pile ==="
  backup_migration_volumes
fi

log "=== 2/4 arrêt de l'ancienne pile ==="
stack_down "$OLD_OPT"

log "=== 3/4 réseau et démarrage de la nouvelle pile ==="
declare -a dry=()
if [[ "$DRY_RUN" == "1" ]]; then dry=(--dry-run); fi
"$OPT_ROOT/scripts/network-create.sh" ${dry[@]+"${dry[@]}"}
"$OPT_ROOT/scripts/app-deploy.sh" --all ${dry[@]+"${dry[@]}"}

log "=== 4/4 vérification des domaines ==="
if [[ "$DRY_RUN" == "1" ]]; then
  log "(dry-run) vérification sautée"
else
  fail=0
  while IFS= read -r host; do
    [[ -n "$host" ]] || continue
    if code="$(wait_domain_ok "$host")"; then
      log "$host : $code"
    else
      err "$host : $code après 90s (certificat pas encore émis ? DNS pas encore propagé ?)"
      fail=1
    fi
  done < <(domains_to_check)
  if [[ "$fail" == "1" ]]; then
    warn "au moins un domaine ne répond pas. Diagnostiquer (docker logs caddy, scripts/status.sh)"
    warn "avant de considérer la bascule terminée. Retour arrière : $0 --rollback --old-opt $OLD_OPT"
  else
    log "tous les domaines répondent"
  fi
fi

log "l'ancienne pile (« $OLD_OPT ») n'a pas été supprimée : à retirer une fois la bascule validée"
log "(voir docs/migration.md, section « nettoyage final »)"
