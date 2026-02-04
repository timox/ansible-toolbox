# Portail Applications - oauth2-proxy

## Vue d'Ensemble

Portail web custom pour afficher les applications disponibles selon les groupes AD de l'utilisateur authentifié via oauth2-proxy.

**Fonctionnalités** :
- Liste dynamique d'applications filtrées par groupe AD
- Authentification via oauth2-proxy (SSO Keycloak)
- Interface moderne, responsive, avec barre de recherche et compteur dynamique
- Aucune base de données requise (stateless)

## Architecture

```
Utilisateur → nginx → oauth2-proxy → nginx portail → Fichiers statiques
                ↓                              ↓
           Keycloak OIDC              Injection headers utilisateur
```

**Headers oauth2-proxy utilisés** :
- `X-Forwarded-Email` : Email utilisateur
- `X-Forwarded-Groups` : Groupes AD (comma-separated)
- `X-Forwarded-Preferred-Username` : Nom d'utilisateur

## Structure Fichiers

```
portal/
├── docker-compose.yml          # Service nginx portail
├── deploy.sh                   # Script de déploiement
├── README.md                   # Cette documentation
├── nginx/
│   ├── portal.conf.template   # Config nginx (template)
│   ├── portal.conf            # Config nginx (généré)
│   └── nginx.conf             # Config nginx principale
├── www/
│   ├── index.html             # Page principale
│   ├── style.css              # Styles
│   └── portal.js              # Logique filtrage apps
└── logs/                      # Logs nginx (créé au démarrage)
```

## Prérequis

### Services Requis

1. **oauth2-proxy** déployé et fonctionnel
   - Emplacement : `/home/user/pomeguac/environments/prod/oauth2-proxy/`
   - Port HTTPS : 44180
   - Doit être dans le réseau Docker `auth-net`

2. **Keycloak** configuré avec :
   - Client `oauth2-proxy` avec OIDC
   - Mappers : `email`, `groups`, `preferred_username`

3. **Réseau Docker `auth-net`** créé :
   ```bash
   docker network create auth-net
   ```

4. **Certificats SSL** :
   - Wildcard : `/data/certs/wildcard.${DOMAIN}.crt`
   - Clé privée : `/data/certs/wildcard.${DOMAIN}.key`

### Variables d'Environnement

Créer `.env` depuis `.env.template` :

```bash
# Domaine principal
DOMAIN=example.com

# Certificats SSL
TLS_CERT_FILE=/data/certs/wildcard.example.com.crt
TLS_KEY_FILE=/data/certs/wildcard.example.com.key
```

## Déploiement

### 1. Déploiement Automatisé

```bash
# Rendre le script exécutable
chmod +x deploy.sh

# Exécuter déploiement
./deploy.sh
```

Le script va :
1. Vérifier prérequis (réseau, certificats, oauth2-proxy)
2. Générer configuration nginx depuis template
3. Créer répertoires de logs
4. Démarrer conteneur nginx
5. Vérifier santé du service

### 2. Déploiement Manuel

```bash
# 1. Créer réseau si nécessaire
docker network create auth-net

# 2. Créer répertoire logs
mkdir -p logs

# 3. Générer configuration
export DOMAIN=example.com
envsubst < nginx/portal.conf.template > nginx/portal.conf

# 4. Démarrer service
docker-compose up -d

# 5. Vérifier
docker-compose ps
docker-compose logs -f portal-nginx
```

### 3. Vérification Déploiement

```bash
# Health check
curl http://localhost:8080/health
# Expected: OK

# Test HTTPS (avec certificat valide)
curl -k https://localhost:8443/health
# Expected: OK

# Vérifier logs
tail -f logs/access.log
```

## Configuration Applications

### Ajouter une Application

Éditer `www/portal.js` :

```javascript
const applications = {
    // ... applications existantes

    // Nouvelle application
    nouvelleapp: {
        name: "Nouvelle App",
        description: "Description de l'application",
        icon: "🚀",  // Emoji ou image
        url: "https://nouvelleapp.${DOMAIN}",
        groups: ["admin-infra", "utilisateurs"]  // Groupes autorisés
    }
};
```

**Groupes disponibles** :
- `tous` : Tous les utilisateurs authentifiés
- `admin-infra` : Administrateurs infrastructure
- `admin-standard` : Administrateurs standard
- `utilisateurs` : Utilisateurs standards

### Modifier le Style

Éditer `www/style.css` :

```css
/* Changer le gradient de fond */
body {
    background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
    /* Remplacer par vos couleurs */
}

/* Modifier taille des cartes */
.apps-grid {
    grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
    /* Ajuster 300px selon besoin */
}
```

## Intégration nginx Principal

Le portail doit être accessible via le nginx principal qui gère toutes les applications.

**Ajouter dans `environments/prod/oauth2-proxy/nginx/apps.conf`** :

```nginx
# Portail Applications
server {
    listen 443 ssl http2;
    server_name portail.${DOMAIN};

    ssl_certificate /certs/wildcard.${DOMAIN}.crt;
    ssl_certificate_key /certs/wildcard.${DOMAIN}.key;

    # Proxy vers portail nginx
    location / {
        proxy_pass https://portal-nginx:443;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

**Alternative : Servir directement depuis nginx principal** :

```nginx
# Dans nginx principal (apps.conf)
server {
    listen 443 ssl http2;
    server_name portail.${DOMAIN};

    ssl_certificate /certs/wildcard.${DOMAIN}.crt;
    ssl_certificate_key /certs/wildcard.${DOMAIN}.key;

    auth_request /oauth2/auth;
    error_page 401 = /oauth2/sign_in;

    auth_request_set $user $upstream_http_x_auth_request_user;
    auth_request_set $email $upstream_http_x_auth_request_email;
    auth_request_set $groups $upstream_http_x_auth_request_groups;

    # API endpoint
    location = /api/user {
        default_type application/json;
        return 200 '{"email": "$email", "name": "$user", "groups": "$groups"}';
    }

    # Fichiers statiques
    location / {
        root /opt/portal/www;
        try_files $uri $uri/ /index.html;
    }

    location /oauth2/ {
        proxy_pass https://oauth2-proxy:44180;
        proxy_set_header Host $host;
    }
}
```

## Endpoints API

### GET /api/user

Retourne informations utilisateur authentifié.

**Réponse** :
```json
{
    "email": "user@example.com",
    "name": "user",
    "groups": "admin-infra,utilisateurs"
}
```

**Utilisation JavaScript** :
```javascript
const response = await fetch('/api/user');
const data = await response.json();
console.log(data.email);    // user@example.com
console.log(data.groups);   // admin-infra,utilisateurs
```

### GET /health

Health check (pas d'authentification requise).

**Réponse** : `OK` (HTTP 200)

### GET /oauth2/sign_out

Déconnexion oauth2-proxy.

**Redirection** : `/oauth2/sign_out?rd=<redirect_url>`

## Debugging

### Problème : Page blanche

```bash
# Vérifier logs nginx
docker-compose logs portal-nginx

# Vérifier fichiers statiques
docker exec portal-nginx ls -la /usr/share/nginx/html/portal/

# Tester endpoint API
curl -k https://localhost:8443/api/user
```

### Problème : Applications non filtrées

```bash
# Vérifier headers dans logs
tail -f logs/access.log | grep auth_user

# Tester endpoint API manuellement
curl -k https://portail.example.com/api/user

# Vérifier console navigateur (F12)
# Doit montrer : currentUser.groups = ["admin-infra", ...]
```

### Problème : Erreur 401 Unauthorized

```bash
# Vérifier oauth2-proxy fonctionne
curl -k https://oauth2-proxy:44180/ping

# Vérifier réseau Docker
docker network inspect auth-net

# Vérifier config nginx auth_request
docker exec portal-nginx nginx -T | grep auth_request
```

### Problème : Certificat SSL invalide

```bash
# Vérifier certificat
openssl x509 -in /data/certs/wildcard.example.com.crt -noout -text

# Vérifier domaine couvert
openssl x509 -in /data/certs/wildcard.example.com.crt -noout -text | grep DNS

# Vérifier montage volume
docker exec portal-nginx ls -la /certs/
```

## Monitoring

### Logs

```bash
# Logs en temps réel
docker-compose logs -f

# Logs access uniquement
tail -f logs/access.log

# Logs erreurs uniquement
tail -f logs/error.log

# Filtrer par utilisateur
tail -f logs/access.log | grep 'user@example.com'

# Format d'audit (portail-access.log)
# <ip> - - [date] "GET /..." 200 612 referer="..." ua="..." email="user@example.com" groups="group1,group2" trace="<id>"
```

### Métriques

```bash
# Nombre de requêtes par utilisateur
awk '{print $NF}' logs/access.log | sort | uniq -c | sort -nr

# Top 10 applications accédées
grep -oP 'https://\K[^.]+' logs/access.log | sort | uniq -c | sort -nr | head -10

# Taux d'erreur 4xx/5xx
awk '$9 ~ /^[45]/ {print $9}' logs/access.log | sort | uniq -c
```

## Sécurité

### Headers de Sécurité

Le portail applique automatiquement :

```nginx
X-Frame-Options: SAMEORIGIN
X-Content-Type-Options: nosniff
X-XSS-Protection: 1; mode=block
Referrer-Policy: strict-origin-when-cross-origin
Strict-Transport-Security: max-age=31536000; includeSubDomains
Content-Security-Policy: default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; script-src 'self'; connect-src 'self'; frame-ancestors 'self'; base-uri 'self'; form-action 'self'
Permissions-Policy: camera=(), microphone=(), geolocation=()
Cross-Origin-Resource-Policy: same-origin
Cross-Origin-Opener-Policy: same-origin
X-Request-Id: <trace_id> (propagé à oauth2-proxy et aux logs)
```

### HTTPS Obligatoire

- Redirection HTTP → HTTPS automatique
- Cookie `_oauth2_proxy` avec flags `Secure`, `HttpOnly`, `SameSite=Lax`

### Authentification

- **Toutes les pages** requièrent authentification oauth2-proxy
- Seul `/health` est accessible sans auth (monitoring)

### Multi-realm Keycloak et rebond reverse-proxy

- **Pas de perte de session** : tant que le domaine reste identique (`*.sdis25.fr`) et que le cookie oauth2-proxy est positionné avec `--cookie-domain=.sdis25.fr`, la navigation qui repasse par le reverse-proxy vers un autre realm Keycloak conserve la trace de l'utilisateur.
- **Un client par realm** : créez un couple `client_id` / `client_secret` dédié par realm et instanciez soit plusieurs oauth2-proxy (un par realm), soit plusieurs routes avec des noms de cookie distincts (`--cookie-name=_oauth2_portal`, `_oauth2_remote`, etc.) pour éviter de réutiliser une session d'un realm sur un autre.
- **Paramètres clés par realm** : `--oidc-issuer-url=https://keycloak.example/realms/realm-x`, `--redirect-url=https://portail.example.com/oauth2/callback`, `--whitelist-domain=.sdis25.fr`, et un `--cookie-name` spécifique.
- **Traçabilité inter-proxy** : les en-têtes `X-Request-Id` et `X-Forwarded-*` sont propagés par nginx et oauth2-proxy ; même en cas de rebond externe (`remote.sdis25.fr → reverse proxy → realm B`), les logs `portal-access.log` et oauth2-proxy resteront corrélables via l'ID de requête.

## Maintenance

### Redémarrage

```bash
# Redémarrage propre
docker-compose restart

# Redémarrage complet (rebuild config)
docker-compose down && docker-compose up -d
```

### Mise à Jour Applications

```bash
# 1. Éditer www/portal.js
vim www/portal.js

# 2. Pas de redémarrage nécessaire (fichiers statiques)
# Les changements sont immédiatement visibles (F5 dans navigateur)
```

### Mise à Jour Configuration nginx

```bash
# 1. Éditer template
vim nginx/portal.conf.template

# 2. Regénérer config
envsubst < nginx/portal.conf.template > nginx/portal.conf

# 3. Tester config
docker exec portal-nginx nginx -t

# 4. Recharger nginx
docker exec portal-nginx nginx -s reload
```

### Rotation Logs

```bash
# Créer /etc/logrotate.d/portal-nginx
cat > /etc/logrotate.d/portal-nginx <<EOF
/home/user/pomeguac/environments/prod/portal/logs/*.log {
    daily
    rotate 7
    compress
    delaycompress
    notifempty
    create 0640 root root
    sharedscripts
    postrotate
        docker exec portal-nginx nginx -s reopen
    endscript
}
EOF
```

## Personnalisation Avancée

### Ajouter Icônes Personnalisées

```javascript
// Dans portal.js
const applications = {
    guacamole: {
        name: "Guacamole",
        icon: '<img src="/icons/guacamole.png" alt="Guacamole">',
        // ... reste config
    }
};
```

### Groupes Complexes

```javascript
// Logique AND (utilisateur doit avoir TOUS les groupes)
function canAccessApp(app) {
    if (app.groups.includes('tous')) return true;

    // AND logic : utilisateur doit avoir TOUS les groupes requis
    return app.groups.every(requiredGroup =>
        currentUser.groups.some(userGroup =>
            userGroup.toLowerCase().includes(requiredGroup.toLowerCase())
        )
    );
}
```

### Recherche Applications

Ajouter dans `index.html` :

```html
<div class="search-bar">
    <input type="text" id="search" placeholder="Rechercher une application..."
           onkeyup="filterApps()">
</div>
```

Ajouter dans `portal.js` :

```javascript
function filterApps() {
    const search = document.getElementById('search').value.toLowerCase();
    const cards = document.querySelectorAll('.app-card');

    cards.forEach(card => {
        const name = card.querySelector('.app-name').textContent.toLowerCase();
        const desc = card.querySelector('.app-description').textContent.toLowerCase();

        if (name.includes(search) || desc.includes(search)) {
            card.style.display = '';
        } else {
            card.style.display = 'none';
        }
    });
}
```

## Support

**Documentation complète** : `/home/user/pomeguac/docs/`

**Fichiers connexes** :
- oauth2-proxy : `environments/prod/oauth2-proxy/README.md`
- Keycloak : `docs/KEYCLOAK-CONFIG.md`
- Architecture : `docs/ARCHITECTURE.md`

**Contact** : support@example.com

---

**Version** : 1.0
**Date** : 2025-11-23
**Compatible avec** : oauth2-proxy v7.6.0+
