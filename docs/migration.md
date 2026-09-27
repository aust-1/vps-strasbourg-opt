# Migration depuis l'installation Traefik existante

À faire une seule fois, sur le VPS qui héberge déjà `traefik/`, `apps/{bourse-tracker,
documentation,portfolio,uptime-kuma}` en dehors de tout dépôt git. Compter une coupure de
quelques secondes à quelques minutes selon la vitesse de build des images.

## 0. Avant de commencer

- Les apps ont déjà été adaptées au proxy Caddy partagé dans leur propre dépôt (labels Traefik
  retirés, `Caddyfile` ajouté, réseau `proxy`) — c'est déjà fait pour `bourse-tracker`,
  `portfolio` et `documentation` au moment d'écrire ceci.
- Repérer les secrets GitHub Actions de chaque app à mettre à jour après coup : `VPS_PATH`
  passera de `/opt/<nom>` à `/opt/apps/<nom>`.
- Les DNS pointent déjà vers ce VPS (migration, pas une nouvelle mise en production) : aucun
  changement DNS nécessaire, seul le service qui répond change.

## 1. Mettre l'ancien `/opt` de côté

```bash
mv /opt /opt.old
```

`/opt.old` reste une installation Docker Compose ordinaire, non touchée par la suite tant que
`--rollback` n'est pas utilisé.

## 2. Cloner le nouveau dépôt à sa place

```bash
git clone --recurse-submodules https://github.com/aust-1/vps-strasbourg-opt.git /opt
cd /opt
```

## 3. Reprendre les secrets existants

```bash
cp /opt.old/apps/bourse-tracker/.env apps/bourse-tracker/.env
# portfolio et documentation n'ont pas de secret (voir leur .env.example)
```

## 4. Préparer (sans encore couper le service)

```bash
scripts/network-create.sh
scripts/fix-perms.sh
scripts/check.sh
```

`check.sh` doit passer avant de poursuivre : c'est le dernier moment pour corriger quelque
chose sans avoir touché à la production.

## 5. Bascule

```bash
scripts/migrate-traefik-to-caddy.sh --old-opt /opt.old
```

Dans l'ordre : confirmation → sauvegarde des volumes Docker de l'ancienne ET de la nouvelle
pile (dans `backups/pre-migration-<horodatage>/`) → arrêt de tout ce qui tourne sous
`/opt.old` → réseau → démarrage de la nouvelle pile (`scripts/app-deploy.sh --all`) →
vérification HTTPS de chaque domaine trouvé dans `proxy/sites/`.

`--dry-run` d'abord si un doute subsiste sur ce qui va être arrêté/démarré :

```bash
scripts/migrate-traefik-to-caddy.sh --old-opt /opt.old --dry-run
```

## 6. Si un domaine ne répond pas

Le script le signale explicitement. Diagnostiquer avant de décider :

```bash
scripts/status.sh
docker compose -f proxy/docker-compose.yml logs caddy --tail=50
```

Souvent : certificat en cours d'émission (attendre une minute, réessayer), ou `.env` d'une app
mal recopié à l'étape 3.

## 7. Retour arrière si nécessaire

Ne supprime rien, ne fait que rebasculer :

```bash
scripts/migrate-traefik-to-caddy.sh --rollback --old-opt /opt.old
```

Arrête la nouvelle pile (Caddy + apps du nouveau dépôt) et relance l'ancienne (Traefik + apps
telles qu'elles étaient sous `/opt.old`) — sans rien supprimer, ni images ni volumes.

## 8. Mettre à jour les secrets CI/CD

Dans chaque dépôt d'app (GitHub → Settings → Secrets and variables → Actions) :
`VPS_PATH` = `/opt/apps/<nom>` (au lieu de l'ancien chemin).

## 9. Période d'observation, puis nettoyage final

Une fois la bascule confirmée stable (les domaines répondent, les déploiements automatiques
fonctionnent avec les nouveaux secrets) :

```bash
rm -rf /opt.old
rm -rf legacy/                      # dans /opt : plus besoin de l'ancien Traefik
git add legacy && git commit -m "chore: retire legacy/ après validation de la migration Caddy"
```

Ne pas se précipiter : `/opt.old` et `legacy/` sont le filet de sécurité tant qu'ils existent.
