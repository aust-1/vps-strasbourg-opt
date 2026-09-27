# legacy/

Conservé uniquement pour le retour arrière de la migration Traefik → Caddy
(`scripts/migrate-traefik-to-caddy.sh --rollback`, voir `docs/migration.md`).

| Fichier                            | Rôle avant la migration                                                         |
| ---------------------------------- | ------------------------------------------------------------------------------- |
| `traefik/docker-compose.yml`       | Le reverse proxy lui-même (remplacé par `proxy/`)                               |
| `portfolio/docker-compose.yml`     | Compose de portfolio avec labels Traefik (jamais versionné ailleurs auparavant) |
| `documentation/docker-compose.yml` | Compose de documentation avec labels Traefik (idem)                             |

`bourse-tracker` n'a pas besoin d'entrée ici : son ancien compose Traefik reste consultable dans
l'historique de son propre dépôt (commit `05dfce2` et antérieurs, avant `fix(infra): déploiement
derrière le Caddy partagé`).

À supprimer une fois la migration validée en production (voir la fin de `docs/migration.md`).
