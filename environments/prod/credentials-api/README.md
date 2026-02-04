# Credentials API

API Flask pour le stockage securise des mots de passe RDP dans le portail Guacamole.

## Vue d'Ensemble

L'API credentials permet aux utilisateurs de stocker leurs mots de passe RDP de maniere securisee
via le portail web. Les credentials sont chiffres et associes a l'utilisateur authentifie via oauth2-proxy.

## Architecture

```
Portail Web → nginx → oauth2-proxy → credentials-api (Flask)
                                          ↓
                                      SQLite (chiffre)
```

## Endpoints

| Methode | Endpoint | Description |
|---------|----------|-------------|
| GET | `/api/credentials` | Liste les credentials de l'utilisateur |
| POST | `/api/credentials` | Cree un nouveau credential |
| PUT | `/api/credentials/{id}` | Met a jour un credential |
| DELETE | `/api/credentials/{id}` | Supprime un credential |
| GET | `/api/connections` | Liste les connexions Guacamole |
| GET | `/health` | Health check |

## Securite

- **Authentification** : Via header `X-Forwarded-User` injecte par oauth2-proxy
- **Chiffrement** : AES-256 pour les mots de passe stockes
- **Isolation** : Chaque utilisateur ne voit que ses propres credentials

## Configuration

### Variables d'Environnement

| Variable | Description | Defaut |
|----------|-------------|--------|
| `ENCRYPTION_KEY` | Cle AES-256 (base64) | Requis |
| `DATABASE_PATH` | Chemin SQLite | `/data/credentials.db` |
| `GUACAMOLE_DB_*` | Connexion PostgreSQL Guacamole | Requis |

### docker-compose.yml

```yaml
services:
  credentials-api:
    build: .
    environment:
      - ENCRYPTION_KEY=${CREDENTIALS_ENCRYPTION_KEY}
      - GUACAMOLE_DB_HOST=guacamole-db
      - GUACAMOLE_DB_PORT=5432
      - GUACAMOLE_DB_NAME=guacamole_db
      - GUACAMOLE_DB_USER=guacamole_user
      - GUACAMOLE_DB_PASSWORD=${GUACAMOLE_DB_PASSWORD}
    volumes:
      - credentials-data:/data
    networks:
      - portal-net
```

## Deploiement

Le service est deploye automatiquement par `deploy.sh` quand `DEPLOY_PORTAL=true`.

```bash
cd environments/prod
./deploy.sh --service portal
```

## Schema Base de Donnees

**SQLite** (`/data/credentials.db`) :

```sql
CREATE TABLE credentials (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_email TEXT NOT NULL,
    connection_name TEXT NOT NULL,
    username TEXT NOT NULL,
    password_encrypted TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(user_email, connection_name)
);
```

## Utilisation depuis le Portail

Le portail web utilise l'API pour pre-remplir les credentials RDP :

```javascript
// Sauvegarder un credential
fetch('/api/credentials', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
        connection_name: 'Serveur-01',
        username: 'jean.dupont',
        password: 'MonMotDePasse'
    })
});

// Recuperer les credentials
fetch('/api/credentials')
    .then(r => r.json())
    .then(data => console.log(data));
```

## Troubleshooting

### API retourne 401

```bash
# Verifier que oauth2-proxy injecte le header
curl -v https://portail.example.com/api/credentials 2>&1 | grep X-Forwarded

# Header attendu : X-Forwarded-User: user@example.com
```

### Erreur chiffrement

```bash
# Verifier la cle de chiffrement
docker exec credentials-api printenv ENCRYPTION_KEY

# La cle doit etre 32 bytes en base64
```

### Base de donnees corrompue

```bash
# Backup et recreer
cp /data/credentials.db /data/credentials.db.bak
rm /data/credentials.db
docker restart credentials-api
```

## Fichiers

| Fichier | Description |
|---------|-------------|
| `app.py` | Application Flask principale |
| `schema.sql` | Schema SQLite |
| `migrate-v2.sql` | Migration vers v2 |
| `requirements.txt` | Dependances Python |
| `Dockerfile` | Build image |

---

**Version** : 1.0
**Date** : Janvier 2026
