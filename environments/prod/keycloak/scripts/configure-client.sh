#!/bin/bash
# =============================================================================
# KEYCLOAK - CONFIGURATION CLIENT OIDC GENERIQUE
# =============================================================================
# Script utilitaire pour configurer un client OIDC dans Keycloak
# Utilise par les scripts specifiques de chaque service
#
# Usage:
#   source configure-client.sh
#   configure_oidc_client "linshare" "$CLIENT_CONFIG"
# =============================================================================

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}[OK]${NC} $1" >&2; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Charger les variables d'environnement
load_env() {
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local env_file="$script_dir/../../.env"

    if [ -f "$env_file" ]; then
        set -a
        source "$env_file"
        set +a
    else
        log_error "Fichier .env introuvable: $env_file"
        return 1
    fi

    # Deriver les variables Keycloak depuis KEYCLOAK_ISSUER si vides
    if [ -n "${KEYCLOAK_ISSUER:-}" ]; then
        # KEYCLOAK_URL: scheme + host (sans /realms/xxx)
        if [ -z "${KEYCLOAK_URL:-}" ]; then
            export KEYCLOAK_URL=$(echo "$KEYCLOAK_ISSUER" | sed 's|/realms/.*||')
        fi

        # KEYCLOAK_HOST: hostname seul
        if [ -z "${KEYCLOAK_HOST:-}" ]; then
            export KEYCLOAK_HOST=$(echo "$KEYCLOAK_ISSUER" | sed -E 's|^https?://||; s|/.*||; s|:.*||')
        fi

        # KEYCLOAK_REALM: nom du realm
        if [ -z "${KEYCLOAK_REALM:-}" ]; then
            export KEYCLOAK_REALM=$(echo "$KEYCLOAK_ISSUER" | sed -E 's|.*/realms/||')
        fi

        # KEYCLOAK_BACKEND_URL: si vide, utiliser KEYCLOAK_URL
        if [ -z "${KEYCLOAK_BACKEND_URL:-}" ]; then
            export KEYCLOAK_BACKEND_URL="$KEYCLOAK_URL"
        fi
    fi

    return 0
}

# URL Keycloak pour API admin (scripts tournent sur l'hote, pas dans Docker)
# Priorite: KEYCLOAK_HOST_BACKEND_URL > fallback localhost
get_keycloak_url() {
    # 1. KEYCLOAK_HOST_BACKEND_URL: URL directe pour les scripts hote
    if [ -n "${KEYCLOAK_HOST_BACKEND_URL:-}" ]; then
        echo "$KEYCLOAK_HOST_BACKEND_URL"
        return
    fi

    # 2. Fallback localhost
    echo "http://localhost:${KEYCLOAK_HTTP_PORT:-8080}"
}

# Obtenir token admin
get_admin_token() {
    local keycloak_url=$(get_keycloak_url)
    local admin_user=${KEYCLOAK_ADMIN:-admin}
    local admin_pass=${KEYCLOAK_ADMIN_PASSWORD}

    if [ -z "$admin_pass" ]; then
        log_error "KEYCLOAK_ADMIN_PASSWORD non defini"
        return 1
    fi

    log_info "Connexion a Keycloak: $keycloak_url"

    local response
    response=$(curl -sk -X POST "${keycloak_url}/realms/master/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=${admin_user}" \
        -d "password=${admin_pass}" \
        -d "grant_type=password" \
        -d "client_id=admin-cli" 2>&1)

    local token
    token=$(echo "$response" | jq -r '.access_token // empty')

    if [ -z "$token" ]; then
        log_error "Impossible d'obtenir le token admin"
        log_error "URL: ${keycloak_url}/realms/master/protocol/openid-connect/token"
        log_error "Reponse: $(echo "$response" | jq -r '.error_description // .error // "connexion impossible"')"
        return 1
    fi

    echo "$token"
}

# Verifier si un client existe
client_exists() {
    local token=$1
    local client_id=$2
    local keycloak_url=$(get_keycloak_url)
    local realm=${KEYCLOAK_REALM:-poc}

    local result
    result=$(curl -sk "${keycloak_url}/admin/realms/${realm}/clients?clientId=${client_id}" \
        -H "Authorization: Bearer ${token}")

    # Verifier si la reponse est une erreur
    if echo "$result" | jq -e '.error' > /dev/null 2>&1; then
        log_error "Erreur API Keycloak: $(echo "$result" | jq -r '.error // .errorMessage // "inconnue"')"
        return 1
    fi

    # Verifier que c'est un tableau
    if ! echo "$result" | jq -e 'type == "array"' > /dev/null 2>&1; then
        log_error "Reponse inattendue de Keycloak (pas un tableau)"
        return 1
    fi

    local uuid
    uuid=$(echo "$result" | jq -r '.[0].id // empty')

    if [ -n "$uuid" ]; then
        echo "$uuid"
        return 0
    fi
    return 1
}

# Creer ou mettre a jour un client
configure_oidc_client() {
    local client_id=$1
    local client_config=$2
    local keycloak_url=$(get_keycloak_url)
    local realm=${KEYCLOAK_REALM:-poc}

    log_info "Configuration du client '${client_id}'..."

    local token
    token=$(get_admin_token) || return 1

    local client_uuid
    client_uuid=$(client_exists "$token" "$client_id")

    local response
    local http_code

    if [ -n "$client_uuid" ]; then
        log_info "Client existe (UUID: $client_uuid), mise a jour..."
        response=$(curl -sk -w "\n%{http_code}" -X PUT "${keycloak_url}/admin/realms/${realm}/clients/${client_uuid}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "$client_config")
        http_code=$(echo "$response" | tail -n1)
        if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
            log_success "Client '${client_id}' mis a jour"
        else
            log_error "Echec mise a jour client (HTTP $http_code)"
            echo "$response" | head -n -1 | jq -r '.errorMessage // .error // .' 2>/dev/null
            return 1
        fi
    else
        log_info "Creation du client dans le realm '${realm}'..."
        response=$(curl -sk -w "\n%{http_code}" -X POST "${keycloak_url}/admin/realms/${realm}/clients" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "$client_config")
        http_code=$(echo "$response" | tail -n1)
        if [ "$http_code" = "201" ] || [ "$http_code" = "204" ]; then
            log_success "Client '${client_id}' cree"
            client_uuid=$(client_exists "$token" "$client_id")
        elif [ "$http_code" = "409" ]; then
            log_info "Client existe deja, recuperation UUID..."
            client_uuid=$(client_exists "$token" "$client_id")
        else
            log_error "Echec creation client (HTTP $http_code)"
            echo "$response" | head -n -1 | jq -r '.errorMessage // .error // .' 2>/dev/null
            return 1
        fi
    fi

    if [ -z "$client_uuid" ]; then
        log_error "Impossible de recuperer l'UUID du client"
        return 1
    fi

    echo "$client_uuid"
}

# Ajouter un mapper au client
add_mapper() {
    local client_uuid=$1
    local mapper_name=$2
    local mapper_config=$3
    local keycloak_url=$(get_keycloak_url)
    local realm=${KEYCLOAK_REALM:-poc}

    local token
    token=$(get_admin_token) || return 1

    # Verifier si le mapper existe
    local existing
    existing=$(curl -sk "${keycloak_url}/admin/realms/${realm}/clients/${client_uuid}/protocol-mappers/models" \
        -H "Authorization: Bearer ${token}" | jq -r ".[] | select(.name == \"${mapper_name}\") | .id")

    if [ -n "$existing" ]; then
        log_info "Mapper '${mapper_name}' existe, mise a jour..."
        curl -sk -X PUT "${keycloak_url}/admin/realms/${realm}/clients/${client_uuid}/protocol-mappers/models/${existing}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "$mapper_config" > /dev/null
    else
        log_info "Creation du mapper '${mapper_name}'..."
        curl -sk -X POST "${keycloak_url}/admin/realms/${realm}/clients/${client_uuid}/protocol-mappers/models" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "$mapper_config" > /dev/null
    fi

    log_success "Mapper '${mapper_name}' configure"
}

# Mapper: domain_discriminator (hardcoded claim)
add_domain_discriminator_mapper() {
    local client_uuid=$1
    local domain_value=$2

    local mapper_config
    mapper_config=$(cat <<EOF
{
    "name": "domain_discriminator",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-hardcoded-claim-mapper",
    "consentRequired": false,
    "config": {
        "claim.value": "${domain_value}",
        "userinfo.token.claim": "true",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "claim.name": "domain_discriminator",
        "jsonType.label": "String"
    }
}
EOF
)
    add_mapper "$client_uuid" "domain_discriminator" "$mapper_config"
}

# Mapper: groups (group membership)
add_groups_mapper() {
    local client_uuid=$1

    local mapper_config
    mapper_config=$(cat <<EOF
{
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
}
EOF
)
    add_mapper "$client_uuid" "groups" "$mapper_config"
}

# Recuperer le secret d'un client
get_client_secret() {
    local client_uuid=$1
    local keycloak_url=$(get_keycloak_url)
    local realm=${KEYCLOAK_REALM:-poc}

    local token
    token=$(get_admin_token) || return 1

    curl -sk "${keycloak_url}/admin/realms/${realm}/clients/${client_uuid}/client-secret" \
        -H "Authorization: Bearer ${token}" | jq -r '.value'
}
