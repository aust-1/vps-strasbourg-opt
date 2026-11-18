# vps-strasbourg-opt

Contenu du `/opt` du VPS, versionné. Mettre à jour le serveur se résume à `git pull` (voir
`scripts/update.sh`) ; tout le reste (permissions, réseau, routage, déploiement, sauvegarde)
passe par un script dédié dans `scripts/`, jamais par une commande tapée à la main.

## Vue d'ensemble

```plaintext
/opt
├── proxy/              reverse proxy Caddy partagé (seul service sur les ports 80/443)
├── services/           services sans dépôt propre (uptime-kuma, rybbit, smtp-relay)
├── apps/                sous-modules git : chaque app est le code d'un dépôt tiers
├── scripts/             un script par action, plus scripts/lib/ (bibliothèque commune)
├── tests/               test de bout en bout du déploiement automatique
└── docs/                documentation détaillée (liens ci-dessous)
```

Chaque app ou service :

- ne publie **aucun port** : le routage HTTPS passe uniquement par `proxy/` (Caddy) ;
- déclare son propre `Caddyfile`, assemblé automatiquement dans `proxy/sites/` ;
- rejoint le réseau Docker externe `proxy` avec un **alias réseau unique** (évite toute
  collision entre deux services qui s'appelleraient tous les deux « web ») ;
- fournit un `.env.example` (jamais son `.env`, qui reste local et hors de git).

## Unités

### Proxy

`proxy/` : Caddy (`caddy:2-alpine`), seul conteneur à publier les ports 80/443 (et 443/udp
pour HTTP/3). Son `Caddyfile` ne contient aucun site : il importe `proxy/sites/*.caddy`,
assemblé par `scripts/routes-sync.sh`. Les certificats Let's Encrypt vivent dans le volume
`caddy_data` (à sauvegarder).

### Services (`services/`)

Services tiers sans dépôt propre, versionnés directement ici.

| Service        | Rôle                                                                                         | Route                          |
| -------------- | -------------------------------------------------------------------------------------------- | ------------------------------ |
| `uptime-kuma`  | Supervision (image `louislam/uptime-kuma:2`)                                                 | `uptime.eliott-roussille.fr`   |
| `rybbit`       | Statistiques de visite (backend, tableau de bord, ClickHouse, Postgres, Redis)               | `analytics.eliott-roussille.fr` |
| `smtp-relay`   | Relais SMTP interne (Postfix) vers Resend, joignable en `smtp-relay:587` sur le réseau `proxy` | aucune (ni `Caddyfile`, ni port) |

`rybbit` : seuls le backend (`/api/*`) et le tableau de bord rejoignent le réseau `proxy` ;
les bases restent sur le réseau `default` du projet.

`smtp-relay` : authentification obligatoire avec un compte par service (`SMTPD_SASL_USERS`),
expéditeur limité à `ALLOWED_SENDER_DOMAINS`, TLS vérifié vers Resend. `scripts/mail-test.sh`
envoie un email de test par le relais et affiche la réponse de Resend. Mise en route (domaine
vérifié chez Resend, DNS, branchement d'un service) : `docs/runbook.md`, section « Envoi
d'emails ».

### Apps (`apps/`)

Sous-modules git : chaque dossier est la racine du dépôt de l'app.

| App                   | Dépôt                                                                  | Contenu                                         | Route                                             |
| --------------------- | ---------------------------------------------------------------------- | ----------------------------------------------- | ------------------------------------------------- |
| `apps/bourse-tracker` | [`aust-1/bourse-tracker`](https://github.com/aust-1/bourse-tracker)    | Suivi d'un PEA (ordres, valeur, alertes)        | `bourse.eliott-roussille.fr`                      |
| `apps/portfolio`      | [`aust-1/portfolio`](https://github.com/aust-1/portfolio)              | Site personnel (SvelteKit prérendu)             | `eliott-roussille.fr`, `www.eliott-roussille.fr`  |
| `apps/documentation`  | [`aust-1/lectures-notes`](https://github.com/aust-1/lectures-notes)    | Notes de cours (site Docusaurus)                | `docs.eliott-roussille.fr`                        |

Le dossier `apps/documentation` ne porte pas le nom de son dépôt (`lectures-notes`) : c'est le
nom du dossier qui sert de nom de projet compose et de route. Ajouter ou retirer une app :
`scripts/app-add.sh` / `scripts/app-remove.sh` (voir `docs/add-a-service.md`).

## Démarrage rapide

```bash
git clone --recurse-submodules https://github.com/aust-1/vps-strasbourg-opt.git /opt
cd /opt
scripts/bootstrap.sh          # réseau, permissions, contrôle, démarre le proxy
scripts/status.sh             # état de chaque unité
```

Détails, mise en production réelle et migration depuis l'ancienne installation Traefik :
voir `docs/deploy.md` et `docs/migration.md`.

## Documentation

| Fichier                                          | Contenu                                                   |
| ------------------------------------------------ | --------------------------------------------------------- |
| [`docs/architecture.md`](docs/architecture.md)   | Comment le proxy, les réseaux et les apps s'articulent    |
| [`docs/runbook.md`](docs/runbook.md)             | Opérations courantes, pannes fréquentes et leur remède    |
| [`docs/add-a-service.md`](docs/add-a-service.md) | Pas à pas pour ajouter (ou retirer) une app ou un service |
| [`docs/deploy.md`](docs/deploy.md)               | Mise en production sur un VPS neuf                        |
| [`docs/ci-deploy.md`](docs/ci-deploy.md)         | Déploiement automatique depuis la CI des apps             |
| [`docs/migration.md`](docs/migration.md)         | Bascule Traefik → Caddy depuis une installation existante |
| [`docs/Charte-graphique-Eliott-Roussille.pdf`](docs/Charte-graphique-Eliott-Roussille.pdf) | Charte graphique (PDF) |

## Scripts

Tous dans `scripts/`, tous avec `-h`/`--help` (sauf `opt-deploy.sh`, séquence fixe sans
option), la plupart avec `--dry-run`. Codes de sortie communs : `0` succès, `1` échec, `2` usage,
`3` prérequis, `4` refus (détail dans l'aide de chaque script). `scripts/lib/` contient la
bibliothèque commune (`common.sh`) et les règles de permissions (`perms.sh`).

| Script                         | Rôle                                                                  |
| ------------------------------ | --------------------------------------------------------------------- |
| `bootstrap.sh`                 | Première mise en place complète (à lancer une fois)                   |
| `update.sh`                    | `git pull` + sous-modules + permissions + routes                      |
| `network-create.sh`            | Crée le réseau Docker partagé `proxy`                                 |
| `fix-perms.sh`                 | Applique les permissions attendues (règles : `scripts/lib/perms.sh`)  |
| `routes-sync.sh`               | Assemble, valide puis recharge les routes Caddy                       |
| `app-add.sh` / `app-remove.sh` | Ajoute / retire une app (sous-module)                                 |
| `app-deploy.sh`                | Construit/démarre une unité (ou `--all`) et attend qu'elle soit saine |
| `app-bump.sh`                  | Aligne le pointeur d'un sous-module sur le commit réellement déployé  |
| `deploy-install.sh`            | Installe le déploiement par CI (gh-deploy, opt-deploy, clés bridées)  |
| `opt-deploy.sh`                | Modèle de `/usr/local/sbin/opt-deploy`, seul point d'entrée des CI (fetch de `origin/main`, `app-deploy.sh`, puis `app-bump.sh`) |
| `status.sh`                    | État d'ensemble (dépôt, réseau, proxy, chaque unité)                  |
| `backup.sh` / `restore.sh`     | Sauvegarde/restauration des volumes Docker et des `.env` (`restore.sh` remplace le contenu des volumes) |
| `check.sh`                     | Contrôle de conformité complet, sans rien modifier                    |
| `mail-test.sh`                 | Envoie un email de test par le relais SMTP et affiche son statut      |
| `migrate-traefik-to-caddy.sh`  | Bascule depuis une ancienne installation Traefik (et `--rollback`)    |

## Tests

`tests/deploy-e2e.sh` teste de bout en bout le déploiement automatique (`deploy-install.sh`,
`opt-deploy`, clés SSH bridées, refus des noms dangereux et des modifications locales,
révocation) dans un conteneur Ubuntu jetable, avec sshd, sudo et git réels et Docker remplacé
par des stubs. Aucun effet hors du conteneur. Depuis la racine du dépôt :

```bash
docker run --rm -v "$PWD":/src:ro ubuntu:25.04 bash /src/tests/deploy-e2e.sh
```

Sous Git Bash, préfixer par `MSYS_NO_PATHCONV=1`. Dernière ligne attendue : « TOUT EST VERT ».

## Rigueur

- Aucun secret dans git : seuls les `.env.example` sont versionnés (`.gitignore` à la racine
  et dans chaque app).
- Toute modification de permissions passe par `scripts/fix-perms.sh` (règle unique :
  `scripts/lib/perms.sh`) — jamais un `chmod` isolé.
- `scripts/check.sh` doit passer avant tout déploiement ; il est aussi le premier réflexe en
  cas de doute sur l'état du serveur.
