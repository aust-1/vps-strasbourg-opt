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

## 5. Sauvegardes et supervision

### Sondes « push » dans Uptime Kuma

Une sauvegarde ratée ou un conteneur malsain doit déclencher une alerte, pas seulement une ligne
dans un journal. `scripts/backup.sh` et `scripts/status.sh` préviennent chacun une sonde « push »
d'Uptime Kuma : « up » quand tout va bien, « down » avec la raison sinon, et Uptime Kuma alerte
aussi quand la sonde ne reçoit plus rien (cron arrêté, serveur figé). L'appel part de l'hôte
(`curl`) vers l'URL publique d'Uptime Kuma : il ne dépend pas du réseau des conteneurs.

Dans Uptime Kuma (<https://uptime.eliott-roussille.fr>), **Ajouter une sonde**, deux fois :

| Réglage                         | Sauvegarde nocturne              | État du serveur (`status.sh`)    |
| ------------------------------- | -------------------------------- | -------------------------------- |
| Type de sonde                   | Push                             | Push                             |
| Nom                             | `VPS : sauvegarde nocturne`      | `VPS : status.sh`                |
| Intervalle de pulsation         | `90000` s (25 h : une par nuit, plus une heure de marge pour la durée de la sauvegarde) | `1200` s (20 min, pour un passage toutes les 15 min) |
| Nouvelles tentatives            | `0`                              | `1` (une exécution manquée ne suffit pas à alerter) |
| Notifications                   | l'email du relais SMTP (`docs/runbook.md`, « Envoi d'emails ») | idem |

Enregistrer, puis copier l'**URL push** de chaque sonde (de la forme
`https://uptime.eliott-roussille.fr/api/push/<jeton>?status=up&msg=OK&ping=`). Le jeton suffit à
faire passer une sonde au vert : il reste hors du dépôt, dans un fichier lisible par root seul :

```bash
install -d -m 700 /etc/vps-opt
install -m 600 /dev/null /etc/vps-opt/monitoring.env
nano /etc/vps-opt/monitoring.env
```

```ini
# Sondes push Uptime Kuma (URL copiées telles quelles ; la partie « ?status=… » est remplacée)
BACKUP_PING_URL=https://uptime.eliott-roussille.fr/api/push/<jeton-sauvegarde>?status=up&msg=OK&ping=
STATUS_PING_URL=https://uptime.eliott-roussille.fr/api/push/<jeton-status>?status=up&msg=OK&ping=
```

Sans ce fichier (ou avec une variable vide), les deux scripts tournent comme avant, sans sonde.
`--ping-url <URL>` remplace la variable pour un essai à la main. Un envoi qui échoue n'est qu'un
avertissement dans la sortie : il ne change pas le code de retour du script.

### Cron

```bash
crontab -e      # en root
```

```cron
30 2 * * *    cd /opt && scripts/backup.sh --stop >> /var/log/vps-opt-backup.log 2>&1
*/15 * * * *  cd /opt && scripts/status.sh > /var/log/vps-opt-status.log 2>&1
```

`status.sh` réécrit son journal à chaque passage (`>`) : `/var/log/vps-opt-status.log` montre
toujours le dernier état. Vérifier une première fois à la main : `scripts/status.sh` puis
`scripts/backup.sh --stop`, et les deux sondes doivent passer au vert dans Uptime Kuma.

Limite : Uptime Kuma tourne sur le même VPS. Si le serveur entier tombe, il ne peut alerter
personne ; seule une supervision extérieure (une sonde HTTP sur un service tiers) couvre ce cas.

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

## Pare-feu

```bash
ufw allow 22,80,443/tcp && ufw enable
```

Aucun port n'est publié par les apps elles-mêmes (contrat, voir `docs/add-a-service.md`) : seul
`ufw` protège 22, tout le reste passe par Caddy sur 80/443.

## Ajouter une app supplémentaire plus tard

Voir `docs/add-a-service.md`.
