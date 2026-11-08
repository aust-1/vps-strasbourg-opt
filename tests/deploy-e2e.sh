#!/usr/bin/env bash
# Test de bout en bout du déploiement automatique (opt-deploy, deploy-install, clés bridées),
# dans un conteneur Ubuntu jetable : sshd, sudo et git réels, Docker remplacé par des stubs.
#
# Depuis la racine du dépôt opt (Git Bash : préfixer par MSYS_NO_PATHCONV=1) :
#   docker run --rm -v "$PWD":/src:ro ubuntu:25.04 bash /src/tests/deploy-e2e.sh
# Dernière ligne attendue : « TOUT EST VERT ». Aucun effet hors du conteneur.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq openssh-server sudo git util-linux passwd >/dev/null
git config --global user.email t@t && git config --global user.name test
git config --global init.defaultBranch main

ok() { printf '  OK   %s\n' "$*"; }
ko() { printf '  ÉCHEC %s\n' "$*"; FAIL=1; }
FAIL=0

# --- /opt : copie du dépôt, app-deploy/app-bump remplacés par des stubs traçants -----------
mkdir -p /opt/apps /opt/services /opt/proxy && cp -a /src/scripts /opt/ && cd /opt
git init -q . 2>/dev/null || true
cat > /opt/scripts/app-deploy.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "STUB app-deploy $1 @ $(git -C /opt/apps/$1 rev-parse --short HEAD)" | tee -a /tmp/trace
EOF
cat > /opt/scripts/app-bump.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "STUB app-bump $*" | tee -a /tmp/trace
EOF
chmod 755 /opt/scripts/*.sh

# --- Deux apps : un dépôt « distant » nu + un clone dans /opt/apps ---------------------------
for app in demo autre; do
  git init -q --bare /srv/$app.git
  git clone -q /srv/$app.git /tmp/work-$app
  (cd /tmp/work-$app && printf 'services: {}\n' > docker-compose.yml && git add . && git commit -qm v1 && git push -q origin HEAD:main)
  git clone -q /srv/$app.git /opt/apps/$app
done

# --- Installation -------------------------------------------------------------------------
/opt/scripts/deploy-install.sh
[[ "$(stat -c '%U:%G %a' /usr/local/sbin/opt-deploy)" == "root:root 755" ]] && ok "wrapper root:root 755" || ko "droits du wrapper"
grep -q '/opt' /usr/local/sbin/opt-deploy && ! grep -q '@OPT_ROOT@' /usr/local/sbin/opt-deploy && ok "chemin opt rendu" || ko "rendu du modèle"
[[ "$(stat -c '%a' /etc/sudoers.d/opt-deploy)" == "440" ]] && ok "sudoers 440" || ko "droits sudoers"
id -nG gh-deploy | grep -qwE 'docker|sudo' && ko "gh-deploy dans un groupe privilégié" || ok "gh-deploy sans groupe privilégié"
passwd -S gh-deploy | grep -q ' L ' && ok "mot de passe verrouillé" || ko "mot de passe non verrouillé"
/opt/scripts/deploy-install.sh 2>&1 | tee /tmp/second | grep -c 'à jour' | grep -qx 2 && ok "réinstallation idempotente (wrapper et sudoers à jour)" || ko "idempotence"; cat /tmp/second

# --- Clé bridée ---------------------------------------------------------------------------
ssh-keygen -q -t ed25519 -N '' -f /tmp/ci-demo
/opt/scripts/deploy-install.sh --key demo "$(cat /tmp/ci-demo.pub)"
/opt/scripts/deploy-install.sh --key demo "$(cat /tmp/ci-demo.pub)"   # remplace, ne duplique pas
[[ "$(grep -c 'opt-deploy:demo' /home/gh-deploy/.ssh/authorized_keys)" == 1 ]] && ok "une seule ligne par app" || ko "doublon de clé"
/opt/scripts/deploy-install.sh --key demo "pas une clé" 2>/dev/null && ko "clé invalide acceptée" || ok "clé invalide refusée"

mkdir -p /run/sshd && /usr/sbin/sshd
ssh-keyscan -q -t ed25519 localhost > /tmp/known 2>/dev/null
SSH=(ssh -T -i /tmp/ci-demo -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/tmp/known gh-deploy@localhost)

# Nouveau commit sur le dépôt distant, puis déploiement par la CI.
(cd /tmp/work-demo && echo v2 > v2 && git add . && git commit -qm v2 && git push -q origin HEAD:main)
want="$(git -C /srv/demo.git rev-parse --short main)"
out="$("${SSH[@]}" 2>&1)" || true
grep -q "STUB app-deploy demo @ $want" /tmp/trace && ok "la CI déploie demo sur le dernier commit ($want)" || { ko "déploiement CI"; echo "$out"; }
grep -q "STUB app-bump --to $want demo" /tmp/trace && ok "app-bump appelé avec le commit déployé" || ko "app-bump"
grep -q "demo : déployé ($want)" /var/log/opt-deploy.log && ok "journal /var/log/opt-deploy.log" || ko "journal"

# La clé ne permet rien d'autre.
: > /tmp/trace
out="$("${SSH[@]}" 'id; cat /etc/shadow' 2>&1)" || true
grep -q 'uid=' <<< "$out" && ko "la clé exécute une commande arbitraire" || ok "commande arbitraire ignorée (commande forcée)"
"${SSH[@]}" -L 1234:localhost:22 -N 2>/dev/null & tunnel=$!; sleep 1
banner="$(timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/1234; head -c 4 <&3' 2>/dev/null || true)"
kill "$tunnel" 2>/dev/null || true
[[ "$banner" == "SSH-" ]] && ko "redirection de port utilisable" || ok "redirections interdites (restrict)"
su -s /bin/sh gh-deploy -c 'sudo -n /usr/local/sbin/opt-deploy autre' >/dev/null 2>&1 && ok "sudo : autre app autorisée par la règle" || ko "règle sudo de autre"
su -s /bin/sh gh-deploy -c 'sudo -n /bin/bash -c id' >/dev/null 2>&1 && ko "gh-deploy obtient un shell root" || ok "gh-deploy : pas de shell root"
su -s /bin/sh gh-deploy -c 'sudo -n /usr/local/sbin/opt-deploy "demo; id"' >/dev/null 2>&1 && ko "argument non prévu accepté" || ok "argument non prévu refusé par sudo"
su -s /bin/sh gh-deploy -c 'sudo -n /usr/local/sbin/opt-deploy demo extra' >/dev/null 2>&1 && ko "argument en trop accepté" || ok "argument en trop refusé"

# Le wrapper refuse les noms dangereux, même lancé par root.
/usr/local/sbin/opt-deploy '../etc' >/dev/null 2>&1 && ko "traversée de chemin" || ok "nom avec ../ refusé"
/usr/local/sbin/opt-deploy inconnue >/dev/null 2>&1 && ko "app inconnue acceptée" || ok "app inconnue refusée"

# Un correctif local sur le serveur n'est jamais écrasé.
echo hotfix >> /opt/apps/demo/docker-compose.yml
rc=0; /usr/local/sbin/opt-deploy demo >/dev/null 2>&1 || rc=$?
[[ "$rc" == 4 ]] && ok "modifications locales : refus (code 4)" || ko "modifications locales écrasées (code $rc)"
git -C /opt/apps/demo checkout -q -- docker-compose.yml

# Un push sur l'app ne peut pas modifier ce qui tourne en root.
(cd /tmp/work-demo && mkdir -p infra && printf '#!/bin/sh\necho PWNED\n' > infra/deploy.sh && git add . && git commit -qm pwn && git push -q origin HEAD:main)
"${SSH[@]}" >/dev/null 2>&1 || true
grep -q PWNED /tmp/trace /var/log/opt-deploy.log && ko "code de l'app exécuté hors Docker" || ok "le dépôt de l'app n'exécute rien en root hors Docker"

# Révocation.
/opt/scripts/deploy-install.sh --revoke demo
"${SSH[@]}" >/dev/null 2>&1 && ko "clé révoquée encore acceptée" || ok "clé révoquée refusée"

/opt/scripts/deploy-install.sh --status
echo; [[ "$FAIL" == 0 ]] && echo "TOUT EST VERT" || { echo "DES ÉCHECS"; exit 1; }
