# Déploiement automatique depuis la CI des apps

Quand la CI de `main` d'une app est verte, son workflow **Déploiement** se connecte au VPS en SSH
et l'app est redéployée. Ce document décrit le mécanisme, son modèle de sécurité, l'installation
sur le serveur et la mise en place pour une app.

## Le mécanisme

```plaintext
GitHub Actions (app X)                       VPS
──────────────────────                       ───────────────────────────────────────────────
CI verte sur main
  └─ deploy.yml : ssh gh-deploy@vps  ──────▶  authorized_keys de gh-deploy :
     (clé dédiée à X, clé d'hôte épinglée)    restrict,command="sudo -n /usr/local/sbin/opt-deploy X"
                                                └─ sudoers : gh-deploy -> « opt-deploy X », rien d'autre
                                                   └─ /usr/local/sbin/opt-deploy X   (root, hors git)
                                                        1. refuse si apps/X a des modifs locales
                                                        2. git fetch + checkout origin/main
                                                        3. scripts/app-deploy.sh X
                                                           (build ou pull, healthchecks, routes)
                                                        4. scripts/app-bump.sh (pointeur opt)
                                                        5. journal : /var/log/opt-deploy.log
```

Toutes les apps passent par ce même chemin, qu'elles construisent leur image sur le VPS
(`build:` dans leur compose) ou la récupèrent d'un registre (`image:` : `app-deploy.sh` fait le
`pull`). Aucune app n'a de script de déploiement à elle.

## Modèle de sécurité

- **Ce qui tourne en root n'est jamais réécrit par un déploiement.** `opt-deploy` est une copie
  de `scripts/opt-deploy.sh` installée en `/usr/local/sbin` (root:root 0755) par
  `scripts/deploy-install.sh`. Les scripts qu'il appelle (`scripts/*.sh`) appartiennent au
  dépôt opt, que seul root met à jour (`scripts/update.sh`, qui réinstalle aussi `opt-deploy`).
  Un push sur une app ne modifie que `apps/<app>`.
- **Une clé ne peut faire qu'une chose.** Chaque app a sa propre clé, bridée dans
  `authorized_keys` par `restrict` (ni shell, ni pty, ni redirection de port, ni agent) et par
  une commande forcée : quelle que soit la commande envoyée, seul `opt-deploy <app>` s'exécute.
  Une clé fuitée permet au pire de redéployer le dernier commit de `main` de cette app.
- **sudo ne fait qu'une chose.** `/etc/sudoers.d/opt-deploy` autorise `gh-deploy` à lancer
  `opt-deploy <app>` pour chaque app, avec ce seul argument exact. `gh-deploy` n'a ni mot de
  passe, ni groupe `docker`, ni `sudo` complet.
- **Pas de secret dans la commande distante.** Le workflow n'envoie aucune commande : rien à
  injecter. `VPS_PATH` n'existe plus.
- **Clé d'hôte épinglée.** Le runner refuse un serveur dont la clé SSH n'est pas celle du
  secret `VPS_KNOWN_HOSTS` (pas d'homme du milieu).

**Limite assumée :** une app est du code exécuté par Docker, et Docker équivaut à root. Le
contenu de `main` d'une app (son `docker-compose.yml`, son `Dockerfile`) est donc de confiance.
La vraie barrière est sur GitHub : protéger `main` (pas de push direct, CI obligatoire) dans
chaque dépôt d'app, et limiter qui peut y écrire.

## Installation sur le serveur (une fois, en root)

```bash
cd /opt
scripts/deploy-install.sh          # compte gh-deploy, /usr/local/sbin/opt-deploy, sudoers
scripts/deploy-install.sh --status # état : règle sudo et clé CI de chaque app
```

À relancer après l'ajout ou le retrait d'une app (le sudoers est régénéré depuis `apps/`) ;
`scripts/update.sh` le fait de lui-même après chaque mise à jour du dépôt opt. `scripts/check.sh`
échoue si la copie installée ne correspond plus à `scripts/opt-deploy.sh`.

Si `sshd` restreint les connexions (`AllowUsers` / `AllowGroups`), y ajouter `gh-deploy` :
`deploy-install.sh` le signale.

## Mettre en place une app

1. **Créer une clé dédiée**, sur ton poste (jamais sur le serveur, jamais réutilisée) :

   ```bash
   ssh-keygen -t ed25519 -N '' -C deploy-<app> -f deploy-<app>
   ```

2. **L'autoriser sur le serveur**, en root :

   ```bash
   scripts/deploy-install.sh --key <app> 'ssh-ed25519 AAAA… deploy-<app>'
   ```

3. **Secrets du dépôt de l'app** (Settings → Secrets and variables → Actions) :

   | Secret            | Valeur                                                                  |
   | ----------------- | ----------------------------------------------------------------------- |
   | `VPS_HOST`        | IP ou nom du VPS                                                        |
   | `VPS_SSH_KEY`     | contenu de `deploy-<app>` (la clé **privée**)                           |
   | `VPS_KNOWN_HOSTS` | clé d'hôte du serveur : `203.0.113.10 ssh-ed25519 AAAA…` (voir dessous) |

   Puis supprimer `deploy-<app>` et `deploy-<app>.pub` du poste.

4. **Workflow** `.github/workflows/deploy.yml` de l'app (identique pour toutes) :

   ```yaml
   name: Déploiement
   on:
     workflow_run:
       workflows: [CI]
       types: [completed]
       branches: [main]
     workflow_dispatch:
   concurrency:
     group: deploy
     cancel-in-progress: false
   permissions:
     contents: read
   jobs:
     deploy:
       if: ${{ github.event_name == 'workflow_dispatch' || github.event.workflow_run.conclusion == 'success' }}
       runs-on: ubuntu-latest
       steps:
         - name: Déployer (clé bridée à « opt-deploy <app> » sur le VPS)
           env:
             VPS_HOST: ${{ secrets.VPS_HOST }}
             VPS_SSH_KEY: ${{ secrets.VPS_SSH_KEY }}
             VPS_KNOWN_HOSTS: ${{ secrets.VPS_KNOWN_HOSTS }}
           run: |
             test -n "$VPS_KNOWN_HOSTS" || { echo "Secret VPS_KNOWN_HOSTS manquant" >&2; exit 1; }
             install -m 700 -d ~/.ssh
             printf '%s\n' "$VPS_SSH_KEY" > ~/.ssh/id_deploy
             printf '%s\n' "$VPS_KNOWN_HOSTS" > ~/.ssh/known_hosts
             chmod 600 ~/.ssh/id_deploy ~/.ssh/known_hosts
             ssh -T -i ~/.ssh/id_deploy -o BatchMode=yes -o StrictHostKeyChecking=yes \
               -o UserKnownHostsFile="$HOME/.ssh/known_hosts" "gh-deploy@$VPS_HOST"
   ```

   Aucune commande n'est envoyée : celle de la clé est forcée par le serveur.

### Obtenir `VPS_KNOWN_HOSTS`

Le plus sûr, depuis le serveur lui-même : `cat /etc/ssh/ssh_host_ed25519_key.pub`, puis préfixer
la ligne par l'IP et retirer le commentaire final (`203.0.113.10 ssh-ed25519 AAAA…`). Depuis un
poste, `ssh-keyscan -t ed25519 <ip>` fonctionne aussi, à condition de comparer l'empreinte
(`ssh-keygen -lf -`) avec celle affichée sur le serveur (`ssh-keygen -lf
/etc/ssh/ssh_host_ed25519_key.pub`). L'OpenSSH livré avec Windows peut échouer sur ce serveur
(`unsupported KEX method`) : passer par Git Bash ou par la méthode depuis le serveur.

## Déployer à la main

```bash
sudo opt-deploy <app>              # exactement ce que fait la CI
scripts/app-deploy.sh <app>        # redémarre le commit actuel, sans git (correctif local)
```

## Révoquer ou remplacer une clé

```bash
scripts/deploy-install.sh --revoke <app>                 # plus aucun déploiement par la CI
scripts/deploy-install.sh --key <app> 'ssh-ed25519 …'    # nouvelle clé (remplace l'ancienne)
```

Puis mettre à jour `VPS_SSH_KEY` dans le dépôt de l'app.

## Dépannage

| Symptôme dans le workflow                    | Cause et remède                                                                    |
| -------------------------------------------- | ---------------------------------------------------------------------------------- |
| `Host key verification failed`               | `VPS_KNOWN_HOSTS` faux ou serveur réinstallé : le régénérer (voir plus haut)       |
| `Permission denied (publickey)`              | clé non autorisée : `deploy-install.sh --key <app> …` ; vérifier `--status`        |
| `sudo: a password is required`               | règle sudoers absente pour cette app : relancer `scripts/deploy-install.sh`        |
| `opt-deploy : … a des modifications locales` | correctif fait sur le serveur : le committer dans le dépôt de l'app, ou l'annuler  |
| `un autre déploiement est toujours en cours` | un déploiement dure plus de 15 min : voir `/var/log/opt-deploy.log`                |
| conteneur non sain                           | `cd /opt/apps/<app> && docker compose logs --tail=100`, puis corriger et repousser |

Historique complet : `/var/log/opt-deploy.log` (lisible par root et le groupe `adm`).

## Tester le mécanisme

```bash
docker run --rm -v "$PWD":/src:ro ubuntu:25.04 bash /src/tests/deploy-e2e.sh
```

Sshd, sudo et git réels dans un conteneur jetable, Docker remplacé par des stubs. Vérifie entre
autres : déploiement du dernier commit, commande arbitraire ignorée, redirections interdites,
pas de shell root, argument non prévu refusé, modifications locales protégées, révocation.
