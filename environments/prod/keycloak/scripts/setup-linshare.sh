#!/bin/bash
# =============================================================================
# KEYCLOAK - CONFIGURATION CLIENT LINSHARE
# =============================================================================
# Configure le client OIDC pour LinShare avec:
# - Client confidential avec PKCE
# - Mapper domain_discriminator (requis pour OIDC User Provider)
# - Mapper groups
#
# Usage:
#   ./setup-linshare.sh
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Charger les fonctions communes
source "$SCRIPT_DIR/configure-client.sh"

# Charger l'environnement
load_env || exit 1

echo ""
echo "=============================================="
echo "  KEYCLOAK - Configuration Client LinShare"
echo "=============================================="
echo ""

# Variables
CLIENT_ID="${LINSHARE_OIDC_CLIENT_ID:-linshare}"
CLIENT_SECRET="${LINSHARE_OIDC_CLIENT_SECRET}"
DOMAIN="${DOMAIN:-poc.local}"

# Generer un secret si non fourni
if [ -z "$CLIENT_SECRET" ]; then
    CLIENT_SECRET=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
    log_warning "Secret genere: $CLIENT_SECRET"
    log_warning "Ajoutez dans .env: LINSHARE_OIDC_CLIENT_SECRET=$CLIENT_SECRET"
fi

# Configuration du client
# NOTE: Seules les URLs de domaine sont configurees.
#       Pour le POC, configurer DNS ou /etc/hosts : *.${DOMAIN} -> IP du serveur
CLIENT_CONFIG=$(cat <<EOF
{
    "clientId": "${CLIENT_ID}",
    "name": "LinShare",
    "description": "Client OIDC pour LinShare - Partage de fichiers securise",
    "enabled": true,
    "clientAuthenticatorType": "client-secret",
    "secret": "${CLIENT_SECRET}",
    "redirectUris": [
        "https://linshare.${DOMAIN}/*",
        "https://linshare-admin.${DOMAIN}/*"
    ],
    "webOrigins": [
        "https://linshare.${DOMAIN}",
        "https://linshare-admin.${DOMAIN}"
    ],
    "protocol": "openid-connect",
    "publicClient": false,
    "serviceAccountsEnabled": true,
    "standardFlowEnabled": true,
    "implicitFlowEnabled": false,
    "directAccessGrantsEnabled": true,
    "attributes": {
        "pkce.code.challenge.method": "S256",
        "post.logout.redirect.uris": "https://linshare.${DOMAIN}/"
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
add_domain_discriminator_mapper "$client_uuid" "$DOMAIN"
add_groups_mapper "$client_uuid"

echo ""
log_success "=============================================="
log_success "  Configuration LinShare terminee"
log_success "=============================================="
echo ""
echo "Client ID:             $CLIENT_ID"
echo "Client Secret:         $CLIENT_SECRET"
echo "Domain Discriminator:  $DOMAIN"
echo ""
echo "IMPORTANT: Le domainDiscriminator '$DOMAIN' doit correspondre"
echo "a la valeur configuree dans LinShare Admin (OIDC User Provider)"
echo ""
