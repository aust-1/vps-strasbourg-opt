# Mise en production (VPS neuf)

Prérequis : Debian/Ubuntu, Docker installé (`curl -fsSL https://get.docker.com | sh`), les DNS
des domaines pointant déjà vers le VPS.

## 1. Cloner le dépôt

**Directement dans `/opt`, sans sous-dossier supplémentaire** — le dépôt EST `/opt`, pas un
dossier à l'intérieur :

```bash
git clone --recurse-submodules https://github.com/aust-1/vps-strasbourg-opt.git /opt
cd /opt
```

(`--recurse-submodules` évite un `git submodule update --init` séparé ; `scripts/bootstrap.sh`
le referait de toute façon si oublié.)

## 2. Bootstrap

```bash
scripts/bootstrap.sh
```

Enchaîne : prérequis → réseau `proxy` → sous-modules → crée les `.env` manquants (depuis leurs
`.env.example`) → permissions → `scripts/check.sh` → routes → démarre le proxy → `status.sh`.
S'arrête avant de rien démarrer si `check.sh` échoue.

## 3. Compléter les secrets

```bash
nano apps/bourse-tracker/.env       # Supabase, Resend, Healthchecks…
nano services/uptime-kuma/.env      # rien de requis par défaut
nano services/rybbit/.env           # URL + secrets (openssl rand -hex 32) ; voir docs/runbook.md
# … une app par une app, selon ce que scripts/bootstrap.sh a signalé comme « à compléter »
```

## 4. Démarrer tout

```bash
scripts/app-deploy.sh --all
scripts/status.sh                   # tout doit être vert
```

Ouvrir chacun des domaines dans un navigateur : le certificat est émis par Caddy à la première
requête, ce qui peut prendre quelques secondes.

## 5. Sauvegardes

```bash
crontab -e
```

```cron
30 2 * * *  cd /opt && scripts/backup.sh --stop >> /var/log/vps-opt-backup.log 2>&1
```

Chaque app avec des données externes garde sa propre sauvegarde en plus (ex.
`apps/bourse-tracker/infra/backup.sh`, voir son propre `docs/DEPLOY.md`).

## 6. Déploiement automatique par app (optionnel)

```bash
scripts/deploy-install.sh                                 # compte gh-deploy, opt-deploy, sudoers
scripts/deploy-install.sh --key <app> 'ssh-ed25519 …'      # une clé dédiée par app
```

Puis, dans chaque dépôt d'app, les secrets `VPS_HOST`, `VPS_SSH_KEY` et `VPS_KNOWN_HOSTS` et le
workflow `deploy.yml` décrits dans `docs/ci-deploy.md`. Après un déploiement automatique,
`scripts/status.sh` doit rester vert ; l'historique est dans `/var/log/opt-deploy.log`.

## 7. Durcissement de l'hôte

Le port 22 reste ouvert à tout Internet, et le compte `gh-deploy` y est joignable : la
configuration SSH par défaut de la distribution ne suffit pas. Les commandes ci-dessous se lancent
en root (ou avec `sudo`), sur un VPS neuf comme sur un serveur déjà en service.

> **Avant de toucher à SSH** : garder la session courante ouverte jusqu'au bout, et ne la fermer
> qu'après avoir ouvert une **nouvelle** session SSH qui fonctionne, depuis un autre terminal.
> Une erreur dans la configuration de `sshd` ou dans `AllowUsers` coupe tout accès : il ne reste
> alors que la console de secours de l'hébergeur.

### Pare-feu

```bash
ufw allow 22,80,443/tcp && ufw enable
```

**Docker contourne `ufw`** pour les ports publiés : il écrit ses propres règles iptables, évaluées
avant celles d'`ufw`, si bien qu'un `ports:` dans un compose est joignable depuis Internet même
si `ufw` ne l'autorise pas (c'est aussi pour cela que le 443/udp de HTTP/3 passe sans règle).
D'où la règle « aucun port publié hors du proxy » (contrat, voir `docs/add-a-service.md`), que
`scripts/check.sh` fait échouer dès qu'une app ou un service publie un port. `ufw` ne protège
donc réellement que les services de l'hôte lui-même, c'est-à-dire `sshd` sur le port 22 ; tout le
reste passe par Caddy sur 80/443.

### SSH : clés uniquement, comptes limités

Prérequis : un compte d'administration personnel (noté `<admin>` ci-dessous) membre du groupe
`sudo`, qui se connecte déjà **par clé**. Le vérifier avant d'aller plus loin :
`ssh <admin>@<vps>` sans mot de passe, puis `sudo -v`.

```bash
cat > /etc/ssh/sshd_config.d/10-durcissement.conf << 'EOF'
# Clés SSH uniquement : ni mot de passe, ni clavier interactif.
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
# Pas de connexion directe en root : on passe par <admin> puis sudo.
PermitRootLogin no
# Seuls ces comptes peuvent se connecter. gh-deploy : clés des CI (docs/ci-deploy.md).
AllowUsers <admin> gh-deploy
MaxAuthTries 3
X11Forwarding no
EOF
chmod 644 /etc/ssh/sshd_config.d/10-durcissement.conf
sshd -t                                     # aucune sortie = configuration valide
sshd -T | grep -E 'passwordauthentication|kbdinteractiveauthentication|permitrootlogin|allowusers'
systemctl reload ssh
```

- `sshd` garde la **première** valeur lue pour chaque option, et lit `sshd_config.d/*.conf` par
  ordre alphabétique : le préfixe `10-` passe donc avant un éventuel `50-cloud-init.conf` qui
  réactiverait `PasswordAuthentication yes`. C'est `sshd -T` qui fait foi : il doit afficher
  `passwordauthentication no`, `kbdinteractiveauthentication no`, `permitrootlogin no` et
  `allowusers <admin>` puis `allowusers gh-deploy`.
- Si l'administration se fait en root par clé, sans compte personnel : `PermitRootLogin
  prohibit-password` à la place de `no`, et `root` à la place de `<admin>` dans `AllowUsers`.
- Sans le déploiement automatique (section 6), retirer `gh-deploy` d'`AllowUsers`. S'il est
  installé plus tard, `scripts/deploy-install.sh` signale un `AllowUsers`/`AllowGroups` qui
  l'oublierait.

Vérifier depuis un **autre** terminal, la session courante toujours ouverte :

```bash
ssh <admin>@<vps>                                                       # doit fonctionner
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password <admin>@<vps>
# doit échouer : « Permission denied (publickey) »
```

Puis relancer le dernier workflow de déploiement d'une app depuis GitHub (Re-run) pour vérifier
que la clé de la CI passe toujours.

### Force brute : fail2ban

```bash
apt install -y fail2ban python3-systemd
cat > /etc/fail2ban/jail.d/sshd.local << 'EOF'
[sshd]
enabled  = true
# Journal systemd : Debian 12 n'écrit plus /var/log/auth.log par défaut.
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
systemctl enable fail2ban
systemctl restart fail2ban
fail2ban-client status sshd                 # prison active, adresses bannies
```

Les CI s'authentifient par clé du premier coup : elles ne sont jamais bannies. Débannir une
adresse (la sienne, après des essais ratés) : `fail2ban-client set sshd unbanip <ip>`, depuis une
autre connexion ou la console de l'hébergeur.

### Mises à jour de sécurité automatiques

```bash
apt install -y unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
unattended-upgrade --dry-run --debug 2>&1 | tail -n 20    # paquets qui seraient mis à jour
```

La configuration fournie (`/etc/apt/apt.conf.d/50unattended-upgrades`) n'installe que les mises
à jour de sécurité de la distribution. Docker, installé depuis le dépôt de Docker, n'en fait pas
partie : le mettre à jour à la main (`apt upgrade`), puis `scripts/status.sh`.

Une mise à jour du noyau ou de la libc ne prend effet qu'au redémarrage : `/var/run/reboot-required`
existe alors (détail dans `/var/run/reboot-required.pkgs`). Deux choix :

- redémarrer à la main au moment voulu (`reboot`), puis `scripts/status.sh` ; les conteneurs
  repartent seuls (`restart: unless-stopped`, service Docker activé au démarrage) ;
- ou laisser `unattended-upgrades` redémarrer seul, après la sauvegarde de 02:30 :

  ```bash
  cat > /etc/apt/apt.conf.d/52reboot << 'EOF'
  Unattended-Upgrade::Automatic-Reboot "true";
  Unattended-Upgrade::Automatic-Reboot-Time "04:30";
  EOF
  ```

## Ajouter une app supplémentaire plus tard

Voir `docs/add-a-service.md`.
