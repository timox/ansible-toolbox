#!/bin/bash
# =============================================================================
# KEYCLOAK - CREATION DES CLIENT SCOPES
# =============================================================================
# Cree les scopes OIDC necessaires (groups, etc.) et les assigne aux clients
#
# Usage:
#   ./setup-scopes.sh
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Charger les fonctions communes
source "$SCRIPT_DIR/configure-client.sh"

# Charger l'environnement
load_env || exit 1

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

REALM="${KEYCLOAK_REALM:-poc}"

# URL Keycloak pour scripts hote
KEYCLOAK_URL="${KEYCLOAK_HOST_BACKEND_URL:-http://localhost:${KEYCLOAK_HTTP_PORT:-8080}}"

echo ""
echo "=============================================="
echo "  KEYCLOAK - Configuration des Scopes"
echo "=============================================="
echo ""
echo "Realm: $REALM"
echo ""

# Verifier Keycloak
log_info "Verification de la connectivite Keycloak..."
if ! curl -sf "${KEYCLOAK_URL}/realms/master" > /dev/null 2>&1; then
    log_error "Keycloak non accessible sur ${KEYCLOAK_URL}"
    exit 1
fi
log_success "Keycloak accessible"

# Obtenir token admin
log_info "Authentification admin..."
ADMIN_TOKEN=$(get_admin_token) || exit 1
log_success "Token obtenu"

# Fonction pour creer un client scope s'il n'existe pas
create_client_scope() {
    local scope_name=$1
    local description=$2

    # Verifier si le scope existe
    EXISTING=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes" \
        -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r ".[] | select(.name==\"$scope_name\") | .id")

    if [ -n "$EXISTING" ]; then
        log_info "Scope '$scope_name' existe deja (ID: $EXISTING)"
        echo "$EXISTING"
        return 0
    fi

    log_info "Creation du scope '$scope_name'..."
    RESPONSE=$(curl -sk -w "\n%{http_code}" -X POST \
        "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes" \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"$scope_name\",
            \"description\": \"$description\",
            \"protocol\": \"openid-connect\",
            \"attributes\": {
                \"include.in.token.scope\": \"true\",
                \"display.on.consent.screen\": \"true\"
            }
        }")

    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    if [ "$HTTP_CODE" = "201" ]; then
        # Recuperer l'ID du scope cree
        SCOPE_ID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes" \
            -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r ".[] | select(.name==\"$scope_name\") | .id")
        log_success "Scope '$scope_name' cree (ID: $SCOPE_ID)"
        echo "$SCOPE_ID"
    else
        log_error "Echec creation scope (HTTP $HTTP_CODE)"
        echo "$RESPONSE" | head -n -1
        return 1
    fi
}

# Fonction pour ajouter un scope a un client
add_scope_to_client() {
    local client_id=$1
    local scope_id=$2
    local scope_type=${3:-optional}  # optional ou default

    # Obtenir l'UUID du client
    CLIENT_UUID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${REALM}/clients?clientId=$client_id" \
        -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.[0].id')

    if [ -z "$CLIENT_UUID" ] || [ "$CLIENT_UUID" = "null" ]; then
        log_info "Client '$client_id' non trouve, skip"
        return 0
    fi

    # Ajouter le scope
    curl -sk -X PUT "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/$CLIENT_UUID/${scope_type}-client-scopes/$scope_id" \
        -H "Authorization: Bearer $ADMIN_TOKEN"

    log_success "Scope ajoute au client '$client_id'"
}

# =============================================================================
# CREATION DES SCOPES
# =============================================================================

# Creer le scope "groups"
GROUPS_SCOPE_ID=$(create_client_scope "groups" "Group membership scope")

# =============================================================================
# ASSIGNATION AUX CLIENTS
# =============================================================================

if [ -n "$GROUPS_SCOPE_ID" ]; then
    echo ""
    log_info "Assignation du scope 'groups' aux clients..."

    # Liste des clients qui ont besoin du scope groups
    CLIENTS=("oauth2-proxy" "guacamole" "linshare" "vaultwarden")

    for client in "${CLIENTS[@]}"; do
        add_scope_to_client "$client" "$GROUPS_SCOPE_ID" "optional"
    done
fi

echo ""
log_success "Configuration des scopes terminee"
echo ""
