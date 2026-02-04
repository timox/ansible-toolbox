#!/bin/bash
# =============================================================================
# SCRIPT DE RESTAURATION LINSHARE
# =============================================================================
# Ce script restaure les données LinShare depuis un backup
#
# Usage:
#   ./restore-linshare.sh <backup_name>
#
# Exemple:
#   ./restore-linshare.sh linshare_backup_20250109_153045
#
# Prérequis:
#   - Docker et Docker Compose installés
#   - Fichiers de backup dans /backup/linshare/
#   - Conteneurs LinShare arrêtés ou prêts à être recréés
# =============================================================================

set -e

# Couleurs pour l'affichage
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Répertoires
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="/backup/linshare"
BACKUP_NAME="$1"

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

# =============================================================================
# FONCTIONS UTILITAIRES
# =============================================================================

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

# =============================================================================
# VÉRIFICATION DES PRÉREQUIS
# =============================================================================

check_prerequisites() {
    log_info "Vérification des prérequis..."

    # Vérifier que le nom de backup est fourni
    if [ -z "$BACKUP_NAME" ]; then
        log_error "Nom du backup manquant"
        echo "Usage: $0 <backup_name>"
        echo ""
        echo "Backups disponibles:"
        ls -1 "$BACKUP_DIR" | grep "linshare_backup_" | sed 's/_postgres.sql.gz//' | sed 's/_mongodb.tar.gz//' | sed 's/_config.tar.gz//' | sed 's/_metadata.txt//' | sort -u
        exit 1
    fi

    # Vérifier que les fichiers de backup existent
    if [ ! -f "$BACKUP_DIR/${BACKUP_NAME}_postgres.sql.gz" ]; then
        log_error "Fichier de backup PostgreSQL manquant: ${BACKUP_NAME}_postgres.sql.gz"
        exit 1
    fi

    if [ ! -f "$BACKUP_DIR/${BACKUP_NAME}_mongodb.tar.gz" ]; then
        log_error "Fichier de backup MongoDB manquant: ${BACKUP_NAME}_mongodb.tar.gz"
        exit 1
    fi

    log_success "Fichiers de backup trouvés"

    # Afficher les métadonnées si disponibles
    if [ -f "$BACKUP_DIR/${BACKUP_NAME}_metadata.txt" ]; then
        log_info "Métadonnées du backup:"
        cat "$BACKUP_DIR/${BACKUP_NAME}_metadata.txt"
        echo ""
    fi
}

# =============================================================================
# CONFIRMATION UTILISATEUR
# =============================================================================

confirm_restore() {
    log_warning "═══════════════════════════════════════════════════════════════════"
    log_warning "ATTENTION: RESTAURATION DESTRUCTIVE"
    log_warning "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "Cette opération va:"
    echo "  1. Arrêter tous les conteneurs LinShare"
    echo "  2. SUPPRIMER toutes les données actuelles"
    echo "  3. Restaurer les données depuis le backup: $BACKUP_NAME"
    echo ""
    log_warning "Toutes les données LinShare actuelles seront PERDUES"
    echo ""
    read -p "Êtes-vous ABSOLUMENT sûr ? (tapez 'yes' pour confirmer): " confirm

    if [ "$confirm" != "yes" ]; then
        log_info "Restauration annulée"
        exit 0
    fi

    log_success "Confirmation reçue, début de la restauration..."
}

# =============================================================================
# ARRÊT DES CONTENEURS
# =============================================================================

stop_containers() {
    log_info "Arrêt des conteneurs LinShare..."

    cd "$SCRIPT_DIR"
    "${DOCKER_COMPOSE_CMD[@]}" -f docker-compose.linshare.yml down || true

    log_success "Conteneurs arrêtés"
}

# =============================================================================
# RESTAURATION POSTGRESQL
# =============================================================================

restore_postgresql() {
    log_info "Restauration PostgreSQL..."

    # Démarrer uniquement PostgreSQL
    cd "$SCRIPT_DIR"
    "${DOCKER_COMPOSE_CMD[@]}" -f docker-compose.linshare.yml up -d linshare-db

    # Attendre que PostgreSQL soit prêt
    log_info "Attente de PostgreSQL..."
    sleep 5

    local max_attempts=30
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if docker exec linshare-postgres pg_isready -U linshare &> /dev/null; then
            log_success "PostgreSQL prêt"
            break
        fi
        attempt=$((attempt + 1))
        echo -n "."
        sleep 2
    done

    if [ $attempt -eq $max_attempts ]; then
        log_error "Timeout: PostgreSQL non disponible"
        exit 1
    fi

    # Supprimer la base de données existante et la recréer
    log_info "Recréation de la base de données..."
    docker exec linshare-postgres psql -U linshare -d postgres -c "DROP DATABASE IF EXISTS linshare;"
    docker exec linshare-postgres psql -U linshare -d postgres -c "CREATE DATABASE linshare;"

    # Restaurer depuis le backup
    log_info "Restauration des données PostgreSQL..."
    gunzip -c "$BACKUP_DIR/${BACKUP_NAME}_postgres.sql.gz" | docker exec -i linshare-postgres psql -U linshare -d linshare

    log_success "PostgreSQL restauré"
}

# =============================================================================
# RESTAURATION MONGODB
# =============================================================================

restore_mongodb() {
    log_info "Restauration MongoDB..."

    # Démarrer MongoDB
    cd "$SCRIPT_DIR"
    "${DOCKER_COMPOSE_CMD[@]}" -f docker-compose.linshare.yml up -d linshare-mongodb

    # Attendre que MongoDB soit prêt
    log_info "Attente de MongoDB..."
    sleep 5

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

    # Extraire le backup
    local temp_dir=$(mktemp -d)
    tar -xzf "$BACKUP_DIR/${BACKUP_NAME}_mongodb.tar.gz" -C "$temp_dir"

    # Copier dans le conteneur
    docker cp "$temp_dir/$(basename ${BACKUP_NAME}_mongodb)" linshare-mongodb:/tmp/mongorestore

    # Restaurer
    log_info "Restauration des données MongoDB..."
    docker exec linshare-mongodb mongorestore \
        --username=linshare \
        --password="${LINSHARE_MONGO_PASSWORD:-changeme}" \
        --authenticationDatabase=admin \
        --db=linshare \
        --drop \
        /tmp/mongorestore/linshare

    # Nettoyer
    docker exec linshare-mongodb rm -rf /tmp/mongorestore
    rm -rf "$temp_dir"

    log_success "MongoDB restauré"
}

# =============================================================================
# RESTAURATION FICHIERS
# =============================================================================

restore_files() {
    if [ -f "$BACKUP_DIR/${BACKUP_NAME}_files.tar.gz" ]; then
        log_info "Restauration des fichiers..."

        # Supprimer les fichiers existants
        if [ -d "/data/linshare/files" ]; then
            rm -rf /data/linshare/files/*
        fi

        # Extraire le backup
        tar -xzf "$BACKUP_DIR/${BACKUP_NAME}_files.tar.gz" -C /data/linshare/

        log_success "Fichiers restaurés"
    else
        log_warning "Pas de backup de fichiers trouvé, ignoré"
    fi
}

# =============================================================================
# RESTAURATION CONFIGURATION
# =============================================================================

restore_config() {
    if [ -f "$BACKUP_DIR/${BACKUP_NAME}_config.tar.gz" ]; then
        log_info "Restauration de la configuration..."

        # Extraire le backup
        local temp_dir=$(mktemp -d)
        tar -xzf "$BACKUP_DIR/${BACKUP_NAME}_config.tar.gz" -C "$temp_dir"

        # Afficher les fichiers de config restaurés
        log_info "Fichiers de configuration disponibles:"
        ls -la "$temp_dir/$(basename ${BACKUP_NAME}_config)"

        log_warning "Les fichiers de configuration sont dans: $temp_dir/$(basename ${BACKUP_NAME}_config)"
        log_warning "Vérifiez et copiez manuellement si nécessaire"
    else
        log_warning "Pas de backup de configuration trouvé, ignoré"
    fi
}

# =============================================================================
# DÉMARRAGE COMPLET
# =============================================================================

start_all_containers() {
    log_info "Démarrage de tous les conteneurs LinShare..."

    cd "$SCRIPT_DIR"
    "${DOCKER_COMPOSE_CMD[@]}" -f docker-compose.linshare.yml up -d

    log_success "Conteneurs démarrés"

    # Attendre que les services soient prêts
    log_info "Attente du démarrage complet (2-3 minutes)..."
    sleep 30

    # Vérifier LinShare Backend
    local max_attempts=60
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if curl -sf http://localhost:8080/linshare/webservice/rest/actuator/health &> /dev/null; then
            log_success "LinShare Backend opérationnel"
            break
        fi
        attempt=$((attempt + 1))
        echo -n "."
        sleep 3
    done

    if [ $attempt -eq $max_attempts ]; then
        log_warning "LinShare Backend non accessible (peut nécessiter plus de temps)"
    fi
}

# =============================================================================
# RÉSUMÉ FINAL
# =============================================================================

show_summary() {
    log_success "═══════════════════════════════════════════════════════════════════"
    log_success "RESTAURATION LINSHARE TERMINÉE"
    log_success "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "Backup restauré: $BACKUP_NAME"
    echo ""
    echo "Services LinShare:"
    "${DOCKER_COMPOSE_CMD[@]}" -f "$SCRIPT_DIR/docker-compose.linshare.yml" ps
    echo ""
    echo "Prochaines étapes:"
    echo "  1. Vérifier les logs: cd $SCRIPT_DIR && docker-compose -f docker-compose.linshare.yml logs -f"
    echo "  2. Tester l'accès: https://linshare.example.com"
    echo "  3. Vérifier que les fichiers sont accessibles"
    echo "  4. Tester l'authentification Keycloak"
    echo ""
    log_success "═══════════════════════════════════════════════════════════════════"
}

# =============================================================================
# FONCTION PRINCIPALE
# =============================================================================

main() {
    # Bannière
    echo ""
    echo "╔════════════════════════════════════════════════════════════════════════════╗"
    echo "║                   RESTAURATION LINSHARE - PORTAIL SÉCURISÉ               ║"
    echo "║                                                                            ║"
    echo "║  Restauration de LinShare depuis un backup                                ║"
    echo "╚════════════════════════════════════════════════════════════════════════════╝"
    echo ""

    # Étapes de restauration
    check_prerequisites
    confirm_restore
    stop_containers
    restore_postgresql
    restore_mongodb
    restore_files
    restore_config
    start_all_containers
    show_summary
}

# Exécution
main "$@"
