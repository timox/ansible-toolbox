#!/bin/bash
# =============================================================================
# SETUP POC - Etapes specifiques au POC (ne fait PAS partie de deploy.sh)
# =============================================================================
# Ce script configure les elements specifiques au POC :
# 1. Demarrage du serveur LDAP de test (simulation AD)
# 2. Configuration des clients Keycloak
# 3. (Optionnel) Creation des utilisateurs de test locaux
#
# PREREQUIS:
#   - deploy.sh a ete execute (services principaux demarres)
#   - Keycloak est accessible
#
# Usage:
#   ./setup-poc.sh                    # Setup complet POC
#   ./setup-poc.sh --ldap-only        # Demarrer uniquement le LDAP
#   ./setup-poc.sh --keycloak-only    # Configurer uniquement Keycloak
#   ./setup-poc.sh --status           # Verifier l'etat du POC
#   ./setup-poc.sh --stop             # Arreter le LDAP de test
#
# Utilisateurs de test (via LDAP):
#   | Email                    | Password | Groupe        |
#   |--------------------------|----------|---------------|
#   | admin.infra@poc.local    | Test123! | admin-infra   |
#   | admin.app@poc.local      | Test123! | admin-app     |
#   | user.test@poc.local      | Test123! | utilisateurs  |
#   | user.multi@poc.local     | Test123! | admin-app, utilisateurs |
#
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Charger .env
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

# =============================================================================
# FONCTIONS
# =============================================================================

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --ldap-only       Demarrer uniquement le serveur LDAP de test"
    echo "  --keycloak-only   Configurer uniquement les clients Keycloak"
    echo "  --test-users      Creer les utilisateurs de test locaux (sans LDAP)"
    echo "  --status          Afficher l'etat du POC"
    echo "  --stop            Arreter le LDAP de test"
    echo "  --help            Afficher cette aide"
    echo ""
    echo "Sans option: execute le setup complet (LDAP + Keycloak)"
}

check_prerequisites() {
    echo -e "${BLUE}[INFO]${NC} Verification des prerequis..."

    # Verifier que Keycloak tourne
    if ! docker ps | grep -q keycloak; then
        echo -e "${RED}[ERROR]${NC} Keycloak n'est pas demarre"
        echo "Executez d'abord: ./deploy.sh"
        exit 1
    fi

    # Verifier que les reseaux existent
    if ! docker network ls | grep -q portal-net; then
        echo -e "${RED}[ERROR]${NC} Reseau portal-net n'existe pas"
        echo "Executez d'abord: ./deploy.sh"
        exit 1
    fi

    echo -e "${GREEN}[OK]${NC} Prerequis valides"
}

setup_poc_ca_bundle() {
    echo ""
    echo -e "${BLUE}[INFO]${NC} Configuration CA bundle pour certificat auto-signe POC..."

    DATA_DIR="/data"
    CUSTOM_CA_DIR="${DATA_DIR}/certs/custom-ca"
    CA_BUNDLE="${DATA_DIR}/certs/ca-bundle.crt"

    mkdir -p "$CUSTOM_CA_DIR"

    # Copier le CA auto-signe du POC dans custom-ca/
    if [ -f "${DATA_DIR}/certs/ca.crt" ]; then
        cp "${DATA_DIR}/certs/ca.crt" "$CUSTOM_CA_DIR/poc-ca.crt"

        # Regenerer le bundle CA
        if [ -f /etc/ssl/certs/ca-certificates.crt ]; then
            cat /etc/ssl/certs/ca-certificates.crt "$CUSTOM_CA_DIR"/*.crt > "$CA_BUNDLE"
            echo -e "${GREEN}[OK]${NC} CA bundle regenere avec CA POC"

            # Redemarrer les services qui utilisent le bundle
            if docker ps | grep -q vaultwarden; then
                docker restart vaultwarden > /dev/null 2>&1
                echo -e "${GREEN}[OK]${NC} Vaultwarden redemarre"
            fi
        fi
    else
        echo -e "${YELLOW}[SKIP]${NC} CA auto-signe non trouve (${DATA_DIR}/certs/ca.crt)"
    fi
}

start_test_ldap() {
    echo ""
    echo -e "${BLUE}=============================================="
    echo -e "  Demarrage LDAP de Test"
    echo -e "==============================================${NC}"
    echo ""

    cd "$SCRIPT_DIR/keycloak/test-ldap"

    # Verifier si deja demarre
    if docker ps | grep -q test-ldap; then
        echo -e "${YELLOW}[SKIP]${NC} LDAP de test deja demarre"
    else
        echo -e "${BLUE}[INFO]${NC} Demarrage du serveur LDAP..."
        docker compose up -d

        # Attendre que le LDAP soit pret
        echo -e "${BLUE}[INFO]${NC} Attente du demarrage LDAP..."
        sleep 5

        # Verifier la sante
        for i in {1..30}; do
            if docker exec test-ldap ldapsearch -x -H ldap://localhost -b "dc=poc,dc=local" -D "cn=admin,dc=poc,dc=local" -w admin123 > /dev/null 2>&1; then
                echo -e "${GREEN}[OK]${NC} LDAP de test operationnel"
                break
            fi
            sleep 2
        done
    fi

    cd "$SCRIPT_DIR"

    echo ""
    echo "LDAP de test:"
    echo "  URL:           ldap://test-ldap:389"
    echo "  Bind DN:       cn=admin,dc=poc,dc=local"
    echo "  Bind Password: admin123"
    echo "  Users DN:      ou=users,dc=poc,dc=local"
    echo "  Groups DN:     ou=groups,dc=poc,dc=local"
    echo ""
    echo "Interface admin: http://localhost:8089"
    echo "  Login DN: cn=admin,dc=poc,dc=local"
    echo "  Password: admin123"
}

stop_test_ldap() {
    echo -e "${BLUE}[INFO]${NC} Arret du LDAP de test..."
    cd "$SCRIPT_DIR/keycloak/test-ldap"
    docker compose down
    cd "$SCRIPT_DIR"
    echo -e "${GREEN}[OK]${NC} LDAP de test arrete"
}

setup_ldap_federation() {
    echo ""
    echo -e "${BLUE}=============================================="
    echo -e "  Configuration Federation LDAP"
    echo -e "==============================================${NC}"
    echo ""

    if [ -f "./keycloak/scripts/setup-ldap-federation.sh" ]; then
        ./keycloak/scripts/setup-ldap-federation.sh
    else
        echo -e "${YELLOW}[WARNING]${NC} Script setup-ldap-federation.sh non trouve"
    fi
}

setup_keycloak() {
    echo ""
    echo -e "${BLUE}=============================================="
    echo -e "  Configuration Keycloak POC"
    echo -e "==============================================${NC}"
    echo ""

    # Configurer la federation LDAP
    setup_ldap_federation

    # Configurer les clients OIDC
    echo -e "${BLUE}[INFO]${NC} Configuration des clients OIDC..."
    ./keycloak/scripts/setup-all.sh

    echo ""
    echo -e "${GREEN}[OK]${NC} Keycloak configure pour le POC"
}

create_test_users() {
    echo ""
    echo -e "${BLUE}=============================================="
    echo -e "  Creation Utilisateurs de Test Locaux"
    echo -e "==============================================${NC}"
    echo ""

    if [ -f "./keycloak/scripts/setup-test-users.sh" ]; then
        ./keycloak/scripts/setup-test-users.sh
    else
        echo -e "${YELLOW}[WARNING]${NC} Script setup-test-users.sh non trouve"
    fi
}

show_status() {
    echo ""
    echo -e "${BLUE}=============================================="
    echo -e "  Etat du POC"
    echo -e "==============================================${NC}"
    echo ""

    echo "=== Services principaux ==="
    for svc in keycloak oauth2-proxy nginx-apps guacamole-web linshare-backend vaultwarden; do
        if docker ps --format '{{.Names}}' | grep -q "^${svc}$"; then
            echo -e "  ${GREEN}[UP]${NC} $svc"
        else
            echo -e "  ${RED}[DOWN]${NC} $svc"
        fi
    done

    echo ""
    echo "=== LDAP de test ==="
    if docker ps --format '{{.Names}}' | grep -q "^test-ldap$"; then
        echo -e "  ${GREEN}[UP]${NC} test-ldap"
        echo -e "  ${GREEN}[UP]${NC} test-ldap-admin (phpLDAPadmin)"
    else
        echo -e "  ${YELLOW}[DOWN]${NC} test-ldap (non demarre)"
    fi

    echo ""
    echo "=== URLs ==="
    echo "  Portail:       https://portail.${DOMAIN:-poc.local}"
    echo "  Keycloak:      https://keycloak.${DOMAIN:-poc.local}"
    echo "  Guacamole:     https://guacamole.${DOMAIN:-poc.local}"
    echo "  LinShare:      https://linshare.${DOMAIN:-poc.local}"
    echo "  Vaultwarden:   https://vault.${DOMAIN:-poc.local}"
    echo "  LDAP Admin:    http://localhost:8089"

    echo ""
    echo "=== Utilisateurs de test (LDAP) ==="
    printf "  %-25s %-10s %-20s\n" "EMAIL" "PASSWORD" "GROUPE"
    printf "  %-25s %-10s %-20s\n" "-----" "--------" "------"
    printf "  %-25s %-10s %-20s\n" "admin.infra@poc.local" "Test123!" "admin-infra"
    printf "  %-25s %-10s %-20s\n" "admin.app@poc.local" "Test123!" "admin-app"
    printf "  %-25s %-10s %-20s\n" "user.test@poc.local" "Test123!" "utilisateurs"
    printf "  %-25s %-10s %-20s\n" "user.multi@poc.local" "Test123!" "admin-app, utilisateurs"
}

# =============================================================================
# MAIN
# =============================================================================

ACTION="full"

while [[ $# -gt 0 ]]; do
    case $1 in
        --ldap-only)
            ACTION="ldap"
            shift
            ;;
        --keycloak-only)
            ACTION="keycloak"
            shift
            ;;
        --test-users)
            ACTION="test-users"
            shift
            ;;
        --status)
            ACTION="status"
            shift
            ;;
        --stop)
            ACTION="stop"
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "Option inconnue: $1"
            show_help
            exit 1
            ;;
    esac
done

echo ""
echo -e "${BLUE}=============================================="
echo -e "  SETUP POC - Portail Securise"
echo -e "==============================================${NC}"

case $ACTION in
    full)
        check_prerequisites
        setup_poc_ca_bundle
        start_test_ldap
        setup_keycloak
        show_status
        ;;
    ldap)
        check_prerequisites
        start_test_ldap
        ;;
    keycloak)
        check_prerequisites
        setup_keycloak
        ;;
    test-users)
        check_prerequisites
        create_test_users
        ;;
    status)
        show_status
        ;;
    stop)
        stop_test_ldap
        ;;
esac

echo ""
echo -e "${GREEN}=============================================="
echo -e "  Setup POC termine"
echo -e "==============================================${NC}"
echo ""
