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

Voir le `docs/DEPLOY.md` (ou équivalent) de chaque app pour ses secrets CI/CD (`VPS_HOST`,
`VPS_PATH=/opt/apps/<nom>`, clé SSH dédiée, clé d'hôte épinglée). Après un déploiement
automatique, `scripts/status.sh` doit rester vert et `git -C apps/<nom> status` propre : sinon,
voir `docs/architecture.md` (section « Déploiement automatique »).

## Pare-feu

```bash
ufw allow 22,80,443/tcp && ufw enable
```

Aucun port n'est publié par les apps elles-mêmes (contrat, voir `docs/add-a-service.md`) : seul
`ufw` protège 22, tout le reste passe par Caddy sur 80/443.

## Ajouter une app supplémentaire plus tard

Voir `docs/add-a-service.md`.
