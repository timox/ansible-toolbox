#!/bin/bash
# =============================================================================
# KEYCLOAK - Configuration Clients OIDC
# =============================================================================
# Configure automatiquement les clients OIDC et le scope "groups"
#
# Usage: ./setup-clients.sh
#
# Clients configurés:
#   - oauth2-proxy : Portail d'authentification
#   - guacamole    : Bastion RDP/SSH (OIDC natif)
#   - headscale    : VPN mesh (optionnel)
#   - vaultwarden  : Gestionnaire de mots de passe (optionnel)
#   - linshare     : Partage de fichiers (optionnel)
# =============================================================================

set -e

# Couleurs pour output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Keycloak - Configuration Clients${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Charger variables d'environnement
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../../.env"

if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
    echo -e "${GREEN}✓${NC} Variables chargées depuis .env"
else
    echo -e "${RED}✗${NC} Fichier .env non trouvé: $ENV_FILE"
    exit 1
fi

# Configuration
KEYCLOAK_URL="${KEYCLOAK_HOST_BACKEND_URL:-http://localhost:${KEYCLOAK_HTTP_PORT:-8080}}"
REALM="${KEYCLOAK_REALM:-poc}"
ADMIN_USER="${KEYCLOAK_ADMIN:-admin}"
ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD}"

# Vérifications
if [ -z "$ADMIN_PASSWORD" ]; then
    echo -e "${RED}✗${NC} KEYCLOAK_ADMIN_PASSWORD non défini dans .env"
    exit 1
fi

if [ -z "$DOMAIN" ]; then
    echo -e "${RED}✗${NC} DOMAIN non défini dans .env"
    exit 1
fi

# Hostnames des services (utilise les variables .env ou construit depuis DOMAIN)
PORTAL_HOST="${PORTAL_HOSTNAME:-portail.${DOMAIN}}"
GUACAMOLE_HOST="${GUACAMOLE_HOSTNAME:-guacamole.${DOMAIN}}"
HEADSCALE_HOST="${HEADSCALE_HOSTNAME:-vpn.${DOMAIN}}"
VAULTWARDEN_HOST="${VAULTWARDEN_HOSTNAME:-vault.${DOMAIN}}"
LINSHARE_HOST="${LINSHARE_HOSTNAME:-linshare.${DOMAIN}}"

echo -e "${BLUE}Configuration:${NC}"
echo "  - Keycloak URL: $KEYCLOAK_URL"
echo "  - Realm: $REALM"
echo "  - Domain: $DOMAIN"
echo ""
echo -e "${BLUE}Redirect URIs configurées:${NC}"
echo "  - Portal:     https://${PORTAL_HOST}/oauth2/callback"
echo "  - Guacamole:  https://${GUACAMOLE_HOST}/*"
echo "  - Headscale:  https://${HEADSCALE_HOST}/oidc/callback"
echo "  - Vaultwarden: https://${VAULTWARDEN_HOST}/identity/connect/oidc-signin"
echo "  - LinShare:   https://${LINSHARE_HOST}/*"
echo ""

# Obtenir token admin
echo -e "${BLUE}[1/6]${NC} Authentification admin Keycloak..."
TOKEN_RESPONSE=$(curl -sk -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "client_id=admin-cli" \
    -d "username=${ADMIN_USER}" \
    -d "password=${ADMIN_PASSWORD}" \
    -d "grant_type=password")

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)

if [ -z "$ACCESS_TOKEN" ]; then
    echo -e "${RED}✗${NC} Impossible d'obtenir le token admin"
    echo "Réponse: $TOKEN_RESPONSE"
    exit 1
fi
echo -e "${GREEN}✓${NC} Token admin obtenu"

# Fonction pour appeler l'API Keycloak
kc_api() {
    local method=$1
    local endpoint=$2
    local data=$3

    if [ -n "$data" ]; then
        curl -sk -X "$method" "${KEYCLOAK_URL}/admin/realms/${REALM}${endpoint}" \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$data"
    else
        curl -sk -X "$method" "${KEYCLOAK_URL}/admin/realms/${REALM}${endpoint}" \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "Content-Type: application/json"
    fi
}

# Fonction pour récupérer l'ID d'un client
get_client_id() {
    local client_id=$1
    kc_api GET "/clients?clientId=${client_id}" | python3 -c "
import json,sys
try:
    clients = json.load(sys.stdin)
    if clients and len(clients) > 0:
        print(clients[0].get('id', ''))
except: pass
" 2>/dev/null
}

# Fonction pour ajouter le scope groups à un client
add_groups_scope() {
    local client_uuid=$1
    local client_name=$2

    if [ -n "$client_uuid" ] && [ -n "$SCOPE_ID" ]; then
        RESULT=$(kc_api PUT "/clients/${client_uuid}/default-client-scopes/${SCOPE_ID}" "" 2>&1)
        if [ -z "$RESULT" ] || echo "$RESULT" | grep -q "^$"; then
            echo -e "${GREEN}✓${NC} Scope 'groups' ajouté au client ${client_name}"
        else
            echo -e "${YELLOW}⚠${NC} Scope 'groups' (${client_name}): $RESULT"
        fi
    fi
}

# =============================================================================
# SCOPE GROUPS
# =============================================================================
echo -e "${BLUE}[2/6]${NC} Création du client scope 'groups'..."

SCOPE_ID=$(kc_api GET "/client-scopes" | python3 -c "
import json,sys
try:
    scopes = json.load(sys.stdin)
    for s in scopes:
        if s.get('name') == 'groups':
            print(s.get('id'))
            break
except: pass
" 2>/dev/null)

if [ -z "$SCOPE_ID" ]; then
    echo "   Création du scope 'groups'..."
    kc_api POST "/client-scopes" '{
        "name": "groups",
        "protocol": "openid-connect",
        "attributes": {
            "include.in.token.scope": "true",
            "display.on.consent.screen": "true",
            "consent.screen.text": "Group membership"
        }
    }' > /dev/null

    sleep 1
    SCOPE_ID=$(kc_api GET "/client-scopes" | python3 -c "
import json,sys
try:
    scopes = json.load(sys.stdin)
    for s in scopes:
        if s.get('name') == 'groups':
            print(s.get('id'))
            break
except: pass
" 2>/dev/null)

    if [ -n "$SCOPE_ID" ]; then
        kc_api POST "/client-scopes/${SCOPE_ID}/protocol-mappers/models" '{
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
        }' > /dev/null
        echo -e "${GREEN}✓${NC} Client scope 'groups' créé avec mapper"
    else
        echo -e "${RED}✗${NC} Erreur: impossible de créer le scope 'groups'"
        exit 1
    fi
else
    echo -e "${GREEN}✓${NC} Client scope 'groups' existe déjà"
fi

# =============================================================================
# CLIENT OAUTH2-PROXY
# =============================================================================
echo -e "${BLUE}[3/6]${NC} Configuration du client 'oauth2-proxy'..."

CLIENT_UUID=$(get_client_id "oauth2-proxy")

OAUTH2_CONFIG=$(cat <<EOF
{
    "clientId": "oauth2-proxy",
    "name": "OAuth2 Proxy - Portail",
    "enabled": true,
    "publicClient": false,
    "standardFlowEnabled": true,
    "implicitFlowEnabled": false,
    "directAccessGrantsEnabled": false,
    "serviceAccountsEnabled": false,
    "protocol": "openid-connect",
    "redirectUris": [
        "https://${PORTAL_HOST}/*",
        "https://${PORTAL_HOST}/oauth2/callback"
    ],
    "webOrigins": [
        "https://${PORTAL_HOST}"
    ],
    "attributes": {
        "oauth2.device.authorization.grant.enabled": "false",
        "post.logout.redirect.uris": "https://${PORTAL_HOST}/*"
    }
}
EOF
)

if [ -z "$CLIENT_UUID" ]; then
    kc_api POST "/clients" "$OAUTH2_CONFIG" > /dev/null
    CLIENT_UUID=$(get_client_id "oauth2-proxy")
    echo -e "${GREEN}✓${NC} Client 'oauth2-proxy' créé"

    # Récupérer le secret généré
    SECRET=$(kc_api GET "/clients/${CLIENT_UUID}/client-secret" | python3 -c "import json,sys; print(json.load(sys.stdin).get('value',''))" 2>/dev/null)
    if [ -n "$SECRET" ]; then
        echo -e "${YELLOW}⚠${NC} Client secret généré: $SECRET"
        echo "   Mettre à jour OIDC_CLIENT_SECRET dans .env"
    fi
else
    kc_api PUT "/clients/${CLIENT_UUID}" "$OAUTH2_CONFIG" > /dev/null
    echo -e "${GREEN}✓${NC} Client 'oauth2-proxy' mis à jour"
fi

add_groups_scope "$CLIENT_UUID" "oauth2-proxy"

# =============================================================================
# CLIENT GUACAMOLE
# =============================================================================
echo -e "${BLUE}[4/6]${NC} Configuration du client 'guacamole'..."

CLIENT_UUID=$(get_client_id "guacamole")

GUACAMOLE_CONFIG=$(cat <<EOF
{
    "clientId": "guacamole",
    "name": "Guacamole Bastion",
    "enabled": true,
    "publicClient": true,
    "standardFlowEnabled": false,
    "implicitFlowEnabled": true,
    "directAccessGrantsEnabled": false,
    "protocol": "openid-connect",
    "redirectUris": [
        "https://${GUACAMOLE_HOST}/*"
    ],
    "webOrigins": [
        "https://${GUACAMOLE_HOST}"
    ],
    "attributes": {
        "oauth2.device.authorization.grant.enabled": "false",
        "post.logout.redirect.uris": "https://${GUACAMOLE_HOST}/*"
    }
}
EOF
)

if [ -z "$CLIENT_UUID" ]; then
    kc_api POST "/clients" "$GUACAMOLE_CONFIG" > /dev/null
    CLIENT_UUID=$(get_client_id "guacamole")
    echo -e "${GREEN}✓${NC} Client 'guacamole' créé"
else
    kc_api PUT "/clients/${CLIENT_UUID}" "$GUACAMOLE_CONFIG" > /dev/null
    echo -e "${GREEN}✓${NC} Client 'guacamole' mis à jour"
fi

add_groups_scope "$CLIENT_UUID" "guacamole"

# =============================================================================
# CLIENT VAULTWARDEN (optionnel)
# =============================================================================
echo -e "${BLUE}[5/6]${NC} Configuration du client 'vaultwarden'..."

if [ -n "$OIDCWARDEN_CLIENT_SECRET" ]; then
    CLIENT_UUID=$(get_client_id "vaultwarden")

    VAULTWARDEN_CONFIG=$(cat <<EOF
{
    "clientId": "vaultwarden",
    "name": "Vaultwarden Password Manager",
    "enabled": true,
    "publicClient": false,
    "standardFlowEnabled": true,
    "implicitFlowEnabled": false,
    "directAccessGrantsEnabled": false,
    "protocol": "openid-connect",
    "redirectUris": [
        "https://${VAULTWARDEN_HOST}/*",
        "https://${VAULTWARDEN_HOST}/identity/connect/oidc-signin"
    ],
    "webOrigins": [
        "https://${VAULTWARDEN_HOST}"
    ],
    "attributes": {
        "oauth2.device.authorization.grant.enabled": "false",
        "post.logout.redirect.uris": "https://${VAULTWARDEN_HOST}/*"
    }
}
EOF
)

    if [ -z "$CLIENT_UUID" ]; then
        kc_api POST "/clients" "$VAULTWARDEN_CONFIG" > /dev/null
        CLIENT_UUID=$(get_client_id "vaultwarden")
        echo -e "${GREEN}✓${NC} Client 'vaultwarden' créé"
    else
        kc_api PUT "/clients/${CLIENT_UUID}" "$VAULTWARDEN_CONFIG" > /dev/null
        echo -e "${GREEN}✓${NC} Client 'vaultwarden' mis à jour"
    fi

    add_groups_scope "$CLIENT_UUID" "vaultwarden"
else
    echo -e "${YELLOW}⚠${NC} OIDCWARDEN_CLIENT_SECRET non défini, client vaultwarden ignoré"
fi

# =============================================================================
# CLIENT HEADSCALE (optionnel)
# =============================================================================
echo -e "${BLUE}[6/6]${NC} Configuration du client 'headscale'..."

if [ -n "$HEADSCALE_OIDC_CLIENT_SECRET" ]; then
    CLIENT_UUID=$(get_client_id "headscale")

    HEADSCALE_CONFIG=$(cat <<EOF
{
    "clientId": "headscale",
    "name": "Headscale VPN",
    "enabled": true,
    "publicClient": false,
    "standardFlowEnabled": true,
    "implicitFlowEnabled": false,
    "directAccessGrantsEnabled": false,
    "protocol": "openid-connect",
    "redirectUris": [
        "https://${HEADSCALE_HOST}/oidc/callback",
        "http://localhost:*/oidc/callback"
    ],
    "webOrigins": [
        "https://${HEADSCALE_HOST}"
    ],
    "attributes": {
        "oauth2.device.authorization.grant.enabled": "false",
        "post.logout.redirect.uris": "https://${HEADSCALE_HOST}/*"
    }
}
EOF
)

    if [ -z "$CLIENT_UUID" ]; then
        kc_api POST "/clients" "$HEADSCALE_CONFIG" > /dev/null
        CLIENT_UUID=$(get_client_id "headscale")
        echo -e "${GREEN}✓${NC} Client 'headscale' créé"
    else
        kc_api PUT "/clients/${CLIENT_UUID}" "$HEADSCALE_CONFIG" > /dev/null
        echo -e "${GREEN}✓${NC} Client 'headscale' mis à jour"
    fi

    add_groups_scope "$CLIENT_UUID" "headscale"
else
    echo -e "${YELLOW}⚠${NC} HEADSCALE_OIDC_CLIENT_SECRET non défini, client headscale ignoré"
fi

# =============================================================================
# RÉSUMÉ
# =============================================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Configuration terminée!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Clients configurés:"
echo "  - oauth2-proxy : https://${PORTAL_HOST}"
echo "  - guacamole    : https://${GUACAMOLE_HOST}"
if [ -n "$OIDCWARDEN_CLIENT_SECRET" ]; then
    echo "  - vaultwarden  : https://${VAULTWARDEN_HOST}"
fi
if [ -n "$HEADSCALE_OIDC_CLIENT_SECRET" ]; then
    echo "  - headscale    : https://${HEADSCALE_HOST}"
fi
echo ""
echo "Scope 'groups' créé et assigné à tous les clients"
echo ""
