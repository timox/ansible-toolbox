#!/bin/bash
# =============================================================================
# setup-semaphore.sh - Import ansible-toolbox project into Semaphore via API
# =============================================================================
# Creates project, keys, repository, inventory, environment, and task templates
#
# Usage:
#   ./semaphore/setup-semaphore.sh
#   SEMAPHORE_URL=http://10.0.0.5:3000 ./semaphore/setup-semaphore.sh
#
# Prerequisites:
#   - Semaphore running and accessible
#   - curl and jq installed
#   - .env file configured (see semaphore/.env.example)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Charger la configuration ---
ENV_FILE="${SCRIPT_DIR}/.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "ERREUR: ${ENV_FILE} introuvable"
    echo "Copier .env.example et configurer : cp semaphore/.env.example semaphore/.env"
    exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

# --- Variables obligatoires ---
SEMAPHORE_URL="${SEMAPHORE_URL:?SEMAPHORE_URL requis dans .env}"
SEMAPHORE_ADMIN_USER="${SEMAPHORE_ADMIN_USER:?SEMAPHORE_ADMIN_USER requis}"
SEMAPHORE_ADMIN_PASSWORD="${SEMAPHORE_ADMIN_PASSWORD:?SEMAPHORE_ADMIN_PASSWORD requis}"
GIT_REPO_URL="${GIT_REPO_URL:-https://github.com/timox/ansible-toolbox.git}"
GIT_BRANCH="${GIT_BRANCH:-main}"
PROJECT_NAME="${PROJECT_NAME:-Ansible Toolbox}"

# --- Couleurs ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

# --- Fonctions API ---
TOKEN=""

api_login() {
    info "Authentification aupres de Semaphore..."
    local response
    response=$(curl -s -w "\n%{http_code}" -X POST "${SEMAPHORE_URL}/api/auth/login" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -c /tmp/semaphore-cookies \
        -d "{\"auth\": \"${SEMAPHORE_ADMIN_USER}\", \"password\": \"${SEMAPHORE_ADMIN_PASSWORD}\"}")

    local http_code
    http_code=$(echo "$response" | tail -1)
    [ "$http_code" = "204" ] || fail "Login echoue (HTTP ${http_code})"
    ok "Connecte a Semaphore"
}

api_get() {
    curl -s -b /tmp/semaphore-cookies -H "Accept: application/json" "${SEMAPHORE_URL}$1"
}

api_post() {
    local endpoint="$1"
    local data="$2"
    local response
    response=$(curl -s -w "\n%{http_code}" -b /tmp/semaphore-cookies \
        -X POST "${SEMAPHORE_URL}${endpoint}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "$data")

    local http_code body
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        echo "$body"
    else
        echo "ERREUR HTTP ${http_code}: ${body}" >&2
        return 1
    fi
}

# --- Trouver ou creer une ressource ---
find_or_create() {
    local resource_type="$1"  # keys, repositories, inventory, environment, templates
    local name="$2"
    local create_data="$3"
    local name_field="${4:-name}"

    local existing
    existing=$(api_get "/api/project/${PROJECT_ID}/${resource_type}" | jq -r ".[] | select(.${name_field} == \"${name}\") | .id" 2>/dev/null)

    if [ -n "$existing" ] && [ "$existing" != "null" ]; then
        info "${resource_type}/${name} existe deja (id=${existing})"
        echo "$existing"
    else
        local result
        result=$(api_post "/api/project/${PROJECT_ID}/${resource_type}" "$create_data") || fail "Creation ${resource_type}/${name}"
        local new_id
        new_id=$(echo "$result" | jq -r '.id')
        ok "${resource_type}/${name} cree (id=${new_id})"
        echo "$new_id"
    fi
}

# =============================================================================
# MAIN
# =============================================================================

echo "=============================================="
echo " Semaphore Setup - ${PROJECT_NAME}"
echo "=============================================="
echo ""

# 1. Login
api_login

# 2. Creer le projet
info "Creation du projet..."
existing_project=$(api_get "/api/projects" | jq -r ".[] | select(.name == \"${PROJECT_NAME}\") | .id" 2>/dev/null)

if [ -n "$existing_project" ] && [ "$existing_project" != "null" ]; then
    PROJECT_ID="$existing_project"
    info "Projet '${PROJECT_NAME}' existe deja (id=${PROJECT_ID})"
else
    result=$(api_post "/api/projects" "{\"name\": \"${PROJECT_NAME}\", \"alert\": false}") || fail "Creation projet"
    PROJECT_ID=$(echo "$result" | jq -r '.id')
    ok "Projet '${PROJECT_NAME}' cree (id=${PROJECT_ID})"
fi
echo ""

# 3. Key Store
info "Configuration du Key Store..."

# 3a. Cle Git (acces depot)
KEY_GIT_ID=$(find_or_create "keys" "git-toolbox" "{
    \"name\": \"git-toolbox\",
    \"type\": \"none\",
    \"project_id\": ${PROJECT_ID}
}")

# 3b. Vault password
KEY_VAULT_ID=$(find_or_create "keys" "vault-password" "{
    \"name\": \"vault-password\",
    \"type\": \"login_password\",
    \"login_password\": {
        \"login\": \"\",
        \"password\": \"${VAULT_PASSWORD:-}\"
    },
    \"project_id\": ${PROJECT_ID}
}")

# 3c. Cle SSH serveurs distants
KEY_SSH_ID=$(find_or_create "keys" "ssh-servers" "{
    \"name\": \"ssh-servers\",
    \"type\": \"ssh\",
    \"ssh\": {
        \"login\": \"${SSH_USER:-ubuntu}\",
        \"private_key\": \"${SSH_PRIVATE_KEY:-}\"
    },
    \"project_id\": ${PROJECT_ID}
}")

# 3d. Credentials Cisco (login/password)
KEY_CISCO_ID=$(find_or_create "keys" "cisco-credentials" "{
    \"name\": \"cisco-credentials\",
    \"type\": \"login_password\",
    \"login_password\": {
        \"login\": \"${CISCO_USER:-admin}\",
        \"password\": \"${CISCO_PASSWORD:-}\"
    },
    \"project_id\": ${PROJECT_ID}
}")
echo ""

# 4. Repository
info "Configuration du repository..."
REPO_ID=$(find_or_create "repositories" "ansible-toolbox" "{
    \"name\": \"ansible-toolbox\",
    \"project_id\": ${PROJECT_ID},
    \"git_url\": \"${GIT_REPO_URL}\",
    \"git_branch\": \"${GIT_BRANCH}\",
    \"ssh_key_id\": ${KEY_GIT_ID}
}")
echo ""

# 5. Inventaires
info "Configuration des inventaires..."

# 5a. Inventaire fichier (remote + zabbix_agents)
INV_FILE_ID=$(find_or_create "inventory" "hosts-file" "{
    \"name\": \"hosts-file\",
    \"project_id\": ${PROJECT_ID},
    \"type\": \"file\",
    \"inventory\": \"inventory/hosts.yml\",
    \"ssh_key_id\": ${KEY_SSH_ID},
    \"become_key_id\": ${KEY_SSH_ID}
}")

# 5b. Inventaire pour equipements reseau (Cisco)
INV_NETWORK_ID=$(find_or_create "inventory" "network-devices" "{
    \"name\": \"network-devices\",
    \"project_id\": ${PROJECT_ID},
    \"type\": \"file\",
    \"inventory\": \"inventory/hosts.yml\",
    \"ssh_key_id\": ${KEY_CISCO_ID},
    \"become_key_id\": ${KEY_CISCO_ID}
}")
echo ""

# 6. Environments
info "Configuration des environnements..."

ENV_DEFAULT_ID=$(find_or_create "environment" "default" "{
    \"name\": \"default\",
    \"project_id\": ${PROJECT_ID},
    \"json\": \"{}\",
    \"env\": \"{}\"
}")
echo ""

# 7. Task Templates
info "Creation des Task Templates..."

create_template() {
    local name="$1"
    local playbook="$2"
    local inventory_id="$3"
    local vault_key="${4:-0}"
    local extra_args="${5:-}"
    local survey_json="${6:-[]}"

    local vault_block=""
    if [ "$vault_key" -gt 0 ]; then
        vault_block="\"vault_key_id\": ${vault_key},"
    fi

    local args_block=""
    if [ -n "$extra_args" ]; then
        args_block="\"arguments\": \"${extra_args}\","
    fi

    find_or_create "templates" "$name" "{
        \"name\": \"${name}\",
        \"project_id\": ${PROJECT_ID},
        \"repository_id\": ${REPO_ID},
        \"inventory_id\": ${inventory_id},
        \"environment_id\": ${ENV_DEFAULT_ID},
        ${vault_block}
        ${args_block}
        \"playbook\": \"${playbook}\",
        \"type\": \"\",
        \"survey_vars\": ${survey_json}
    }" > /dev/null
}

# --- Bootstrap & Check (hosts: remote) ---
create_template \
    "Bootstrap - Server" \
    "playbooks/bootstrap.yml" \
    "$INV_FILE_ID" \
    "$KEY_VAULT_ID"

create_template \
    "Check - Server state" \
    "playbooks/check.yml" \
    "$INV_FILE_ID" \
    0

create_template \
    "Bootstrap - Dry Run" \
    "playbooks/bootstrap.yml" \
    "$INV_FILE_ID" \
    "$KEY_VAULT_ID" \
    "[\\\"--check\\\", \\\"--diff\\\"]"

# --- Zabbix Agent (hosts: zabbix_agents) ---
create_template \
    "Deploy - Zabbix Agent 2" \
    "playbooks/deploy-zabbix-agent.yml" \
    "$INV_FILE_ID" \
    0

create_template \
    "Deploy - Zabbix Agent 2 (Dry Run)" \
    "playbooks/deploy-zabbix-agent.yml" \
    "$INV_FILE_ID" \
    0 \
    "[\\\"--check\\\", \\\"--diff\\\"]"

# --- Cisco Backup (hosts: network) ---
create_template \
    "Backup - Cisco configs" \
    "playbooks/backup-cisco.yml" \
    "$INV_NETWORK_ID" \
    0

create_template \
    "Backup - Cisco configs (no push)" \
    "playbooks/backup-cisco.yml" \
    "$INV_NETWORK_ID" \
    0 \
    "[\\\"--extra-vars\\\", \\\"cisco_backup_git_push=false\\\"]"

echo ""
echo "=============================================="
echo " Setup termine"
echo "=============================================="
echo ""
echo "Projet     : ${PROJECT_NAME} (id=${PROJECT_ID})"
echo "URL        : ${SEMAPHORE_URL}/project/${PROJECT_ID}/templates"
echo ""
echo "Templates crees :"
echo "  - Bootstrap - Server"
echo "  - Bootstrap - Dry Run"
echo "  - Check - Server state"
echo "  - Deploy - Zabbix Agent 2"
echo "  - Deploy - Zabbix Agent 2 (Dry Run)"
echo "  - Backup - Cisco configs"
echo "  - Backup - Cisco configs (no push)"
echo ""
echo "Prochaines etapes :"
echo "  1. Verifier les credentials dans Key Store (SSH key, Cisco, vault)"
echo "  2. Configurer les hosts dans inventory/hosts.yml"
echo "  3. Lancer un template de test"

# Cleanup
rm -f /tmp/semaphore-cookies
