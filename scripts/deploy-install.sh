#!/usr/bin/env bash
# Installe (ou met à jour) le système de déploiement automatique des apps. À lancer en root.
#
#   - compte gh-deploy : sans mot de passe, sans groupe docker, utilisé UNIQUEMENT par les
#     clés SSH des CI, chacune bridée à une seule commande ;
#   - /usr/local/sbin/opt-deploy : copie de scripts/opt-deploy.sh, root:root 0755, hors de tout
#     dépôt git (un déploiement ne peut pas réécrire ce qui tourne en root) ;
#   - /etc/sudoers.d/opt-deploy : gh-deploy peut lancer « opt-deploy <app> », app par app, rien
#     d'autre (régénéré à chaque exécution depuis apps/*, validé par visudo avant d'être posé).
#
# Idempotent : à relancer après une mise à jour de opt (update.sh le signale) ou l'ajout d'une app.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

readonly DEPLOY_USER=gh-deploy
readonly DEPLOY_HOME=/home/gh-deploy
readonly WRAPPER=/usr/local/sbin/opt-deploy
readonly SUDOERS=/etc/sudoers.d/opt-deploy
readonly TEMPLATE="$OPT_ROOT/scripts/opt-deploy.sh"

usage() {
  cat << 'EOF'
Usage : scripts/deploy-install.sh [--dry-run]
        scripts/deploy-install.sh --key <app> '<clé publique ssh-ed25519 …>'
        scripts/deploy-install.sh --revoke <app>
        scripts/deploy-install.sh --status

Sans option : crée le compte gh-deploy s'il manque, installe /usr/local/sbin/opt-deploy et
régénère /etc/sudoers.d/opt-deploy (une ligne par app de apps/).

  --key <app> <clé>   autorise une clé (celle de la CI de <app>) à lancer « opt-deploy <app> »
                      et rien d'autre ; remplace la clé précédente de cette app
  --revoke <app>      retire la clé de <app>
  --status            état de l'installation et des clés (lecture seule)
  --dry-run           affiche les commandes sans rien modifier
  -h, --help          cette aide

Codes de sortie : 0 succès ; 1 erreur ; 2 usage ; 3 prérequis (root, sudo, visudo…).
EOF
}

MODE=install
KEY_APP=""
KEY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --key)
      [[ $# -ge 3 ]] || usage_error "--key attend un nom d'app et une clé publique"
      MODE=key
      KEY_APP="$2"
      KEY="$3"
      shift 3
      ;;
    --revoke)
      [[ $# -ge 2 ]] || usage_error "--revoke attend un nom d'app"
      MODE=revoke
      KEY_APP="$2"
      shift 2
      ;;
    --status)
      MODE=status
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

# render_wrapper : le modèle avec le vrai chemin du dépôt opt.
render_wrapper() {
  sed "s|@OPT_ROOT@|$OPT_ROOT|" "$TEMPLATE"
}

# key_line <app> <clé> : ligne authorized_keys bridée à « opt-deploy <app> ».
key_line() {
  local app="$1" type blob
  read -r type blob _ <<< "$2"
  printf 'restrict,command="/usr/bin/sudo -n %s %s" %s %s opt-deploy:%s\n' \
    "$WRAPPER" "$app" "$type" "$blob" "$app"
}

check_app() {
  valid_name "$1" || usage_error "nom d'app invalide : $1"
  [[ -f "$APPS_DIR/$1/docker-compose.yml" ]] || die "app inconnue : apps/$1" 2
}

install_all() {
  require_root
  require_cmd visudo
  require_cmd sudo
  require_cmd flock
  [[ -f "$TEMPLATE" ]] || die "modèle introuvable : $TEMPLATE" 3

  # 1. Compte dédié : shell /bin/sh (requis pour exécuter la commande forcée), mot de passe
  #    verrouillé, aucun groupe privilégié.
  if id "$DEPLOY_USER" > /dev/null 2>&1; then
    log "compte $DEPLOY_USER : déjà présent"
  else
    run useradd --system --create-home --home-dir "$DEPLOY_HOME" --shell /bin/sh \
      --comment "Déploiements CI (clés SSH bridées à opt-deploy)" "$DEPLOY_USER"
    log "compte $DEPLOY_USER : créé"
  fi
  run passwd -q -l "$DEPLOY_USER" > /dev/null
  if id -nG "$DEPLOY_USER" 2> /dev/null | tr ' ' '\n' | grep -qxE 'docker|sudo|adm'; then
    warn "$DEPLOY_USER appartient à un groupe privilégié (docker/sudo/adm) : à retirer"
  fi
  run install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 700 "$DEPLOY_HOME/.ssh"
  [[ -f "$DEPLOY_HOME/.ssh/authorized_keys" ]] \
    || run install -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 600 /dev/null "$DEPLOY_HOME/.ssh/authorized_keys"

  # 2. Point d'entrée privilégié, hors dépôt git.
  local tmp
  tmp="$(mktemp)"
  render_wrapper > "$tmp"
  if [[ -f "$WRAPPER" ]] && cmp -s "$tmp" "$WRAPPER"; then
    log "$WRAPPER : à jour"
  else
    run install -o root -g root -m 0755 "$tmp" "$WRAPPER"
    log "$WRAPPER : installé"
  fi
  rm -f "$tmp"

  # 3. sudoers : une règle exacte par app (sans joker : aucun autre argument accepté).
  local app sudoers_tmp
  sudoers_tmp="$(mktemp)"
  {
    echo "# Généré par $OPT_ROOT/scripts/deploy-install.sh : ne pas modifier à la main."
    echo "# $DEPLOY_USER ne peut lancer que « opt-deploy <app> », pour les apps listées ici."
    echo "Defaults:$DEPLOY_USER !lecture, env_reset"
    while IFS= read -r app; do
      app="$(basename "$app")"
      valid_name "$app" || continue
      echo "$DEPLOY_USER ALL=(root) NOPASSWD: $WRAPPER $app"
    done < <(list_apps)
  } > "$sudoers_tmp"
  visudo -cqf "$sudoers_tmp" || die "règle sudoers générée invalide (non posée)" 1
  if [[ -f "$SUDOERS" ]] && cmp -s "$sudoers_tmp" "$SUDOERS"; then
    log "$SUDOERS : à jour"
  else
    run install -o root -g root -m 0440 "$sudoers_tmp" "$SUDOERS"
    log "$SUDOERS : $(grep -c NOPASSWD "$sudoers_tmp") app(s) autorisée(s)"
  fi
  rm -f "$sudoers_tmp"

  # 4. Journal des déploiements.
  [[ -f /var/log/opt-deploy.log ]] || run install -o root -g adm -m 0640 /dev/null /var/log/opt-deploy.log

  # 5. sshd : un AllowUsers/AllowGroups qui n'inclut pas gh-deploy bloquerait les CI.
  if command -v sshd > /dev/null 2>&1; then
    local allow
    allow="$(sshd -T 2> /dev/null | awk '$1=="allowusers"||$1=="allowgroups"{print}')"
    if [[ -n "$allow" ]] && ! grep -qw "$DEPLOY_USER" <<< "$allow"; then
      warn "sshd restreint les connexions ($allow) : y ajouter $DEPLOY_USER"
    fi
  fi
  log "suite : une clé par app avec scripts/deploy-install.sh --key <app> '<clé publique>'"
}

set_key() {
  require_root
  check_app "$KEY_APP"
  id "$DEPLOY_USER" > /dev/null 2>&1 || die "compte $DEPLOY_USER absent : lancer d'abord scripts/deploy-install.sh" 3
  local tmp file="$DEPLOY_HOME/.ssh/authorized_keys"
  tmp="$(mktemp)"
  printf '%s\n' "$KEY" > "$tmp"
  ssh-keygen -lf "$tmp" > /dev/null 2>&1 || {
    rm -f "$tmp"
    die "clé publique invalide (attendu : ssh-ed25519 AAAA…)" 2
  }
  [[ "$KEY" == ssh-ed25519\ * ]] || warn "clé non ed25519 : acceptée, mais ed25519 est recommandé"
  # La ligne précédente de cette app est remplacée (marqueur « opt-deploy:<app> » en fin de ligne).
  { grep -v " opt-deploy:$KEY_APP\$" "$file" 2> /dev/null || true; } > "$tmp"
  key_line "$KEY_APP" "$KEY" >> "$tmp"
  run install -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 600 "$tmp" "$file"
  rm -f "$tmp"
  log "clé de $KEY_APP : autorisée à lancer « opt-deploy $KEY_APP » uniquement"
}

revoke_key() {
  require_root
  valid_name "$KEY_APP" || usage_error "nom d'app invalide : $KEY_APP"
  local tmp file="$DEPLOY_HOME/.ssh/authorized_keys"
  [[ -f "$file" ]] || die "aucune clé installée" 1
  tmp="$(mktemp)"
  grep -v " opt-deploy:$KEY_APP\$" "$file" > "$tmp" || true
  run install -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 600 "$tmp" "$file"
  rm -f "$tmp"
  log "clé de $KEY_APP : retirée"
}

show_status() {
  local app
  if id "$DEPLOY_USER" > /dev/null 2>&1; then log "compte $DEPLOY_USER : présent"; else warn "compte $DEPLOY_USER : absent"; fi
  if [[ ! -f "$WRAPPER" ]]; then
    warn "$WRAPPER : absent (lancer scripts/deploy-install.sh)"
  elif render_wrapper | cmp -s - "$WRAPPER"; then
    log "$WRAPPER : à jour"
  else
    warn "$WRAPPER : différent de scripts/opt-deploy.sh (relancer scripts/deploy-install.sh)"
  fi
  while IFS= read -r app; do
    app="$(basename "$app")"
    local rule=non key=non
    if [[ -r "$SUDOERS" ]] && grep -q "NOPASSWD: $WRAPPER $app\$" "$SUDOERS"; then rule=oui; fi
    if [[ -r "$DEPLOY_HOME/.ssh/authorized_keys" ]] \
      && grep -q " opt-deploy:$app\$" "$DEPLOY_HOME/.ssh/authorized_keys"; then key=oui; fi
    log "$app : règle sudo $rule, clé CI $key"
  done < <(list_apps)
}

case "$MODE" in
  install) install_all ;;
  key) set_key ;;
  revoke) revoke_key ;;
  status) show_status ;;
esac
