#!/usr/bin/env bash
# ==============================================================================
# setup-semaphore.sh - Provision des projets Semaphore via API
#
# Cree 5 projets avec keys, repository, inventaire, environnement et templates :
#   - Infrastructure       : bootstrap, check serveurs
#   - Portail Securise     : deploy/destroy stack portail
#   - Le Professeur        : deploy app reduction des risques
#   - Monitoring           : Zabbix agent
#   - Network Backup       : sauvegarde configs Cisco
#
# Usage : ./semaphore/setup-semaphore.sh
# ==============================================================================

set -euo pipefail

# --- Couleurs ----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Charger .env ------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}Erreur: ${ENV_FILE} introuvable${NC}"
    echo "Copier .env.example vers .env et configurer les valeurs."
    exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

# --- Variables ---------------------------------------------------------------
SEMAPHORE_URL="http://localhost:${SEMAPHORE_PORT:-3000}"
API="${SEMAPHORE_URL}/api"

# Noms des projets (configurables dans .env)
PROJECT_INFRA="${PROJECT_INFRA:-Infrastructure}"
PROJECT_PORTAL="${PROJECT_PORTAL:-Portail Securise}"
PROJECT_MONITORING="${PROJECT_MONITORING:-Monitoring}"
PROJECT_NETWORK="${PROJECT_NETWORK:-Network Backup}"
PROJECT_PROFESSEUR="${PROJECT_PROFESSEUR:-Le Professeur}"

# Git
GIT_URL="${GIT_REPO_URL:-https://github.com/timox/ansible-toolbox.git}"
GIT_BRANCH="${GIT_BRANCH:-main}"

# Chemins playbooks et inventaire (relatifs a la racine du repo)
PLAYBOOK_DIR="playbooks"
INVENTORY_PATH="inventory/hosts.yml"

# Token API (rempli par authenticate)
TOKEN=""

# --- Fonctions utilitaires ---------------------------------------------------

log_info()  { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_section() { echo -e "\n${BLUE}=== $* ===${NC}" >&2; }

# Appel API generique
api_call() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    local args=(-s -f -X "$method"
        -H "Content-Type: application/json"
        -H "Accept: application/json"
        -H "Authorization: Bearer ${TOKEN}")

    if [ -n "$data" ]; then
        args+=(-d "$data")
    fi

    curl "${args[@]}" "${API}${endpoint}" 2>/dev/null
}

# --- Authentification --------------------------------------------------------

authenticate() {
    log_info "Authentification aupres de Semaphore..."

    local response
    response=$(curl -s -f -X POST \
        -H "Content-Type: application/json" \
        -d "{\"auth\":\"${SEMAPHORE_ADMIN_USER}\",\"password\":\"${SEMAPHORE_ADMIN_PASSWORD}\"}" \
        "${API}/auth/login" 2>/dev/null) || {
        log_error "Impossible de se connecter a Semaphore (${SEMAPHORE_URL})"
        log_error "Verifier que Semaphore est demarre et que les credentials sont corrects."
        exit 1
    }

    # Creer un token API via cookie jar
    local cookie_jar
    cookie_jar=$(mktemp)
    curl -s -f -X POST \
        -H "Content-Type: application/json" \
        -c "$cookie_jar" \
        -d "{\"auth\":\"${SEMAPHORE_ADMIN_USER}\",\"password\":\"${SEMAPHORE_ADMIN_PASSWORD}\"}" \
        "${API}/auth/login" >/dev/null 2>&1

    TOKEN=$(curl -s -f -X POST \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -b "$cookie_jar" \
        "${API}/user/tokens" 2>/dev/null | jq -r '.id // empty') || true

    rm -f "$cookie_jar"

    if [ -z "$TOKEN" ]; then
        log_error "Impossible d'obtenir un token API."
        exit 1
    fi

    log_ok "Authentifie (token: ${TOKEN:0:8}...)"
}

# --- Creation de ressources --------------------------------------------------

# Cherche un projet par nom, retourne l'ID ou vide
find_project() {
    local name="$1"
    api_call GET "/projects" | jq -r ".[] | select(.name==\"${name}\") | .id // empty" 2>/dev/null || true
}

# Cree un projet, retourne l'ID
create_project() {
    local name="$1"
    local existing
    existing=$(find_project "$name")

    if [ -n "$existing" ]; then
        log_warn "Projet '${name}' existe deja (id: ${existing})"
        echo "$existing"
        return
    fi

    local result
    result=$(api_call POST "/projects" "{\"name\":\"${name}\"}")
    local id
    id=$(echo "$result" | jq -r '.id')

    if [ -z "$id" ] || [ "$id" = "null" ]; then
        log_error "Echec creation projet '${name}'"
        exit 1
    fi

    log_ok "Projet '${name}' cree (id: ${id})"
    echo "$id"
}

# Cherche une key par nom dans un projet
find_key() {
    local project_id="$1"
    local name="$2"
    api_call GET "/project/${project_id}/keys" | jq -r ".[] | select(.name==\"${name}\") | .id // empty" 2>/dev/null || true
}

# Cree une key de type "none"
create_key_none() {
    local project_id="$1"
    local name="$2"

    local existing
    existing=$(find_key "$project_id" "$name")
    if [ -n "$existing" ]; then
        log_warn "  Key '${name}' existe deja (id: ${existing})"
        echo "$existing"
        return
    fi

    local result
    result=$(api_call POST "/project/${project_id}/keys" \
        "{\"name\":\"${name}\",\"type\":\"none\",\"project_id\":${project_id}}")
    local id
    id=$(echo "$result" | jq -r '.id')
    log_ok "  Key '${name}' creee (none, id: ${id})"
    echo "$id"
}

# Cree une key de type "login_password"
create_key_login_password() {
    local project_id="$1"
    local name="$2"
    local login="$3"
    local password="$4"

    local existing
    existing=$(find_key "$project_id" "$name")
    if [ -n "$existing" ]; then
        log_warn "  Key '${name}' existe deja (id: ${existing})"
        echo "$existing"
        return
    fi

    local result
    result=$(api_call POST "/project/${project_id}/keys" \
        "{\"name\":\"${name}\",\"type\":\"login_password\",\"project_id\":${project_id},\"login_password\":{\"login\":\"${login}\",\"password\":\"${password}\"}}")
    local id
    id=$(echo "$result" | jq -r '.id')
    log_ok "  Key '${name}' creee (login_password, id: ${id})"
    echo "$id"
}

# Cree une key SSH
create_key_ssh() {
    local project_id="$1"
    local name="$2"
    local login="$3"
    local private_key="$4"

    local existing
    existing=$(find_key "$project_id" "$name")
    if [ -n "$existing" ]; then
        log_warn "  Key '${name}' existe deja (id: ${existing})"
        echo "$existing"
        return
    fi

    # Echapper la cle privee pour JSON (remplacer newlines par \n)
    local escaped_key
    escaped_key=$(echo "$private_key" | jq -Rs '.')

    local result
    result=$(api_call POST "/project/${project_id}/keys" \
        "{\"name\":\"${name}\",\"type\":\"ssh\",\"project_id\":${project_id},\"ssh\":{\"login\":\"${login}\",\"passphrase\":\"\",\"private_key\":${escaped_key}}}")
    local id
    id=$(echo "$result" | jq -r '.id')
    log_ok "  Key '${name}' creee (ssh, id: ${id})"
    echo "$id"
}

# Cherche un repository par nom dans un projet
find_repository() {
    local project_id="$1"
    local name="$2"
    api_call GET "/project/${project_id}/repositories" | jq -r ".[] | select(.name==\"${name}\") | .id // empty" 2>/dev/null || true
}

# Cree un repository
create_repository() {
    local project_id="$1"
    local name="$2"
    local git_url="$3"
    local branch="$4"
    local key_id="$5"

    local existing
    existing=$(find_repository "$project_id" "$name")
    if [ -n "$existing" ]; then
        log_warn "  Repository '${name}' existe deja (id: ${existing})"
        echo "$existing"
        return
    fi

    local result
    result=$(api_call POST "/project/${project_id}/repositories" \
        "{\"name\":\"${name}\",\"project_id\":${project_id},\"git_url\":\"${git_url}\",\"git_branch\":\"${branch}\",\"ssh_key_id\":${key_id}}")
    local id
    id=$(echo "$result" | jq -r '.id')
    log_ok "  Repository '${name}' cree (id: ${id})"
    echo "$id"
}

# Cherche un inventaire par nom dans un projet
find_inventory() {
    local project_id="$1"
    local name="$2"
    api_call GET "/project/${project_id}/inventory" | jq -r ".[] | select(.name==\"${name}\") | .id // empty" 2>/dev/null || true
}

# Cree un inventaire de type "file"
create_inventory() {
    local project_id="$1"
    local name="$2"
    local file_path="$3"
    local ssh_key_id="$4"
    local repo_id="$5"

    local existing
    existing=$(find_inventory "$project_id" "$name")
    if [ -n "$existing" ]; then
        log_warn "  Inventaire '${name}' existe deja (id: ${existing})"
        echo "$existing"
        return
    fi

    local result
    result=$(api_call POST "/project/${project_id}/inventory" \
        "{\"name\":\"${name}\",\"project_id\":${project_id},\"inventory\":\"${file_path}\",\"type\":\"file\",\"ssh_key_id\":${ssh_key_id},\"repository_id\":${repo_id}}")
    local id
    id=$(echo "$result" | jq -r '.id')
    log_ok "  Inventaire '${name}' cree (id: ${id})"
    echo "$id"
}

# Cherche un environnement par nom dans un projet
find_environment() {
    local project_id="$1"
    local name="$2"
    api_call GET "/project/${project_id}/environment" | jq -r ".[] | select(.name==\"${name}\") | .id // empty" 2>/dev/null || true
}

# Cree un environnement
create_environment() {
    local project_id="$1"
    local name="$2"

    local existing
    existing=$(find_environment "$project_id" "$name")
    if [ -n "$existing" ]; then
        log_warn "  Environnement '${name}' existe deja (id: ${existing})"
        echo "$existing"
        return
    fi

    local result
    result=$(api_call POST "/project/${project_id}/environment" \
        "{\"name\":\"${name}\",\"project_id\":${project_id},\"json\":\"{}\",\"env\":\"{}\"}")
    local id
    id=$(echo "$result" | jq -r '.id')
    log_ok "  Environnement '${name}' cree (id: ${id})"
    echo "$id"
}

# Cherche un template par nom dans un projet
find_template() {
    local project_id="$1"
    local name="$2"
    api_call GET "/project/${project_id}/templates" | jq -r ".[] | select(.name==\"${name}\") | .id // empty" 2>/dev/null || true
}

# Cree un template
# Arguments: project_id name playbook inventory_id repo_id env_id [arguments] [survey_json] [vault_key_id] [description]
create_template() {
    local project_id="$1"
    local name="$2"
    local playbook="$3"
    local inventory_id="$4"
    local repo_id="$5"
    local env_id="$6"
    local arguments="${7:-}"
    local survey_json="${8:-}"
    local vault_key_id="${9:-}"
    local description="${10:-}"

    local existing
    existing=$(find_template "$project_id" "$name")
    if [ -n "$existing" ]; then
        log_warn "  Template '${name}' existe deja (id: ${existing})"
        return
    fi

    # Construire le JSON
    local json
    json=$(jq -n \
        --arg name "$name" \
        --arg playbook "$playbook" \
        --arg description "$description" \
        --argjson project_id "$project_id" \
        --argjson inventory_id "$inventory_id" \
        --argjson repo_id "$repo_id" \
        --argjson env_id "$env_id" \
        '{
            project_id: $project_id,
            inventory_id: $inventory_id,
            repository_id: $repo_id,
            environment_id: $env_id,
            name: $name,
            playbook: $playbook,
            description: $description,
            app: "ansible",
            allow_override_args_in_task: true
        }')

    # Ajouter arguments si present
    if [ -n "$arguments" ]; then
        json=$(echo "$json" | jq --arg args "$arguments" '. + {arguments: $args}')
    fi

    # Ajouter survey_vars si present
    if [ -n "$survey_json" ]; then
        json=$(echo "$json" | jq --argjson sv "$survey_json" '. + {survey_vars: $sv}')
    fi

    # Ajouter vaults si vault_key_id present
    if [ -n "$vault_key_id" ]; then
        json=$(echo "$json" | jq --argjson vkid "$vault_key_id" '. + {vaults: [{vault_key_id: $vkid, name: "default", type: "password"}]}')
    fi

    api_call POST "/project/${project_id}/templates" "$json" >/dev/null
    log_ok "  Template '${name}' cree"
}

# ==============================================================================
# Configuration des projets
# ==============================================================================

# --- Projet Infrastructure ---------------------------------------------------
setup_project_infra() {
    local project_name="$PROJECT_INFRA"
    log_section "Projet : ${project_name}"

    local project_id
    project_id=$(create_project "$project_name")

    # Keys
    log_info "Configuration des keys..."
    local key_git key_ssh key_vault
    key_git=$(create_key_none "$project_id" "git-toolbox")

    if [ -n "${SSH_PRIVATE_KEY:-}" ]; then
        key_ssh=$(create_key_ssh "$project_id" "ssh-servers" "${SSH_USER:-ubuntu}" "$SSH_PRIVATE_KEY")
    else
        key_ssh=$(create_key_none "$project_id" "ssh-servers")
        log_warn "  SSH_PRIVATE_KEY non defini, key creee sans cle (a configurer dans l'UI)"
    fi

    if [ -n "${VAULT_PASSWORD:-}" ]; then
        key_vault=$(create_key_login_password "$project_id" "vault-password" "" "$VAULT_PASSWORD")
    else
        key_vault=$(create_key_login_password "$project_id" "vault-password" "" "changeme")
        log_warn "  VAULT_PASSWORD non defini dans .env, utiliser 'changeme' par defaut"
    fi

    # Repository
    log_info "Configuration du repository..."
    local repo_id
    repo_id=$(create_repository "$project_id" "ansible-toolbox" "$GIT_URL" "$GIT_BRANCH" "$key_git")

    # Inventaire
    log_info "Configuration de l'inventaire..."
    local inv_id
    inv_id=$(create_inventory "$project_id" "vps-ovh" "$INVENTORY_PATH" "$key_ssh" "$repo_id")

    # Environnement
    log_info "Configuration de l'environnement..."
    local env_id
    env_id=$(create_environment "$project_id" "lab")

    # Templates
    log_info "Creation des templates..."

    create_template "$project_id" \
        "Bootstrap - Server" \
        "${PLAYBOOK_DIR}/bootstrap.yml" \
        "$inv_id" "$repo_id" "$env_id" \
        "" "" "$key_vault" \
        "Preparation initiale d'un serveur (packages, users, Docker)"

    create_template "$project_id" \
        "Bootstrap - Dry Run" \
        "${PLAYBOOK_DIR}/bootstrap.yml" \
        "$inv_id" "$repo_id" "$env_id" \
        "[\"--check\", \"--diff\"]" "" "$key_vault" \
        "Verification sans modification du bootstrap"

    create_template "$project_id" \
        "Check - Server state" \
        "${PLAYBOOK_DIR}/check.yml" \
        "$inv_id" "$repo_id" "$env_id" \
        "" "" "$key_vault" \
        "Verification de l'etat des serveurs (connectivity, services)"

    create_template "$project_id" \
        "Setup - SSH Key" \
        "${PLAYBOOK_DIR}/setup-ssh-key.yml" \
        "$inv_id" "$repo_id" "$env_id" \
        "" "" "" \
        "Deploie une clef SSH sur serveur vierge (-e ssh_public_key=...)"

    create_template "$project_id" \
        "Setup - Self-Signed Certificate" \
        "${PLAYBOOK_DIR}/setup-selfsigned-cert.yml" \
        "$inv_id" "$repo_id" "$env_id" \
        "" "" "" \
        "Genere un certificat SSL auto-signe (-e domain=xxx -e force=true)"

    create_template "$project_id" \
        "Setup - Wildcard Certificate" \
        "${PLAYBOOK_DIR}/setup-wildcard-cert.yml" \
        "$inv_id" "$repo_id" "$env_id" \
        "" "" "" \
        "Deploie un certificat wildcard (-e cert_local_path=... -e key_local_path=...)"

    create_template "$project_id" \
        "Setup - Let's Encrypt OVH" \
        "${PLAYBOOK_DIR}/setup-letsencrypt-ovh.yml" \
        "$inv_id" "$repo_id" "$env_id" \
        "" "" "" \
        "Wildcard Let's Encrypt via DNS OVH. Etape 1: -e generate_consumer_key=true. Etape 2: -e ovh_consumer_key=xxx"

    create_template "$project_id" \
        "Setup - TBS Certificats" \
        "${PLAYBOOK_DIR}/setup-tbscertbot.yml" \
        "$inv_id" "$repo_id" "$env_id" \
        "" "" "" \
        "Certificat commercial TBS (-e tbs_order_id=... -e tbs_api_login=...)"

    log_ok "Projet '${project_name}' configure (${project_id})"
}

# --- Projet Portail Securise --------------------------------------------------
setup_project_portal() {
    local project_name="$PROJECT_PORTAL"
    log_section "Projet : ${project_name}"

    local project_id
    project_id=$(create_project "$project_name")

    # Keys
    log_info "Configuration des keys..."
    local key_git key_ssh key_vault
    key_git=$(create_key_none "$project_id" "git-toolbox")

    if [ -n "${SSH_PRIVATE_KEY:-}" ]; then
        key_ssh=$(create_key_ssh "$project_id" "ssh-servers" "${SSH_USER:-ubuntu}" "$SSH_PRIVATE_KEY")
    else
        key_ssh=$(create_key_none "$project_id" "ssh-servers")
        log_warn "  SSH_PRIVATE_KEY non defini, key creee sans cle (a configurer dans l'UI)"
    fi

    if [ -n "${VAULT_PASSWORD:-}" ]; then
        key_vault=$(create_key_login_password "$project_id" "vault-password" "" "$VAULT_PASSWORD")
    else
        key_vault=$(create_key_login_password "$project_id" "vault-password" "" "changeme")
        log_warn "  VAULT_PASSWORD non defini dans .env, utiliser 'changeme' par defaut"
    fi

    # Repository
    log_info "Configuration du repository..."
    local repo_id
    repo_id=$(create_repository "$project_id" "ansible-toolbox" "$GIT_URL" "$GIT_BRANCH" "$key_git")

    # Inventaire
    log_info "Configuration de l'inventaire..."
    local inv_id
    inv_id=$(create_inventory "$project_id" "portal-servers" "$INVENTORY_PATH" "$key_ssh" "$repo_id")

    # Environnement
    log_info "Configuration de l'environnement..."
    local env_id
    env_id=$(create_environment "$project_id" "lab")

    # Templates
    log_info "Creation des templates..."

    create_template "$project_id" \
        "Portal - Check Status" \
        "${PLAYBOOK_DIR}/portal-check.yml" \
        "$inv_id" "$repo_id" "$env_id" \
        "" "" "$key_vault" \
        "Verification de l'etat des containers et services portail"

    create_template "$project_id" \
        "Portal - Deploy Stack Complete" \
        "${PLAYBOOK_DIR}/portal-site.yml" \
        "$inv_id" "$repo_id" "$env_id" \
        "" "" "$key_vault" \
        "Deploiement complet de la stack portail securise"

    create_template "$project_id" \
        "Portal - Dry Run" \
        "${PLAYBOOK_DIR}/portal-site.yml" \
        "$inv_id" "$repo_id" "$env_id" \
        "[\"--check\", \"--diff\"]" "" "$key_vault" \
        "Verification sans modification (dry run) de la stack complete"

    create_template "$project_id" \
        "Portal - Deploy Service" \
        "${PLAYBOOK_DIR}/portal-deploy-service.yml" \
        "$inv_id" "$repo_id" "$env_id" \
        "" "" "$key_vault" \
        "Deploiement d'un service (-e service=keycloak)"

    create_template "$project_id" \
        "Portal - Destroy Service" \
        "${PLAYBOOK_DIR}/portal-destroy.yml" \
        "$inv_id" "$repo_id" "$env_id" \
        "" "" "$key_vault" \
        "Destruction d'un service (-e service=xxx -e confirm=true)"

    log_ok "Projet '${project_name}' configure (${project_id})"
}

# --- Projet Monitoring --------------------------------------------------------
setup_project_monitoring() {
    local project_name="$PROJECT_MONITORING"
    log_section "Projet : ${project_name}"

    local project_id
    project_id=$(create_project "$project_name")

    # Keys
    log_info "Configuration des keys..."
    local key_git key_ssh
    key_git=$(create_key_none "$project_id" "git-toolbox")

    if [ -n "${SSH_PRIVATE_KEY:-}" ]; then
        key_ssh=$(create_key_ssh "$project_id" "ssh-servers" "${SSH_USER:-ubuntu}" "$SSH_PRIVATE_KEY")
    else
        key_ssh=$(create_key_none "$project_id" "ssh-servers")
        log_warn "  SSH_PRIVATE_KEY non defini, key creee sans cle (a configurer dans l'UI)"
    fi

    # Repository
    log_info "Configuration du repository..."
    local repo_id
    repo_id=$(create_repository "$project_id" "ansible-toolbox" "$GIT_URL" "$GIT_BRANCH" "$key_git")

    # Inventaire
    log_info "Configuration de l'inventaire..."
    local inv_id
    inv_id=$(create_inventory "$project_id" "zabbix-agents" "$INVENTORY_PATH" "$key_ssh" "$repo_id")

    # Environnement
    log_info "Configuration de l'environnement..."
    local env_id
    env_id=$(create_environment "$project_id" "lab")

    # Templates
    log_info "Creation des templates..."

    create_template "$project_id" \
        "Deploy - Zabbix Agent 2" \
        "${PLAYBOOK_DIR}/deploy-zabbix-agent.yml" \
        "$inv_id" "$repo_id" "$env_id" \
        "" "" "" \
        "Installation et configuration de Zabbix Agent 2"

    create_template "$project_id" \
        "Deploy - Zabbix Agent 2 (Dry Run)" \
        "${PLAYBOOK_DIR}/deploy-zabbix-agent.yml" \
        "$inv_id" "$repo_id" "$env_id" \
        "[\"--check\", \"--diff\"]" "" "" \
        "Verification sans modification du deploiement Zabbix Agent 2"

    log_ok "Projet '${project_name}' configure (${project_id})"
}

# --- Projet Network Backup ---------------------------------------------------
setup_project_network() {
    local project_name="$PROJECT_NETWORK"
    log_section "Projet : ${project_name}"

    local project_id
    project_id=$(create_project "$project_name")

    # Keys
    log_info "Configuration des keys..."
    local key_git key_cisco
    key_git=$(create_key_none "$project_id" "git-toolbox")

    if [ -n "${CISCO_USER:-}" ] && [ -n "${CISCO_PASSWORD:-}" ]; then
        key_cisco=$(create_key_login_password "$project_id" "cisco-credentials" "$CISCO_USER" "$CISCO_PASSWORD")
    else
        key_cisco=$(create_key_login_password "$project_id" "cisco-credentials" "admin" "changeme")
        log_warn "  CISCO_USER/CISCO_PASSWORD non definis, utiliser des valeurs par defaut"
    fi

    # Repository
    log_info "Configuration du repository..."
    local repo_id
    repo_id=$(create_repository "$project_id" "ansible-toolbox" "$GIT_URL" "$GIT_BRANCH" "$key_git")

    # Inventaire
    log_info "Configuration de l'inventaire..."
    local inv_id
    inv_id=$(create_inventory "$project_id" "network-devices" "$INVENTORY_PATH" "$key_cisco" "$repo_id")

    # Environnement
    log_info "Configuration de l'environnement..."
    local env_id
    env_id=$(create_environment "$project_id" "lab")

    # Templates
    log_info "Creation des templates..."

    create_template "$project_id" \
        "Backup - Network configs" \
        "${PLAYBOOK_DIR}/backup-cisco.yml" \
        "$inv_id" "$repo_id" "$env_id" \
        "" "" "" \
        "Sauvegarde des configurations reseau (Cisco) avec push Git"

    create_template "$project_id" \
        "Backup - Network configs (no push)" \
        "${PLAYBOOK_DIR}/backup-cisco.yml" \
        "$inv_id" "$repo_id" "$env_id" \
        "[\"-e\", \"cisco_backup_git_push=false\"]" "" "" \
        "Sauvegarde des configurations reseau sans push Git"

    log_ok "Projet '${project_name}' configure (${project_id})"
}

# --- Projet Le Professeur ----------------------------------------------------
setup_project_professeur() {
    local project_name="$PROJECT_PROFESSEUR"
    log_section "Projet : ${project_name}"

    local project_id
    project_id=$(create_project "$project_name")

    # Keys
    log_info "Configuration des keys..."
    local key_git key_ssh key_vault
    key_git=$(create_key_none "$project_id" "git-toolbox")

    if [ -n "${SSH_PRIVATE_KEY:-}" ]; then
        key_ssh=$(create_key_ssh "$project_id" "ssh-servers" "${SSH_USER:-ubuntu}" "$SSH_PRIVATE_KEY")
    else
        key_ssh=$(create_key_none "$project_id" "ssh-servers")
        log_warn "  SSH_PRIVATE_KEY non defini, key creee sans cle (a configurer dans l'UI)"
    fi

    if [ -n "${VAULT_PASSWORD:-}" ]; then
        key_vault=$(create_key_login_password "$project_id" "vault-password" "" "$VAULT_PASSWORD")
    else
        key_vault=$(create_key_login_password "$project_id" "vault-password" "" "changeme")
        log_warn "  VAULT_PASSWORD non defini dans .env, utiliser 'changeme' par defaut"
    fi

    # Repository
    log_info "Configuration du repository..."
    local repo_id
    repo_id=$(create_repository "$project_id" "ansible-toolbox" "$GIT_URL" "$GIT_BRANCH" "$key_git")

    # Inventaire
    log_info "Configuration de l'inventaire..."
    local inv_id
    inv_id=$(create_inventory "$project_id" "professeur-servers" "$INVENTORY_PATH" "$key_ssh" "$repo_id")

    # Environnement
    log_info "Configuration de l'environnement..."
    local env_id
    env_id=$(create_environment "$project_id" "production")

    # Templates
    log_info "Creation des templates..."

    create_template "$project_id" \
        "Professeur - Bootstrap Server" \
        "${PLAYBOOK_DIR}/professeur.yml" \
        "$inv_id" "$repo_id" "$env_id" \
        "[\"--tags\", \"bootstrap,docker,professeur\"]" "" "$key_vault" \
        "Premiere installation : bootstrap serveur + Docker + deploiement app"

    create_template "$project_id" \
        "Professeur - Deploy" \
        "${PLAYBOOK_DIR}/professeur.yml" \
        "$inv_id" "$repo_id" "$env_id" \
        "" "" "$key_vault" \
        "Deploiement/mise a jour de Le Professeur"

    create_template "$project_id" \
        "Professeur - Dry Run" \
        "${PLAYBOOK_DIR}/professeur.yml" \
        "$inv_id" "$repo_id" "$env_id" \
        "[\"--check\", \"--diff\"]" "" "$key_vault" \
        "Verification sans modification (dry run)"

    log_ok "Projet '${project_name}' configure (${project_id})"
}

# ==============================================================================
# Resume
# ==============================================================================

print_summary() {
    log_section "Resume"

    echo -e "\nProjets crees :" >&2
    echo -e "  ${GREEN}1.${NC} ${PROJECT_INFRA}" >&2
    echo -e "     Templates : Bootstrap, Check, Setup SSH Key, Setup Certs (self-signed/wildcard)" >&2
    echo -e "     Keys      : git-toolbox, ssh-servers, vault-password" >&2
    echo "" >&2
    echo -e "  ${GREEN}2.${NC} ${PROJECT_PORTAL}" >&2
    echo -e "     Templates : Portal - Check Status, Portal - Deploy Stack Complete," >&2
    echo -e "                 Portal - Dry Run, Portal - Deploy Service, Portal - Destroy Service" >&2
    echo -e "     Keys      : git-toolbox, ssh-servers, vault-password" >&2
    echo "" >&2
    echo -e "  ${GREEN}3.${NC} ${PROJECT_MONITORING}" >&2
    echo -e "     Templates : Deploy - Zabbix Agent 2, Deploy - Zabbix Agent 2 (Dry Run)" >&2
    echo -e "     Keys      : git-toolbox, ssh-servers" >&2
    echo "" >&2
    echo -e "  ${GREEN}4.${NC} ${PROJECT_NETWORK}" >&2
    echo -e "     Templates : Backup - Network configs, Backup - Network configs (no push)" >&2
    echo -e "     Keys      : git-toolbox, cisco-credentials" >&2
    echo "" >&2
    echo -e "  ${GREEN}5.${NC} ${PROJECT_PROFESSEUR}" >&2
    echo -e "     Templates : Professeur - Bootstrap Server, Professeur - Deploy, Professeur - Dry Run" >&2
    echo -e "     Keys      : git-toolbox, ssh-servers, vault-password" >&2
    echo "" >&2

    echo -e "Acces Semaphore : ${BLUE}${SEMAPHORE_URL}${NC}" >&2
    echo -e "Utilisateur     : ${SEMAPHORE_ADMIN_USER}" >&2
    echo "" >&2
    echo -e "${YELLOW}Prochaines etapes :${NC}" >&2
    echo "  1. Verifier les credentials dans Key Store (SSH key, vault password)" >&2
    echo "  2. Configurer les hosts dans inventory/hosts.yml" >&2
    echo "  3. Lancer un template de test" >&2
}

# ==============================================================================
# Main
# ==============================================================================

main() {
    echo -e "${BLUE}=============================================${NC}" >&2
    echo -e "${BLUE}  Semaphore - Configuration multi-projets${NC}" >&2
    echo -e "${BLUE}=============================================${NC}" >&2
    echo "" >&2

    # Verifier les prerequis
    if ! command -v jq &>/dev/null; then
        log_error "jq est requis. Installer avec : apt install jq"
        exit 1
    fi

    if ! command -v curl &>/dev/null; then
        log_error "curl est requis."
        exit 1
    fi

    # Verifier que Semaphore est accessible
    if ! curl -sf "${SEMAPHORE_URL}/api/ping" >/dev/null 2>&1; then
        log_error "Semaphore n'est pas accessible sur ${SEMAPHORE_URL}"
        log_error "Demarrer avec : cd semaphore && docker compose up -d"
        exit 1
    fi

    # Authentification
    authenticate

    # Creer les 5 projets
    setup_project_infra
    setup_project_portal
    setup_project_professeur
    setup_project_monitoring
    setup_project_network

    # Resume
    print_summary

    log_ok "Configuration terminee."
}

main "$@"
