# Ajouter (ou retirer) une app ou un service

## App (a son propre dépôt git)

### 1. Préparer le dépôt de l'app

À la racine du dépôt de l'app (pas dans un sous-dossier), trois fichiers :

**`docker-compose.yml`**

```yaml
name: <nom> # DOIT correspondre au nom du dossier apps/<nom> : sinon les volumes
# changeraient de nom au moindre déplacement.

services:
  web: # le nom du service importe peu, seul l'alias compte
    image: ... # ou build: pour une image construite sur place
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    networks:
      proxy:
        aliases:
          - <nom>-web # UNIQUE sur tout le VPS : c'est ce que le Caddyfile cible
    healthcheck: # scripts/app-deploy.sh attend qu'il soit « healthy »
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:<port>/"]
      interval: 15s
      timeout: 5s
      retries: 5

networks:
  proxy:
    external: true
    name: ${PROXY_NETWORK:-proxy}
```

Aucun `ports:` (aucun port publié — seul le proxy peut le faire). Une base de données ou un
worker interne n'a pas besoin du réseau `proxy` : le réseau `default` (créé automatiquement)
suffit à le faire parler avec le service web de la même app.

**`Caddyfile`** (site(s) uniquement, jamais de configuration globale) :

```caddyfile
mondomaine.exemple.fr {
 encode zstd gzip
 reverse_proxy <nom>-web:<port>
}
```

**`.env.example`** : toutes les variables nécessaires, sans valeur secrète. Le `.gitignore` de
l'app doit ignorer `.env` (sinon `scripts/app-add.sh` refuse l'ajout) :

```gitignore
.env
.env.*
!.env.example
```

Commiter et pousser ces trois fichiers sur `main` (ou la branche à suivre) **avant** de passer
à l'étape 2 : `scripts/app-add.sh` clone ce dépôt tel qu'il est sur son distant.

### 2. L'ajouter au dépôt opt

```bash
scripts/app-add.sh <nom> <url-git>
```

Clone en sous-module `apps/<nom>`, vérifie le contrat ci-dessus, crée `.env` depuis
`.env.example`, applique les permissions, publie la route (sans redémarrer Caddy — le nouveau
service n'existe pas encore). En cas de contrat non respecté, **tout est annulé** : aucun
résidu dans git ni sur le disque.

```bash
nano apps/<nom>/.env              # compléter les valeurs
scripts/app-deploy.sh <nom>       # build/pull, démarre, attend le healthcheck, recharge Caddy
scripts/status.sh                 # vérifier que tout est vert
```

Committer (`--commit` sur `app-add.sh`, ou `git add .gitmodules apps/<nom> && git commit`) —
sans pousser depuis le VPS si ce n'est pas l'usage prévu pour ce dépôt.

### Déploiement automatique (CI de l'app)

Voir `docs/architecture.md` (section « Déploiement automatique ») : le workflow de l'app avance
son propre sous-module, puis appelle `scripts/app-bump.sh` pour aligner le pointeur enregistré
dans opt. Modèle pour `infra/deploy.sh` de l'app :

```bash
git fetch --quiet origin main && git reset --hard origin/main
docker compose build --pull && docker compose up -d --remove-orphans
# … attendre que le healthcheck soit bon …
../../scripts/app-bump.sh --to "$(git rev-parse HEAD)" --commit "$(basename "$PWD")" || true
```

### Retirer une app

```bash
scripts/app-remove.sh <nom>                    # arrête, sauvegarde .env, désinscrit, retire la route
scripts/app-remove.sh <nom> --purge-volumes    # + supprime ses volumes Docker (irréversible)
```

Sans `--purge-volumes`, les volumes Docker restent (au cas où) : le script indique comment les
supprimer explicitement une fois sûr.

## Service sans dépôt propre (image tierce)

Pas de `scripts/app-add.sh` pour ce cas — c'est un dossier ordinaire du dépôt opt :

```bash
mkdir services/<nom>
# créer docker-compose.yml, Caddyfile, .env.example (même contrat que ci-dessus)
scripts/fix-perms.sh
scripts/app-deploy.sh <nom>
git add services/<nom> && git commit -m "feat(services): ajoute <nom>"
```

`services/uptime-kuma` est un exemple à suivre directement.

## Vérifier avant de pousser

```bash
scripts/check.sh
```
