#!/bin/bash
# =============================================================================
# SCRIPT DE BACKUP LINSHARE
# =============================================================================
# Ce script sauvegarde les données LinShare (PostgreSQL + MongoDB + fichiers)
#
# Usage:
#   ./backup-linshare.sh [--full]
#
# Options:
#   --full  : Sauvegarde complète incluant tous les fichiers (peut être volumineuse)
#
# Prérequis:
#   - Docker et Docker Compose installés
#   - Conteneurs LinShare en cours d'exécution
#   - Espace disque suffisant dans /backup
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
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="linshare_backup_${TIMESTAMP}"

# Options
FULL_BACKUP=false

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

    # Vérifier que les conteneurs sont en cours d'exécution
    if ! docker ps | grep -q "linshare-postgres"; then
        log_error "Le conteneur linshare-postgres n'est pas en cours d'exécution"
        exit 1
    fi

    if ! docker ps | grep -q "linshare-mongodb"; then
        log_error "Le conteneur linshare-mongodb n'est pas en cours d'exécution"
        exit 1
    fi

    log_success "Conteneurs LinShare actifs"

    # Créer le répertoire de backup
    mkdir -p "$BACKUP_DIR"
    log_success "Répertoire de backup créé: $BACKUP_DIR"

    # Vérifier l'espace disque disponible
    local available_space=$(df -BG "$BACKUP_DIR" | tail -1 | awk '{print $4}' | sed 's/G//')
    if [ "$available_space" -lt 10 ]; then
        log_warning "Espace disque faible: ${available_space}GB disponible"
        log_warning "Il est recommandé d'avoir au moins 10GB pour les backups"
    else
        log_success "Espace disque: ${available_space}GB disponible"
    fi
}

# =============================================================================
# BACKUP POSTGRESQL
# =============================================================================

backup_postgresql() {
    log_info "Backup PostgreSQL (métadonnées)..."

    local pg_backup_file="$BACKUP_DIR/${BACKUP_NAME}_postgres.sql"

    # Dump de la base de données
    docker exec linshare-postgres pg_dump -U linshare linshare > "$pg_backup_file"

    # Compression
    gzip "$pg_backup_file"
    log_success "PostgreSQL sauvegardé: ${pg_backup_file}.gz"

    # Afficher la taille
    local size=$(du -h "${pg_backup_file}.gz" | cut -f1)
    log_info "Taille: $size"
}

# =============================================================================
# BACKUP MONGODB
# =============================================================================

backup_mongodb() {
    log_info "Backup MongoDB (fichiers)..."

    local mongo_backup_dir="$BACKUP_DIR/${BACKUP_NAME}_mongodb"

    # Dump de MongoDB
    docker exec linshare-mongodb mongodump \
        --username=linshare \
        --password="${LINSHARE_MONGO_PASSWORD:-changeme}" \
        --authenticationDatabase=admin \
        --db=linshare \
        --out=/tmp/mongodump

    # Copier le dump hors du conteneur
    docker cp linshare-mongodb:/tmp/mongodump "$mongo_backup_dir"

    # Nettoyer dans le conteneur
    docker exec linshare-mongodb rm -rf /tmp/mongodump

    # Compression
    tar -czf "${mongo_backup_dir}.tar.gz" -C "$BACKUP_DIR" "$(basename "$mongo_backup_dir")"
    rm -rf "$mongo_backup_dir"

    log_success "MongoDB sauvegardé: ${mongo_backup_dir}.tar.gz"

    # Afficher la taille
    local size=$(du -h "${mongo_backup_dir}.tar.gz" | cut -f1)
    log_info "Taille: $size"
}

# =============================================================================
# BACKUP FICHIERS (optionnel, peut être très volumineux)
# =============================================================================

backup_files() {
    if [ "$FULL_BACKUP" = true ]; then
        log_info "Backup des fichiers stockés (FULL)..."

        local files_backup_file="$BACKUP_DIR/${BACKUP_NAME}_files.tar.gz"

        # Backup du répertoire de fichiers
        if [ -d "/data/linshare/files" ]; then
            tar -czf "$files_backup_file" -C /data/linshare files

            log_success "Fichiers sauvegardés: $files_backup_file"

            # Afficher la taille
            local size=$(du -h "$files_backup_file" | cut -f1)
            log_info "Taille: $size"
        else
            log_warning "Répertoire /data/linshare/files introuvable, ignoré"
        fi
    else
        log_info "Backup des fichiers ignoré (utilisez --full pour un backup complet)"
    fi
}

# =============================================================================
# BACKUP CONFIGURATION
# =============================================================================

backup_config() {
    log_info "Backup de la configuration..."

    local config_backup_dir="$BACKUP_DIR/${BACKUP_NAME}_config"
    mkdir -p "$config_backup_dir"

    # Copier les fichiers de configuration
    cp "$SCRIPT_DIR/docker-compose.linshare.yml" "$config_backup_dir/" 2>/dev/null || true
    cp "$SCRIPT_DIR/.env.example" "$config_backup_dir/" 2>/dev/null || true
    cp "$SCRIPT_DIR/config/"* "$config_backup_dir/" 2>/dev/null || true

    # Compression
    tar -czf "${config_backup_dir}.tar.gz" -C "$BACKUP_DIR" "$(basename "$config_backup_dir")"
    rm -rf "$config_backup_dir"

    log_success "Configuration sauvegardée: ${config_backup_dir}.tar.gz"
}

# =============================================================================
# NETTOYAGE DES ANCIENS BACKUPS
# =============================================================================

cleanup_old_backups() {
    log_info "Nettoyage des backups de plus de 30 jours..."

    # Supprimer les backups de plus de 30 jours
    find "$BACKUP_DIR" -name "linshare_backup_*" -type f -mtime +30 -delete

    local count=$(find "$BACKUP_DIR" -name "linshare_backup_*" -type f | wc -l)
    log_success "Backups conservés: $count"
}

# =============================================================================
# CRÉER UN FICHIER DE MÉTADONNÉES
# =============================================================================

create_metadata() {
    log_info "Création des métadonnées de backup..."

    local metadata_file="$BACKUP_DIR/${BACKUP_NAME}_metadata.txt"

    cat > "$metadata_file" << EOF
LinShare Backup Metadata
========================

Date: $(date)
Timestamp: $TIMESTAMP
Backup Type: $([ "$FULL_BACKUP" = true ] && echo "Full" || echo "Incremental")

Components:
- PostgreSQL: Yes
- MongoDB: Yes
- Files: $([ "$FULL_BACKUP" = true ] && echo "Yes" || echo "No")
- Config: Yes

LinShare Version:
$(docker exec linshare-backend cat /etc/os-release | head -1 || echo "Unknown")

Disk Usage:
$(du -sh "$BACKUP_DIR/${BACKUP_NAME}"* 2>/dev/null | awk '{total+=$1} END {print total}' || echo "Unknown")

Files:
$(ls -lh "$BACKUP_DIR/${BACKUP_NAME}"* 2>/dev/null || echo "No files")

Restore Command:
./restore-linshare.sh ${BACKUP_NAME}
EOF

    log_success "Métadonnées créées: $metadata_file"
}

# =============================================================================
# RÉSUMÉ FINAL
# =============================================================================

show_summary() {
    log_success "═══════════════════════════════════════════════════════════════════"
    log_success "BACKUP LINSHARE TERMINÉ"
    log_success "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "Répertoire de backup: $BACKUP_DIR"
    echo ""
    echo "Fichiers créés:"
    ls -lh "$BACKUP_DIR/${BACKUP_NAME}"* 2>/dev/null || echo "Aucun fichier"
    echo ""
    echo "Espace disque utilisé:"
    du -sh "$BACKUP_DIR/${BACKUP_NAME}"* 2>/dev/null | awk '{sum+=$1} END {print "Total: " sum}'
    echo ""
    echo "Pour restaurer ce backup:"
    echo "  ./restore-linshare.sh ${BACKUP_NAME}"
    echo ""
    log_success "═══════════════════════════════════════════════════════════════════"
}

# =============================================================================
# FONCTION PRINCIPALE
# =============================================================================

main() {
    # Parser les arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --full)
                FULL_BACKUP=true
                shift
                ;;
            *)
                log_error "Option inconnue: $1"
                echo "Usage: $0 [--full]"
                exit 1
                ;;
        esac
    done

    # Bannière
    echo ""
    echo "╔════════════════════════════════════════════════════════════════════════════╗"
    echo "║                      BACKUP LINSHARE - PORTAIL SÉCURISÉ                   ║"
    echo "║                                                                            ║"
    echo "║  Backup automatique de LinShare (PostgreSQL + MongoDB + Configuration)    ║"
    echo "╚════════════════════════════════════════════════════════════════════════════╝"
    echo ""

    # Étapes de backup
    check_prerequisites
    backup_postgresql
    backup_mongodb
    backup_files
    backup_config
    create_metadata
    cleanup_old_backups
    show_summary
}

# Exécution
main "$@"
