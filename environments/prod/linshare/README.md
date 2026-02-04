# LinShare - Partage de Fichiers Sécurisé

Solution de partage de fichiers sécurisés intégrée au portail avec authentification Keycloak OIDC et exposition via oauth2-proxy.

## Table des Matières

- [Vue d'ensemble](#vue-densemble)
- [Architecture](#architecture)
- [Sécurité](#sécurité)
- [Installation](#installation)
- [Configuration](#configuration)
- [Utilisation](#utilisation)
- [Administration](#administration)
- [Troubleshooting](#troubleshooting)

## Vue d'ensemble

### Qu'est-ce que LinShare ?

LinShare est une solution open source de partage de fichiers sécurisés conçue pour les organisations avec des exigences de sécurité élevées. Elle permet :

| Fonctionnalité | Description |
|----------------|-------------|
| Transferts sécurisés | Chiffrement des fichiers, liens temporaires avec expiration |
| Scan antivirus | Intégration ClamAV pour vérification automatique |
| Gestion des droits | Contrôle d'accès par groupes Keycloak |
| Quotas utilisateur | Limitation de l'espace de stockage par utilisateur |
| Audit complet | Traçabilité de tous les uploads/downloads |
| Notifications | Emails automatiques pour partages et téléchargements |
| Partage externe | Invités temporaires pour partages avec des externes |
| Workgroups | Espaces collaboratifs partagés |

### Intégration avec le Portail

```
Utilisateur → oauth2-proxy + nginx → LinShare → Keycloak (OIDC)
                     ↓                    ↓
                 Contrôle             Stockage
                 d'accès              sécurisé
```

LinShare s'intègre parfaitement dans votre portail sécurisé :

- **Authentification** : Via Keycloak OIDC (pas de LDAP nécessaire)
- **Autorisation** : Basée sur les groupes Keycloak
- **Exposition** : Via oauth2-proxy avec headers X-Forwarded-*
- **Audit** : Logs centralisés avec identité utilisateur réelle

## Architecture

### Composants

| Conteneur | Rôle | Port | Réseau |
|-----------|------|------|--------|
| linshare-postgres | Base de données métadonnées | 5432 | linshare-net |
| linshare-mongodb | Stockage fichiers (GridFS) | 27017 | linshare-net |
| linshare-backend | API REST LinShare | 8080 | linshare-net, apps-net |
| linshare-ui-user | Interface utilisateur | 8082 | apps-net |
| linshare-ui-admin | Interface administration | 8083 | apps-net |
| linshare-antivirus | ClamAV scan antivirus | 3310 | linshare-net |
| linshare-thumbnail | Génération miniatures | 8080 | linshare-net |
| linshare-smtp | Serveur mail notifications | 25 | linshare-net |

### Flux de Données

```
1. Upload fichier:
   User → oauth2-proxy/nginx → LinShare UI → Backend → ClamAV scan → MongoDB

2. Authentification:
   User → oauth2-proxy → Keycloak OIDC → Token JWT → LinShare

3. Download fichier:
   User → oauth2-proxy/nginx → LinShare Backend → MongoDB → User
                                                ↓
                                             Audit log
```

### Stockage

| Répertoire | Contenu | Taille estimée |
|------------|---------|----------------|
| /data/linshare/postgres | Métadonnées utilisateurs, partages | 1-5 GB |
| /data/linshare/mongodb | Fichiers uploadés | Variable (quotas) |
| /data/linshare/files | Stockage filesystem (alternative) | Variable |
| /data/linshare/clamav | Signatures antivirus | 2-3 GB |
| /data/linshare/logs | Logs applicatifs | 1-10 GB |

## Sécurité

### Authentification OIDC

LinShare utilise Keycloak comme fournisseur d'identité :

```yaml
Flow d'authentification:
1. User accède https://linshare.example.com
2. Redirection vers Keycloak (/auth/realms/enterprise)
3. User s'authentifie (+ MFA si configuré)
4. Keycloak génère token JWT avec claims
5. Redirection vers LinShare avec token
6. LinShare valide token et crée/auth user
```

### Gestion des Groupes

| Groupe Keycloak | Rôle LinShare | Droits |
|-----------------|---------------|--------|
| GG-POM-ADMINS | Admin | Administration complète |
| GG-POM-USERS | User | Upload, partage interne |
| GG-POM-LINSHARE-ADVANCED | Power User | Upload, partage externe, invités |

### Scan Antivirus

Tous les fichiers uploadés sont scannés automatiquement :

- **Engine** : ClamAV avec signatures à jour
- **Action** : Rejet automatique si virus détecté
- **Logs** : Événements consignés pour audit
- **Performance** : Scan asynchrone, pas de blocage UI

### Contrôles d'Accès

| Contrôle | Implémentation |
|----------|----------------|
| Taille max fichier | 100 MB par défaut (configurable) |
| Quota utilisateur | 10 GB par défaut (configurable) |
| Types MIME interdits | .exe, .bat, .cmd, .com, .pif, .scr, .vbs |
| Expiration partages | 30 jours par défaut, 365 jours max |
| Partage externe | Requiert groupe LINSHARE-ADVANCED |
| Sessions | Timeout 1h, cookies sécurisés |

### Audit et Traçabilité

LinShare enregistre :

- Identité utilisateur (via headers oauth2-proxy)
- Actions : upload, download, partage, suppression
- Horodatage précis
- Adresses IP sources
- Fichiers concernés

## Installation

### Prérequis

1. **Infrastructure** :
   - Docker et Docker Compose
   - 4 CPU, 8 GB RAM minimum
   - 50 GB stockage pour démarrage
   - Certificat wildcard valide

2. **Configuration Keycloak** :
   - Client OIDC "linshare" créé
   - Groupes utilisateur configurés
   - Mapper "groups" dans token ID

3. **Configuration oauth2-proxy** :
   - Routes LinShare ajoutées dans nginx apps.conf
   - Certificats SSL en place

### Déploiement

```bash
# 1. Se placer dans le répertoire LinShare
cd /home/user/pomeguac/environments/prod/linshare

# 2. Copier et configurer les variables d'environnement
cd ..
cp .env.example .env
vim .env  # Configurer LINSHARE_* variables

# 3. Configurer Keycloak (voir instructions ci-dessous)

# 4. Lancer le déploiement
cd linshare
./deploy-linshare.sh
```

### Configuration Keycloak

```
Étapes dans l'interface Keycloak:

1. Clients → Create Client
   - Client ID: linshare
   - Client Protocol: openid-connect
   - Access Type: confidential

2. Settings (onglet)
   - Root URL: https://linshare.example.com
   - Valid Redirect URIs: https://linshare.example.com/*
   - Web Origins: https://linshare.example.com
   - Save

3. Credentials (onglet)
   - Copier le Secret
   - L'ajouter dans .env: LINSHARE_OIDC_CLIENT_SECRET=<secret>

4. Mappers → Create
   - Name: groups
   - Mapper Type: Group Membership
   - Token Claim Name: groups
   - Full group path: OFF
   - Add to ID token: ON
   - Add to access token: ON
   - Save

5. Vérifier les groupes existent :
   - GG-POM-ADMINS
   - GG-POM-USERS
   - GG-POM-LINSHARE-ADVANCED (optionnel)
```

## Configuration

### Variables d'Environnement

Principales variables dans `environments/prod/.env` :

```bash
# Base de données
LINSHARE_DB_PASSWORD=<mot-de-passe-postgres>
LINSHARE_MONGO_PASSWORD=<mot-de-passe-mongodb>

# OIDC
LINSHARE_OIDC_CLIENT_ID=linshare
LINSHARE_OIDC_CLIENT_SECRET=<depuis-keycloak>

# Groupes
LINSHARE_ADMIN_GROUP=GG-POM-ADMINS
LINSHARE_USER_GROUP=GG-POM-USERS

# Limites
LINSHARE_MAX_FILE_SIZE=104857600   # 100 MB
LINSHARE_QUOTA_DEFAULT=10737418240 # 10 GB

# SMTP (optionnel)
LINSHARE_SMTP_HOST=smtp.example.com
LINSHARE_SMTP_FROM=noreply@example.com
```

### Fichiers de Configuration

| Fichier | Rôle |
|---------|------|
| docker-compose.linshare.yml | Définition des services |
| config/linshare.properties | Configuration backend LinShare |
| config/config.js | Configuration UI utilisateur |
| init-db.sql | Initialisation PostgreSQL |

### Personnalisation

#### Modifier les quotas

Éditez `.env` :

```bash
LINSHARE_MAX_FILE_SIZE=209715200    # 200 MB
LINSHARE_QUOTA_DEFAULT=53687091200  # 50 GB
```

Puis redémarrez :

```bash
cd /home/user/pomeguac/environments/prod/linshare
docker-compose -f docker-compose.linshare.yml restart linshare-backend
```

#### Ajouter des types MIME autorisés

Dans `config/linshare.properties` :

```properties
# Autoriser uniquement PDF et images
linshare.documents.allowed-mime-types=application/pdf,image/jpeg,image/png,image/gif
```

## Utilisation

### Accès Utilisateur

1. Ouvrir https://linshare.example.com
2. Authentification via Keycloak (avec MFA si configuré)
3. Première connexion : création automatique du compte LinShare

### Upload de Fichiers

```
Interface utilisateur:
1. Cliquer sur "Upload" ou glisser-déposer
2. Sélectionner fichier(s)
3. Upload automatique avec scan antivirus
4. Fichier disponible dans "My Space"
```

### Partage de Fichiers

| Type de partage | Description | Requis |
|-----------------|-------------|--------|
| Interne | Partage avec utilisateurs de l'organisation | Groupe USERS |
| Externe (invité) | Créer un compte temporaire pour externe | Groupe ADVANCED |
| Lien public | Lien temporaire sans auth | Groupe ADVANCED |
| Workgroup | Espace collaboratif partagé | Groupe USERS |

### Notifications

LinShare envoie des emails automatiquement pour :

- Upload dans un partage
- Download d'un fichier partagé
- Expiration proche d'un partage
- Invitation à un workgroup

## Administration

### Interface Admin

Accès : https://linshare-admin.example.com

Identifiants par défaut (à changer immédiatement) :
- Login: root@localhost.localdomain
- Password: adminlinshare

### Gestion des Utilisateurs

```
Admin UI → Users:
- Voir tous les utilisateurs créés automatiquement via OIDC
- Modifier quotas individuels
- Activer/désactiver comptes
- Consulter utilisation stockage
```

### Gestion des Domaines

LinShare organise les utilisateurs en domaines (équivalent des tenants).

Pour ce déploiement : 1 domaine = LinShareRootDomain (tous les users)

### Politiques de Sécurité

```
Admin UI → Functionality:
- Activer/désactiver partage externe
- Définir taille max fichiers
- Configurer expiration par défaut
- Activer notifications
- Gérer types MIME autorisés
```

### Quotas

| Niveau | Configuration |
|--------|---------------|
| Global | Quota total LinShare |
| Domaine | Quota pour tous les users d'un domaine |
| Utilisateur | Quota individuel |

### Surveillance

#### Logs

```bash
# Logs backend
docker logs -f linshare-backend

# Logs antivirus
docker logs -f linshare-clamav

# Logs toutes les composantes
cd /home/user/pomeguac/environments/prod/linshare
docker-compose -f docker-compose.linshare.yml logs -f
```

#### Métriques

LinShare expose des métriques pour monitoring :

- Nombre d'uploads/downloads
- Utilisation stockage
- Fichiers scannés/infectés
- Temps de réponse API

#### Healthchecks

```bash
# Vérifier statut de tous les services
cd /home/user/pomeguac/environments/prod/linshare
docker-compose -f docker-compose.linshare.yml ps

# Tester health endpoint
curl http://localhost:8080/linshare/webservice/rest/actuator/health
```

### Sauvegarde

#### Données à sauvegarder

```bash
# 1. Base PostgreSQL
docker exec linshare-postgres pg_dump -U linshare linshare > backup-postgres-$(date +%Y%m%d).sql

# 2. Base MongoDB
docker exec linshare-mongodb mongodump --out=/backup --gzip

# 3. Fichiers filesystem (si utilisé)
tar -czf backup-files-$(date +%Y%m%d).tar.gz /data/linshare/files/

# 4. Configuration
tar -czf backup-config-$(date +%Y%m%d).tar.gz /home/user/pomeguac/environments/prod/linshare/config/
```

#### Restauration

```bash
# 1. PostgreSQL
docker exec -i linshare-postgres psql -U linshare linshare < backup-postgres-YYYYMMDD.sql

# 2. MongoDB
docker cp backup/ linshare-mongodb:/backup
docker exec linshare-mongodb mongorestore /backup --gzip

# 3. Fichiers
tar -xzf backup-files-YYYYMMDD.tar.gz -C /
```

## Troubleshooting

### Problèmes Courants

#### LinShare inaccessible

```bash
# Vérifier conteneurs
docker ps | grep linshare

# Vérifier logs
docker logs linshare-backend

# Vérifier nginx (reverse proxy)
docker logs nginx-apps | grep linshare
```

#### Erreur OIDC "Invalid redirect URI"

Vérifier dans Keycloak :
- Client "linshare" existe
- Valid Redirect URIs contient: https://linshare.example.com/*

#### Upload échoue

```bash
# Vérifier ClamAV
docker logs linshare-clamav

# ClamAV peut prendre 5-10 min au premier démarrage
# Attendre téléchargement des signatures

# Vérifier quota utilisateur
# Admin UI → Users → <user> → Quota
```

#### Notifications non envoyées

Vérifier configuration SMTP dans `.env` :

```bash
LINSHARE_SMTP_HOST=smtp.example.com
LINSHARE_SMTP_PORT=587
LINSHARE_SMTP_USER=linshare@example.com
LINSHARE_SMTP_PASSWORD=<password>
```

Redémarrer backend :

```bash
docker-compose -f docker-compose.linshare.yml restart linshare-backend
```

#### Base de données corrompue

```bash
# Restaurer depuis backup
docker-compose -f docker-compose.linshare.yml down
docker volume rm linshare_postgres_data
docker-compose -f docker-compose.linshare.yml up -d linshare-db
# Attendre démarrage
docker exec -i linshare-postgres psql -U linshare linshare < backup.sql
docker-compose -f docker-compose.linshare.yml up -d
```

### Logs de Debug

Activer debug dans `config/linshare.properties` :

```properties
logging.level.root=DEBUG
logging.level.org.linagora.linshare=DEBUG
```

Redémarrer :

```bash
docker-compose -f docker-compose.linshare.yml restart linshare-backend
```

### Support

| Ressource | URL |
|-----------|-----|
| Documentation officielle | https://www.linshare.org/documentation |
| GitHub | https://github.com/linagora/linshare |
| Forum | https://forum.linshare.org |

## Références

- [Documentation LinShare](https://www.linshare.org/documentation)
- [Configuration OIDC LinShare](https://github.com/linagora/linshare/wiki/OIDC-configuration)
- [Documentation oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/)
- [Keycloak Client Configuration](https://www.keycloak.org/docs/latest/server_admin/#_clients)
