#!/bin/bash
# =============================================================================
# CONFIGURATION LINSHARE OIDC USER PROVIDER
# =============================================================================
# Ce script configure automatiquement le domaine et l'OIDC User Provider
# dans LinShare Admin pour permettre l'authentification OIDC
#
# Usage:
#   ./configure-linshare-oidc.sh
#
# Prerequis:
#   - LinShare backend demarre et accessible
#   - Variables d'environnement definies dans .env
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

log_info() { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}[OK]${NC} $1" >&2; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Charger les variables d'environnement
if [ -f "$PROD_DIR/.env" ]; then
    export $(grep -v '^#' "$PROD_DIR/.env" | grep -v '^\s*$' | xargs)
else
    log_error "Fichier .env introuvable dans $PROD_DIR"
    exit 1
fi

# Variables
DOMAIN=${DOMAIN:-poc.local}
LINSHARE_ADMIN_USER="root@localhost.localdomain"
LINSHARE_ADMIN_PASSWORD="adminlinshare"
LINSHARE_API_BASE="http://localhost:8080/linshare/webservice/rest/admin/v5"

# Fonction pour exécuter curl via docker exec (car LinShare backend n'est pas exposé)
linshare_curl() {
    docker exec linshare-backend curl -s "$@"
}

# =============================================================================
# FONCTIONS LINSHARE API
# =============================================================================

wait_for_linshare() {
    log_info "Attente du demarrage de LinShare..."

    local max_attempts=60
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if linshare_curl -u "${LINSHARE_ADMIN_USER}:${LINSHARE_ADMIN_PASSWORD}" \
            "${LINSHARE_API_BASE}/domains" > /dev/null 2>&1; then
            log_success "LinShare accessible"
            return 0
        fi
        attempt=$((attempt + 1))
        echo -n "."
        sleep 2
    done

    echo ""
    log_error "Timeout: LinShare n'est pas accessible apres ${max_attempts} tentatives"
    return 1
}

get_domain_uuid() {
    local domain_name=$1

    local result
    result=$(linshare_curl -u "${LINSHARE_ADMIN_USER}:${LINSHARE_ADMIN_PASSWORD}" \
        "${LINSHARE_API_BASE}/domains" 2>/dev/null)

    if [ $? -ne 0 ]; then
        log_error "Erreur lors de la recuperation des domaines"
        return 1
    fi

    local uuid
    uuid=$(echo "$result" | jq -r ".[] | select(.name == \"${domain_name}\") | .uuid")

    echo "$uuid"
}

create_domain() {
    local domain_name=$1

    log_info "Creation du domaine '${domain_name}'..."

    # Verifier si le domaine existe deja
    local existing_uuid
    existing_uuid=$(get_domain_uuid "$domain_name")

    if [ -n "$existing_uuid" ]; then
        log_info "Domaine '${domain_name}' existe deja (UUID: ${existing_uuid})"
        echo "$existing_uuid"
        return 0
    fi

    # Recuperer l'UUID du domaine racine (parent requis pour TOPDOMAIN)
    local root_uuid
    root_uuid=$(linshare_curl -u "${LINSHARE_ADMIN_USER}:${LINSHARE_ADMIN_PASSWORD}" \
        "${LINSHARE_API_BASE}/domains" 2>/dev/null | jq -r '.[] | select(.type == "ROOTDOMAIN") | .uuid')

    if [ -z "$root_uuid" ] || [ "$root_uuid" = "null" ]; then
        log_error "Impossible de trouver le domaine racine LinShare"
        return 1
    fi

    # Creer le domaine (parent = domaine racine)
    local domain_config
    domain_config=$(cat <<EOF
{
    "name": "${domain_name}",
    "type": "TOPDOMAIN",
    "description": "Domaine OIDC pour ${domain_name}",
    "parent": {
        "uuid": "${root_uuid}"
    }
}
EOF
)

    local result
    result=$(linshare_curl -X POST \
        -u "${LINSHARE_ADMIN_USER}:${LINSHARE_ADMIN_PASSWORD}" \
        -H "Content-Type: application/json" \
        -d "$domain_config" \
        "${LINSHARE_API_BASE}/domains" 2>/dev/null)

    if [ $? -ne 0 ]; then
        log_error "Erreur lors de la creation du domaine"
        return 1
    fi

    local new_uuid
    new_uuid=$(echo "$result" | jq -r '.uuid')

    if [ -z "$new_uuid" ] || [ "$new_uuid" = "null" ]; then
        log_error "Erreur lors de la creation du domaine: $result"
        return 1
    fi

    log_success "Domaine '${domain_name}' cree (UUID: ${new_uuid})"
    echo "$new_uuid"
}

get_user_provider() {
    local domain_uuid=$1

    local result
    result=$(linshare_curl -u "${LINSHARE_ADMIN_USER}:${LINSHARE_ADMIN_PASSWORD}" \
        "${LINSHARE_API_BASE}/domains/${domain_uuid}/user_providers" 2>/dev/null)

    echo "$result"
}

create_or_update_oidc_provider() {
    local domain_uuid=$1
    local domain_discriminator=$2

    log_info "Configuration de l'OIDC User Provider pour le domaine..."

    # Verifier si un provider existe deja
    local existing_providers
    existing_providers=$(get_user_provider "$domain_uuid")

    local existing_uuid
    # Note: LinShare API retourne un JSON avec clés dupliquées, jq échoue
    # Utiliser grep/sed pour extraire l'UUID de manière plus robuste
    if echo "$existing_providers" | grep -q '"type":"OIDC_PROVIDER"'; then
        existing_uuid=$(echo "$existing_providers" | grep -o '"uuid":"[^"]*"' | head -1 | sed 's/"uuid":"//;s/"$//')
    else
        existing_uuid=""
    fi

    local provider_config
    provider_config=$(cat <<EOF
{
    "type": "OIDC_PROVIDER",
    "domainDiscriminator": "${domain_discriminator}",
    "checkExternalUserID": false,
    "useAccessClaim": false,
    "useRoleClaim": false,
    "useEmailLocaleClaim": false
}
EOF
)

    if [ -n "$existing_uuid" ]; then
        log_info "OIDC User Provider existe deja (UUID: ${existing_uuid}), mise a jour..."

        # Ajouter l'UUID et le domaine pour la mise a jour
        provider_config=$(cat <<EOF
{
    "type": "OIDC_PROVIDER",
    "uuid": "${existing_uuid}",
    "domain": {
        "uuid": "${domain_uuid}"
    },
    "domainDiscriminator": "${domain_discriminator}",
    "checkExternalUserID": false,
    "useAccessClaim": false,
    "useRoleClaim": false,
    "useEmailLocaleClaim": false
}
EOF
)

        local result
        result=$(linshare_curl -X PUT \
            -u "${LINSHARE_ADMIN_USER}:${LINSHARE_ADMIN_PASSWORD}" \
            -H "Content-Type: application/json" \
            -d "$provider_config" \
            "${LINSHARE_API_BASE}/domains/${domain_uuid}/user_providers/${existing_uuid}" 2>/dev/null)

        if echo "$result" | jq -e '.uuid' > /dev/null 2>&1; then
            log_success "OIDC User Provider mis a jour avec domainDiscriminator='${domain_discriminator}'"
        else
            log_error "Erreur lors de la mise a jour: $result"
            return 1
        fi
    else
        log_info "Creation de l'OIDC User Provider..."

        local result
        result=$(linshare_curl -X POST \
            -u "${LINSHARE_ADMIN_USER}:${LINSHARE_ADMIN_PASSWORD}" \
            -H "Content-Type: application/json" \
            -d "$provider_config" \
            "${LINSHARE_API_BASE}/domains/${domain_uuid}/user_providers" 2>/dev/null)

        if echo "$result" | jq -e '.uuid' > /dev/null 2>&1; then
            local new_uuid
            new_uuid=$(echo "$result" | jq -r '.uuid')
            log_success "OIDC User Provider cree (UUID: ${new_uuid})"
        else
            log_error "Erreur lors de la creation: $result"
            return 1
        fi
    fi
}

verify_configuration() {
    local domain_uuid=$1

    log_info "Verification de la configuration..."

    local providers
    providers=$(get_user_provider "$domain_uuid")

    # Note: LinShare API retourne un JSON avec clés dupliquées, jq échoue
    # Utiliser grep/sed pour vérifier et extraire les valeurs
    if echo "$providers" | grep -q '"type":"OIDC_PROVIDER"'; then
        local discriminator
        discriminator=$(echo "$providers" | grep -o '"domainDiscriminator":"[^"]*"' | head -1 | sed 's/"domainDiscriminator":"//;s/"$//')

        echo ""
        log_success "Configuration OIDC verifiee:"
        echo "  - Domain UUID: ${domain_uuid}"
        echo "  - Domain Discriminator: ${discriminator}"
        echo ""

        if [ "$discriminator" = "${DOMAIN}" ]; then
            log_success "La configuration est correcte!"
            return 0
        else
            log_warning "Le domainDiscriminator (${discriminator}) ne correspond pas a DOMAIN (${DOMAIN})"
            return 1
        fi
    else
        log_error "Aucun OIDC User Provider trouve"
        return 1
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    echo ""
    echo "=============================================="
    echo "  CONFIGURATION LINSHARE OIDC USER PROVIDER"
    echo "=============================================="
    echo ""
    echo "Domain: ${DOMAIN}"
    echo ""

    # Attendre que LinShare soit pret
    if ! wait_for_linshare; then
        exit 1
    fi

    # Creer le domaine
    local domain_uuid
    domain_uuid=$(create_domain "$DOMAIN")

    if [ -z "$domain_uuid" ]; then
        log_error "Impossible de creer/recuperer le domaine"
        exit 1
    fi

    # Creer/mettre a jour l'OIDC User Provider
    if ! create_or_update_oidc_provider "$domain_uuid" "$DOMAIN"; then
        exit 1
    fi

    # Verifier la configuration
    if ! verify_configuration "$domain_uuid"; then
        exit 1
    fi

    echo ""
    log_success "=============================================="
    log_success "  CONFIGURATION TERMINEE"
    log_success "=============================================="
    echo ""
    echo "LinShare est maintenant configure pour accepter les"
    echo "utilisateurs authentifies via Keycloak OIDC."
    echo ""
    echo "Le domainDiscriminator '${DOMAIN}' doit correspondre"
    echo "a la valeur envoyee par le mapper Keycloak."
    echo ""
}

main "$@"
