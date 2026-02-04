#!/bin/bash
# =============================================================================
# KEYCLOAK - CONFIGURATION TOUS LES CLIENTS
# =============================================================================
# Configure tous les clients OIDC pour le POC:
# - LinShare (partage de fichiers)
# - Guacamole (bastion RDP/SSH)
# - Vaultwarden (gestionnaire mots de passe)
# - oauth2-proxy (portail)
#
# Usage:
#   ./setup-all.sh [--only SERVICE]
#
# Options:
#   --only SERVICE  : Configurer uniquement le service specifie
#                     (linshare, guacamole, vaultwarden, oauth2-proxy)
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Charger les fonctions communes
source "$SCRIPT_DIR/configure-client.sh"

# Charger l'environnement
load_env || exit 1

# Parser arguments
ONLY_SERVICE=""
WITH_TEST_USERS=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --only)
            ONLY_SERVICE="$2"
            shift 2
            ;;
        --with-test-users)
            WITH_TEST_USERS=true
            shift
            ;;
        *)
            echo "Option inconnue: $1"
            echo "Usage: $0 [--only SERVICE] [--with-test-users]"
            exit 1
            ;;
    esac
done

echo ""
echo "=============================================="
echo "  KEYCLOAK - Configuration Clients OIDC"
echo "=============================================="
echo ""
echo "Realm: ${KEYCLOAK_REALM:-poc}"
echo "Domain: ${DOMAIN:-poc.local}"
echo ""

# Verifier la connectivite Keycloak
log_info "Verification de la connectivite Keycloak..."
KEYCLOAK_URL=$(get_keycloak_url)
if ! curl -s "${KEYCLOAK_URL}/health/ready" > /dev/null 2>&1; then
    log_error "Keycloak n'est pas accessible"
    exit 1
fi
log_success "Keycloak accessible sur ${KEYCLOAK_URL}"

# Obtenir le token pour verifier les credentials
log_info "Verification des credentials admin..."
TOKEN=$(get_admin_token) || exit 1
log_success "Authentification admin OK"

echo ""

# Configurer les clients
run_setup() {
    local service=$1
    local script="$SCRIPT_DIR/setup-${service}.sh"

    if [ -f "$script" ]; then
        log_info "Configuration de ${service}..."
        chmod +x "$script"
        "$script"
        echo ""
    else
        log_warning "Script non trouve: $script"
    fi
}

if [ -n "$ONLY_SERVICE" ]; then
    run_setup "$ONLY_SERVICE"
else
    # Creer les groupes d'abord
    run_setup "groups"

    # Creer les scopes OIDC (groups, etc.)
    run_setup "scopes"

    # Configurer tous les clients
    run_setup "oauth2-proxy"
    run_setup "linshare"
    run_setup "guacamole"
    run_setup "vaultwarden"

    # Configurer headscale si activé
    if [ "${DEPLOY_HEADSCALE:-false}" = "true" ]; then
        local headscale_script="$SCRIPT_DIR/../../headscale/configure-keycloak-headscale.sh"
        if [ -f "$headscale_script" ]; then
            log_info "Configuration de headscale..."
            chmod +x "$headscale_script"
            "$headscale_script"
            echo ""
        else
            log_warning "Script headscale non trouve: $headscale_script"
        fi
    fi

    # Creer les utilisateurs de test POC (optionnel, specifique POC)
    if [ "$WITH_TEST_USERS" = true ]; then
        run_setup "test-users"
    fi
fi

echo ""
log_success "=============================================="
log_success "  Configuration terminee"
log_success "=============================================="
echo ""
echo "Clients configures dans le realm '${KEYCLOAK_REALM:-poc}'"
echo ""
echo "Pour verifier dans Keycloak Admin:"
echo "  ${KEYCLOAK_URL}/admin/master/console/#/${KEYCLOAK_REALM:-poc}/clients"
echo ""
