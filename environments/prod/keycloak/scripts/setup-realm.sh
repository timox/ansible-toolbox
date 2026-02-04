#!/bin/bash
# =============================================================================
# KEYCLOAK - CREATION DU REALM
# =============================================================================
# Cree le realm s'il n'existe pas (prerequis pour tous les services OIDC)
#
# Usage:
#   ./setup-realm.sh
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
echo "  KEYCLOAK - Creation Realm"
echo "=============================================="
echo ""
echo "Realm: $REALM"
echo ""

# Verifier Keycloak
log_info "Verification de la connectivite Keycloak..."
for i in {1..30}; do
    if curl -sf "${KEYCLOAK_URL}/realms/master" > /dev/null 2>&1; then
        break
    fi
    sleep 2
done

if ! curl -sf "${KEYCLOAK_URL}/realms/master" > /dev/null 2>&1; then
    log_error "Keycloak non accessible sur ${KEYCLOAK_URL}"
    exit 1
fi
log_success "Keycloak accessible"

# Obtenir token admin
log_info "Authentification admin..."
ADMIN_TOKEN=$(get_admin_token) || exit 1
log_success "Token obtenu"

# Verifier si le realm existe
log_info "Verification du realm '$REALM'..."
REALM_EXISTS=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${REALM}" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -o /dev/null -w "%{http_code}")

if [ "$REALM_EXISTS" = "200" ]; then
    log_success "Realm '$REALM' existe deja"
else
    log_info "Creation du realm '$REALM'..."

    RESPONSE=$(curl -sk -w "\n%{http_code}" -X POST \
        "${KEYCLOAK_URL}/admin/realms" \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
            \"realm\": \"$REALM\",
            \"enabled\": true,
            \"displayName\": \"Portail Securise\",
            \"registrationAllowed\": false,
            \"loginWithEmailAllowed\": true,
            \"duplicateEmailsAllowed\": false,
            \"resetPasswordAllowed\": true,
            \"editUsernameAllowed\": false,
            \"bruteForceProtected\": true,
            \"permanentLockout\": false,
            \"maxFailureWaitSeconds\": 900,
            \"minimumQuickLoginWaitSeconds\": 60,
            \"waitIncrementSeconds\": 60,
            \"quickLoginCheckMilliSeconds\": 1000,
            \"maxDeltaTimeSeconds\": 43200,
            \"failureFactor\": 5,
            \"sslRequired\": \"external\",
            \"accessTokenLifespan\": 300,
            \"accessTokenLifespanForImplicitFlow\": 900,
            \"ssoSessionIdleTimeout\": 1800,
            \"ssoSessionMaxLifespan\": 36000,
            \"offlineSessionIdleTimeout\": 2592000,
            \"accessCodeLifespan\": 60,
            \"accessCodeLifespanUserAction\": 300,
            \"accessCodeLifespanLogin\": 1800,
            \"actionTokenGeneratedByAdminLifespan\": 43200,
            \"actionTokenGeneratedByUserLifespan\": 300,
            \"internationalizationEnabled\": true,
            \"supportedLocales\": [\"fr\", \"en\"],
            \"defaultLocale\": \"fr\"
        }")

    HTTP_CODE=$(echo "$RESPONSE" | tail -1)

    if [ "$HTTP_CODE" = "201" ]; then
        log_success "Realm '$REALM' cree"
    else
        log_error "Echec creation realm (HTTP $HTTP_CODE)"
        echo "$RESPONSE" | head -n -1
        exit 1
    fi
fi

echo ""
log_success "Realm '$REALM' pret"
echo ""
