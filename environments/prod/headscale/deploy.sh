#!/bin/bash
# Script de déploiement Headscale - VPN Mesh Open Source
# Alternative à Tailscale avec authentification Keycloak OIDC

set -e

# Couleurs pour output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Headscale VPN - Déploiement${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Déterminer le répertoire du script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# 1. Charger variables d'environnement depuis .env parent
echo -e "${BLUE}[1/7]${NC} Chargement de la configuration..."
if [ -f ../.env ]; then
    export $(grep -v '^#' ../.env | xargs)
    echo -e "${GREEN}✓${NC} Fichier .env chargé depuis environments/prod/.env"
else
    echo -e "${RED}✗${NC} Erreur: Fichier ../.env manquant"
    echo ""
    echo "Étapes à suivre:"
    echo "  1. cd environments/prod"
    echo "  2. cp .env.example .env"
    echo "  3. Éditer .env et ajouter section HEADSCALE"
    echo "  4. Relancer: headscale/deploy.sh"
    exit 1
fi

# Variables avec valeurs par défaut
DOMAIN=${DOMAIN:-"example.com"}
HEADSCALE_VERSION=${HEADSCALE_VERSION:-"0.25"}
HEADSCALE_HTTPS_PORT=${HEADSCALE_HTTPS_PORT:-"8443"}
HEADPLANE_VERSION=${HEADPLANE_VERSION:-"latest"}
HEADPLANE_PORT=${HEADPLANE_PORT:-"3000"}

# 2. Vérifier prérequis
echo -e "${BLUE}[2/7]${NC} Vérification des prérequis..."

# Vérifier KEYCLOAK_ISSUER
if [ -z "$KEYCLOAK_ISSUER" ]; then
    echo -e "${RED}✗${NC} KEYCLOAK_ISSUER non défini dans .env"
    exit 1
else
    echo -e "${GREEN}✓${NC} KEYCLOAK_ISSUER: $KEYCLOAK_ISSUER"
fi

# Vérifier HEADSCALE_OIDC_CLIENT_SECRET
if [ -z "$HEADSCALE_OIDC_CLIENT_SECRET" ]; then
    echo -e "${RED}✗${NC} HEADSCALE_OIDC_CLIENT_SECRET non défini dans .env"
    echo ""
    echo "Configuration Keycloak requise:"
    echo "  1. Créer client 'headscale' dans realm portal"
    echo "  2. Access Type: confidential"
    echo "  3. Valid Redirect URIs: https://vpn.${DOMAIN}/oidc/callback"
    echo "  4. Scopes: openid, email, profile, groups"
    echo "  5. Copier Client Secret dans .env → HEADSCALE_OIDC_CLIENT_SECRET"
    exit 1
else
    echo -e "${GREEN}✓${NC} HEADSCALE_OIDC_CLIENT_SECRET configuré"
fi

# Vérifier Docker
if ! command -v docker &> /dev/null; then
    echo -e "${RED}✗${NC} Docker n'est pas installé"
    exit 1
else
    echo -e "${GREEN}✓${NC} Docker installé: $(docker --version)"
fi

# Vérifier docker-compose
if ! command -v docker compose &> /dev/null; then
    echo -e "${RED}✗${NC} Docker Compose n'est pas installé"
    exit 1
else
    echo -e "${GREEN}✓${NC} Docker Compose installé"
fi

# 3. Créer structure de répertoires
echo -e "${BLUE}[3/7]${NC} Création des répertoires de données..."

sudo mkdir -p /data/headscale/data
sudo mkdir -p /data/headscale/caddy
sudo mkdir -p /data/headscale/run
sudo mkdir -p /data/headplane
sudo mkdir -p /data/certs
sudo chmod 777 /data/headscale/data
sudo chmod 777 /data/headscale/run
sudo chmod 755 /data/headplane

echo -e "${GREEN}✓${NC} Répertoires créés"

# 4. Générer configurations depuis templates
echo -e "${BLUE}[4/7]${NC} Génération des configurations..."

# Vérifier présence templates
if [ ! -f "config.yaml.template" ]; then
    echo -e "${RED}✗${NC} Fichier config.yaml.template manquant"
    exit 1
fi

if [ ! -f "acls.yaml.template" ]; then
    echo -e "${RED}✗${NC} Fichier acls.yaml.template manquant"
    exit 1
fi

# Générer config.yaml (inclut toutes les variables du template)
envsubst < config.yaml.template > config.yaml
echo -e "${GREEN}✓${NC} config.yaml généré"

# Générer acls.yaml
envsubst < acls.yaml.template > acls.yaml
echo -e "${GREEN}✓${NC} acls.yaml généré"

# Générer headplane.yaml (pour Web UI)
if [ -f "headplane.yaml.template" ]; then
    # Générer HEADPLANE_COOKIE_SECRET si absent
    if [ -z "$HEADPLANE_COOKIE_SECRET" ]; then
        HEADPLANE_COOKIE_SECRET=$(openssl rand -base64 32)
        echo "HEADPLANE_COOKIE_SECRET=${HEADPLANE_COOKIE_SECRET}" >> ../.env
        echo -e "${GREEN}✓${NC} HEADPLANE_COOKIE_SECRET généré et ajouté à .env"
    fi
    envsubst < headplane.yaml.template > headplane.yaml
    echo -e "${GREEN}✓${NC} headplane.yaml généré"
fi

# 5. Vérifier configuration Keycloak
echo -e "${BLUE}[5/7]${NC} Vérification Keycloak..."

# Test endpoint OIDC
if curl -s -f "${KEYCLOAK_ISSUER}/.well-known/openid-configuration" > /dev/null 2>&1; then
    echo -e "${GREEN}✓${NC} Keycloak OIDC endpoint accessible"
else
    echo -e "${YELLOW}⚠${NC} Impossible d'accéder à ${KEYCLOAK_ISSUER}/.well-known/openid-configuration"
    echo "Vérifier que Keycloak est démarré et accessible"
fi

# 6. Démarrer Headscale
echo -e "${BLUE}[6/7]${NC} Démarrage des conteneurs..."

# Arrêter si déjà running
if docker ps | grep -q headscale; then
    echo "Arrêt de l'instance existante..."
    docker compose down
fi

# Démarrer headscale + UI (headplane + caddy)
docker compose --profile ui up -d

# Attendre démarrage
echo "Attente du démarrage (20s)..."
sleep 20

# Vérifier santé headscale
if docker ps | grep -q headscale; then
    echo -e "${GREEN}✓${NC} Headscale démarré"
else
    echo -e "${RED}✗${NC} Erreur: Headscale non démarré"
    echo "Logs:"
    docker logs headscale --tail 50
    exit 1
fi

# Vérifier santé headplane UI
if docker ps | grep -q headplane; then
    echo -e "${GREEN}✓${NC} Headplane UI démarré"
else
    echo -e "${YELLOW}⚠${NC} Headplane UI non démarré (vérifier logs)"
fi

# Vérifier caddy
if docker ps | grep -q headscale-caddy; then
    echo -e "${GREEN}✓${NC} Headscale-caddy démarré"
else
    echo -e "${YELLOW}⚠${NC} Headscale-caddy non démarré (vérifier logs)"
fi

# 7. Post-installation
echo -e "${BLUE}[7/7]${NC} Configuration post-installation..."

# Information sur l'API key (optionnel pour Headplane avec OIDC)
echo ""
echo -e "${BLUE}Info:${NC} Headplane utilise OIDC pour l'authentification"
echo "Une API key n'est requise que pour accès CLI externe"
echo ""

# Créer réseau externe si nécessaire
if ! docker network ls | grep -q prod_apps-net; then
    echo "Création du réseau prod_apps-net..."
    docker network create prod_apps-net
    echo -e "${GREEN}✓${NC} Réseau créé"
fi

# Afficher informations de démarrage
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Déploiement terminé !${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "URLs:"
echo "  - Control Plane: https://vpn.${DOMAIN}"
echo "  - Health Check: https://vpn.${DOMAIN}/health"
echo "  - Metrics: http://localhost:${HEADSCALE_METRICS_PORT:-9091}/metrics"
echo ""
echo "Prochaines étapes:"
echo ""
echo "1. Vérifier santé Headscale:"
echo "   docker exec headscale headscale health"
echo ""
echo "2. Enregistrer premier client:"
echo "   Sur le poste client:"
echo "   sudo tailscale up --login-server=https://vpn.${DOMAIN} --accept-routes"
echo "   → Connexion Keycloak s'ouvrira dans le navigateur"
echo ""
echo "3. Lister les machines:"
echo "   docker exec headscale headscale nodes list"
echo ""
echo "4. Démarrer Headplane Web UI:"
echo "   docker compose --profile ui up -d"
echo "   Accès: https://vpn.${DOMAIN}/admin"
echo "   → Authentification via Keycloak OIDC"
echo ""
echo "Configuration Keycloak requise (si pas déjà fait):"
echo "  1. Créer client 'headscale' dans realm portal"
echo "  2. Client Protocol: openid-connect"
echo "  3. Access Type: confidential"
echo "  4. Valid Redirect URIs:"
echo "     - https://vpn.${DOMAIN}/oidc/callback"
echo "     - https://vpn.${DOMAIN}/admin/oidc/callback"
echo "     - http://localhost:*/oidc/callback"
echo "  5. Scopes: openid, email, profile, groups"
echo "  6. Mapper 'groups': Group Membership → groups claim"
echo "  7. Créer groupes: admin-infra, admin-standard, utilisateurs"
echo ""
echo "Documentation complète: environments/prod/headscale/README.md"
echo ""
echo "Logs:"
echo "  docker logs headscale -f"
echo "  docker logs headplane -f  (si UI activée)"
echo ""
