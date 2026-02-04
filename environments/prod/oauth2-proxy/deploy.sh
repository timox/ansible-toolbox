#!/bin/bash
# Script de déploiement oauth2-proxy + nginx
# Version 2.0 - Migration depuis Pomerium

set -e

# Couleurs pour output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Déploiement oauth2-proxy + nginx${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Déterminer le répertoire du script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# 1. Charger variables d'environnement
echo -e "${BLUE}[1/10]${NC} Chargement de la configuration..."
# Utiliser .env centralisé dans le dossier parent (environments/prod/.env)
if [ -f ../.env ]; then
    export $(grep -v '^#' ../.env | xargs)
    ENV_FILE="../.env"
    echo -e "${GREEN}✓${NC} Fichier .env chargé depuis environments/prod/.env"
elif [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
    ENV_FILE=".env"
    echo -e "${GREEN}✓${NC} Fichier .env chargé (local)"
else
    echo -e "${RED}✗${NC} Erreur: Fichier .env manquant"
    echo ""
    echo "Étapes à suivre:"
    echo "  1. cd /home/user/pomeguac/environments/prod"
    echo "  2. cp .env.example .env"
    echo "  3. Éditer .env avec vos valeurs (voir section oauth2-proxy)"
    echo "  4. cd oauth2-proxy && ./deploy.sh"
    exit 1
fi

# Variables avec valeurs par défaut
DOMAIN=${DOMAIN:-"example.com"}
CERT_PATH="${TLS_CERT_FILE:-/data/certs/wildcard.${DOMAIN}.crt}"
KEY_PATH="${TLS_KEY_FILE:-/data/certs/wildcard.${DOMAIN}.key}"

# 2. Vérifier prérequis
echo -e "${BLUE}[2/10]${NC} Vérification des prérequis..."

# Vérifier certificats SSL
if [ ! -f "$CERT_PATH" ]; then
    echo -e "${RED}✗${NC} Certificat SSL manquant: $CERT_PATH"
    exit 1
else
    echo -e "${GREEN}✓${NC} Certificat SSL trouvé: $CERT_PATH"
fi

if [ ! -f "$KEY_PATH" ]; then
    echo -e "${RED}✗${NC} Clé privée SSL manquante: $KEY_PATH"
    exit 1
else
    echo -e "${GREEN}✓${NC} Clé privée SSL trouvée: $KEY_PATH"
fi

# Vérifier Keycloak issuer
if [ -z "$KEYCLOAK_ISSUER" ]; then
    echo -e "${RED}✗${NC} KEYCLOAK_ISSUER non défini dans .env"
    exit 1
else
    echo -e "${GREEN}✓${NC} KEYCLOAK_ISSUER: $KEYCLOAK_ISSUER"
fi

# Vérifier OIDC client ID (valeur par défaut pour compatibilité)
if [ -z "$OIDC_CLIENT_ID" ]; then
    echo -e "${YELLOW}⚠${NC} OIDC_CLIENT_ID non défini, utilisation de la valeur par défaut: oauth2-proxy"
    OIDC_CLIENT_ID="oauth2-proxy"
fi
# Exporter pour envsubst et autres sous-processus
export OIDC_CLIENT_ID

# Vérifier OIDC client secret
if [ -z "$OIDC_CLIENT_SECRET" ]; then
    echo -e "${RED}✗${NC} OIDC_CLIENT_SECRET non défini dans .env"
    echo "Récupérer le secret depuis Keycloak: Clients → oauth2-proxy → Credentials"
    exit 1
else
    echo -e "${GREEN}✓${NC} OIDC_CLIENT_SECRET configuré"
fi

# Vérifier Docker
if ! command -v docker &> /dev/null; then
    echo -e "${RED}✗${NC} Docker n'est pas installé"
    exit 1
else
    echo -e "${GREEN}✓${NC} Docker installé: $(docker --version)"
fi

# Vérifier docker compose (nouvelle syntaxe v2)
if ! docker compose version &> /dev/null; then
    echo -e "${RED}✗${NC} docker compose n'est pas installé"
    exit 1
else
    echo -e "${GREEN}✓${NC} docker compose installé: $(docker compose version --short)"
fi

# 3. Créer structure de répertoires
echo -e "${BLUE}[3/10]${NC} Création de la structure de répertoires..."
mkdir -p /data/certs
mkdir -p nginx
echo -e "${GREEN}✓${NC} Répertoires créés"

# 4. Copier certificats (si nécessaire)
echo -e "${BLUE}[4/10]${NC} Installation des certificats..."

# Copier uniquement si source != destination
CERT_DEST="/data/certs/$(basename "$CERT_PATH")"
KEY_DEST="/data/certs/$(basename "$KEY_PATH")"

if [ "$CERT_PATH" != "$CERT_DEST" ]; then
    cp "$CERT_PATH" /data/certs/
    echo -e "${GREEN}✓${NC} Certificat copié: $CERT_PATH → /data/certs/"
else
    echo -e "${GREEN}✓${NC} Certificat déjà en place: $CERT_PATH"
fi

if [ "$KEY_PATH" != "$KEY_DEST" ]; then
    cp "$KEY_PATH" /data/certs/
    echo -e "${GREEN}✓${NC} Clé privée copiée: $KEY_PATH → /data/certs/"
else
    echo -e "${GREEN}✓${NC} Clé privée déjà en place: $KEY_PATH"
fi

# Permissions: 644 pour certificats (lecture publique), 640 pour clés (lecture groupe)
# Les conteneurs Docker peuvent lire avec ces permissions via volume mount
chmod 644 /data/certs/*.crt 2>/dev/null || true
chmod 640 /data/certs/*.key 2>/dev/null || true
echo -e "${GREEN}✓${NC} Permissions certificats configurées (644/640)"

# 5. Générer cookie secret si nécessaire
echo -e "${BLUE}[5/10]${NC} Vérification des secrets..."
if [ -z "$COOKIE_SECRET" ]; then
    echo -e "${YELLOW}⚠${NC} COOKIE_SECRET non défini, génération..."
    COOKIE_SECRET=$(python3 -c 'import os,base64; print(base64.urlsafe_b64encode(os.urandom(32)).decode())')
    echo "COOKIE_SECRET=${COOKIE_SECRET}" >> "$ENV_FILE"
    export COOKIE_SECRET
    echo -e "${GREEN}✓${NC} Cookie secret généré et ajouté à $ENV_FILE"
else
    echo -e "${GREEN}✓${NC} COOKIE_SECRET déjà configuré"
fi

# 6. Générer configuration depuis templates
echo -e "${BLUE}[6/10]${NC} Génération des fichiers de configuration..."

# Vérifier envsubst
if ! command -v envsubst &> /dev/null; then
    echo -e "${RED}✗${NC} envsubst non disponible (installer gettext-base)"
    exit 1
fi

# Générer oauth2-proxy.cfg
if [ -f templates/oauth2-proxy.cfg.template ]; then
    envsubst '$DOMAIN $KEYCLOAK_ISSUER $KEYCLOAK_HOST $OIDC_CLIENT_ID $OIDC_CLIENT_SECRET $COOKIE_SECRET $TLS_CERT_FILE $TLS_KEY_FILE $OAUTH2_PROXY_REDIRECT_URL $OAUTH2_PROXY_HTTPS_ADDRESS $OAUTH2_PROXY_COOKIE_DOMAINS $OAUTH2_PROXY_COOKIE_SECURE' < templates/oauth2-proxy.cfg.template > oauth2-proxy.cfg
    echo -e "${GREEN}✓${NC} oauth2-proxy.cfg généré"
else
    echo -e "${RED}✗${NC} Template oauth2-proxy.cfg.template non trouvé"
    exit 1
fi

# Générer nginx apps.conf
if [ -f nginx/apps.conf.template ]; then
    envsubst '$DOMAIN' < nginx/apps.conf.template > nginx/apps.conf
    echo -e "${GREEN}✓${NC} nginx/apps.conf généré"
else
    echo -e "${YELLOW}⚠${NC} Template nginx/apps.conf.template non trouvé, création manuelle requise"
fi

# 7. Afficher instructions Keycloak
echo ""
echo -e "${BLUE}[7/10]${NC} Configuration Keycloak requise:"
echo -e "${YELLOW}========================================${NC}"
echo -e "Si ce n'est pas déjà fait, configurer dans Keycloak:"
echo ""
echo "  1. Créer client 'oauth2-proxy'"
echo "     - Client Protocol: openid-connect"
echo "     - Access Type: confidential"
echo ""
echo "  2. Valid Redirect URIs:"
echo "     - https://portail.${DOMAIN}/oauth2/callback"
echo "     - https://*.${DOMAIN}/oauth2/callback"
echo ""
echo "  3. Mappers (Clients → oauth2-proxy → Mappers):"
echo "     a) groups mapper:"
echo "        - Name: groups"
echo "        - Mapper Type: Group Membership"
echo "        - Token Claim Name: groups"
echo "        - Add to ID token: ON"
echo ""
echo "     b) Vérifier mappers standards (email, preferred_username)"
echo ""
echo "  4. Copier Client Secret:"
echo "     - Clients → oauth2-proxy → Credentials → Client Secret"
echo "     - Ajouter dans .env → OIDC_CLIENT_SECRET"
echo ""
echo "  5. MFA RADIUS (optionnel):"
echo "     - Authentication → Flows → Browser"
echo "     - Add execution → RADIUS"
echo "     - Server: ${RADIUS_SERVER:-10.0.0.50}"
echo "     - Port: ${RADIUS_PORT:-1812}"
echo "     - Set as Required"
echo -e "${YELLOW}========================================${NC}"
echo ""

read -p "Continuer le déploiement? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Déploiement annulé${NC}"
    exit 0
fi

# 8. Arrêter anciens services (si migration Pomerium)
echo -e "${BLUE}[8/10]${NC} Vérification services existants..."
if docker ps | grep -q pomerium; then
    echo -e "${YELLOW}⚠${NC} Services Pomerium détectés"
    read -p "Arrêter Pomerium avant déploiement oauth2-proxy? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Arrêt des services Pomerium..."
        docker stop pomerium-auth 2>/dev/null || true
        docker stop portal-web 2>/dev/null || true
        echo -e "${GREEN}✓${NC} Services Pomerium arrêtés"
    fi
fi

# 9. Créer réseaux et démarrer services
echo -e "${BLUE}[9/10]${NC} Création des réseaux et démarrage des conteneurs..."

# Créer les réseaux externes si nécessaire
for net in "guacamole-net" "portal-net" "prod_apps-net"; do
    if ! docker network inspect "$net" >/dev/null 2>&1; then
        echo -e "  Création du réseau $net..."
        docker network create "$net"
    fi
done

echo -e "${GREEN}✓${NC} Réseaux Docker prêts"

# Démarrer les backends
PROD_DIR="$(dirname "$SCRIPT_DIR")"

echo -e "${YELLOW}Démarrage des backends...${NC}"
if [ -f "$PROD_DIR/guacamole/docker compose.yml" ]; then
    echo -e "  Guacamole..."
    docker compose -f "$PROD_DIR/guacamole/docker compose.yml" up -d 2>/dev/null || true
fi
if [ -f "$PROD_DIR/linshare/docker compose.linshare.yml" ]; then
    echo -e "  LinShare..."
    docker compose -f "$PROD_DIR/linshare/docker compose.linshare.yml" up -d 2>/dev/null || true
fi
if [ -f "$PROD_DIR/credentials-api/docker compose.yml" ]; then
    echo -e "  Credentials API..."
    docker compose -f "$PROD_DIR/credentials-api/docker compose.yml" up -d 2>/dev/null || true
fi
if [ -f "$PROD_DIR/portal/docker compose.yml" ]; then
    echo -e "  Portal..."
    docker compose -f "$PROD_DIR/portal/docker compose.yml" up -d 2>/dev/null || true
fi
echo -e "${GREEN}✓${NC} Backends démarrés"

docker compose up -d

# Attendre démarrage
echo "Attente du démarrage des services..."
sleep 5

# 10. Vérification déploiement
echo -e "${BLUE}[10/10]${NC} Vérification du déploiement..."

# Vérifier oauth2-proxy
if curl -k https://localhost:44180/ping > /dev/null 2>&1; then
    echo -e "${GREEN}✓${NC} oauth2-proxy opérationnel (port 44180)"
else
    echo -e "${RED}✗${NC} oauth2-proxy non accessible"
    echo "Logs oauth2-proxy:"
    docker compose logs --tail=20 oauth2-proxy
    exit 1
fi

# Vérifier nginx
if docker compose ps nginx-apps | grep -q "Up"; then
    echo -e "${GREEN}✓${NC} nginx opérationnel"

    # Test configuration nginx
    if docker exec nginx-apps nginx -t 2>&1 | grep -q "successful"; then
        echo -e "${GREEN}✓${NC} Configuration nginx valide"
    else
        echo -e "${RED}✗${NC} Erreur configuration nginx"
        docker exec nginx-apps nginx -t
    fi
else
    echo -e "${RED}✗${NC} nginx non démarré"
    echo "Logs nginx:"
    docker compose logs --tail=20 nginx-apps
    exit 1
fi

# Vérifier Redis si profil HA
if docker compose ps redis 2>/dev/null | grep -q "Up"; then
    echo -e "${GREEN}✓${NC} Redis opérationnel (mode HA activé)"
fi

# Résumé
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Déploiement réussi!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}URLs configurées:${NC}"
echo "  - Auth endpoint:  https://portail.${DOMAIN}"
echo "  - Guacamole:      https://guacamole.${DOMAIN}"
echo "  - GLPI:           https://glpi.${DOMAIN}"
echo "  - Zabbix:         https://zabbix.${DOMAIN}"
echo "  - Nextcloud:      https://nextcloud.${DOMAIN}"
echo "  - Wiki:           https://wiki.${DOMAIN}"
echo "  - vCenter:        https://vcenter.${DOMAIN}"
echo ""
echo -e "${BLUE}Monitoring:${NC}"
echo "  - Metrics:        http://localhost:9090/metrics"
echo "  - Health check:   https://localhost:44180/ping"
echo ""
echo -e "${BLUE}Prochaines étapes:${NC}"
echo "  1. Configurer DNS:"
echo "     *.${DOMAIN} → $(hostname -I | awk '{print $1}')"
echo ""
echo "  2. Tester authentification:"
echo "     https://wiki.${DOMAIN}"
echo ""
echo "  3. Vérifier logs:"
echo "     docker compose logs -f"
echo ""
echo "  4. Monitoring:"
echo "     docker compose ps"
echo "     curl http://localhost:9090/metrics"
echo ""
echo -e "${YELLOW}Notes importantes:${NC}"
echo "  - Les backends (guacamole, glpi, etc.) doivent être accessibles"
echo "  - Vérifier réseau Docker 'apps-net' pour connexion backends"
echo "  - Logs: docker compose logs -f <service>"
echo ""
