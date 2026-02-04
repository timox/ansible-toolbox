# OIDCWarden - Gestionnaire de Mots de Passe avec SSO Avance

Fork de Vaultwarden par Timshel avec fonctionnalites SSO avancees pour deploiement organisationnel :
- **Sync groupes Keycloak → Organizations** : Chaque groupe = 1 coffre partage
- **Mapping roles** : admin-infra → admin Vaultwarden
- **Frontend ameliore** : Redirection auto vers SSO

Documentation : https://github.com/Timshel/OIDCWarden

## Pourquoi OIDCWarden vs Vaultwarden ?

| Fonctionnalite | Vaultwarden 1.35+ | OIDCWarden |
|----------------|-------------------|------------|
| SSO OIDC Keycloak | ✓ | ✓ |
| **Role Mapping (admin/user)** | ✗ | ✓ |
| **Org Mapping (groupes)** | ✗ | ✓ |
| **Auto-provisioning orgs** | ✗ | ✓ |
| Revocation on group removal | ✗ | ✓ |
| Sync on token refresh | ✗ | ✓ |

## Architecture

```
                              Keycloak
                                 │
                    ┌────────────┼────────────┐
                    │            │            │
               groups claim  roles claim  auth
                    │            │            │
                    ▼            ▼            ▼
              ┌─────────────────────────────────┐
              │          OIDCWarden             │
              │  ┌─────────┐  ┌──────────────┐  │
              │  │  Orgs   │  │ Admin/User   │  │
              │  │ Mapping │  │   Roles      │  │
              │  └─────────┘  └──────────────┘  │
              └─────────────────────────────────┘
                              │
              ┌───────────────┼───────────────┐
              │               │               │
         IT-Team Org    Finance Org    HR Org
         (du groupe)    (du groupe)   (du groupe)
```

## Prerequis

- Keycloak configure avec :
  - Client `vaultwarden` (confidential)
  - Mapper **groups** (Group Membership → groups claim)
  - Mapper **roles** (User Client Role → resource_access)
- Reseau Docker `portal-net` existant

## Installation

### 1. Configuration Keycloak

#### Creer le client

```
Clients > Create client

Client ID: vaultwarden
Client Protocol: openid-connect
Access Type: confidential

Valid Redirect URIs:
  - https://vault.example.com/*

Web Origins:
  - https://vault.example.com
```

#### Ajouter les mappers

**Mapper 1 - Groups (pour org mapping):**
```
Clients > vaultwarden > Client scopes > vaultwarden-dedicated > Add mapper

Name: groups
Mapper Type: Group Membership
Token Claim Name: groups
Full group path: OFF
Add to ID token: ON
Add to access token: ON
Add to userinfo: ON
```

**Mapper 2 - Client Roles (pour role mapping):**
```
Clients > vaultwarden > Roles > Create role
  - admin
  - user

Clients > vaultwarden > Client scopes > vaultwarden-dedicated > Add mapper

Name: client roles
Mapper Type: User Client Role
Client ID: vaultwarden
Token Claim Name: resource_access.${client_id}.roles
Add to ID token: ON
Add to access token: ON
```

**Creer les groupes pour les Organizations :**
```
Groups > Create group
  - admin-infra (admins infrastructure)
  - admin-standard (admins standards)
  - utilisateurs (utilisateurs finaux)
```

Chaque groupe Keycloak = 1 Organisation dans OIDCWarden avec coffre partage.

#### Assigner les roles aux utilisateurs

```
Users > <user> > Role mapping > Assign role > Filter by clients
  - Selectionner "admin" ou "user" du client vaultwarden

Users > [utilisateur] > Groups > Join Group
```

### 2. Configuration .env

```bash
# Copier configuration
cd environments/prod
cp .env.example .env

# Editer les variables OIDCWarden
nano .env
```

**Variables obligatoires :**

```bash
DOMAIN=example.com
KEYCLOAK_ISSUER=https://keycloak.example.com/realms/portal

# Client secret depuis Keycloak
OIDCWARDEN_CLIENT_SECRET=<secret-from-keycloak>

# Admin token pour /admin
VAULTWARDEN_ADMIN_TOKEN=$(openssl rand -base64 48)

# Role mapping (depuis token)
OIDCWARDEN_ROLES_ENABLED=true
OIDCWARDEN_ROLES_TOKEN_PATH=/resource_access/vaultwarden/roles

# Org mapping (depuis groupes Keycloak)
OIDCWARDEN_ORGS_ENABLED=true
OIDCWARDEN_ORGS_TOKEN_PATH=/groups
OIDCWARDEN_ORGS_REVOCATION=true
```

### 3. Deploiement

```bash
# Depuis la racine
./deploy.sh --service vault

# Ou manuellement
cd vaultwarden
docker compose up -d

# Verifier
docker compose logs -f vaultwarden
```

## Fonctionnalites Avancees

### Role Mapping

Les roles du token Keycloak definissent les droits dans OIDCWarden :

| Role Keycloak | Droit OIDCWarden |
|---------------|------------------|
| `admin` | Acces admin console + gestion utilisateurs |
| `user` | Acces standard (vault personnel) |

**Verification :**
```bash
# Decoder le token pour voir les roles
echo $ACCESS_TOKEN | cut -d'.' -f2 | base64 -d | jq '.resource_access.vaultwarden.roles'
```

### Organisation Mapping

Les groupes Keycloak creent automatiquement des organisations :

```
Keycloak Groups          →  OIDCWarden Organisations
─────────────────           ────────────────────────
/IT-Team                 →  IT-Team (auto-cree)
/Finance                 →  Finance (auto-cree)
/IT-Team/DevOps          →  IT-Team/DevOps (hierarchie)
```

**Comportement :**
- Premier login : invitation automatique aux orgs correspondant aux groupes
- Login suivant : sync des appartenances
- Suppression groupe Keycloak : revocation si `OIDCWARDEN_ORGS_REVOCATION=true`

### Configuration Avancee

```bash
# Forcer SSO uniquement (desactive email/password)
OIDCWARDEN_SSO_ONLY=true

# Utiliser realm roles au lieu de client roles
OIDCWARDEN_ROLES_TOKEN_PATH=/realm_access/roles

# Desactiver revocation (garder les utilisateurs meme si groupe retire)
OIDCWARDEN_ORGS_REVOCATION=false
```

## Utilisation

### Acces Web

- **URL** : https://vault.example.com
- **Login** : Cliquer "Enterprise Single Sign-On" → email → redirection Keycloak

### Apps Bitwarden

Les clients officiels Bitwarden sont 100% compatibles :
- Extension browser (Chrome, Firefox, Edge, Safari)
- App desktop (Windows, macOS, Linux)
- App mobile (iOS, Android)

**Configuration client :**
```
Settings > Self-hosted
Server URL: https://vault.example.com
```

## Administration

### Acces Admin

```
URL: https://vault.example.com/admin
Token: valeur de VAULTWARDEN_ADMIN_TOKEN
```

Note : Avec role mapping actif, les utilisateurs avec role `admin` dans Keycloak
ont automatiquement acces a l'admin sans token.

### Gestion des Organisations

```bash
# Voir les organisations creees
docker exec vaultwarden sqlite3 /data/db.sqlite3 "SELECT name FROM organizations;"

# Voir les membres
docker exec vaultwarden sqlite3 /data/db.sqlite3 \
  "SELECT u.email, o.name FROM users u
   JOIN users_organizations uo ON u.uuid = uo.user_uuid
   JOIN organizations o ON uo.org_uuid = o.uuid;"
```

### Backup

```bash
# Backup complet
docker compose exec vaultwarden tar czf /data/backup-$(date +%Y%m%d).tar.gz /data

# Ou copier le volume
docker cp vaultwarden:/data ./backup/
```

### Logs

```bash
# Logs standards
docker compose logs -f vaultwarden

# Debug SSO (activer dans .env: SSO_DEBUG_TOKENS=true)
docker compose logs vaultwarden | grep -i "sso\|oidc\|token"
```

## Troubleshooting

### Roles non reconnus

1. Verifier le mapper "client roles" dans Keycloak
2. Verifier le chemin : `OIDCWARDEN_ROLES_TOKEN_PATH`
3. Decoder le token pour voir la structure :
   ```bash
   # Le token doit contenir :
   # { "resource_access": { "vaultwarden": { "roles": ["admin"] } } }
   ```

### Organisations non creees

1. Verifier le mapper "groups" dans Keycloak
2. Verifier `OIDCWARDEN_ORGS_ENABLED=true`
3. L'utilisateur doit se deconnecter/reconnecter apres ajout au groupe

### Erreur "email not verified"

```bash
# Dans docker-compose.yml, deja configure :
SSO_ALLOW_UNKNOWN_EMAIL_VERIFICATION: "true"
```

### Token expire trop vite

Augmenter la duree dans Keycloak :
```
Clients > vaultwarden > Advanced Settings > Access Token Lifespan: 30m
```

## Documentation

- [OIDCWarden GitHub](https://github.com/Timshel/OIDCWarden)
- [OIDCWarden SSO.md](https://github.com/Timshel/OIDCWarden/blob/main/SSO.md)
- [Vaultwarden Wiki](https://github.com/dani-garcia/vaultwarden/wiki)
- [Bitwarden Help](https://bitwarden.com/help/)
