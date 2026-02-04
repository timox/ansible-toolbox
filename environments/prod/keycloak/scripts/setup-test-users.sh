#!/bin/bash
# =============================================================================
# KEYCLOAK - CREATION DES UTILISATEURS DE TEST POC
# =============================================================================
# Cree les utilisateurs de test pour le POC avec leurs groupes :
#
# | Username     | Password       | Groupe         |
# |--------------|----------------|----------------|
# | admin-infra  | poc-admin-123  | admin-infra    |
# | admin-std    | poc-std-123    | admin-standard |
# | user-test    | poc-user-123   | utilisateurs   |
#
# Usage:
#   ./setup-test-users.sh [--dry-run] [--delete]
#
# Options:
#   --dry-run  : Afficher les actions sans les executer
#   --delete   : Supprimer les utilisateurs de test
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
DRY_RUN=false
DELETE_MODE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --delete)
            DELETE_MODE=true
            shift
            ;;
        *)
            echo "Option inconnue: $1"
            echo "Usage: $0 [--dry-run] [--delete]"
            exit 1
            ;;
    esac
done

# Utilisateurs de test a creer
# Format: "username:password:email:groupe"
TEST_USERS=(
    "admin-infra:poc-admin-123:admin-infra@poc.local:admin-infra"
    "admin-std:poc-std-123:admin-std@poc.local:admin-standard"
    "user-test:poc-user-123:user-test@poc.local:utilisateurs"
)

echo ""
echo "=============================================="
echo "  KEYCLOAK - Utilisateurs de Test POC"
echo "=============================================="
echo ""
echo "Realm: ${KEYCLOAK_REALM:-poc}"
echo ""

# URL Keycloak pour scripts hote
KEYCLOAK_BASE="${KEYCLOAK_HOST_BACKEND_URL:-http://localhost:${KEYCLOAK_HTTP_PORT:-8080}}"

# Verifier Keycloak
echo -e "${BLUE}[INFO]${NC} Verification de la connectivite Keycloak..."
if ! curl -sf "${KEYCLOAK_BASE}/health/ready" > /dev/null 2>&1; then
    if ! curl -sf "${KEYCLOAK_BASE}/realms/master" > /dev/null 2>&1; then
        echo -e "${RED}[ERROR]${NC} Keycloak non accessible sur ${KEYCLOAK_BASE}"
        exit 1
    fi
fi
echo -e "${GREEN}[OK]${NC} Keycloak accessible sur ${KEYCLOAK_BASE}"

# Obtenir token admin
echo -e "${BLUE}[INFO]${NC} Authentification admin..."
ADMIN_TOKEN=$(get_admin_token) || exit 1
echo -e "${GREEN}[OK]${NC} Token obtenu"

REALM="${KEYCLOAK_REALM:-poc}"
KEYCLOAK_URL="${KEYCLOAK_BASE}"

# Fonction pour obtenir l'ID d'un groupe
get_group_id() {
    local group_name=$1
    curl -sk "${KEYCLOAK_URL}/admin/realms/${REALM}/groups" \
        -H "Authorization: Bearer $ADMIN_TOKEN" | \
        grep -o "\"id\":\"[^\"]*\",\"name\":\"$group_name\"" | \
        head -1 | cut -d'"' -f4
}

# Fonction pour obtenir l'ID d'un utilisateur
get_user_id() {
    local username=$1
    curl -sk "${KEYCLOAK_URL}/admin/realms/${REALM}/users?username=$username&exact=true" \
        -H "Authorization: Bearer $ADMIN_TOKEN" | \
        grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4
}

# Fonction pour creer un utilisateur
create_user() {
    local username=$1
    local password=$2
    local email=$3
    local group=$4

    echo -e "${BLUE}[INFO]${NC} Traitement utilisateur: $username"

    # Verifier si l'utilisateur existe
    local user_id=$(get_user_id "$username")

    if [ -n "$user_id" ]; then
        echo -e "${YELLOW}[SKIP]${NC} Utilisateur '$username' existe deja (ID: $user_id)"
    else
        if [ "$DRY_RUN" = true ]; then
            echo -e "${YELLOW}[DRY-RUN]${NC} Creer utilisateur '$username' avec groupe '$group'"
        else
            # Creer l'utilisateur
            local response=$(curl -sk -w "\n%{http_code}" -X POST \
                "${KEYCLOAK_URL}/admin/realms/${REALM}/users" \
                -H "Authorization: Bearer $ADMIN_TOKEN" \
                -H "Content-Type: application/json" \
                -d "{
                    \"username\": \"$username\",
                    \"email\": \"$email\",
                    \"emailVerified\": true,
                    \"enabled\": true,
                    \"firstName\": \"$username\",
                    \"lastName\": \"POC\",
                    \"credentials\": [{
                        \"type\": \"password\",
                        \"value\": \"$password\",
                        \"temporary\": false
                    }]
                }")

            local http_code=$(echo "$response" | tail -1)

            if [ "$http_code" = "201" ]; then
                echo -e "${GREEN}[OK]${NC} Utilisateur '$username' cree"
                user_id=$(get_user_id "$username")
            else
                echo -e "${RED}[ERROR]${NC} Echec creation utilisateur '$username' (HTTP $http_code)"
                return 1
            fi
        fi
    fi

    # Ajouter au groupe
    if [ -n "$user_id" ] && [ "$DRY_RUN" = false ]; then
        local group_id=$(get_group_id "$group")
        if [ -n "$group_id" ]; then
            curl -sk -X PUT \
                "${KEYCLOAK_URL}/admin/realms/${REALM}/users/$user_id/groups/$group_id" \
                -H "Authorization: Bearer $ADMIN_TOKEN"
            echo -e "${GREEN}[OK]${NC}   -> Ajoute au groupe '$group'"
        else
            echo -e "${YELLOW}[WARNING]${NC} Groupe '$group' non trouve"
        fi
    fi
}

# Fonction pour supprimer un utilisateur
delete_user() {
    local username=$1

    local user_id=$(get_user_id "$username")

    if [ -z "$user_id" ]; then
        echo -e "${YELLOW}[SKIP]${NC} Utilisateur '$username' n'existe pas"
    else
        if [ "$DRY_RUN" = true ]; then
            echo -e "${YELLOW}[DRY-RUN]${NC} Supprimer utilisateur '$username' (ID: $user_id)"
        else
            curl -sk -X DELETE \
                "${KEYCLOAK_URL}/admin/realms/${REALM}/users/$user_id" \
                -H "Authorization: Bearer $ADMIN_TOKEN"
            echo -e "${GREEN}[OK]${NC} Utilisateur '$username' supprime"
        fi
    fi
}

# Mode suppression
if [ "$DELETE_MODE" = true ]; then
    echo -e "${RED}=== Mode SUPPRESSION ===${NC}"
    echo ""
    for user_entry in "${TEST_USERS[@]}"; do
        IFS=':' read -r username password email group <<< "$user_entry"
        delete_user "$username"
    done
    echo ""
    echo -e "${GREEN}[OK]${NC} Suppression terminee"
    exit 0
fi

# Mode creation
echo "=== Creation des utilisateurs de test ==="
echo ""

for user_entry in "${TEST_USERS[@]}"; do
    IFS=':' read -r username password email group <<< "$user_entry"
    create_user "$username" "$password" "$email" "$group"
    echo ""
done

echo "=============================================="
echo "  Resume"
echo "=============================================="
echo ""
echo "Utilisateurs de test crees:"
echo ""
printf "  %-15s %-18s %-15s\n" "USERNAME" "PASSWORD" "GROUPE"
printf "  %-15s %-18s %-15s\n" "--------" "--------" "------"
for user_entry in "${TEST_USERS[@]}"; do
    IFS=':' read -r username password email group <<< "$user_entry"
    printf "  %-15s %-18s %-15s\n" "$username" "$password" "$group"
done
echo ""
echo "Pour tester la connexion:"
echo "  https://portail.${DOMAIN:-poc.local}"
echo ""
echo "Pour gerer les utilisateurs dans Keycloak Admin:"
echo "  http://${KEYCLOAK_BACKEND_URL:-localhost:8080}/admin/master/console/#/${REALM}/users"
echo ""
