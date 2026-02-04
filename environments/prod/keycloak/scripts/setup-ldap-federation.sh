#!/bin/bash
# =============================================================================
# KEYCLOAK - CONFIGURATION FEDERATION LDAP
# =============================================================================
# Configure la federation LDAP pour le test-ldap du POC
#
# Usage:
#   ./setup-ldap-federation.sh [--delete]
#
# Options:
#   --delete : Supprimer la federation existante
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

# Parser arguments
DELETE_MODE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --delete)
            DELETE_MODE=true
            shift
            ;;
        *)
            echo "Option inconnue: $1"
            echo "Usage: $0 [--delete]"
            exit 1
            ;;
    esac
done

echo ""
echo "=============================================="
echo "  KEYCLOAK - Federation LDAP"
echo "=============================================="
echo ""
echo "Realm: ${KEYCLOAK_REALM:-poc}"
echo ""

# Configuration LDAP
LDAP_NAME="test-ldap"
LDAP_CONNECTION_URL="ldap://test-ldap:389"
LDAP_BIND_DN="cn=admin,dc=poc,dc=local"
LDAP_BIND_PASSWORD="admin123"
LDAP_USERS_DN="ou=users,dc=poc,dc=local"
LDAP_UUID_ATTRIBUTE="entryUUID"
LDAP_USERNAME_ATTRIBUTE="uid"
LDAP_RDN_ATTRIBUTE="uid"
LDAP_USER_OBJECT_CLASSES="inetOrgPerson, posixAccount"

# Construire l'URL Keycloak
KEYCLOAK_BASE="${KEYCLOAK_BACKEND_URL:-http://localhost:8080}"
KEYCLOAK_BASE="${KEYCLOAK_BASE#http://}"
KEYCLOAK_BASE="${KEYCLOAK_BASE#https://}"
KEYCLOAK_URL="http://$KEYCLOAK_BASE"

REALM="${KEYCLOAK_REALM:-poc}"

# Verifier Keycloak
echo -e "${BLUE}[INFO]${NC} Verification de la connectivite Keycloak..."
if ! curl -sf "${KEYCLOAK_URL}/health/ready" > /dev/null 2>&1; then
    if ! curl -sf "${KEYCLOAK_URL}/realms/master" > /dev/null 2>&1; then
        echo -e "${RED}[ERROR]${NC} Keycloak non accessible sur ${KEYCLOAK_URL}"
        exit 1
    fi
fi
echo -e "${GREEN}[OK]${NC} Keycloak accessible"

# Obtenir token admin
echo -e "${BLUE}[INFO]${NC} Authentification admin..."
ADMIN_TOKEN=$(get_admin_token) || exit 1
echo -e "${GREEN}[OK]${NC} Token obtenu"

# Obtenir l'UUID du realm (necessaire pour parentId)
REALM_UUID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${REALM}" \
    -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.id')
if [ -z "$REALM_UUID" ] || [ "$REALM_UUID" = "null" ]; then
    echo -e "${RED}[ERROR]${NC} Impossible d'obtenir l'UUID du realm"
    exit 1
fi

# Fonction pour obtenir l'ID de la federation LDAP (par nom ou premiere trouvee)
get_ldap_federation_id() {
    local name_filter="${1:-}"
    if [ -n "$name_filter" ]; then
        curl -sk "${KEYCLOAK_URL}/admin/realms/${REALM}/components?type=org.keycloak.storage.UserStorageProvider" \
            -H "Authorization: Bearer $ADMIN_TOKEN" | \
            jq -r ".[] | select(.name==\"$name_filter\") | .id"
    else
        # Retourner la premiere federation LDAP trouvee
        curl -sk "${KEYCLOAK_URL}/admin/realms/${REALM}/components?type=org.keycloak.storage.UserStorageProvider" \
            -H "Authorization: Bearer $ADMIN_TOKEN" | \
            jq -r ".[0].id // empty"
    fi
}

# Mode suppression
if [ "$DELETE_MODE" = true ]; then
    echo -e "${RED}=== Mode SUPPRESSION ===${NC}"
    LDAP_ID=$(get_ldap_federation_id)
    if [ -n "$LDAP_ID" ]; then
        curl -sk -X DELETE "${KEYCLOAK_URL}/admin/realms/${REALM}/components/$LDAP_ID" \
            -H "Authorization: Bearer $ADMIN_TOKEN"
        echo -e "${GREEN}[OK]${NC} Federation LDAP '$LDAP_NAME' supprimee"
    else
        echo -e "${YELLOW}[SKIP]${NC} Federation LDAP '$LDAP_NAME' n'existe pas"
    fi
    exit 0
fi

# Verifier si une federation LDAP existe deja
LDAP_ID=$(get_ldap_federation_id)

if [ -n "$LDAP_ID" ]; then
    echo -e "${BLUE}[INFO]${NC} Federation LDAP existante (ID: $LDAP_ID), mise a jour..."

    # Mettre a jour la configuration existante
    EXISTING_CONFIG=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${REALM}/components/$LDAP_ID" \
        -H "Authorization: Bearer $ADMIN_TOKEN")

    # Mettre a jour avec les nouveaux parametres
    UPDATED_CONFIG=$(echo "$EXISTING_CONFIG" | jq "
        .config.connectionUrl = [\"$LDAP_CONNECTION_URL\"] |
        .config.bindDn = [\"$LDAP_BIND_DN\"] |
        .config.bindCredential = [\"$LDAP_BIND_PASSWORD\"] |
        .config.usersDn = [\"$LDAP_USERS_DN\"] |
        .config.usernameLDAPAttribute = [\"$LDAP_USERNAME_ATTRIBUTE\"] |
        .config.rdnLDAPAttribute = [\"$LDAP_RDN_ATTRIBUTE\"] |
        .config.uuidLDAPAttribute = [\"$LDAP_UUID_ATTRIBUTE\"]
    ")

    RESPONSE=$(curl -sk -w "\n%{http_code}" -X PUT \
        "${KEYCLOAK_URL}/admin/realms/${REALM}/components/$LDAP_ID" \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$UPDATED_CONFIG")

    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    if [ "$HTTP_CODE" = "204" ]; then
        echo -e "${GREEN}[OK]${NC} Federation LDAP mise a jour"
    else
        echo -e "${RED}[ERROR]${NC} Echec mise a jour (HTTP $HTTP_CODE)"
    fi
else
    echo -e "${BLUE}[INFO]${NC} Creation de la federation LDAP '$LDAP_NAME'..."

    # Creer la federation LDAP
    RESPONSE=$(curl -sk -w "\n%{http_code}" -X POST \
        "${KEYCLOAK_URL}/admin/realms/${REALM}/components" \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"$LDAP_NAME\",
            \"providerId\": \"ldap\",
            \"providerType\": \"org.keycloak.storage.UserStorageProvider\",
            \"parentId\": \"$REALM_UUID\",
            \"config\": {
                \"enabled\": [\"true\"],
                \"priority\": [\"0\"],
                \"importEnabled\": [\"true\"],
                \"editMode\": [\"READ_ONLY\"],
                \"syncRegistrations\": [\"false\"],
                \"vendor\": [\"other\"],
                \"connectionUrl\": [\"$LDAP_CONNECTION_URL\"],
                \"bindDn\": [\"$LDAP_BIND_DN\"],
                \"bindCredential\": [\"$LDAP_BIND_PASSWORD\"],
                \"usersDn\": [\"$LDAP_USERS_DN\"],
                \"authType\": [\"simple\"],
                \"searchScope\": [\"1\"],
                \"useTruststoreSpi\": [\"ldapsOnly\"],
                \"connectionPooling\": [\"true\"],
                \"pagination\": [\"true\"],
                \"batchSizeForSync\": [\"1000\"],
                \"fullSyncPeriod\": [\"-1\"],
                \"changedSyncPeriod\": [\"-1\"],
                \"usernameLDAPAttribute\": [\"$LDAP_USERNAME_ATTRIBUTE\"],
                \"rdnLDAPAttribute\": [\"$LDAP_RDN_ATTRIBUTE\"],
                \"uuidLDAPAttribute\": [\"$LDAP_UUID_ATTRIBUTE\"],
                \"userObjectClasses\": [\"$LDAP_USER_OBJECT_CLASSES\"]
            }
        }")

    HTTP_CODE=$(echo "$RESPONSE" | tail -1)

    if [ "$HTTP_CODE" = "201" ]; then
        echo -e "${GREEN}[OK]${NC} Federation LDAP '$LDAP_NAME' creee"
        LDAP_ID=$(get_ldap_federation_id)
    else
        echo -e "${RED}[ERROR]${NC} Echec creation federation (HTTP $HTTP_CODE)"
        echo "$RESPONSE" | head -n -1
        exit 1
    fi
fi

# Configurer les mappers
echo -e "${BLUE}[INFO]${NC} Configuration des mappers..."

# Fonction pour creer/maj un mapper
configure_mapper() {
    local mapper_name=$1
    local mapper_type=$2
    local mapper_config=$3

    # Verifier si le mapper existe
    MAPPER_ID=$(curl -sk "${KEYCLOAK_URL}/admin/realms/${REALM}/components?parent=$LDAP_ID&type=org.keycloak.storage.ldap.mappers.LDAPStorageMapper" \
        -H "Authorization: Bearer $ADMIN_TOKEN" | \
        jq -r ".[] | select(.name==\"$mapper_name\") | .id")

    if [ -n "$MAPPER_ID" ]; then
        echo -e "${YELLOW}  [SKIP]${NC} Mapper '$mapper_name' existe"
    else
        RESPONSE=$(curl -sk -w "\n%{http_code}" -X POST \
            "${KEYCLOAK_URL}/admin/realms/${REALM}/components" \
            -H "Authorization: Bearer $ADMIN_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{
                \"name\": \"$mapper_name\",
                \"providerId\": \"$mapper_type\",
                \"providerType\": \"org.keycloak.storage.ldap.mappers.LDAPStorageMapper\",
                \"parentId\": \"$LDAP_ID\",
                \"config\": $mapper_config
            }")

        HTTP_CODE=$(echo "$RESPONSE" | tail -1)
        if [ "$HTTP_CODE" = "201" ]; then
            echo -e "${GREEN}  [OK]${NC} Mapper '$mapper_name' cree"
        else
            echo -e "${RED}  [ERROR]${NC} Mapper '$mapper_name' (HTTP $HTTP_CODE)"
        fi
    fi
}

# Mapper email
configure_mapper "email" "user-attribute-ldap-mapper" '{
    "ldap.attribute": ["mail"],
    "user.model.attribute": ["email"],
    "read.only": ["true"],
    "always.read.value.from.ldap": ["true"],
    "is.mandatory.in.ldap": ["true"]
}'

# Mapper firstName
configure_mapper "first name" "user-attribute-ldap-mapper" '{
    "ldap.attribute": ["givenName"],
    "user.model.attribute": ["firstName"],
    "read.only": ["true"],
    "always.read.value.from.ldap": ["true"],
    "is.mandatory.in.ldap": ["false"]
}'

# Mapper lastName
configure_mapper "last name" "user-attribute-ldap-mapper" '{
    "ldap.attribute": ["sn"],
    "user.model.attribute": ["lastName"],
    "read.only": ["true"],
    "always.read.value.from.ldap": ["true"],
    "is.mandatory.in.ldap": ["true"]
}'

# Mapper username
configure_mapper "username" "user-attribute-ldap-mapper" '{
    "ldap.attribute": ["uid"],
    "user.model.attribute": ["username"],
    "read.only": ["true"],
    "always.read.value.from.ldap": ["true"],
    "is.mandatory.in.ldap": ["true"]
}'

# Synchroniser les utilisateurs
echo ""
echo -e "${BLUE}[INFO]${NC} Synchronisation des utilisateurs LDAP..."
SYNC_RESPONSE=$(curl -sk -X POST \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/user-storage/$LDAP_ID/sync?action=triggerFullSync" \
    -H "Authorization: Bearer $ADMIN_TOKEN")

ADDED=$(echo "$SYNC_RESPONSE" | jq -r '.added // 0')
UPDATED=$(echo "$SYNC_RESPONSE" | jq -r '.updated // 0')
FAILED=$(echo "$SYNC_RESPONSE" | jq -r '.failed // 0')

echo -e "${GREEN}[OK]${NC} Synchronisation: $ADDED ajoutes, $UPDATED mis a jour, $FAILED echecs"

echo ""
echo "=============================================="
echo "  Resume"
echo "=============================================="
echo ""
echo "Federation LDAP configuree:"
echo "  Nom:        $LDAP_NAME"
echo "  URL:        $LDAP_CONNECTION_URL"
echo "  Users DN:   $LDAP_USERS_DN"
echo "  Username:   $LDAP_USERNAME_ATTRIBUTE"
echo ""
echo "Utilisateurs synchronises depuis LDAP."
echo ""
echo "Pour tester:"
echo "  - admin.infra@poc.local / Test123!"
echo "  - admin.app@poc.local / Test123!"
echo "  - user.test@poc.local / Test123!"
echo ""
