#!/bin/bash
# =============================================================================
# KEYCLOAK - CREATION DES GROUPES
# =============================================================================
# Cree les groupes definis dans .env :
# - ADMIN_GROUP     : Administrateurs infrastructure (acces complet)
# - ADMIN_APP_GROUP : Administrateurs applicatifs (monitoring, services)
# - USER_GROUP      : Utilisateurs standards
#
# Usage:
#   ./setup-groups.sh [--dry-run]
#
# Options:
#   --dry-run  : Afficher les actions sans les executer
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Charger les fonctions communes
source "$SCRIPT_DIR/configure-client.sh"

# Charger l'environnement
load_env || exit 1

# Parser arguments
DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Option inconnue: $1"
            echo "Usage: $0 [--dry-run]"
            exit 1
            ;;
    esac
done

# Groupes depuis .env (avec valeurs par defaut)
ADMIN_GROUP="${ADMIN_GROUP:-admin-infra}"
ADMIN_APP_GROUP="${ADMIN_APP_GROUP:-admin-app}"
USER_GROUP="${USER_GROUP:-utilisateurs}"

# Groupes a creer
# Format: "nom_groupe:description"
# ATTENTION: Ne pas utiliser "GROUPS" comme nom de variable (variable reservee bash)
KEYCLOAK_GROUPS=(
    "${ADMIN_GROUP}:Administrateurs infrastructure - acces complet a tous les services"
    "${ADMIN_APP_GROUP}:Administrateurs applicatifs - monitoring et services admin"
    "${USER_GROUP}:Utilisateurs standards - acces services metier"
)

echo ""
echo "=============================================="
echo "  KEYCLOAK - Creation des Groupes"
echo "=============================================="
echo ""
echo "Realm: ${KEYCLOAK_REALM:-poc}"
echo ""

if [ "$DRY_RUN" = true ]; then
    echo "[DRY-RUN] Mode simulation active"
    echo ""
fi

# Verifier la connectivite Keycloak
log_info "Verification de la connectivite Keycloak..."
KEYCLOAK_URL=$(get_keycloak_url)
if ! curl -s -k "${KEYCLOAK_URL}/health/ready" > /dev/null 2>&1; then
    log_error "Keycloak n'est pas accessible sur ${KEYCLOAK_URL}"
    exit 1
fi
log_success "Keycloak accessible"

# Obtenir le token admin
log_info "Authentification admin..."
TOKEN=$(get_admin_token) || exit 1
log_success "Token obtenu"

REALM="${KEYCLOAK_REALM:-poc}"

# Fonction pour verifier si un groupe existe
group_exists() {
    local group_name="$1"
    local result
    result=$(curl -s -k -X GET \
        "${KEYCLOAK_URL}/admin/realms/${REALM}/groups?search=${group_name}&exact=true" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json")

    # Verifier si le groupe existe avec le nom exact
    echo "$result" | jq -e ".[] | select(.name == \"${group_name}\")" > /dev/null 2>&1
}

# Fonction pour creer un groupe
create_group() {
    local group_name="$1"
    local group_desc="$2"

    if group_exists "$group_name"; then
        log_info "Groupe '$group_name' existe deja"
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY-RUN] Creer groupe: $group_name ($group_desc)"
        return 0
    fi

    log_info "Creation du groupe '$group_name'..."

    local payload
    payload=$(jq -n \
        --arg name "$group_name" \
        --arg desc "$group_desc" \
        '{
            name: $name,
            attributes: {
                description: [$desc]
            }
        }')

    local response
    local http_code
    response=$(curl -s -k -w "\n%{http_code}" -X POST \
        "${KEYCLOAK_URL}/admin/realms/${REALM}/groups" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$payload")

    http_code=$(echo "$response" | tail -n1)

    if [ "$http_code" = "201" ] || [ "$http_code" = "204" ]; then
        log_success "Groupe '$group_name' cree"
    elif [ "$http_code" = "409" ]; then
        log_info "Groupe '$group_name' existe deja"
    else
        log_error "Erreur creation groupe '$group_name' (HTTP $http_code)"
        echo "$response" | head -n -1
        return 1
    fi
}

# Creer les groupes
echo ""
for group_entry in "${KEYCLOAK_GROUPS[@]}"; do
    group_name="${group_entry%%:*}"
    group_desc="${group_entry#*:}"
    create_group "$group_name" "$group_desc"
done

# Afficher le resume
echo ""
echo "=============================================="
echo "  Resume"
echo "=============================================="
echo ""

log_info "Groupes dans le realm '${REALM}':"
groups_list=$(curl -s -k -X GET \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/groups" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json")

echo "$groups_list" | jq -r '.[] | "  - \(.name)"' 2>/dev/null || echo "  (aucun groupe)"

echo ""
echo "Pour gerer les groupes dans Keycloak Admin:"
echo "  ${KEYCLOAK_URL}/admin/master/console/#/${REALM}/groups"
echo ""
echo "Pour ajouter un utilisateur a un groupe:"
echo "  Users > [user] > Groups > Join Group"
echo ""
