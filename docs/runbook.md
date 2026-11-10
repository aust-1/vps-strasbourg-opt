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

## Déployer une app

```bash
sudo opt-deploy <nom>             # dernier commit de main : exactement ce que fait la CI
scripts/app-deploy.sh <nom>       # commit actuel, sans git : build/pull, up -d, healthchecks, route
scripts/app-deploy.sh --all       # proxy, puis chaque service, puis chaque app
```

## Déploiements automatiques (CI des apps)

```bash
scripts/deploy-install.sh --status          # règle sudo et clé CI de chaque app
tail -n 50 /var/log/opt-deploy.log          # historique (qui, quoi, quel commit, résultat)
scripts/deploy-install.sh --revoke <nom>    # couper la CI d'une app (clé fuitée, gel…)
```

Pannes fréquentes et remèdes : tableau « Dépannage » de `docs/ci-deploy.md`.

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

## Envoi d'emails (relais SMTP)

`services/smtp-relay` : un Postfix interne que tous les services utilisent comme serveur SMTP
(`smtp-relay:587`), et qui transmet à **Resend** (offre gratuite, ~3 000 emails/mois et
~100/jour : largement assez pour des alertes et des invitations). Le VPS n'envoie donc jamais
directement sur Internet : pas de port 25, pas de réputation d'IP à surveiller. Expéditeur :
`noreply@eliott-roussille.fr`.

Le relais exige un compte par service, refuse tout expéditeur hors du domaine vérifié et ne
parle à Resend qu'en TLS vérifié. Aucun port n'est publié.

### 1. Vérifier le domaine chez Resend (une seule fois)

1. <https://resend.com> → **Domains** → **Add Domain** : `eliott-roussille.fr`, région
   `eu-west-1` (Irlande).
2. Chez le registrar, créer les enregistrements DNS que Resend affiche. Recopier les valeurs
   exactes depuis Resend (la clé DKIM est propre au compte) :

   | Type | Nom                 | Rôle                                                         |
   | ---- | ------------------- | ------------------------------------------------------------ |
   | TXT  | `resend._domainkey` | DKIM : clé publique qui prouve que le mail vient bien de toi |
   | MX   | `send`              | Adresse de retour des rebonds (priorité 10)                  |
   | TXT  | `send`              | SPF du sous-domaine d'envoi (`v=spf1 include:… ~all`)        |

   Ils portent sur `send.` et `resend._domainkey.` : rien ne change pour la racine du domaine
   (site, éventuels MX/SPF existants).

3. Recommandé, à ajouter soi-même : TXT `_dmarc` → `v=DMARC1; p=none; rua=mailto:<ton-adresse>`.
   Une fois que tout part correctement depuis quelques semaines (rapports reçus), durcir en
   `p=quarantine`.
4. **Verify DNS Records**, puis attendre l'état **Verified** (de quelques minutes à quelques
   heures selon le registrar).
5. **API Keys** → **Create API Key** : permission « Sending access », domaine
   `eliott-roussille.fr`. Cette clé sert uniquement au relais : on peut la révoquer sans
   toucher à `bourse-tracker`.

Tant que le domaine n'est pas vérifié, Resend refuse tout envoi depuis `noreply@eliott-roussille.fr`.
`scripts/mail-test.sh` affiche alors la réponse de Resend.

### 2. Mise en route

```bash
cp services/smtp-relay/.env.example services/smtp-relay/.env
nano services/smtp-relay/.env      # RELAYHOST_PASSWORD (clé Resend) et un compte par service :
                                   # SMTPD_SASL_USERS=uptime-kuma@eliott-roussille.fr:<openssl rand -hex 24>
scripts/fix-perms.sh
scripts/app-deploy.sh smtp-relay
scripts/mail-test.sh <ton-adresse>   # « accepté par le fournisseur » = tout fonctionne
```

Vérifier l'arrivée dans la boîte de réception, pas dans les spams, et le résultat
« DKIM : PASS » dans l'en-tête complet (« Afficher l'original » sur Gmail).

### 3. Brancher un service

Le conteneur qui envoie doit être sur le réseau `proxy`. C'est déjà le cas d'un service exposé.
Un worker qui ne serait que sur `default` doit rejoindre `proxy` en plus.

| Réglage      | Valeur                                                                              |
| ------------ | ----------------------------------------------------------------------------------- |
| Hôte         | `smtp-relay`                                                                        |
| Port         | `587`                                                                               |
| Sécurité     | aucune : ni TLS ni STARTTLS (le trajet ne quitte pas le pont Docker de l'hôte)      |
| Identifiant  | le compte du service dans `SMTPD_SASL_USERS`, ex. `uptime-kuma@eliott-roussille.fr` |
| Mot de passe | celui du même compte                                                                |
| Expéditeur   | `noreply@eliott-roussille.fr` (tout autre domaine est refusé)                       |

Ajouter un service : ajouter son compte à `SMTPD_SASL_USERS` (séparés par des virgules), puis
`scripts/app-deploy.sh smtp-relay`. Retirer un compte de la même façon lui coupe l'accès.

**Uptime Kuma** : **Paramètres** → **Notifications** → **Configurer une notification** → type
**Email (SMTP)**. Renseigner les valeurs du tableau, régler la sécurité sur « Aucune », mettre
ton adresse dans « À », puis **Tester**. Cocher « Activé par défaut » pour l'appliquer aux
nouvelles sondes.

`bourse-tracker` appelle l'API Resend directement et n'utilise pas le relais. Une fois le
domaine vérifié, il suffit de passer `EMAIL_FROM=Bourse Tracker <noreply@eliott-roussille.fr>`
dans son `.env` pour qu'il puisse écrire aux personnes invitées. Supabase Auth est hébergé
chez Supabase et ne peut pas joindre le relais : configurer directement `smtp.resend.com` dans
son tableau de bord (voir `apps/bourse-tracker/docs/DEPLOY.md`).

## Pannes fréquentes

### Un email n'arrive pas

1. `scripts/mail-test.sh <ton-adresse>`. Le message d'erreur dit qui a refusé :
   - **refusé par le relais** : compte ou mot de passe faux, expéditeur hors de
     `ALLOWED_SENDER_DOMAINS`, ou domaine destinataire qui ne reçoit pas de mail ;
   - **différé** : le mail attend dans la file du relais, qui réessaie tout seul. La raison
     suit : clé Resend invalide (`535`), domaine non vérifié, quota du jour atteint, Resend
     injoignable ;
   - **refusé par le fournisseur** : rejet définitif par Resend ou par le destinataire.
2. `cd services/smtp-relay && docker compose logs postfix --tail=50`. Chaque envoi indique
   `sasl_username=` (quel service) et `status=`.
3. File d'attente : `docker compose exec postfix postqueue -p`. Après correction (nouvelle
   clé, par exemple), `docker compose exec postfix postqueue -f` relance les envois en attente.
4. Arrivé en spam : vérifier dans l'en-tête que DKIM et SPF sont « PASS » (étape 1 de la mise
   en route).

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
