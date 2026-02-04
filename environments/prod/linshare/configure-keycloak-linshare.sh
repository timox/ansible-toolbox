#!/bin/bash
# =============================================================================
# CONFIGURATION KEYCLOAK POUR LINSHARE
# =============================================================================
# Ce script configure automatiquement le client Keycloak pour LinShare OIDC
#
# Usage:
#   ./configure-keycloak-linshare.sh
#
# Prerequis:
#   - Keycloak accessible et demarré
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

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Charger les variables d'environnement
if [ -f "$PROD_DIR/.env" ]; then
    export $(grep -v '^#' "$PROD_DIR/.env" | grep -v '^\s*$' | xargs)
else
    log_error "Fichier .env introuvable dans $PROD_DIR"
    exit 1
fi

# Variables avec valeurs par defaut
KEYCLOAK_ADMIN=${KEYCLOAK_ADMIN:-admin}
KEYCLOAK_ADMIN_PASSWORD=${KEYCLOAK_ADMIN_PASSWORD:-}
LINSHARE_OIDC_CLIENT_ID=${LINSHARE_OIDC_CLIENT_ID:-linshare}
LINSHARE_OIDC_CLIENT_SECRET=${LINSHARE_OIDC_CLIENT_SECRET:-}
DOMAIN=${DOMAIN:-example.com}

# Auto-deriver les variables Keycloak depuis KEYCLOAK_ISSUER si necessaire
if [ -n "$KEYCLOAK_ISSUER" ]; then
    KEYCLOAK_HOST=${KEYCLOAK_HOST:-$(echo "$KEYCLOAK_ISSUER" | sed -E 's|^https?://([^:/]+).*|\1|')}
    KEYCLOAK_REALM=${KEYCLOAK_REALM:-$(echo "$KEYCLOAK_ISSUER" | sed -E 's|.*/realms/([^/]+).*|\1|')}
    KEYCLOAK_URL=${KEYCLOAK_URL:-$(echo "$KEYCLOAK_ISSUER" | sed -E 's|(https?://[^/]+).*|\1|')}
else
    log_error "KEYCLOAK_ISSUER non defini dans .env"
    exit 1
fi

# URL Keycloak pour API admin (supporte HTTP ou HTTPS)
# Priorite: KEYCLOAK_BACKEND_URL > KEYCLOAK_URL > auto-detection
if [ -n "$KEYCLOAK_BACKEND_URL" ]; then
    KEYCLOAK_INTERNAL_URL="$KEYCLOAK_BACKEND_URL"
elif [ -n "$KEYCLOAK_URL" ]; then
    KEYCLOAK_INTERNAL_URL="$KEYCLOAK_URL"
else
    # Fallback: essayer localhost HTTP puis HTTPS
    KEYCLOAK_INTERNAL_URL="http://localhost:8080"
fi

# =============================================================================
# FONCTIONS KEYCLOAK API
# =============================================================================

get_admin_token() {
    log_info "Obtention du token admin Keycloak..."

    local token
    token=$(curl -s -k -X POST "${KEYCLOAK_INTERNAL_URL}/realms/master/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=${KEYCLOAK_ADMIN}" \
        -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
        -d "grant_type=password" \
        -d "client_id=admin-cli" | jq -r '.access_token')

    if [ -z "$token" ] || [ "$token" = "null" ]; then
        log_error "Impossible d'obtenir le token admin Keycloak"
        log_info "Verifiez que Keycloak est accessible et les credentials sont corrects"
        exit 1
    fi

    echo "$token"
}

check_client_exists() {
    local token=$1
    local client_id=$2

    local result
    result=$(curl -s -k -X GET "${KEYCLOAK_INTERNAL_URL}/admin/realms/${KEYCLOAK_REALM}/clients?clientId=${client_id}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json")

    if echo "$result" | jq -e '.[0].id' > /dev/null 2>&1; then
        echo $(echo "$result" | jq -r '.[0].id')
    else
        echo ""
    fi
}

create_or_update_client() {
    local token=$1

    log_info "Configuration du client Keycloak '${LINSHARE_OIDC_CLIENT_ID}'..."

    # Verifier si le client existe
    local client_uuid
    client_uuid=$(check_client_exists "$token" "$LINSHARE_OIDC_CLIENT_ID")

    # Generer un secret si non fourni
    if [ -z "$LINSHARE_OIDC_CLIENT_SECRET" ]; then
        LINSHARE_OIDC_CLIENT_SECRET=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
        log_warning "Secret genere: $LINSHARE_OIDC_CLIENT_SECRET"
        log_warning "Ajoutez-le dans .env: LINSHARE_OIDC_CLIENT_SECRET=$LINSHARE_OIDC_CLIENT_SECRET"
    fi

    # Configuration du client
    local client_config
    client_config=$(cat <<EOF
{
    "clientId": "${LINSHARE_OIDC_CLIENT_ID}",
    "name": "LinShare",
    "description": "Client OIDC pour LinShare - Partage de fichiers securise",
    "enabled": true,
    "clientAuthenticatorType": "client-secret",
    "secret": "${LINSHARE_OIDC_CLIENT_SECRET}",
    "redirectUris": [
        "https://linshare.${DOMAIN}/*",
        "https://linshare-admin.${DOMAIN}/*",
        "http://localhost:8082/*",
        "http://192.168.122.1:8082/*"
    ],
    "webOrigins": [
        "https://linshare.${DOMAIN}",
        "https://linshare-admin.${DOMAIN}",
        "http://localhost:8082",
        "http://192.168.122.1:8082"
    ],
    "protocol": "openid-connect",
    "publicClient": false,
    "serviceAccountsEnabled": true,
    "authorizationServicesEnabled": false,
    "standardFlowEnabled": true,
    "implicitFlowEnabled": false,
    "directAccessGrantsEnabled": true,
    "attributes": {
        "pkce.code.challenge.method": "S256",
        "post.logout.redirect.uris": "https://linshare.${DOMAIN}/*##http://localhost:8082/*"
    },
    "defaultClientScopes": [
        "web-origins",
        "acr",
        "profile",
        "roles",
        "email"
    ],
    "optionalClientScopes": [
        "address",
        "phone",
        "offline_access",
        "microprofile-jwt"
    ]
}
EOF
)

    if [ -n "$client_uuid" ]; then
        log_info "Client existe deja (UUID: $client_uuid), mise a jour..."
        curl -s -k -X PUT "${KEYCLOAK_INTERNAL_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${client_uuid}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "$client_config" > /dev/null
        log_success "Client '${LINSHARE_OIDC_CLIENT_ID}' mis a jour"
    else
        log_info "Creation du client..."
        curl -s -k -X POST "${KEYCLOAK_INTERNAL_URL}/admin/realms/${KEYCLOAK_REALM}/clients" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "$client_config" > /dev/null
        log_success "Client '${LINSHARE_OIDC_CLIENT_ID}' cree"

        # Recuperer l'UUID du client cree
        client_uuid=$(check_client_exists "$token" "$LINSHARE_OIDC_CLIENT_ID")
    fi

    echo "$client_uuid"
}

create_domain_discriminator_mapper() {
    local token=$1
    local client_uuid=$2

    log_info "Configuration du mapper 'domain_discriminator'..."

    # Verifier si le mapper existe
    local mappers
    mappers=$(curl -s -k -X GET "${KEYCLOAK_INTERNAL_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${client_uuid}/protocol-mappers/models" \
        -H "Authorization: Bearer ${token}")

    local mapper_exists
    mapper_exists=$(echo "$mappers" | jq -r '.[] | select(.name == "domain_discriminator") | .id')

    local mapper_config
    mapper_config=$(cat <<EOF
{
    "name": "domain_discriminator",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-hardcoded-claim-mapper",
    "consentRequired": false,
    "config": {
        "claim.value": "${DOMAIN}",
        "userinfo.token.claim": "true",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "claim.name": "domain_discriminator",
        "jsonType.label": "String"
    }
}
EOF
)

    if [ -n "$mapper_exists" ]; then
        log_info "Mapper existe deja, mise a jour..."
        curl -s -k -X PUT "${KEYCLOAK_INTERNAL_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${client_uuid}/protocol-mappers/models/${mapper_exists}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "$mapper_config" > /dev/null
    else
        log_info "Creation du mapper..."
        curl -s -k -X POST "${KEYCLOAK_INTERNAL_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${client_uuid}/protocol-mappers/models" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "$mapper_config" > /dev/null
    fi

    log_success "Mapper 'domain_discriminator' configure avec valeur '${DOMAIN}'"
}

create_groups_mapper() {
    local token=$1
    local client_uuid=$2

    log_info "Configuration du mapper 'groups'..."

    # Verifier si le mapper existe
    local mappers
    mappers=$(curl -s -k -X GET "${KEYCLOAK_INTERNAL_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${client_uuid}/protocol-mappers/models" \
        -H "Authorization: Bearer ${token}")

    local mapper_exists
    mapper_exists=$(echo "$mappers" | jq -r '.[] | select(.name == "groups") | .id')

    local mapper_config
    mapper_config=$(cat <<EOF
{
    "name": "groups",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-group-membership-mapper",
    "consentRequired": false,
    "config": {
        "full.path": "false",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "claim.name": "groups",
        "userinfo.token.claim": "true"
    }
}
EOF
)

    if [ -n "$mapper_exists" ]; then
        log_info "Mapper 'groups' existe deja"
    else
        log_info "Creation du mapper 'groups'..."
        curl -s -k -X POST "${KEYCLOAK_INTERNAL_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${client_uuid}/protocol-mappers/models" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "$mapper_config" > /dev/null
        log_success "Mapper 'groups' cree"
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    echo ""
    echo "=============================================="
    echo "  CONFIGURATION KEYCLOAK POUR LINSHARE"
    echo "=============================================="
    echo ""

    # Verifier que Keycloak est accessible
    log_info "Verification de la connectivite Keycloak sur ${KEYCLOAK_INTERNAL_URL}..."
    if ! curl -s -k "${KEYCLOAK_INTERNAL_URL}/health/ready" > /dev/null 2>&1; then
        # Essayer alternatives si la premiere URL echoue
        local alternatives=("http://keycloak:8080" "https://keycloak:8443" "http://localhost:8080" "https://localhost:8443")
        local found=false
        for alt_url in "${alternatives[@]}"; do
            if curl -s -k "${alt_url}/health/ready" > /dev/null 2>&1; then
                KEYCLOAK_INTERNAL_URL="$alt_url"
                log_info "Keycloak trouve sur ${alt_url}"
                found=true
                break
            fi
        done
        if [ "$found" = "false" ]; then
            log_error "Keycloak n'est pas accessible"
            log_info "URLs testees: ${KEYCLOAK_INTERNAL_URL}, ${alternatives[*]}"
            log_info "Verifiez que Keycloak est demarre: docker ps | grep keycloak"
            log_info "Ou definissez KEYCLOAK_BACKEND_URL dans .env"
            exit 1
        fi
    fi
    log_success "Keycloak accessible sur ${KEYCLOAK_INTERNAL_URL}"

    # Obtenir le token admin
    local token
    token=$(get_admin_token)

    # Creer/mettre a jour le client
    local client_uuid
    client_uuid=$(create_or_update_client "$token")

    if [ -z "$client_uuid" ]; then
        log_error "Impossible de recuperer l'UUID du client"
        exit 1
    fi

    # Creer les mappers
    create_domain_discriminator_mapper "$token" "$client_uuid"
    create_groups_mapper "$token" "$client_uuid"

    echo ""
    log_success "=============================================="
    log_success "  CONFIGURATION KEYCLOAK TERMINEE"
    log_success "=============================================="
    echo ""
    echo "Client ID:     ${LINSHARE_OIDC_CLIENT_ID}"
    echo "Client Secret: ${LINSHARE_OIDC_CLIENT_SECRET}"
    echo "Realm:         ${KEYCLOAK_REALM}"
    echo "Issuer:        ${KEYCLOAK_ISSUER}"
    echo ""
    echo "Mappers configures:"
    echo "  - domain_discriminator: ${DOMAIN}"
    echo "  - groups: Group Membership"
    echo ""
}

main "$@"
