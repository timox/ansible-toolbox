#!/bin/bash
# =============================================================================
# SETUP-RUNDECK.SH - Configure Rundeck projects avec Ansible
# =============================================================================
set -euo pipefail

# --- Configuration -----------------------------------------------------------
RUNDECK_URL="${RUNDECK_URL:-http://localhost:4440}"
RUNDECK_USER="${RUNDECK_USER:-admin}"
RUNDECK_PASS="${RUNDECK_PASS:-admin}"
ANSIBLE_BASE="/home/rundeck/ansible-toolbox"
API_VERSION="41"

# --- Couleurs ----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --- Variables globales ------------------------------------------------------
API_TOKEN=""
COOKIES_FILE=""

# --- Cleanup -----------------------------------------------------------------
cleanup() {
    [ -n "$COOKIES_FILE" ] && rm -f "$COOKIES_FILE"
}
trap cleanup EXIT

# --- Attendre que Rundeck soit prêt ------------------------------------------
wait_for_rundeck() {
    log_info "Attente de Rundeck..."
    local max_attempts=30
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if curl -sf "${RUNDECK_URL}/" > /dev/null 2>&1; then
            log_ok "Rundeck est accessible"
            return 0
        fi
        attempt=$((attempt + 1))
        echo -n "." >&2
        sleep 2
    done
    echo "" >&2

    log_error "Rundeck n'est pas accessible après ${max_attempts} tentatives"
    return 1
}

# --- Obtenir un token API ----------------------------------------------------
get_api_token() {
    log_info "Obtention du token API..."

    COOKIES_FILE=$(mktemp)

    # Login via formulaire
    curl -sf -c "$COOKIES_FILE" "${RUNDECK_URL}/j_security_check" \
        -d "j_username=${RUNDECK_USER}" \
        -d "j_password=${RUNDECK_PASS}" \
        -L > /dev/null 2>&1 || {
        log_error "Échec login"
        return 1
    }

    # Créer un token API
    local response
    response=$(curl -sf -b "$COOKIES_FILE" "${RUNDECK_URL}/api/${API_VERSION}/tokens" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d '{"user":"admin","roles":["admin"],"duration":"1d","name":"setup-script"}' 2>/dev/null) || {
        log_error "Échec création token"
        return 1
    }

    API_TOKEN=$(echo "$response" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

    if [ -z "$API_TOKEN" ]; then
        log_error "Token vide"
        return 1
    fi

    log_ok "Token obtenu"
}

# --- Appel API avec token ----------------------------------------------------
api_call() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    local args=(-sf -X "$method")
    args+=(-H "Accept: application/json")
    args+=(-H "X-Rundeck-Auth-Token: ${API_TOKEN}")

    if [ -n "$data" ]; then
        args+=(-H "Content-Type: application/json")
        args+=(-d "$data")
    fi

    curl "${args[@]}" "${RUNDECK_URL}/api/${API_VERSION}${endpoint}" 2>/dev/null
}

api_call_yaml() {
    local method="$1"
    local endpoint="$2"
    local data="$3"

    curl -sf -X "$method" \
        -H "Accept: application/json" \
        -H "Content-Type: application/yaml" \
        -H "X-Rundeck-Auth-Token: ${API_TOKEN}" \
        -d "$data" \
        "${RUNDECK_URL}/api/${API_VERSION}${endpoint}" 2>/dev/null
}

# --- Créer un projet ---------------------------------------------------------
create_project() {
    local project_name="$1"
    local project_desc="$2"

    log_info "Création du projet: $project_name"

    # Vérifier si le projet existe
    local exists
    exists=$(api_call GET "/project/${project_name}" 2>/dev/null || echo "")

    if echo "$exists" | grep -q "\"name\":\"${project_name}\""; then
        log_ok "Le projet $project_name existe déjà"
        return 0
    fi

    # Configuration du projet
    local config
    config=$(cat <<EOF
{
    "name": "${project_name}",
    "description": "${project_desc}",
    "config": {
        "project.description": "${project_desc}",
        "resources.source.1.type": "com.rundeck.plugins.ansible.plugin.AnsibleResourceModelSourceFactory",
        "resources.source.1.config.ansible-inventory": "${ANSIBLE_BASE}/inventory/hosts.yml",
        "resources.source.1.config.ansible-config-file-path": "${ANSIBLE_BASE}/ansible.cfg",
        "resources.source.1.config.ansible-gather-facts": "false",
        "resources.source.1.config.ansible-ignore-errors": "true",
        "service.NodeExecutor.default.provider": "com.rundeck.plugins.ansible.plugin.AnsibleNodeExecutor",
        "project.plugin.NodeExecutor.com.rundeck.plugins.ansible.plugin.AnsibleNodeExecutor.ansible-config-file-path": "${ANSIBLE_BASE}/ansible.cfg",
        "service.FileCopier.default.provider": "com.rundeck.plugins.ansible.plugin.AnsibleFileCopier",
        "project.plugin.FileCopier.com.rundeck.plugins.ansible.plugin.AnsibleFileCopier.ansible-config-file-path": "${ANSIBLE_BASE}/ansible.cfg"
    }
}
EOF
)

    local response
    response=$(api_call POST "/projects" "$config" 2>&1) || true

    if echo "$response" | grep -q "\"name\":\"${project_name}\""; then
        log_ok "Projet $project_name créé"
    elif echo "$response" | grep -q "already exists"; then
        log_ok "Projet $project_name existe déjà"
    else
        log_error "Échec création projet: $response"
        return 1
    fi
}

# --- Créer un job Ansible Playbook -------------------------------------------
create_job() {
    local project_name="$1"
    local job_name="$2"
    local playbook_path="$3"
    local job_desc="${4:-$job_name}"

    log_info "  → Job: $job_name"

    # Utiliser exec script pour appeler ansible-playbook directement
    local job_yaml
    job_yaml=$(cat <<EOF
- name: ${job_name}
  description: "${job_desc}"
  project: ${project_name}
  loglevel: INFO
  nodeFilterEditable: false
  executionEnabled: true
  sequence:
    keepgoing: false
    strategy: sequential
    commands:
    - exec: ansible-playbook -i ${ANSIBLE_BASE}/inventory/hosts.yml ${playbook_path}
EOF
)

    local response
    response=$(api_call_yaml POST "/project/${project_name}/jobs/import?dupeOption=update" "$job_yaml") || true

    if echo "$response" | grep -q '"succeeded":\[{'; then
        log_ok "  → Job: $job_name"
    elif echo "$response" | grep -q '"skipped":\[{'; then
        log_warn "  → Job: $job_name (existant)"
    else
        log_error "  → Job: $job_name (échec: $response)"
    fi
}

# --- Configuration des projets -----------------------------------------------
setup_infrastructure_project() {
    create_project "infrastructure" "Infrastructure - Bootstrap et maintenance serveurs"

    create_job "infrastructure" "Bootstrap" \
        "${ANSIBLE_BASE}/playbooks/bootstrap.yml" \
        "Prépare un serveur vierge (packages, SSH, Docker)"

    create_job "infrastructure" "Check" \
        "${ANSIBLE_BASE}/playbooks/check.yml" \
        "Vérifie l'état des serveurs"

    create_job "infrastructure" "Setup SSH Key" \
        "${ANSIBLE_BASE}/playbooks/setup-ssh-key.yml" \
        "Déploie une clé SSH sur un serveur"

    create_job "infrastructure" "Setup Self-Signed Cert" \
        "${ANSIBLE_BASE}/playbooks/setup-selfsigned-cert.yml" \
        "Génère un certificat SSL auto-signé"

    create_job "infrastructure" "Setup Lets Encrypt OVH" \
        "${ANSIBLE_BASE}/playbooks/setup-letsencrypt-ovh.yml" \
        "Certificat wildcard Let's Encrypt via DNS OVH"

    create_job "infrastructure" "Setup TBS Certbot" \
        "${ANSIBLE_BASE}/playbooks/setup-tbscertbot.yml" \
        "Certificat commercial TBS"
}

setup_portal_project() {
    create_project "portail" "Portail Sécurisé - Déploiement services"

    create_job "portail" "Deploy Stack" \
        "${ANSIBLE_BASE}/playbooks/portal-site.yml" \
        "Déploiement complet du portail"

    create_job "portail" "Deploy Service" \
        "${ANSIBLE_BASE}/playbooks/portal-deploy-service.yml" \
        "Déploie un service individuel"

    create_job "portail" "Check Status" \
        "${ANSIBLE_BASE}/playbooks/portal-check.yml" \
        "Vérifie l'état des services"

    create_job "portail" "Destroy" \
        "${ANSIBLE_BASE}/playbooks/portal-destroy.yml" \
        "Supprime un ou tous les services"
}

setup_monitoring_project() {
    create_project "monitoring" "Monitoring - Zabbix"

    create_job "monitoring" "Deploy Zabbix Agent" \
        "${ANSIBLE_BASE}/playbooks/deploy-zabbix-agent.yml" \
        "Installe Zabbix Agent 2"
}

setup_network_project() {
    create_project "network" "Network - Backup équipements"

    create_job "network" "Backup Cisco" \
        "${ANSIBLE_BASE}/playbooks/backup-cisco.yml" \
        "Sauvegarde configs Cisco IOS"
}

# --- Main --------------------------------------------------------------------
main() {
    echo ""
    echo "=============================================="
    echo "  Setup Rundeck - Ansible Toolbox"
    echo "=============================================="
    echo ""

    wait_for_rundeck
    get_api_token

    echo ""
    log_info "Création des projets et jobs..."
    echo ""

    setup_infrastructure_project
    echo ""

    setup_portal_project
    echo ""

    setup_monitoring_project
    echo ""

    setup_network_project
    echo ""

    echo "=============================================="
    echo -e "${GREEN}  Setup terminé !${NC}"
    echo "=============================================="
    echo ""
    echo "  URL: ${RUNDECK_URL}"
    echo "  Login: ${RUNDECK_USER}"
    echo ""
    echo "  Projets créés:"
    echo "    - infrastructure (6 jobs)"
    echo "    - portail (4 jobs)"
    echo "    - monitoring (1 job)"
    echo "    - network (1 job)"
    echo ""
}

main "$@"
