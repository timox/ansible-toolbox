#!/bin/bash
# =============================================================================
# KEYCLOAK - COPIE FEDERATION LDAP ENTRE REALMS
# =============================================================================
# Copie la configuration de federation d'identite LDAP d'un realm source
# vers un realm cible, incluant tous les mappers associes.
#
# Usage:
#   ./copy-ldap-federation.sh <source-realm> <target-realm> [ldap-name]
#   ./copy-ldap-federation.sh --list <realm>
#
# Exemples:
#   ./copy-ldap-federation.sh master poc
#   ./copy-ldap-federation.sh master poc "ldap-ad"
#   ./copy-ldap-federation.sh --list master
#
# Options:
#   --list <realm>  : Lister les federations LDAP du realm
#   --dry-run       : Afficher sans executer
#   --help          : Afficher l'aide
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Charger les fonctions communes
if [ -f "$SCRIPT_DIR/configure-client.sh" ]; then
    source "$SCRIPT_DIR/configure-client.sh"
else
    echo "Erreur: configure-client.sh introuvable"
    exit 1
fi

# Variables
DRY_RUN=false
LIST_MODE=false

# Aide
show_help() {
    cat << 'EOF'
Usage: ./copy-ldap-federation.sh <source-realm> <target-realm> [ldap-name]
       ./copy-ldap-federation.sh --list <realm>

Copie la configuration de federation LDAP d'un realm vers un autre.

Arguments:
  source-realm    Realm source contenant la federation LDAP
  target-realm    Realm cible ou copier la configuration
  ldap-name       (Optionnel) Nom de la federation LDAP a copier
                  Si non specifie, copie toutes les federations LDAP

Options:
  --list <realm>  Lister les federations LDAP du realm
  --dry-run       Afficher les actions sans les executer
  --help          Afficher cette aide

Exemples:
  # Copier toutes les federations LDAP de master vers poc
  ./copy-ldap-federation.sh master poc

  # Copier une federation specifique
  ./copy-ldap-federation.sh master poc "Active Directory"

  # Lister les federations du realm master
  ./copy-ldap-federation.sh --list master

  # Mode simulation
  ./copy-ldap-federation.sh --dry-run master poc

Notes:
  - Les mappers LDAP sont aussi copies
  - Si une federation avec le meme nom existe deja, elle est mise a jour
  - Les mots de passe de bind LDAP doivent etre reconfigures manuellement
EOF
}

# Parser les arguments
SOURCE_REALM=""
TARGET_REALM=""
LDAP_NAME=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            show_help
            exit 0
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --list)
            LIST_MODE=true
            shift
            if [[ $# -gt 0 ]]; then
                SOURCE_REALM="$1"
                shift
            fi
            ;;
        *)
            if [ -z "$SOURCE_REALM" ]; then
                SOURCE_REALM="$1"
            elif [ -z "$TARGET_REALM" ]; then
                TARGET_REALM="$1"
            elif [ -z "$LDAP_NAME" ]; then
                LDAP_NAME="$1"
            fi
            shift
            ;;
    esac
done

# Charger l'environnement
load_env || exit 1

KEYCLOAK_URL=$(get_keycloak_url)

# Obtenir le token admin
get_token() {
    local token
    token=$(get_admin_token 2>/dev/null)
    if [ -z "$token" ]; then
        log_error "Impossible d'obtenir le token admin"
        exit 1
    fi
    echo "$token"
}

# Lister les federations LDAP d'un realm
list_ldap_federations() {
    local realm=$1
    local token=$2

    curl -sk "${KEYCLOAK_URL}/admin/realms/${realm}/components?type=org.keycloak.storage.UserStorageProvider" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json"
}

# Obtenir une federation LDAP par son ID
get_ldap_federation() {
    local realm=$1
    local component_id=$2
    local token=$3

    curl -sk "${KEYCLOAK_URL}/admin/realms/${realm}/components/${component_id}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json"
}

# Obtenir les mappers d'une federation
get_ldap_mappers() {
    local realm=$1
    local parent_id=$2
    local token=$3

    curl -sk "${KEYCLOAK_URL}/admin/realms/${realm}/components?parent=${parent_id}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json"
}

# Verifier si une federation existe dans le realm cible
federation_exists() {
    local realm=$1
    local name=$2
    local token=$3

    local result
    result=$(list_ldap_federations "$realm" "$token")

    local existing_id
    existing_id=$(echo "$result" | jq -r ".[] | select(.name == \"${name}\") | .id")

    if [ -n "$existing_id" ]; then
        echo "$existing_id"
        return 0
    fi
    return 1
}

# Creer ou mettre a jour une federation
create_or_update_federation() {
    local realm=$1
    local config=$2
    local token=$3

    local name
    name=$(echo "$config" | jq -r '.name')

    # Supprimer l'ID et parentId pour la creation
    local clean_config
    clean_config=$(echo "$config" | jq 'del(.id, .parentId)')

    # Verifier si existe deja
    local existing_id
    existing_id=$(federation_exists "$realm" "$name" "$token") || true

    if [ -n "$existing_id" ]; then
        log_info "Federation '$name' existe deja, mise a jour..."

        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY-RUN] PUT ${KEYCLOAK_URL}/admin/realms/${realm}/components/${existing_id}"
            echo "$existing_id"
            return 0
        fi

        local response
        local http_code
        response=$(curl -sk -w "\n%{http_code}" -X PUT \
            "${KEYCLOAK_URL}/admin/realms/${realm}/components/${existing_id}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "$clean_config")

        http_code=$(echo "$response" | tail -n1)

        if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
            log_success "Federation '$name' mise a jour"
            echo "$existing_id"
        else
            log_error "Erreur mise a jour federation (HTTP $http_code)"
            echo "$response" | head -n -1
            return 1
        fi
    else
        log_info "Creation de la federation '$name'..."

        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY-RUN] POST ${KEYCLOAK_URL}/admin/realms/${realm}/components"
            echo "dry-run-id"
            return 0
        fi

        local response
        local http_code
        response=$(curl -sk -w "\n%{http_code}" -X POST \
            "${KEYCLOAK_URL}/admin/realms/${realm}/components" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "$clean_config")

        http_code=$(echo "$response" | tail -n1)

        if [ "$http_code" = "201" ]; then
            # Recuperer l'ID de la nouvelle federation
            local new_id
            new_id=$(federation_exists "$realm" "$name" "$token")
            log_success "Federation '$name' creee (ID: $new_id)"
            echo "$new_id"
        else
            log_error "Erreur creation federation (HTTP $http_code)"
            echo "$response" | head -n -1
            return 1
        fi
    fi
}

# Creer un mapper
create_mapper() {
    local realm=$1
    local parent_id=$2
    local mapper_config=$3
    local token=$4

    local name
    name=$(echo "$mapper_config" | jq -r '.name')

    # Mettre a jour le parentId avec le nouveau parent
    local clean_config
    clean_config=$(echo "$mapper_config" | jq --arg pid "$parent_id" 'del(.id) | .parentId = $pid')

    log_info "  Creation du mapper '$name'..."

    if [ "$DRY_RUN" = true ]; then
        log_info "  [DRY-RUN] POST ${KEYCLOAK_URL}/admin/realms/${realm}/components"
        return 0
    fi

    local response
    local http_code
    response=$(curl -sk -w "\n%{http_code}" -X POST \
        "${KEYCLOAK_URL}/admin/realms/${realm}/components" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "$clean_config")

    http_code=$(echo "$response" | tail -n1)

    if [ "$http_code" = "201" ] || [ "$http_code" = "204" ]; then
        log_success "  Mapper '$name' cree"
    elif [ "$http_code" = "409" ]; then
        log_info "  Mapper '$name' existe deja"
    else
        log_warning "  Erreur creation mapper '$name' (HTTP $http_code)"
    fi
}

# Copier une federation complete (config + mappers)
copy_federation() {
    local source_realm=$1
    local target_realm=$2
    local federation_id=$3
    local token=$4

    # Obtenir la configuration de la federation
    local fed_config
    fed_config=$(get_ldap_federation "$source_realm" "$federation_id" "$token")

    local fed_name
    fed_name=$(echo "$fed_config" | jq -r '.name')

    echo ""
    log_info "Copie de la federation '$fed_name'..."

    # Creer ou mettre a jour la federation dans le realm cible
    local new_fed_id
    new_fed_id=$(create_or_update_federation "$target_realm" "$fed_config" "$token")

    if [ -z "$new_fed_id" ]; then
        log_error "Echec de la copie de la federation"
        return 1
    fi

    # Copier les mappers
    log_info "Copie des mappers..."

    local mappers
    mappers=$(get_ldap_mappers "$source_realm" "$federation_id" "$token")

    local mapper_count
    mapper_count=$(echo "$mappers" | jq 'length')

    if [ "$mapper_count" -gt 0 ]; then
        echo "$mappers" | jq -c '.[]' | while read -r mapper; do
            create_mapper "$target_realm" "$new_fed_id" "$mapper" "$token"
        done
        log_success "$mapper_count mapper(s) traite(s)"
    else
        log_info "Aucun mapper a copier"
    fi

    echo ""
    log_warning "IMPORTANT: Le mot de passe de bind LDAP doit etre reconfigure manuellement"
    log_info "  -> Keycloak Admin > $target_realm > User Federation > $fed_name > Bind Credential"
}

# =============================================================================
# MAIN
# =============================================================================

echo ""
echo "=============================================="
echo "  KEYCLOAK - Copie Federation LDAP"
echo "=============================================="
echo ""

if [ "$DRY_RUN" = true ]; then
    log_warning "Mode DRY-RUN active - aucune modification"
    echo ""
fi

# Mode liste
if [ "$LIST_MODE" = true ]; then
    if [ -z "$SOURCE_REALM" ]; then
        log_error "Realm requis pour --list"
        echo "Usage: $0 --list <realm>"
        exit 1
    fi

    # Obtenir le token (messages sur stderr)
    TOKEN=$(get_token 2>/dev/null)
    if [ -z "$TOKEN" ]; then
        log_error "Impossible d'obtenir le token admin"
        exit 1
    fi

    federations=$(list_ldap_federations "$SOURCE_REALM" "$TOKEN")

    # Filtrer uniquement les LDAP
    ldap_feds=$(echo "$federations" | jq '[.[] | select(.providerId == "ldap")]')

    count=$(echo "$ldap_feds" | jq 'length')

    echo "Federations LDAP dans le realm '$SOURCE_REALM':"
    echo ""

    if [ "$count" -eq 0 ]; then
        echo "  (aucune federation LDAP)"
    else
        echo "$ldap_feds" | jq -r '.[] | "  - \(.name) (ID: \(.id))"'
        echo ""
        echo "Total: $count federation(s) LDAP"
    fi

    exit 0
fi

# Mode copie - validation des arguments
if [ -z "$SOURCE_REALM" ] || [ -z "$TARGET_REALM" ]; then
    log_error "Realms source et cible requis"
    echo ""
    echo "Usage: $0 <source-realm> <target-realm> [ldap-name]"
    echo "       $0 --list <realm>"
    echo ""
    echo "Utilisez --help pour plus d'informations"
    exit 1
fi

if [ "$SOURCE_REALM" = "$TARGET_REALM" ]; then
    log_error "Les realms source et cible doivent etre differents"
    exit 1
fi

log_info "Source: $SOURCE_REALM"
log_info "Cible:  $TARGET_REALM"
if [ -n "$LDAP_NAME" ]; then
    log_info "LDAP:   $LDAP_NAME"
fi
echo ""

# Verifier la connectivite
log_info "Verification de la connectivite Keycloak..."
if ! curl -sk "${KEYCLOAK_URL}/health/ready" > /dev/null 2>&1; then
    # Essayer sans /health/ready (anciennes versions)
    if ! curl -sk "${KEYCLOAK_URL}" > /dev/null 2>&1; then
        log_error "Keycloak n'est pas accessible sur ${KEYCLOAK_URL}"
        exit 1
    fi
fi
log_success "Keycloak accessible: $KEYCLOAK_URL"

# Obtenir le token
log_info "Authentification admin..."
TOKEN=$(get_token)
log_success "Token obtenu"

# Lister les federations LDAP du realm source
log_info "Recherche des federations LDAP dans '$SOURCE_REALM'..."
federations=$(list_ldap_federations "$SOURCE_REALM" "$TOKEN")

# Filtrer les LDAP
ldap_feds=$(echo "$federations" | jq '[.[] | select(.providerId == "ldap")]')

count=$(echo "$ldap_feds" | jq 'length')

if [ "$count" -eq 0 ]; then
    log_error "Aucune federation LDAP trouvee dans le realm '$SOURCE_REALM'"
    exit 1
fi

log_success "$count federation(s) LDAP trouvee(s)"

# Si un nom specifique est demande, filtrer
if [ -n "$LDAP_NAME" ]; then
    ldap_feds=$(echo "$ldap_feds" | jq --arg name "$LDAP_NAME" '[.[] | select(.name == $name)]')
    count=$(echo "$ldap_feds" | jq 'length')

    if [ "$count" -eq 0 ]; then
        log_error "Federation LDAP '$LDAP_NAME' introuvable dans '$SOURCE_REALM'"
        log_info "Federations disponibles:"
        list_ldap_federations "$SOURCE_REALM" "$TOKEN" | jq -r '.[] | select(.providerId == "ldap") | "  - \(.name)"'
        exit 1
    fi
fi

# Copier chaque federation
echo "$ldap_feds" | jq -r '.[].id' | while read -r fed_id; do
    copy_federation "$SOURCE_REALM" "$TARGET_REALM" "$fed_id" "$TOKEN"
done

echo ""
echo "=============================================="
echo "  Copie terminee"
echo "=============================================="
echo ""
log_info "Verifier la configuration dans Keycloak Admin:"
echo "  ${KEYCLOAK_URL}/admin/master/console/#/${TARGET_REALM}/user-federation"
echo ""
