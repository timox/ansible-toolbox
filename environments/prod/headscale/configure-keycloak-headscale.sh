#!/bin/bash
# =============================================================================
# CONFIGURATION KEYCLOAK POUR HEADSCALE
# =============================================================================
# Ce script configure automatiquement le client Keycloak pour Headscale OIDC
#
# Usage:
#   ./configure-keycloak-headscale.sh
#
# Prerequis:
#   - Keycloak accessible et demarre
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

# Variables avec valeurs par defaut
KEYCLOAK_ADMIN=${KEYCLOAK_ADMIN:-admin}
KEYCLOAK_ADMIN_PASSWORD=${KEYCLOAK_ADMIN_PASSWORD:-}
HEADSCALE_OIDC_CLIENT_ID=${HEADSCALE_OIDC_CLIENT_ID:-headscale}
HEADSCALE_OIDC_CLIENT_SECRET=${HEADSCALE_OIDC_CLIENT_SECRET:-}
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

# URL Keycloak pour API admin (scripts tournent sur l'hote)
KEYCLOAK_INTERNAL_URL="${KEYCLOAK_HOST_BACKEND_URL:-http://localhost:${KEYCLOAK_HTTP_PORT:-8080}}"

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

    log_info "Configuration du client Keycloak '${HEADSCALE_OIDC_CLIENT_ID}'..."

    # Verifier si le client existe
    local client_uuid
    client_uuid=$(check_client_exists "$token" "$HEADSCALE_OIDC_CLIENT_ID")

    # Generer un secret si non fourni
    if [ -z "$HEADSCALE_OIDC_CLIENT_SECRET" ]; then
        HEADSCALE_OIDC_CLIENT_SECRET=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
        log_warning "Secret genere: $HEADSCALE_OIDC_CLIENT_SECRET"

        # Ajouter au .env si pas deja present
        if ! grep -q "^HEADSCALE_OIDC_CLIENT_SECRET=" "$PROD_DIR/.env" 2>/dev/null; then
            echo "HEADSCALE_OIDC_CLIENT_SECRET=$HEADSCALE_OIDC_CLIENT_SECRET" >> "$PROD_DIR/.env"
            log_success "Secret ajoute dans .env"
        else
            log_warning "Mettez a jour .env: HEADSCALE_OIDC_CLIENT_SECRET=$HEADSCALE_OIDC_CLIENT_SECRET"
        fi
    fi

    # Configuration du client
    # Note: Headscale et Headplane ont des redirectUris differents
    local client_config
    client_config=$(cat <<EOF
{
    "clientId": "${HEADSCALE_OIDC_CLIENT_ID}",
    "name": "Headscale VPN",
    "description": "Client OIDC pour Headscale VPN mesh et Headplane UI",
    "enabled": true,
    "clientAuthenticatorType": "client-secret",
    "secret": "${HEADSCALE_OIDC_CLIENT_SECRET}",
    "redirectUris": [
        "https://vpn.${DOMAIN}/*",
        "https://vpn.${DOMAIN}/oidc/callback",
        "https://vpn.${DOMAIN}/admin/oidc/callback"
    ],
    "webOrigins": [
        "https://vpn.${DOMAIN}"
    ],
    "protocol": "openid-connect",
    "publicClient": false,
    "serviceAccountsEnabled": false,
    "authorizationServicesEnabled": false,
    "standardFlowEnabled": true,
    "implicitFlowEnabled": false,
    "directAccessGrantsEnabled": true,
    "attributes": {
        "pkce.code.challenge.method": "S256",
        "post.logout.redirect.uris": "https://vpn.${DOMAIN}/*"
    },
    "defaultClientScopes": [
        "web-origins",
        "acr",
        "profile",
        "roles",
        "email",
        "openid"
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
        log_success "Client '${HEADSCALE_OIDC_CLIENT_ID}' mis a jour"
    else
        log_info "Creation du client..."
        curl -s -k -X POST "${KEYCLOAK_INTERNAL_URL}/admin/realms/${KEYCLOAK_REALM}/clients" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "$client_config" > /dev/null
        log_success "Client '${HEADSCALE_OIDC_CLIENT_ID}' cree"

        # Recuperer l'UUID du client cree
        client_uuid=$(check_client_exists "$token" "$HEADSCALE_OIDC_CLIENT_ID")
    fi

    echo "$client_uuid"
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
    echo "  CONFIGURATION KEYCLOAK POUR HEADSCALE"
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

    # Creer le mapper groups
    create_groups_mapper "$token" "$client_uuid"

    echo ""
    log_success "=============================================="
    log_success "  CONFIGURATION KEYCLOAK TERMINEE"
    log_success "=============================================="
    echo ""
    echo "Client ID:     ${HEADSCALE_OIDC_CLIENT_ID}"
    echo "Client Secret: ${HEADSCALE_OIDC_CLIENT_SECRET}"
    echo "Realm:         ${KEYCLOAK_REALM}"
    echo "Issuer:        ${KEYCLOAK_ISSUER}"
    echo ""
    echo "Redirect URIs:"
    echo "  - https://vpn.${DOMAIN}/oidc/callback (Headscale)"
    echo "  - https://vpn.${DOMAIN}/admin/oidc/callback (Headplane)"
    echo ""
    echo "Mappers configures:"
    echo "  - groups: Group Membership"
    echo ""
    echo "Prochaines etapes:"
    echo "  1. Si le secret a ete genere, il a ete ajoute dans .env"
    echo "  2. Relancer deploy.sh --service headscale pour regenerer les configs"
    echo "  3. Redemarrer les containers: docker restart headscale headplane"
    echo ""
}

main "$@"
