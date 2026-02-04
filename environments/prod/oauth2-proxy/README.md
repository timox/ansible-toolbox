# oauth2-proxy - Reverse Proxy Authentifiant

Configuration oauth2-proxy + nginx pour authentification centralisee multi-applications.

## Guide de Configuration

Voir **[QUICKSTART.md](../docs/OAUTH2-PROXY-QUICKSTART.md)** pour :
- Configuration Keycloak
- Variables .env
- Deploiement
- Ajout d'applications
- Troubleshooting

## Commandes Rapides

```bash
# Deploiement complet
./redeploy.sh --all

# Status
./redeploy.sh --status

# Logs
./redeploy.sh --logs

# Redemarrer un service
./redeploy.sh --nginx
./redeploy.sh --oauth2
```

## Fichiers

| Fichier | Description |
|---------|-------------|
| deploy.sh | Premier deploiement |
| redeploy.sh | Redeploiement et gestion |
| docker-compose.yml | Stack Docker |
| nginx/apps.conf.template | Template routage applications |
| templates/oauth2-proxy.cfg.template | Template config oauth2-proxy |
| [../docs/OAUTH2-PROXY-QUICKSTART.md](../docs/OAUTH2-PROXY-QUICKSTART.md) | Guide complet |
