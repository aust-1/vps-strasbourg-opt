# Architecture

## Le principe : le routage vit avec le code

Historiquement, `bourse-tracker` embarquait son propre Caddy (commit `8658317`), remplacé
ensuite par Traefik (commit `05dfce2`) parce qu'un seul processus peut occuper les ports 80/443
d'un VPS. Cette restructuration garde l'idée de départ — le routage d'une app vit dans son
dépôt, pas dans un fichier central — sans le défaut (un proxy par app) : **un seul Caddy**
partagé importe le `Caddyfile` de chaque app.

```plaintext
                         ┌─────────────────────────────┐
 Internet ── 80/443 ──▶  │  proxy/  (Caddy, seul       │
                         │  service sur ces ports)     │
                         │  Caddyfile = import sites/* │
                         └──────────────┬──────────────┘
                                        │ réseau externe « proxy »
                    ┌───────────┬───────┴───────┬───────────────┬──────────────────┐
                    │           │               │               │                  │
             apps/bourse-   apps/portfolio  apps/documentation  services/          services/rybbit
             tracker (alias  (alias          (alias              uptime-kuma        (alias rybbit-backend
             bourse-web)     portfolio)       documentation)     (alias uptime-kuma) et rybbit-client)
```

`services/rybbit` (statistiques de visite des trois apps) illustre aussi le cas des bases
internes : ClickHouse, Postgres et Redis restent sur son réseau `default`, seuls le backend
(`/api/*`, qui reçoit aussi les événements des sites suivis) et le tableau de bord rejoignent
`proxy`.

## Réseaux Docker

Un seul réseau externe, **`proxy`** (nom configurable par la variable `PROXY_NETWORK`, créé par
`scripts/network-create.sh`, jamais à la main). Seul le service qu'une app expose au public le
rejoint, avec un **alias réseau explicite et unique** — c'est ce nom que son `Caddyfile` cible
dans `reverse_proxy`. Sans cet alias, deux apps qui appelleraient toutes deux leur service `web`
entreraient en collision sur le réseau partagé.

Les bases de données, workers et autres services internes d'une app restent sur SON réseau
`default` (créé automatiquement par son propre `docker compose`), invisibles du reste du VPS.

`bourse-tracker` illustre les deux cas : son service `web` est sur `default` **et** `proxy`
(alias `bourse-web`), son `worker` reste seul sur `default`.

## Le proxy (`proxy/`)

- `proxy/docker-compose.yml` : Caddy, ports 80/443 (+ 443/udp pour HTTP/3), volumes
  `caddy_data` (certificats Let's Encrypt — à sauvegarder) et `caddy_config`.
- `proxy/Caddyfile` : uniquement la configuration globale (email ACME) et `import sites/*.caddy`
  — **aucun site n'y est écrit directement**.
- `proxy/sites/` : généré par `scripts/routes-sync.sh`, ignoré par git. Une copie (jamais un
  lien symbolique — ils cassent dans un montage de conteneur) du `Caddyfile` de chaque
  app/service qui en fournit un.

Pas de `docker.sock` monté : Caddy ne découvre rien tout seul, `routes-sync.sh` le fait à sa
place. C'est la différence de fond avec l'ancien Traefik (qui montait `docker.sock` en lecture
seule — déjà une surface d'attaque proche de root sur l'hôte).

## Le contrat d'une unité (app ou service)

Documenté en détail dans `docs/add-a-service.md`. En bref, à la racine de son dossier :

- `docker-compose.yml` avec `name: <dossier>` (le nom de projet doit correspondre au nom du
  dossier — sinon les volumes changeraient de nom à chaque déplacement), réseau externe
  `proxy` avec un alias unique, `restart: unless-stopped`, un healthcheck ;
- `Caddyfile` (site(s) uniquement — pas la configuration globale) ;
- `.env.example` (jamais `.env`, ignoré par le `.gitignore` de l'unité).

`scripts/check.sh` vérifie ce contrat mécaniquement (alias en double, ports publiés, nom de
projet, `docker.sock`, cible du `reverse_proxy`…).

## Apps en sous-modules, proxy et services en fichiers

- **`apps/`** : chaque app a son propre dépôt GitHub (code applicatif ET son
  `docker-compose.yml`/`Caddyfile`), ajouté en sous-module git. Le dossier `apps/<nom>` EST la
  racine de ce dépôt — jamais un sous-dossier supplémentaire.
- **`services/` et `proxy/`** : pas de dépôt propre (image tierce, ou le proxy lui-même) —
  versionnés directement dans CE dépôt.

## Déploiement automatique

Chaque app garde son propre workflow CI/CD (ex. `apps/bourse-tracker/.github/workflows/deploy.yml`),
qui avance SON dépôt sur le VPS (`git fetch`/`reset --hard origin/main` dans SON `infra/deploy.sh`
— légitime, un sous-module est un dépôt git à part entière) puis reconstruit et redémarre. Pour
que le dépôt opt reste le reflet fidèle du commit réellement déployé (sans quoi `git status`
dans `/opt` afficherait ce sous-module comme modifié en permanence), le déploiement appelle en
fin de course `scripts/app-bump.sh --to <commit> --commit <nom>` : il avance le pointeur du
sous-module et crée un commit local dans opt — jamais de push automatique.

## Limitation connue : permissions sous Windows/WSL

`scripts/fix-perms.sh` et `scripts/check.sh` reposent sur les bits de permission POSIX
(`chmod`, `stat -c '%a'`). Sur un montage Windows accédé depuis WSL (`/mnt/c/...`), `chmod`
« réussit » sans que la permission ne persiste réellement (limitation connue de DrvFs) : ces
deux scripts n'y donnent donc pas un résultat fiable. Sur le VPS (disque Linux natif), aucun
problème. Les bits de mode **suivis par git** (755 pour un script, 644 pour un fichier sourcé)
restent, eux, corrects indépendamment de la plateforme : c'est git, pas le système de fichiers,
qui les porte jusqu'au clonage sur le VPS.
