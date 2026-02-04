#!/bin/bash
# =============================================================================
# SCRIPT DE FIX MONGODB POUR LINSHARE
# =============================================================================
# Ce script corrige la configuration MongoDB en recréant l'utilisateur
# et la base de données LinShare avec les bons droits
#
# Usage:
#   ./fix-mongodb.sh
#
# ATTENTION: Ce script va réinitialiser MongoDB (PERTE DE DONNÉES)
# =============================================================================

set -e

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_DIR="$(dirname "$SCRIPT_DIR")"

# Docker Compose command detection
DOCKER_COMPOSE_CMD=()
if command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE_CMD=(docker-compose)
elif docker compose version &> /dev/null; then
    DOCKER_COMPOSE_CMD=(docker compose)
else
    echo -e "${RED}[ERROR]${NC} Docker Compose not found"
    exit 1
fi

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

echo ""
echo "╔════════════════════════════════════════════════════════════════════════════╗"
echo "║                    FIX MONGODB - LINSHARE                                  ║"
echo "╚════════════════════════════════════════════════════════════════════════════╝"
echo ""

# Charger les variables d'environnement
if [ -f "$PROD_DIR/.env" ]; then
    export $(grep -v '^#' "$PROD_DIR/.env" | xargs)
fi

log_warning "═══════════════════════════════════════════════════════════════════"
log_warning "ATTENTION: RÉINITIALISATION MONGODB"
log_warning "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Cette opération va:"
echo "  1. Arrêter le conteneur MongoDB"
echo "  2. SUPPRIMER toutes les données MongoDB existantes"
echo "  3. Recréer MongoDB avec la configuration correcte"
echo "  4. Initialiser l'utilisateur et la base de données LinShare"
echo ""
log_warning "TOUTES LES DONNÉES MONGODB ACTUELLES SERONT PERDUES"
echo ""
read -p "Êtes-vous ABSOLUMENT sûr ? (tapez 'yes' pour confirmer): " confirm

if [ "$confirm" != "yes" ]; then
    log_info "Annulation"
    exit 0
fi

# =============================================================================
# 1. ARRÊTER MONGODB
# =============================================================================

log_info "Arrêt de MongoDB..."
cd "$SCRIPT_DIR"
"${DOCKER_COMPOSE_CMD[@]}" -f docker-compose.linshare.yml stop linshare-mongodb
"${DOCKER_COMPOSE_CMD[@]}" -f docker-compose.linshare.yml rm -f linshare-mongodb
log_success "MongoDB arrêté"

# =============================================================================
# 2. SUPPRIMER LES DONNÉES
# =============================================================================

log_info "Suppression des données MongoDB..."
if [ -d "/data/linshare/mongodb" ]; then
    if command -v sudo &> /dev/null && [ "$(id -u)" -ne 0 ]; then
        sudo rm -rf /data/linshare/mongodb/*
    else
        rm -rf /data/linshare/mongodb/*
    fi
    log_success "Données supprimées"
else
    log_warning "Répertoire /data/linshare/mongodb introuvable"
fi

# =============================================================================
# 3. VÉRIFIER LE SCRIPT D'INIT
# =============================================================================

log_info "Vérification du script d'initialisation..."
if [ ! -f "$SCRIPT_DIR/init-mongo.js" ]; then
    log_error "Script init-mongo.js manquant !"
    exit 1
fi
log_success "Script init-mongo.js présent"

# =============================================================================
# 4. REDÉMARRER MONGODB
# =============================================================================

log_info "Démarrage de MongoDB avec nouvelle configuration..."
cd "$SCRIPT_DIR"
"${DOCKER_COMPOSE_CMD[@]}" -f docker-compose.linshare.yml up -d linshare-mongodb

# Attendre que MongoDB soit prêt
log_info "Attente de MongoDB (initialisation)..."
sleep 10

local max_attempts=30
local attempt=0
while [ $attempt -lt $max_attempts ]; do
    if docker exec linshare-mongodb mongosh --eval "db.adminCommand('ping')" &> /dev/null; then
        log_success "MongoDB prêt"
        break
    fi
    attempt=$((attempt + 1))
    echo -n "."
    sleep 2
done

if [ $attempt -eq $max_attempts ]; then
    log_error "Timeout: MongoDB non disponible"
    exit 1
fi

# =============================================================================
# 5. VÉRIFIER L'INITIALISATION
# =============================================================================

log_info "Vérification de l'utilisateur LinShare..."

# Tester la connexion avec l'utilisateur linshare
if docker exec linshare-mongodb mongosh \
    -u linshare \
    -p "${LINSHARE_MONGO_PASSWORD:-changeme}" \
    --authenticationDatabase linshare \
    --eval "db.adminCommand('ping')" &> /dev/null; then
    log_success "Utilisateur LinShare configuré correctement"
else
    log_error "Échec de connexion avec l'utilisateur LinShare"
    log_info "Vérification des logs:"
    docker logs linshare-mongodb | tail -20
    exit 1
fi

# =============================================================================
# 6. REDÉMARRER LINSHARE BACKEND
# =============================================================================

log_info "Redémarrage de LinShare Backend..."
cd "$SCRIPT_DIR"
"${DOCKER_COMPOSE_CMD[@]}" -f docker-compose.linshare.yml restart linshare-backend

log_info "Attente du démarrage de LinShare Backend (60 secondes)..."
sleep 60

# =============================================================================
# RÉSUMÉ
# =============================================================================

echo ""
log_success "═══════════════════════════════════════════════════════════════════"
log_success "FIX MONGODB TERMINÉ"
log_success "═══════════════════════════════════════════════════════════════════"
echo ""
echo "MongoDB a été réinitialisé avec:"
echo "  - Utilisateur: linshare"
echo "  - Base de données: linshare"
echo "  - Collections GridFS créées"
echo ""
echo "Vérification:"
echo "  Logs MongoDB:  docker logs linshare-mongodb"
echo "  Logs Backend:  docker logs linshare-backend"
echo ""
echo "Test de connexion:"
echo "  docker exec linshare-mongodb mongosh -u linshare -p \${LINSHARE_MONGO_PASSWORD} --authenticationDatabase linshare"
echo ""
log_success "═══════════════════════════════════════════════════════════════════"
