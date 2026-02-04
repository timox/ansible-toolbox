# Portal API

API backend pour la gestion persistante des applications du portail.

## Description

Service Node.js Express minimal qui expose deux endpoints:
- `GET /api/applications` - Récupère la liste des applications
- `POST /api/applications` - Sauvegarde la liste des applications

Les données sont stockées dans un fichier JSON persistant via un volume Docker.

## Utilisation

Voir [PORTAL-ADMIN.md](../../docs/PORTAL-ADMIN.md) pour la documentation complète.

## Prérequis

**IMPORTANT**: Avant de démarrer le service pour la première fois, vous devez créer les répertoires de données avec les bonnes permissions.

```bash
# Méthode automatique (recommandée)
cd /home/user/pomeguac/environments/prod
sudo ./setup-data-dirs.sh

# OU méthode manuelle
sudo mkdir -p /data/portal
sudo chmod 777 /data/portal
```

Sans cette étape, vous obtiendrez l'erreur :
```
Error: EACCES: permission denied, open '/data/applications.json'
```

Voir [TROUBLESHOOTING-PERMISSIONS.md](../../TROUBLESHOOTING-PERMISSIONS.md) pour plus de détails.

## Déploiement

```bash
# Build
docker-compose build portal-api

# Démarrer
docker-compose up -d portal-api

# Logs
docker logs portal-api

# Health check
curl http://localhost:3000/health
```

## Configuration

| Variable | Défaut | Description |
|----------|--------|-------------|
| `DATA_DIR` | `/data` | Répertoire de stockage du fichier JSON |
| `PORT` | `3000` | Port d'écoute de l'API |

## Fichier de données

**Emplacement**: `${DATA_DIR}/applications.json`

**Format**:
```json
[
  {
    "id": "string",
    "name": "string",
    "description": "string",
    "icon": "string (Font Awesome class)",
    "url": "string (URL)",
    "color": "string (app-primary|app-success|...)",
    "groups": ["string", "string"]
  }
]
```

## Sécurité

- Pas d'authentification (accès réseau interne uniquement)
- Validation des données avant sauvegarde
- User non-root (node)
- Logs de toutes les opérations

## Développement

```bash
# Installation
npm install

# Démarrage
DATA_DIR=./data node server.js

# Test
curl http://localhost:3000/health
curl http://localhost:3000/api/applications
```

## Dépannage

### Erreur: EACCES permission denied

Si vous obtenez cette erreur au démarrage :

```
Error: EACCES: permission denied, open '/data/applications.json'
```

**Solution rapide** :
```bash
sudo chmod 777 /data/portal
docker compose restart portal-api
```

**Solution complète** : Voir [TROUBLESHOOTING-PERMISSIONS.md](../../TROUBLESHOOTING-PERMISSIONS.md)

### Vérifier les permissions

```bash
# Vérifier le répertoire
ls -la /data/portal

# Vérifier les logs du container
docker logs portal-api

# Tester l'écriture
docker exec portal-api touch /data/test && docker exec portal-api rm /data/test
```
