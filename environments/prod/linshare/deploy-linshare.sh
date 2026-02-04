#!/bin/bash
# =============================================================================
# SCRIPT DE DEPLOIEMENT LINSHARE AVEC OIDC
# =============================================================================
# Ce script deploie LinShare avec authentification Keycloak OIDC complete:
# - Generation des configurations depuis templates
# - Configuration automatique du client Keycloak
# - Creation du domaine et OIDC User Provider dans LinShare
#
# Usage:
#   ./deploy-linshare.sh [OPTIONS]
#
# Options:
#   --clean       : Nettoyer les donnees existantes (ATTENTION: perte de donnees)
#   --skip-keycloak : Ne pas configurer Keycloak (si deja fait)
#   --yes, -y     : Mode non-interactif (accepter toutes les confirmations)
#
# Prerequis:
#   - Docker et Docker Compose installes
#   - Fichier .env configure dans environments/prod/
#   - Keycloak demarre et accessible
#   - Certificats SSL en place
# =============================================================================

set -e

# Couleurs pour l'affichage
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Repertoires
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="/data/linshare"
DOCKER_COMPOSE_CMD=()
DOCKER_COMPOSE_DISPLAY="docker-compose"

# Options
CLEAN_DATA=false
SKIP_KEYCLOAK=false
NON_INTERACTIVE=false

# =============================================================================
# FONCTIONS UTILITAIRES
# =============================================================================

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

confirm() {
    if [ "$NON_INTERACTIVE" = true ]; then
        return 0
    fi
    read -p "$1 (o/N): " response
    case "$response" in
        [oOyY]) return 0 ;;
        *) return 1 ;;
    esac
}

# =============================================================================
# VERIFICATION DES PREREQUIS
# =============================================================================

check_prerequisites() {
    log_info "Verification des prerequis..."

    # Docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker n'est pas installe"
        exit 1
    fi
    log_success "Docker: $(docker --version | head -1)"

    # Docker Compose
    if command -v docker-compose &> /dev/null; then
        DOCKER_COMPOSE_CMD=(docker-compose)
        DOCKER_COMPOSE_DISPLAY="docker-compose"
    elif docker compose version &> /dev/null; then
        DOCKER_COMPOSE_CMD=(docker compose)
        DOCKER_COMPOSE_DISPLAY="docker compose"
    else
        log_error "Docker Compose n'est pas installe"
        exit 1
    fi
    log_success "Docker Compose OK"

    # jq pour JSON parsing
    if ! command -v jq &> /dev/null; then
        log_error "jq n'est pas installe (apt install jq)"
        exit 1
    fi
    log_success "jq OK"

    # envsubst
    if ! command -v envsubst &> /dev/null; then
        log_error "envsubst n'est pas installe (apt install gettext-base)"
        exit 1
    fi
    log_success "envsubst OK"

    # Fichier .env
    if [ ! -f "$PROD_DIR/.env" ]; then
        log_error "Fichier .env manquant dans $PROD_DIR/"
        log_info "Copiez .env.example vers .env et configurez-le"
        exit 1
    fi
    log_success "Fichier .env trouve"

    # Charger les variables d'environnement
    set -a
    source "$PROD_DIR/.env"
    set +a

    # Verifier variables critiques
    local missing_vars=()
    [ -z "$DOMAIN" ] && missing_vars+=("DOMAIN")
    [ -z "$KEYCLOAK_ISSUER" ] && missing_vars+=("KEYCLOAK_ISSUER")
    [ -z "$LINSHARE_OIDC_CLIENT_ID" ] && missing_vars+=("LINSHARE_OIDC_CLIENT_ID")

    if [ ${#missing_vars[@]} -gt 0 ]; then
        log_error "Variables manquantes dans .env: ${missing_vars[*]}"
        exit 1
    fi
    log_success "Variables d'environnement validees"
}

# =============================================================================
# CREATION DES REPERTOIRES
# =============================================================================

create_directories() {
    log_info "Creation des repertoires de donnees..."

    mkdir -p "$DATA_DIR"/{postgres,mongodb,files,clamav,logs,config}
    mkdir -p /data/logs/linshare

    # Permissions
    chmod 755 "$DATA_DIR"
    chmod 755 /data/logs/linshare

    log_success "Repertoires crees dans $DATA_DIR"
}

# =============================================================================
# NETTOYAGE DES DONNEES (si --clean)
# =============================================================================

clean_data() {
    if [ "$CLEAN_DATA" = true ]; then
        log_warning "ATTENTION: Nettoyage des donnees LinShare"

        if ! confirm "Cette operation va SUPPRIMER toutes les donnees. Continuer?"; then
            log_info "Annulation du nettoyage"
            return
        fi

        log_info "Arret des conteneurs LinShare..."
        cd "$SCRIPT_DIR"
        COMPOSE_FILES="--env-file $PROD_DIR/.env -f docker-compose.linshare.yml"
        [ -f "docker-compose.override.yml" ] && COMPOSE_FILES="$COMPOSE_FILES -f docker-compose.override.yml"
        "${DOCKER_COMPOSE_CMD[@]}" $COMPOSE_FILES --profile linshare down -v 2>/dev/null || true

        # Supprimer conteneurs orphelins
        docker rm -f linshare-postgres linshare-mongodb linshare-backend \
            linshare-ui-user linshare-ui-admin linshare-thumbnail linshare-clamav 2>/dev/null || true

        log_info "Suppression des donnees..."
        rm -rf "$DATA_DIR"/* 2>/dev/null || true

        log_success "Donnees nettoyees"
    fi
}

# =============================================================================
# GENERATION DES CONFIGURATIONS DEPUIS TEMPLATES
# =============================================================================

generate_configs() {
    log_info "Generation des configurations depuis les templates..."

    # Creer le repertoire config si necessaire
    mkdir -p "$SCRIPT_DIR/config"
    mkdir -p "$DATA_DIR/config"

    # Variables pour envsubst
    export KEYCLOAK_ISSUER
    export LINSHARE_OIDC_CLIENT_ID
    export LINSHARE_OIDC_CLIENT_SECRET
    export DOMAIN
    export POSTGRES_HOST=${POSTGRES_HOST:-linshare-db}
    export POSTGRES_PORT=${POSTGRES_PORT:-5432}
    export POSTGRES_DATABASE=${POSTGRES_DATABASE:-linshare}
    export POSTGRES_USER=${POSTGRES_USER:-linshare}
    export POSTGRES_PASSWORD=${LINSHARE_DB_PASSWORD:-changeme}
    export MONGODB_DATA_REPLICA_SET=${MONGODB_DATA_REPLICA_SET:-linshare-mongodb:27017}
    export MONGODB_SMALLFILES_REPLICA_SET=${MONGODB_SMALLFILES_REPLICA_SET:-linshare-mongodb:27017}
    export MONGODB_BIGFILES_REPLICA_SET=${MONGODB_BIGFILES_REPLICA_SET:-linshare-mongodb:27017}
    export MONGODB_DATA_DATABASE=${MONGODB_DATA_DATABASE:-linshare}
    export MONGODB_SMALLFILES_DATABASE=${MONGODB_SMALLFILES_DATABASE:-linshare-files}
    export MONGODB_BIGFILES_DATABASE=${MONGODB_BIGFILES_DATABASE:-linshare-bigfiles}
    export MONGODB_USER=${MONGODB_USER:-linshare}
    export MONGODB_PASSWORD=${LINSHARE_MONGO_PASSWORD:-changeme}
    export MONGODB_AUTH_DATABASE=${MONGODB_AUTH_DATABASE:-admin}
    export MONGODB_WRITE_CONCERN=${MONGODB_WRITE_CONCERN:-MAJORITY}
    export STORAGE_MODE=${STORAGE_MODE:-filesystem}
    export STORAGE_BUCKET=${STORAGE_BUCKET:-linshare}
    export STORAGE_FILESYSTEM_DIR=${STORAGE_FILESYSTEM_DIR:-/var/lib/linshare/filesystemstorage}
    export STORAGE_MULTIPART_UPLOAD=${STORAGE_MULTIPART_UPLOAD:-true}
    export CLAMAV_HOST=${CLAMAV_HOST:-linshare-antivirus}
    export CLAMAV_PORT=${CLAMAV_PORT:-3310}
    export THUMBNAIL_HOST=${THUMBNAIL_HOST:-linshare-thumbnail}
    export THUMBNAIL_PORT=${THUMBNAIL_PORT:-8080}
    export THUMBNAIL_ENABLE=${THUMBNAIL_ENABLE:-true}
    export THUMBNAIL_ENABLE_PDF=${THUMBNAIL_ENABLE_PDF:-true}
    export SMTP_HOST=${LINSHARE_SMTP_HOST:-localhost}
    export SMTP_PORT=${LINSHARE_SMTP_PORT:-25}
    export SMTP_USER=${LINSHARE_SMTP_USER:-}
    export SMTP_PASSWORD=${LINSHARE_SMTP_PASSWORD:-}
    export SMTP_AUTH_ENABLE=${SMTP_AUTH_ENABLE:-false}
    export SMTP_START_TLS_ENABLE=${SMTP_START_TLS_ENABLE:-false}
    export SMTP_SSL_ENABLE=${SMTP_SSL_ENABLE:-false}
    export SSO_IP_LIST_ENABLE=${SSO_IP_LIST_ENABLE:-false}
    export SSO_IP_LIST=${SSO_IP_LIST:-127.0.0.1}
    export JWT_EXPIRATION=${JWT_EXPIRATION:-300}
    export JWT_TOKEN_MAX_LIFETIME=${JWT_TOKEN_MAX_LIFETIME:-300}

    # Generer linshare.properties depuis template
    if [ -f "$SCRIPT_DIR/config/linshare.properties.template" ]; then
        log_info "Generation de linshare.properties..."
        envsubst < "$SCRIPT_DIR/config/linshare.properties.template" > "$DATA_DIR/config/linshare.properties"
        chmod 600 "$DATA_DIR/config/linshare.properties"
        log_success "linshare.properties genere"
    else
        log_warning "Template linshare.properties.template introuvable"
    fi

    # Generer config.js depuis template
    if [ -f "$SCRIPT_DIR/config/config.js.template" ]; then
        log_info "Generation de config.js (frontend)..."
        envsubst < "$SCRIPT_DIR/config/config.js.template" > "$SCRIPT_DIR/config/config.js"
        cp "$SCRIPT_DIR/config/config.js" "$DATA_DIR/config/config.js"
        log_success "config.js genere"
    else
        log_warning "Template config.js.template introuvable"
    fi

    # Copier config-admin.js (identique pour le POC)
    if [ -f "$SCRIPT_DIR/config/config.js" ]; then
        cp "$SCRIPT_DIR/config/config.js" "$SCRIPT_DIR/config/config-admin.js"
        cp "$SCRIPT_DIR/config/config.js" "$DATA_DIR/config/config-admin.js"
        log_success "config-admin.js copie"
    fi
}

# =============================================================================
# SCRIPT D'INITIALISATION DB
# =============================================================================

create_init_sql() {
    log_info "Creation du script d'initialisation PostgreSQL..."

    cat > "$SCRIPT_DIR/init-db.sql" << 'EOF'
-- LinShare Database Initialization
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
GRANT ALL PRIVILEGES ON DATABASE linshare TO linshare;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO linshare;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO linshare;
EOF

    log_success "init-db.sql cree"
}

# =============================================================================
# CONFIGURATION KEYCLOAK
# =============================================================================

configure_keycloak() {
    if [ "$SKIP_KEYCLOAK" = true ]; then
        log_info "Configuration Keycloak ignoree (--skip-keycloak)"
        return
    fi

    log_info "Configuration du client Keycloak pour LinShare..."

    # Utiliser le script centralise dans keycloak/scripts/
    local keycloak_script="$PROD_DIR/keycloak/scripts/setup-linshare.sh"

    if [ -f "$keycloak_script" ]; then
        chmod +x "$keycloak_script"
        "$keycloak_script" || {
            log_warning "Configuration Keycloak echouee - continuer quand meme?"
            if ! confirm "Continuer sans configuration Keycloak?"; then
                exit 1
            fi
        }
    else
        log_warning "Script $keycloak_script introuvable"
        log_info "Vous devrez configurer Keycloak manuellement"
    fi
}

# =============================================================================
# DEPLOIEMENT DES CONTENEURS
# =============================================================================

deploy_containers() {
    log_info "Deploiement des conteneurs LinShare..."

    cd "$SCRIPT_DIR"

    # Construire la commande compose
    COMPOSE_FILES="--env-file $PROD_DIR/.env -f docker-compose.linshare.yml"
    [ -f "docker-compose.override.yml" ] && COMPOSE_FILES="$COMPOSE_FILES -f docker-compose.override.yml"

    # Arreter conteneurs existants
    log_info "Arret des conteneurs existants..."
    "${DOCKER_COMPOSE_CMD[@]}" $COMPOSE_FILES --profile linshare down 2>/dev/null || true
    docker rm -f linshare-postgres linshare-mongodb linshare-backend \
        linshare-ui-user linshare-ui-admin linshare-thumbnail linshare-clamav 2>/dev/null || true

    # Creer les reseaux si necessaire
    docker network create linshare_linshare-net 2>/dev/null || true
    docker network create prod_apps-net 2>/dev/null || true
    docker network create portal-net 2>/dev/null || true

    # Pull et demarrage
    log_info "Telechargement des images Docker..."
    "${DOCKER_COMPOSE_CMD[@]}" $COMPOSE_FILES --profile linshare pull

    log_info "Demarrage des conteneurs..."
    "${DOCKER_COMPOSE_CMD[@]}" $COMPOSE_FILES --profile linshare up -d

    log_success "Conteneurs demarres"
}

# =============================================================================
# ATTENTE ET VERIFICATION DU DEPLOIEMENT
# =============================================================================

wait_for_services() {
    log_info "Attente du demarrage des services (peut prendre 2-3 minutes)..."

    local max_attempts=90

    # Attendre PostgreSQL
    log_info "Attente de PostgreSQL..."
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if docker exec linshare-postgres pg_isready -U linshare &> /dev/null; then
            log_success "PostgreSQL pret"
            break
        fi
        attempt=$((attempt + 1))
        echo -n "."
        sleep 2
    done
    [ $attempt -eq $max_attempts ] && log_warning "PostgreSQL timeout"

    # Attendre MongoDB
    log_info "Attente de MongoDB..."
    attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if docker exec linshare-mongodb mongosh --eval "db.adminCommand('ping')" &> /dev/null; then
            log_success "MongoDB pret"
            break
        fi
        attempt=$((attempt + 1))
        echo -n "."
        sleep 2
    done
    [ $attempt -eq $max_attempts ] && log_warning "MongoDB timeout"

    # Attendre LinShare Backend
    log_info "Attente de LinShare Backend (premier demarrage peut prendre du temps)..."
    attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if curl -sf http://localhost:8080/linshare/ &> /dev/null; then
            log_success "LinShare Backend pret"
            break
        fi
        attempt=$((attempt + 1))
        echo -n "."
        sleep 3
    done
    [ $attempt -eq $max_attempts ] && log_warning "LinShare Backend timeout - verifiez les logs"

    echo ""
}

# =============================================================================
# CONFIGURATION LINSHARE OIDC USER PROVIDER
# =============================================================================

configure_linshare_oidc() {
    log_info "Configuration du domaine et OIDC User Provider dans LinShare..."

    if [ -f "$SCRIPT_DIR/configure-linshare-oidc.sh" ]; then
        chmod +x "$SCRIPT_DIR/configure-linshare-oidc.sh"
        "$SCRIPT_DIR/configure-linshare-oidc.sh" || {
            log_warning "Configuration OIDC User Provider echouee"
            log_info "Vous pouvez relancer: $SCRIPT_DIR/configure-linshare-oidc.sh"
        }
    else
        log_warning "Script configure-linshare-oidc.sh introuvable"
    fi
}

# =============================================================================
# RESUME FINAL
# =============================================================================

show_summary() {
    echo ""
    log_success "=============================================="
    log_success "  DEPLOIEMENT LINSHARE TERMINE"
    log_success "=============================================="
    echo ""
    echo "URLs d'acces:"
    echo "  Interface utilisateur: https://linshare.${DOMAIN}"
    echo "  Interface admin:       https://linshare-admin.${DOMAIN}"
    echo "  (ou http://localhost:8082 et http://localhost:8083)"
    echo ""
    echo "Identifiants admin LinShare (a changer):"
    echo "  Email:    root@localhost.localdomain"
    echo "  Password: adminlinshare"
    echo ""
    echo "Configuration OIDC:"
    echo "  Keycloak Issuer:       ${KEYCLOAK_ISSUER}"
    echo "  Client ID:             ${LINSHARE_OIDC_CLIENT_ID}"
    echo "  Domain Discriminator:  ${DOMAIN}"
    echo ""
    echo "Commandes utiles:"
    echo "  Logs:    docker logs -f linshare-backend"
    echo "  Status:  docker ps | grep linshare"
    echo "  Restart: docker restart linshare-backend"
    echo ""
    log_success "=============================================="
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    # Parser les arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --clean)
                CLEAN_DATA=true
                shift
                ;;
            --skip-keycloak)
                SKIP_KEYCLOAK=true
                shift
                ;;
            --yes|-y)
                NON_INTERACTIVE=true
                shift
                ;;
            *)
                log_error "Option inconnue: $1"
                echo "Usage: $0 [--clean] [--skip-keycloak] [--yes|-y]"
                exit 1
                ;;
        esac
    done

    # Banniere
    echo ""
    echo "=============================================="
    echo "  DEPLOIEMENT LINSHARE AVEC OIDC"
    echo "=============================================="
    echo ""

    # Etapes de deploiement
    check_prerequisites
    clean_data
    create_directories
    create_init_sql
    generate_configs
    configure_keycloak
    deploy_containers
    wait_for_services
    configure_linshare_oidc
    show_summary
}

# Execution
main "$@"
