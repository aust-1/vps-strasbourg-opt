# vps-strasbourg-opt

Contenu du `/opt` du VPS, versionné. Mettre à jour le serveur se résume à `git pull` (voir
`scripts/update.sh`) ; tout le reste (permissions, réseau, routage, déploiement, sauvegarde)
passe par un script dédié dans `scripts/`, jamais par une commande tapée à la main.

## Vue d'ensemble

```plaintext
/opt
├── proxy/              reverse proxy Caddy partagé (seul service sur les ports 80/443)
├── services/           services sans dépôt propre (uptime-kuma, rybbit)
├── apps/                sous-modules git : chaque app est le code d'un dépôt tiers
├── scripts/             un script par action, plus scripts/lib/ (bibliothèque commune)
├── legacy/              anciens fichiers Traefik, conservés pour le retour arrière
└── docs/                documentation détaillée (liens ci-dessous)
```

Chaque app ou service :

- ne publie **aucun port** : le routage HTTPS passe uniquement par `proxy/` (Caddy) ;
- déclare son propre `Caddyfile`, assemblé automatiquement dans `proxy/sites/` ;
- rejoint le réseau Docker externe `proxy` avec un **alias réseau unique** (évite toute
  collision entre deux services qui s'appelleraient tous les deux « web ») ;
- fournit un `.env.example` (jamais son `.env`, qui reste local et hors de git).

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
| [`docs/migration.md`](docs/migration.md)         | Bascule Traefik → Caddy depuis une installation existante |

## Scripts

Tous dans `scripts/`, tous avec `-h`/`--help`, tous idempotents, la plupart avec `--dry-run`.

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
| `status.sh`                    | État d'ensemble (dépôt, réseau, proxy, chaque unité)                  |
| `backup.sh` / `restore.sh`     | Sauvegarde/restauration des volumes Docker et des `.env`              |
| `check.sh`                     | Contrôle de conformité complet, sans rien modifier                    |
| `migrate-traefik-to-caddy.sh`  | Bascule depuis une ancienne installation Traefik                      |

## Rigueur

- Aucun secret dans git : seuls les `.env.example` sont versionnés (`.gitignore` à la racine
  et dans chaque app).
- Toute modification de permissions passe par `scripts/fix-perms.sh` (règle unique :
  `scripts/lib/perms.sh`) — jamais un `chmod` isolé.
- `scripts/check.sh` doit passer avant tout déploiement ; il est aussi le premier réflexe en
  cas de doute sur l'état du serveur.
