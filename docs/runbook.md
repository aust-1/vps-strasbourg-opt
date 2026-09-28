# Runbook

Toutes les commandes sont lancées depuis `/opt` (racine du dépôt), sauf mention contraire.

## Vérifier l'état du serveur

```bash
scripts/status.sh
```

Une ligne par app/service : commit du sous-module, conteneurs sains/total, `.env` présent,
route publiée et à jour. Code de sortie non nul dès qu'une ligne est anormale — utilisable en
supervision (cron + alerte sur échec).

## Mettre à jour depuis le dépôt

```bash
scripts/update.sh                 # git pull --ff-only + sous-modules + permissions + routes
scripts/update.sh --deploy        # + redéploie les apps dont le sous-module a changé
```

Refuse si l'arbre git n'est pas propre ou si la branche n'est pas `main` (`--force` pour passer
outre — le `pull` reste `--ff-only` dans tous les cas : jamais de fusion ni de rebase surprise).

## Déployer une app après une modification manuelle

```bash
scripts/app-deploy.sh <nom>       # build/pull, up -d, attend les healthchecks, publie la route
scripts/app-deploy.sh --all       # proxy, puis chaque service, puis chaque app
```

## Consulter les journaux

```bash
docker compose -f proxy/docker-compose.yml logs -f caddy      # proxy
cd apps/<nom> && docker compose logs -f                        # une app
```

## Recharger uniquement les routes (après avoir modifié un Caddyfile à la main)

```bash
scripts/routes-sync.sh            # valide, copie dans proxy/sites/, recharge Caddy
scripts/routes-sync.sh --check    # signale un écart sans rien modifier (utile en CI/cron)
```

Une configuration invalide ne remplace **jamais** `proxy/sites/` : Caddy garde son ancienne
configuration tant que la nouvelle n'est pas validée.

## Sauvegarder / restaurer

```bash
scripts/backup.sh                          # volumes Docker + .env -> backups/opt-<horodatage>.tar.gz
scripts/backup.sh --stop --keep-days 30    # cohérence des bases SQLite (arrête, copie, redémarre)
scripts/restore.sh backups/opt-2026...tar.gz --only uptime-kuma_data
```

Ne concerne pas les données métier d'une app dont la base est externe (ex. Supabase pour
`bourse-tracker` : voir `apps/bourse-tracker/infra/backup.sh`, indépendant de celui-ci).

## Contrôler la conformité de l'ensemble

```bash
scripts/check.sh
```

À lancer avant tout commit ou déploiement important. Vérifie : forme des scripts (shebang,
`set -euo pipefail`, LF, bit exécutable), permissions, cohérence des sous-modules, absence de
secret versionné, contrat de chaque app/service (alias en double, ports publiés, `docker.sock`,
nom de projet, cible du `reverse_proxy`), validité de la configuration Caddy assemblée.

## Statistiques de visite (Rybbit)

Tableau de bord : <https://analytics.eliott-roussille.fr> (`services/rybbit`). Le DNS de ce
sous-domaine doit pointer vers le VPS avant le premier déploiement (certificat).

Première mise en route :

```bash
cp services/rybbit/.env.example services/rybbit/.env
nano services/rybbit/.env               # BETTER_AUTH_SECRET et les 3 mots de passe : openssl rand -hex 32
scripts/fix-perms.sh
scripts/app-deploy.sh rybbit
```

1. Ouvrir le tableau de bord, créer le compte administrateur.
2. Passer `DISABLE_SIGNUP=true` dans `services/rybbit/.env`, puis `scripts/app-deploy.sh rybbit`
   (sinon n'importe qui peut créer un compte).
3. Ajouter les sites **dans cet ordre** : leurs identifiants sont ceux déjà codés en dur dans le
   `data-site-id` de chaque app — vérifier dans le tableau de bord (réglages du site → code de
   suivi) et corriger l'app si un identifiant diffère.

| ID  | Domaine                      | Où est inséré le script                                  |
| --- | ---------------------------- | -------------------------------------------------------- |
| 1   | `eliott-roussille.fr`        | `apps/portfolio/site/index.html`                         |
| 2   | `docs.eliott-roussille.fr`   | `apps/documentation/site/docusaurus.config.ts` (scripts) |
| 3   | `bourse.eliott-roussille.fr` | `apps/bourse-tracker/apps/web/app/layout.tsx`            |

Monter de version : changer `RYBBIT_VERSION` dans `.env` (les notes de version indiquent les
migrations éventuelles), puis `scripts/app-deploy.sh rybbit`. Les volumes ClickHouse/Postgres ne
sont copiés de façon cohérente que par `scripts/backup.sh --stop` (celui du cron).

## Pannes fréquentes

### Un domaine répond 502 / ne répond plus

1. `scripts/status.sh` — la route est-elle publiée (`ok`) ou `ABSENTE`/`OBSOLÈTE` ?
2. `docker compose -f proxy/docker-compose.yml logs caddy --tail=50`
3. Le conteneur cible est-il sain ? `cd apps/<nom> && docker compose ps`
4. `scripts/routes-sync.sh` (republie/recharge)

### Certificat expiré ou jamais émis

- Le port 80 (défi HTTP) et 443 doivent être joignables depuis Internet : `ufw status`,
  et le DNS du domaine doit déjà pointer vers le VPS.
- `docker compose -f proxy/docker-compose.yml logs caddy | grep -i acme`

### `scripts/*.sh` refuse de s'exécuter (Permission denied)

```bash
scripts/fix-perms.sh
```

### Le réseau `proxy` est absent

```bash
scripts/network-create.sh
```

### Un sous-module est en HEAD détachée ou pointe sur un commit inattendu

```bash
git submodule status                  # repère l'app concernée
scripts/app-bump.sh --to <réf> <nom>   # réaligne explicitement (voir docs/architecture.md)
```

### Espace disque bas

```bash
docker system df
docker image prune -f
find backups -name '*.tar.gz*' -mtime +30   # sauvegardes anciennes (backup.sh les purge déjà par défaut)
```
