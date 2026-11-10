#!/usr/bin/env bash
# Envoie un email de test par services/smtp-relay, exactement comme le ferait un autre service
# (connexion SMTP authentifiée à smtp-relay:587 depuis le réseau proxy), puis lit dans les
# journaux de Postfix ce que le fournisseur en amont (Resend) a répondu.
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat << 'EOF'
Usage : scripts/mail-test.sh [--from ADRESSE] [--user COMPTE] [--timeout SECONDES] [--dry-run]
                             <destinataire>

Envoie un email de test à <destinataire> par le relais smtp-relay:587, puis attend son statut
dans les journaux de Postfix : « sent » = accepté par le fournisseur en amont.

Options :
  --from ADRESSE   expéditeur (défaut : noreply@eliott-roussille.fr) ; son domaine doit
                   figurer dans ALLOWED_SENDER_DOMAINS et être vérifié chez le fournisseur
  --user COMPTE    compte SMTP du relais à utiliser (défaut : le premier de SMTPD_SASL_USERS
                   dans services/smtp-relay/.env)
  --timeout N      attente maximale du statut, en secondes (défaut 30)
  --dry-run        affiche la commande d'envoi sans l'exécuter
  -h, --help       cette aide

Codes de sortie : 0 accepté par le fournisseur ; 1 refusé, différé ou statut inconnu ;
                  2 usage ; 3 prérequis (Docker, réseau, relais arrêté).
EOF
}

FROM="noreply@eliott-roussille.fr"
TIMEOUT=30
TO=""
USER_NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)
      [[ $# -ge 2 && "$2" == *@* ]] || usage_error "--from attend une adresse email"
      FROM="$2"
      shift 2
      ;;
    --user)
      [[ $# -ge 2 && -n "$2" ]] || usage_error "--user attend un nom de compte"
      USER_NAME="$2"
      shift 2
      ;;
    --timeout)
      [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || usage_error "--timeout attend un nombre de secondes"
      TIMEOUT="$2"
      shift 2
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
      [[ -z "$TO" ]] || usage_error "un seul destinataire attendu"
      TO="$1"
      shift
      ;;
  esac
done
[[ "$TO" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] || usage_error "destinataire manquant ou invalide"

readonly RELAY_DIR="$SERVICES_DIR/smtp-relay"
readonly RELAY_ADDR="smtp-relay:587"

require_docker
require_network
[[ -f "$RELAY_DIR/.env" ]] || die "services/smtp-relay/.env manquant (voir docs/runbook.md, « Envoi d'emails »)" 3

# Compte SMTP : lu dans .env sans le sourcer (jamais exécuter un fichier de secrets).
accounts="$(sed -n 's/^SMTPD_SASL_USERS=//p' "$RELAY_DIR/.env" | tail -n 1)"
accounts="${accounts%\"}"
accounts="${accounts#\"}"
PASSWORD=""
IFS=',' read -r -a entries <<< "$accounts"
for entry in ${entries[@]+"${entries[@]}"}; do
  if [[ -z "$USER_NAME" || "${entry%%:*}" == "$USER_NAME" ]]; then
    USER_NAME="${entry%%:*}"
    PASSWORD="${entry#*:}"
    break
  fi
done
[[ -n "$USER_NAME" && -n "$PASSWORD" && "$PASSWORD" != "$USER_NAME" ]] \
  || die "compte ${USER_NAME:-?} introuvable ou sans mot de passe dans SMTPD_SASL_USERS (services/smtp-relay/.env)" 3

relay_id="$(cd "$RELAY_DIR" && docker compose ps -q postfix)"
if [[ -z "$relay_id" ]]; then
  [[ "$DRY_RUN" == "1" ]] || die "le relais ne tourne pas : scripts/app-deploy.sh smtp-relay" 3
  warn "le relais ne tourne pas (normal en dry-run)"
elif [[ "$(docker inspect -f '{{.State.Health.Status}}' "$relay_id")" != "healthy" ]]; then
  warn "le relais n'est pas « healthy » : l'envoi risque d'échouer"
fi

# Même image que le relais (déjà présente) : son busybox fournit un client SMTP minimal.
IMAGE="$(cd "$RELAY_DIR" && docker compose config --images | head -n 1)"
[[ -n "$IMAGE" ]] || die "image du relais introuvable dans services/smtp-relay/docker-compose.yml"

MESSAGE="From: VPS <$FROM>
To: <$TO>
Subject: Test du relais SMTP ($(hostname))
Date: $(date -R)
Message-ID: <$(stamp).$$@${FROM#*@}>
Content-Type: text/plain; charset=UTF-8

Email de test envoyé par scripts/mail-test.sh depuis $(hostname), via $RELAY_ADDR.
Si tu le lis, le relais et le domaine expéditeur fonctionnent."

# Identifiants transmis par l'entrée standard (deux premières lignes), jamais en argument :
# ils seraient visibles dans « ps » sur l'hôte. Le client busybox les lit sur le descripteur 4.
# shellcheck disable=SC2016 # $1, $2 et $u/$p sont développés par le sh du conteneur
readonly CLIENT='read -r u; read -r p; printf "%s\n%s\n" "$u" "$p" > /tmp/auth
exec busybox sendmail -amLOGIN -S "$0" -f "$1" "$2" 4< /tmp/auth'
declare -a SEND=(docker run --rm -i --network "$PROXY_NETWORK" --entrypoint sh "$IMAGE"
  -c "$CLIENT" "$RELAY_ADDR" "$FROM" "$TO")

if [[ "$DRY_RUN" == "1" ]]; then
  run "${SEND[@]}"
  exit 0
fi

since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "envoi de $FROM à $TO par $RELAY_ADDR (compte $USER_NAME)"
printf '%s\n%s\n%s\n' "$USER_NAME" "$PASSWORD" "$MESSAGE" | "${SEND[@]}" \
  || die "le relais a refusé le message (compte, mot de passe, ou expéditeur hors de ALLOWED_SENDER_DOMAINS ?)"

# Le client busybox sort en 0 même quand le relais refuse un destinataire : seuls les journaux
# de Postfix font foi (refus du relais, puis réponse du fournisseur).
deadline=$((SECONDS + TIMEOUT))
while :; do
  line="$(cd "$RELAY_DIR" && docker compose logs --no-log-prefix --since "$since" postfix 2>&1 \
    | grep -F "to=<$TO>" | grep -E 'NOQUEUE: reject|status=(sent|deferred|bounced)' | tail -n 1 || true)"
  case "$line" in
    *"NOQUEUE: reject"*) die "refusé par le relais : $(sed -E 's/.*NOQUEUE: reject: RCPT from [^:]+: //; s/; from=.*//' <<< "$line")" ;;
    *status=sent*)
      log "accepté par le fournisseur : ${line#*status=}"
      exit 0
      ;;
    *status=bounced*) die "refusé par le fournisseur : ${line#*status=}" ;;
    *status=deferred*) die "différé (resté dans la file du relais) : ${line#*status=}" ;;
  esac
  ((SECONDS < deadline)) || die "aucun statut après ${TIMEOUT}s : cd services/smtp-relay && docker compose logs postfix"
  sleep 2
done
