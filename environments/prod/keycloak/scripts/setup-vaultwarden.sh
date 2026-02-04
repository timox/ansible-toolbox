#!/bin/bash
# =============================================================================
# KEYCLOAK - CONFIGURATION CLIENT VAULTWARDEN
# =============================================================================
# Configure le client OIDC pour Vaultwarden avec:
# - Client confidential
# - Mapper groups
#
# Usage:
#   ./setup-vaultwarden.sh
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Charger les fonctions communes
source "$SCRIPT_DIR/configure-client.sh"

# Charger l'environnement
load_env || exit 1

echo ""
echo "=============================================="
echo "  KEYCLOAK - Configuration Client Vaultwarden"
echo "=============================================="
echo ""

# Variables (utilise OIDCWARDEN_* pour cohérence avec docker-compose)
CLIENT_ID="${OIDCWARDEN_CLIENT_ID:-vaultwarden}"
CLIENT_SECRET="${OIDCWARDEN_CLIENT_SECRET}"
DOMAIN="${DOMAIN:-poc.local}"

# Generer un secret si non fourni
if [ -z "$CLIENT_SECRET" ]; then
    CLIENT_SECRET=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
    log_warning "Secret genere: $CLIENT_SECRET"
    log_warning "Ajoutez dans .env: OIDCWARDEN_CLIENT_SECRET=$CLIENT_SECRET"
fi

# Configuration du client
# NOTE: Seules les URLs de domaine sont configurees.
#       Pour le POC, configurer DNS ou /etc/hosts : *.${DOMAIN} -> IP du serveur
CLIENT_CONFIG=$(cat <<EOF
{
    "clientId": "${CLIENT_ID}",
    "name": "Vaultwarden",
    "description": "Client OIDC pour Vaultwarden - Gestionnaire de mots de passe",
    "enabled": true,
    "clientAuthenticatorType": "client-secret",
    "secret": "${CLIENT_SECRET}",
    "redirectUris": [
        "https://vault.${DOMAIN}/identity/connect/oidc-signin"
    ],
    "webOrigins": [
        "https://vault.${DOMAIN}"
    ],
    "protocol": "openid-connect",
    "publicClient": false,
    "serviceAccountsEnabled": false,
    "standardFlowEnabled": true,
    "implicitFlowEnabled": false,
    "directAccessGrantsEnabled": true,
    "attributes": {
        "pkce.code.challenge.method": "S256",
        "post.logout.redirect.uris": "https://vault.${DOMAIN}/"
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
log_success "  Configuration Vaultwarden terminee"
log_success "=============================================="
echo ""
echo "Client ID:     $CLIENT_ID"
echo "Client Secret: $CLIENT_SECRET"
echo ""
