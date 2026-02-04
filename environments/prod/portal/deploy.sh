#!/bin/bash
# Script de déploiement Portail Applications oauth2-proxy
# Version: 1.0
# Date: 2025-11-23

set -e

echo "=========================================="
echo "Déploiement Portail Applications"
echo "=========================================="
echo ""

# Couleurs pour output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Fonctions helper
error() {
    echo -e "${RED}❌ ERREUR: $1${NC}" >&2
    exit 1
}

success() {
    echo -e "${GREEN}✅ $1${NC}"
}

warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

info() {
    echo "ℹ️  $1"
}

# Charger variables d'environnement
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
    success "Variables d'environnement chargées depuis .env"
elif [ -f ../.env ]; then
    export $(grep -v '^#' ../.env | xargs)
    success "Variables d'environnement chargées depuis ../.env"
else
    warning "Fichier .env non trouvé"
    info "Utilisation de valeurs par défaut ou variables système"
fi

# Variables avec valeurs par défaut
DOMAIN=${DOMAIN:-"example.com"}
CERT_PATH="${TLS_CERT_FILE:-/data/certs/wildcard.${DOMAIN}.crt}"
KEY_PATH="${TLS_KEY_FILE:-/data/certs/wildcard.${DOMAIN}.key}"

echo ""
info "Configuration:"
info "  - Domaine: ${DOMAIN}"
info "  - Certificat: ${CERT_PATH}"
info "  - Clé privée: ${KEY_PATH}"
echo ""

# Étape 1: Vérifier prérequis
echo "1. Vérification des prérequis..."

# Docker
if ! command -v docker &> /dev/null; then
    error "Docker non installé"
fi
success "Docker installé"

# Docker Compose
if ! command -v docker-compose &> /dev/null; then
    error "docker-compose non installé"
fi
success "docker-compose installé"

# Certificats SSL
if [ ! -f "$CERT_PATH" ]; then
    error "Certificat SSL manquant: $CERT_PATH"
fi
success "Certificat SSL trouvé"

if [ ! -f "$KEY_PATH" ]; then
    error "Clé privée SSL manquante: $KEY_PATH"
fi
success "Clé privée SSL trouvée"

# Vérifier réseau Docker auth-net
if ! docker network inspect auth-net &> /dev/null; then
    warning "Réseau Docker 'auth-net' n'existe pas"
    info "Création du réseau auth-net..."
    docker network create auth-net
    success "Réseau auth-net créé"
else
    success "Réseau Docker auth-net existe"
fi

# Vérifier oauth2-proxy est en cours d'exécution
if docker ps | grep -q oauth2-proxy; then
    success "oauth2-proxy est en cours d'exécution"
else
    warning "oauth2-proxy ne semble pas être en cours d'exécution"
    info "Vérifier: cd ../oauth2-proxy && docker-compose ps"
fi

echo ""

# Étape 2: Créer structure de répertoires
echo "2. Création de la structure de répertoires..."

mkdir -p logs
success "Répertoire logs créé"

mkdir -p nginx
success "Répertoire nginx créé"

mkdir -p www
success "Répertoire www créé"

echo ""

# Étape 3: Générer configuration nginx
echo "3. Génération de la configuration nginx..."

if [ -f nginx/portal.conf.template ]; then
    envsubst < nginx/portal.conf.template > nginx/portal.conf
    success "Configuration nginx générée depuis template"
else
    warning "Template nginx/portal.conf.template non trouvé"
    if [ ! -f nginx/portal.conf ]; then
        error "Aucune configuration nginx disponible (ni template ni config)"
    fi
    info "Utilisation de nginx/portal.conf existant"
fi

echo ""

# Étape 4: Vérifier fichiers statiques
echo "4. Vérification des fichiers statiques..."

if [ ! -f www/index.html ]; then
    error "Fichier www/index.html manquant"
fi
success "www/index.html présent"

if [ ! -f www/style.css ]; then
    error "Fichier www/style.css manquant"
fi
success "www/style.css présent"

if [ ! -f www/portal.js ]; then
    error "Fichier www/portal.js manquant"
fi
success "www/portal.js présent"

echo ""

# Étape 5: Arrêter conteneur existant si présent
echo "5. Arrêt des conteneurs existants..."

if docker ps -a | grep -q portal-nginx; then
    docker-compose down
    success "Conteneurs arrêtés"
else
    info "Aucun conteneur à arrêter"
fi

echo ""

# Étape 6: Démarrer services
echo "6. Démarrage des services..."

docker-compose up -d

if [ $? -eq 0 ]; then
    success "Services démarrés"
else
    error "Échec du démarrage des services"
fi

echo ""

# Étape 7: Attendre que nginx soit prêt
echo "7. Attente du démarrage de nginx..."

TIMEOUT=30
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
    if docker exec portal-nginx nginx -t &> /dev/null; then
        success "nginx est opérationnel"
        break
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    error "Timeout en attendant le démarrage de nginx"
fi

echo ""

# Étape 8: Vérifier configuration nginx
echo "8. Vérification de la configuration nginx..."

if docker exec portal-nginx nginx -t &> /dev/null; then
    success "Configuration nginx valide"
else
    error "Configuration nginx invalide"
    docker exec portal-nginx nginx -t
fi

echo ""

# Étape 9: Vérifier health check
echo "9. Vérification du health check..."

sleep 3

if curl -f http://localhost:8080/health &> /dev/null; then
    success "Health check HTTP OK"
else
    warning "Health check HTTP échoué"
fi

if curl -k -f https://localhost:8443/health &> /dev/null; then
    success "Health check HTTPS OK"
else
    warning "Health check HTTPS échoué"
fi

echo ""

# Étape 10: Afficher statut
echo "10. Statut des services..."

docker-compose ps

echo ""
echo "=========================================="
echo -e "${GREEN}✅ Déploiement terminé avec succès !${NC}"
echo "=========================================="
echo ""

echo "URLs d'accès:"
echo "  - HTTP  : http://localhost:8080"
echo "  - HTTPS : https://localhost:8443"
echo "  - Public: https://portail.${DOMAIN}"
echo ""

echo "Commandes utiles:"
echo "  - Logs en temps réel : docker-compose logs -f"
echo "  - Statut services    : docker-compose ps"
echo "  - Arrêter services   : docker-compose down"
echo "  - Redémarrer         : docker-compose restart"
echo ""

echo "Prochaines étapes:"
echo "  1. Configurer DNS: portail.${DOMAIN} → $(hostname -I | awk '{print $1}')"
echo "  2. Ajouter route dans nginx principal (voir README.md)"
echo "  3. Tester: https://portail.${DOMAIN}"
echo "  4. Personnaliser applications dans www/portal.js"
echo ""

echo "Documentation complète: README.md"
echo ""

# Afficher logs récents
info "Derniers logs (10 lignes):"
docker-compose logs --tail=10

echo ""
echo -e "${GREEN}🎉 Portail prêt à l'emploi !${NC}"
