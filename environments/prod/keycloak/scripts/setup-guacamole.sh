#!/bin/bash
# =============================================================================
# KEYCLOAK - CONFIGURATION CLIENT GUACAMOLE
# =============================================================================
# Configure le client OIDC pour Guacamole avec:
# - Client public (Guacamole utilise implicit flow)
# - Mapper groups
# - Mapper preferred_username
#
# Usage:
#   ./setup-guacamole.sh
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Charger les fonctions communes
source "$SCRIPT_DIR/configure-client.sh"

# Charger l'environnement
load_env || exit 1

echo ""
echo "=============================================="
echo "  KEYCLOAK - Configuration Client Guacamole"
echo "=============================================="
echo ""

# Variables
CLIENT_ID="${GUACAMOLE_OIDC_CLIENT_ID:-guacamole}"
DOMAIN="${DOMAIN:-poc.local}"

# Configuration du client (public pour Guacamole)
# NOTE: Seules les URLs de domaine sont configurees.
#       Pour le POC, configurer DNS ou /etc/hosts : *.${DOMAIN} -> IP du serveur
CLIENT_CONFIG=$(cat <<EOF
{
    "clientId": "${CLIENT_ID}",
    "name": "Guacamole",
    "description": "Client OIDC pour Guacamole - Bastion RDP/SSH/VNC",
    "enabled": true,
    "publicClient": true,
    "redirectUris": [
        "https://guacamole.${DOMAIN}/*"
    ],
    "webOrigins": [
        "https://guacamole.${DOMAIN}"
    ],
    "protocol": "openid-connect",
    "standardFlowEnabled": true,
    "implicitFlowEnabled": true,
    "directAccessGrantsEnabled": false,
    "attributes": {
        "post.logout.redirect.uris": "https://guacamole.${DOMAIN}/"
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
log_success "  Configuration Guacamole terminee"
log_success "=============================================="
echo ""
echo "Client ID:     $CLIENT_ID"
echo "Type:          Public (pas de secret)"
echo ""
