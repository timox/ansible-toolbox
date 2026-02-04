#!/bin/bash
# =============================================================================
# KEYCLOAK - CONFIGURATION CLIENT OAUTH2-PROXY
# =============================================================================
# Configure le client OIDC pour oauth2-proxy avec:
# - Client confidential
# - Mapper groups
#
# Usage:
#   ./setup-oauth2-proxy.sh
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Charger les fonctions communes
source "$SCRIPT_DIR/configure-client.sh"

# Charger l'environnement
load_env || exit 1

echo ""
echo "=============================================="
echo "  KEYCLOAK - Configuration Client oauth2-proxy"
echo "=============================================="
echo ""

# Variables
CLIENT_ID="${OIDC_CLIENT_ID:-oauth2-proxy}"
CLIENT_SECRET="${OIDC_CLIENT_SECRET}"
DOMAIN="${DOMAIN:-poc.local}"

# Generer un secret si non fourni
if [ -z "$CLIENT_SECRET" ]; then
    CLIENT_SECRET=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
    log_warning "Secret genere: $CLIENT_SECRET"
    log_warning "Ajoutez dans .env: OIDC_CLIENT_SECRET=$CLIENT_SECRET"
fi

# Configuration du client
# NOTE: Seules les URLs de domaine sont configurees.
#       Pour le POC, configurer DNS ou /etc/hosts : *.${DOMAIN} -> IP du serveur
CLIENT_CONFIG=$(cat <<EOF
{
    "clientId": "${CLIENT_ID}",
    "name": "OAuth2 Proxy - Portail",
    "description": "Client OIDC pour oauth2-proxy - Portail d'authentification",
    "enabled": true,
    "clientAuthenticatorType": "client-secret",
    "secret": "${CLIENT_SECRET}",
    "redirectUris": [
        "https://portail.${DOMAIN}/oauth2/callback"
    ],
    "webOrigins": [
        "https://portail.${DOMAIN}",
        "https://*.${DOMAIN}"
    ],
    "protocol": "openid-connect",
    "publicClient": false,
    "serviceAccountsEnabled": false,
    "standardFlowEnabled": true,
    "implicitFlowEnabled": false,
    "directAccessGrantsEnabled": false,
    "attributes": {
        "post.logout.redirect.uris": "https://portail.${DOMAIN}/oauth2/sign_in"
    },
    "defaultClientScopes": [
        "web-origins",
        "acr",
        "profile",
        "roles",
        "email"
    ]
}
EOF
)

# Configurer le client
client_uuid=$(configure_oidc_client "$CLIENT_ID" "$CLIENT_CONFIG")

if [ -z "$client_uuid" ]; then
    log_error "Impossible de configurer le client"
    exit 1
fi

# Ajouter les mappers
log_info "Configuration des mappers..."
add_groups_mapper "$client_uuid"

echo ""
log_success "=============================================="
log_success "  Configuration oauth2-proxy terminee"
log_success "=============================================="
echo ""
echo "Client ID:     $CLIENT_ID"
echo "Client Secret: $CLIENT_SECRET"
echo ""
