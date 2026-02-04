#!/bin/bash
# =============================================================================
# Script de déploiement Portail Sécurisé - Architecture complète
# =============================================================================
# Usage:
#   ./deploy.sh                           # Déploie tous les services activés dans .env
#   ./deploy.sh --service linshare        # Déploie uniquement LinShare
#   ./deploy.sh --service oauth2-proxy guacamole  # Déploie services spécifiques
#   ./deploy.sh --stop linshare           # Arrête LinShare
#   ./deploy.sh --restart nginx-apps      # Redémarre nginx-apps
#   ./deploy.sh --list                    # Liste les services disponibles
#   ./deploy.sh --status                  # Affiche l'état des services
#   ./deploy.sh --logs linshare           # Affiche les logs LinShare
#   ./deploy.sh --help                    # Affiche l'aide
# =============================================================================

set -e

# Couleurs pour output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Déterminer le répertoire du script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# =============================================================================
# DÉFINITION DES SERVICES DISPONIBLES
# =============================================================================
# Format: SERVICE_NAME:PROFILE:COMPOSE_PATH:DESCRIPTION
AVAILABLE_SERVICES=(
    "oauth2-proxy:core:oauth2-proxy/docker-compose.yml:Authentification OIDC + nginx reverse proxy"
    "guacamole:core:guacamole/docker-compose.yml:Bastion RDP/SSH/VNC"
    "credentials-api:core:credentials-api/docker-compose.yml:API gestion credentials"
    "portal-api:core:portal/docker-compose.api.yml:API gestion applications portail"
    "linshare:linshare:linshare/docker-compose.linshare.yml:Partage de fichiers sécurisé"
    "headscale:headscale:headscale/docker-compose.yml:VPN mesh open-source"
    "vaultwarden:vault:vaultwarden/docker-compose.yml:Gestionnaire mots de passe"
    "bookstack:bookstack:bookstack/docker-compose.yml:Wiki / Documentation"
    "keycloak:standalone:keycloak/docker-compose.yml:Identity Provider (autonome)"
)

# =============================================================================
# FONCTIONS UTILITAIRES
# =============================================================================
show_help() {
    echo -e "${BLUE}Usage:${NC} $0 [OPTIONS] [SERVICES...]"
    echo ""
    echo -e "${BLUE}Options:${NC}"
    echo "  --service SERVICE [...]   Déploie uniquement les services spécifiés"
    echo "  --stop SERVICE [...]      Arrête les services spécifiés"
    echo "  --restart SERVICE [...]   Redémarre les services spécifiés"
    echo "  --clean SERVICE [...]     ${YELLOW}Supprime et recrée${NC} les containers (sans volumes)"
    echo "  --destroy SERVICE [...]   ${RED}Supprime${NC} containers + volumes (données!)"
    echo "  --destroy-all             ${RED}Supprime TOUT${NC} le déploiement (confirmation requise)"
    echo "  --prune                   Nettoie les images Docker inutilisées"
    echo "  --info                    Affiche URLs et identifiants (admin)"
    echo "  --logs SERVICE            Affiche les logs d'un service"
    echo "  --list, -l                Liste tous les services disponibles"
    echo "  --status, -s              Affiche l'état de tous les services"
    echo "  --env FILE                Utilise un fichier .env spécifique (multi-serveur)"
    echo "  --force, -f               Force le redéploiement (recreate containers)"
    echo "  --yes, -y                 Mode non-interactif (confirme automatiquement)"
    echo "  --help, -h                Affiche cette aide"
    echo ""
    echo -e "${BLUE}Services disponibles:${NC}"
    for svc in "${AVAILABLE_SERVICES[@]}"; do
        IFS=':' read -r name profile path desc <<< "$svc"
        if [ "$profile" = "core" ]; then
            echo -e "  ${GREEN}$name${NC} (core) - $desc"
        elif [ "$profile" = "standalone" ]; then
            echo -e "  ${YELLOW}$name${NC} (standalone) - $desc"
        else
            echo -e "  $name (profile: $profile) - $desc"
        fi
    done
    echo ""
    echo -e "${BLUE}Exemples:${NC}"
    echo "  $0                          # Déploie tous les services activés"
    echo "  $0 --service linshare       # Déploie uniquement LinShare"
    echo "  $0 --stop linshare          # Arrête LinShare"
    echo "  $0 --restart nginx-apps     # Redémarre nginx"
    echo "  $0 --logs guacamole-web     # Logs de guacamole-web"
}

list_services() {
    echo -e "${BLUE}Services disponibles:${NC}"
    echo ""
    printf "%-20s %-15s %-10s %s\n" "SERVICE" "PROFILE" "ACTIVÉ" "DESCRIPTION"
    printf "%-20s %-15s %-10s %s\n" "-------" "-------" "------" "-----------"
    for svc in "${AVAILABLE_SERVICES[@]}"; do
        IFS=':' read -r name profile path desc <<< "$svc"
        # Vérifier si activé dans .env
        case "$profile" in
            core) enabled="${GREEN}oui${NC}" ;;
            standalone) enabled="${YELLOW}manuel${NC}" ;;
            linshare) [ "${DEPLOY_LINSHARE:-false}" = "true" ] && enabled="${GREEN}oui${NC}" || enabled="non" ;;
            headscale) [ "${DEPLOY_HEADSCALE:-false}" = "true" ] && enabled="${GREEN}oui${NC}" || enabled="non" ;;
            vault) [ "${DEPLOY_VAULTWARDEN:-false}" = "true" ] && enabled="${GREEN}oui${NC}" || enabled="non" ;;
            bookstack) [ "${DEPLOY_BOOKSTACK:-false}" = "true" ] && enabled="${GREEN}oui${NC}" || enabled="non" ;;
            *) enabled="?" ;;
        esac
        printf "%-20s %-15s %-10b %s\n" "$name" "$profile" "$enabled" "$desc"
    done
}

show_status() {
    echo -e "${BLUE}État des services:${NC}"
    echo ""
    docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "(NAME|oauth2|nginx|guacamole|linshare|headscale|vault|bookstack|keycloak|credentials)" || echo "Aucun service trouvé"
}

get_service_profile() {
    local service_name="$1"
    for svc in "${AVAILABLE_SERVICES[@]}"; do
        IFS=':' read -r name profile path desc <<< "$svc"
        if [ "$name" = "$service_name" ]; then
            echo "$profile"
            return 0
        fi
    done
    echo "unknown"
}

get_service_compose() {
    local service_name="$1"
    for svc in "${AVAILABLE_SERVICES[@]}"; do
        IFS=':' read -r name profile path desc <<< "$svc"
        if [ "$name" = "$service_name" ]; then
            echo "$path"
            return 0
        fi
    done
    echo ""
}

# =============================================================================
# GÉNÉRATION SYSTÉMATIQUE DES CONFIGS DEPUIS TEMPLATES
# =============================================================================
# Chaque module peut avoir des fichiers .template qui seront traités par envsubst
# Convention: fichier.ext.template → fichier.ext
#
# process_template() construit automatiquement la liste des variables à
# substituer depuis les clés du .env. Plus besoin de listes manuelles.
# Les variables nginx ($host, $scheme, etc.) ne sont PAS touchées car
# elles n'existent pas dans le .env.
# =============================================================================

# Variable globale : liste des variables envsubst (construite une seule fois)
_ENVSUBST_VARS=""

# Construit la liste des variables d'environnement pour envsubst
# Appelée automatiquement par process_template() au premier appel
build_envsubst_vars() {
    if [ -n "$_ENVSUBST_VARS" ]; then
        return 0  # Déjà construit
    fi
    local env_file="${ENV_FILE:-.env}"
    if [ ! -f "$env_file" ]; then
        echo -e "${RED}✗${NC} .env non trouvé pour build_envsubst_vars" >&2
        return 1
    fi
    # Toutes les clés du .env → $VAR1 $VAR2 ...
    _ENVSUBST_VARS=$(grep -v '^#' "$env_file" | grep -v '^$' | cut -d= -f1 | sed 's/^/$/' | tr '\n' ' ')
    # Variables calculées à l'exécution (pas dans .env mais exportées par deploy.sh)
    _ENVSUBST_VARS="$_ENVSUBST_VARS \$BUILD_DATE \$KEYCLOAK_HOST_BACKEND_URL"
    # Hostnames dérivés de DOMAIN (utilisés dans templates nginx et portal)
    _ENVSUBST_VARS="$_ENVSUBST_VARS \$PORTAL_HOSTNAME \$GUACAMOLE_HOSTNAME \$VAULTWARDEN_HOSTNAME"
    _ENVSUBST_VARS="$_ENVSUBST_VARS \$LINSHARE_HOSTNAME \$LINSHARE_ADMIN_HOSTNAME \$HEADSCALE_HOSTNAME"
    _ENVSUBST_VARS="$_ENVSUBST_VARS \$BOOKSTACK_HOSTNAME \$KEYCLOAK_PROXY_HOSTNAME"
    # Variables oauth2-proxy calculées
    _ENVSUBST_VARS="$_ENVSUBST_VARS \$OAUTH2_PROXY_REDIRECT_URL \$OAUTH2_PROXY_COOKIE_DOMAINS \$OAUTH2_PROXY_COOKIE_SECURE"
}

# Substitue un template vers un fichier destination
# Usage: process_template <source.template> <destination>
process_template() {
    local src="$1"
    local dest="$2"
    if [ ! -f "$src" ]; then
        echo -e "${YELLOW}⚠${NC} Template non trouvé: $src" >&2
        return 1
    fi
    build_envsubst_vars
    envsubst "$_ENVSUBST_VARS" < "$src" > "$dest"
}

# Génère tous les fichiers config depuis les templates d'un répertoire
generate_templates_in_dir() {
    local dir="$1"
    local dest_dir="${2:-$dir}"  # Par défaut, même répertoire

    if [ ! -d "$dir" ]; then
        return 0
    fi

    # Trouver tous les fichiers .template
    find "$dir" -maxdepth 2 -name "*.template" -type f 2>/dev/null | while read template; do
        # Calculer le nom du fichier destination (sans .template)
        local filename=$(basename "$template")
        local destname="${filename%.template}"
        local subdir=$(dirname "$template")
        local dest

        # Si dest_dir différent, ajuster le chemin
        if [ "$dest_dir" != "$dir" ]; then
            dest="${dest_dir}/${destname}"
        else
            dest="${subdir}/${destname}"
        fi

        # Générer avec process_template (liste de variables auto)
        process_template "$template" "$dest"
        echo -e "  ${GREEN}✓${NC} ${destname} généré depuis template"
    done
}

# Génère le truststore Java pour LinShare (import wildcard cert + CA personnalisés)
generate_linshare_truststore() {
    local truststore="${DATA_DIR}/linshare/certs/cacerts"
    mkdir -p "${DATA_DIR}/linshare/certs"
    # Supprimer si c'est un répertoire ou un symlink cassé
    [ -d "$truststore" ] && rm -rf "$truststore"
    [ -L "$truststore" ] && rm -f "$truststore"
    if [ -f "$truststore" ]; then
        return 0  # Déjà généré
    fi
    local wildcard="${DATA_DIR}/certs/wildcard.${DOMAIN}.crt"
    # Copier le truststore Java de base depuis Keycloak
    docker cp keycloak:/etc/pki/ca-trust/extracted/java/cacerts "$truststore" 2>/dev/null || true
    if [ -f "$truststore" ] && [ -f "$wildcard" ]; then
        chmod 666 "$truststore"
        docker run --rm \
            -v "$truststore:/tmp/cacerts" \
            -v "$wildcard:/tmp/wildcard.crt:ro" \
            eclipse-temurin:17-jre-jammy \
            keytool -import -trustcacerts -alias wildcard-poc \
                -file /tmp/wildcard.crt -keystore /tmp/cacerts \
                -storepass changeit -noprompt 2>/dev/null || true
        for ca_file in "${DATA_DIR}/certs/custom-ca"/*.crt "${DATA_DIR}/certs/custom-ca"/*.pem; do
            [ -f "$ca_file" ] || continue
            local alias_name=$(basename "$ca_file" | sed 's/\.[^.]*$//')
            docker run --rm \
                -v "$truststore:/tmp/cacerts" \
                -v "$ca_file:/tmp/ca.crt:ro" \
                eclipse-temurin:17-jre-jammy \
                keytool -import -trustcacerts -alias "$alias_name" \
                    -file /tmp/ca.crt -keystore /tmp/cacerts \
                    -storepass changeit -noprompt 2>/dev/null || true
        done
        chmod 644 "$truststore"
        echo -e "${GREEN}✓${NC} Truststore Java LinShare généré avec certificat wildcard"
    else
        echo -e "${YELLOW}⚠${NC} Truststore LinShare non généré (keycloak ou wildcard manquant)"
    fi
}

# Régénère les configs depuis les templates
regenerate_configs() {
    local service_name="$1"

    # S'assurer que les variables essentielles sont définies
    DATA_DIR="${DATA_DIR:-/data}"
    DOMAIN="${DOMAIN:-example.com}"

    # Variables Keycloak
    export KEYCLOAK_ISSUER="${KEYCLOAK_ISSUER}"
    export KEYCLOAK_HOST="${KEYCLOAK_HOST:-keycloak.${DOMAIN}}"
    export KEYCLOAK_REALM="${KEYCLOAK_REALM:-poc}"
    export KEYCLOAK_URL="${KEYCLOAK_URL:-https://${KEYCLOAK_HOST}}"
    export KEYCLOAK_BACKEND_URL="${KEYCLOAK_BACKEND_URL:-${KEYCLOAK_URL}}"
    export OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-oauth2-proxy}"

    # Groupes Keycloak
    export ADMIN_GROUP="${ADMIN_GROUP:-admin-infra}"
    export ADMIN_APP_GROUP="${ADMIN_APP_GROUP:-admin-app}"
    export USER_GROUP="${USER_GROUP:-utilisateurs}"

    # Hostnames des services
    export PORTAL_HOSTNAME="${PORTAL_HOSTNAME:-portail.${DOMAIN}}"
    export GUACAMOLE_HOSTNAME="${GUACAMOLE_HOSTNAME:-guacamole.${DOMAIN}}"
    export VAULTWARDEN_HOSTNAME="${VAULTWARDEN_HOSTNAME:-vault.${DOMAIN}}"
    export LINSHARE_HOSTNAME="${LINSHARE_HOSTNAME:-linshare.${DOMAIN}}"
    export LINSHARE_ADMIN_HOSTNAME="${LINSHARE_ADMIN_HOSTNAME:-linshare-admin.${DOMAIN}}"
    export HEADSCALE_HOSTNAME="${HEADSCALE_HOSTNAME:-vpn.${DOMAIN}}"
    export BOOKSTACK_HOSTNAME="${BOOKSTACK_HOSTNAME:-wiki.${DOMAIN}}"
    export KEYCLOAK_PROXY_HOSTNAME="${KEYCLOAK_PROXY_HOSTNAME:-keycloak.${DOMAIN}}"

    # Variables oauth2-proxy
    export OAUTH2_PROXY_REDIRECT_URL="${OAUTH2_PROXY_REDIRECT_URL:-https://${PORTAL_HOSTNAME}/oauth2/callback}"
    export OAUTH2_PROXY_COOKIE_DOMAINS="${OAUTH2_PROXY_COOKIE_DOMAINS:-.${DOMAIN}}"
    export OAUTH2_PROXY_COOKIE_SECURE="${OAUTH2_PROXY_COOKIE_SECURE:-true}"

    # Vérifier envsubst
    if ! command -v envsubst &> /dev/null; then
        echo -e "${RED}✗${NC} envsubst non disponible (installer gettext-base)"
        return 1
    fi

    case "$service_name" in
        oauth2-proxy)
            # oauth2-proxy configs
            if [ -f oauth2-proxy/templates/oauth2-proxy.cfg.template ]; then
                process_template oauth2-proxy/templates/oauth2-proxy.cfg.template oauth2-proxy/oauth2-proxy.cfg
                echo -e "${GREEN}✓${NC} oauth2-proxy.cfg régénéré"
            fi
            # Créer répertoire conf.d pour nginx
            mkdir -p oauth2-proxy/nginx/conf.d
            # nginx apps.conf (config principale)
            if [ -f oauth2-proxy/nginx/apps.conf.template ]; then
                process_template oauth2-proxy/nginx/apps.conf.template oauth2-proxy/nginx/conf.d/apps.conf
                echo -e "${GREEN}✓${NC} nginx/conf.d/apps.conf régénéré"
            fi
            # Traiter les templates additionnels (apps distantes)
            for tpl in oauth2-proxy/nginx/*.conf.template; do
                [ -f "$tpl" ] || continue
                [ "$(basename "$tpl")" = "apps.conf.template" ] && continue  # Déjà traité
                # Vérifier les flags DEPLOY_* pour les templates de services optionnels
                local tpl_basename="$(basename "$tpl")"
                case "$tpl_basename" in
                    linshare.conf.template)
                        [ "${DEPLOY_LINSHARE:-false}" != "true" ] && continue
                        ;;
                    headscale.conf.template)
                        [ "${DEPLOY_HEADSCALE:-false}" != "true" ] && continue
                        ;;
                    vaultwarden.conf.template)
                        [ "${DEPLOY_VAULTWARDEN:-false}" != "true" ] && continue
                        ;;
                esac
                local outfile="oauth2-proxy/nginx/conf.d/$(basename "${tpl%.template}")"
                process_template "$tpl" "$outfile"
                echo -e "${GREEN}✓${NC} $(basename "$outfile") régénéré (app distante)"
            done
            # Nettoyage des configs nginx de services désactivés
            [ "${DEPLOY_LINSHARE:-false}" != "true" ] && rm -f oauth2-proxy/nginx/conf.d/linshare.conf
            [ "${DEPLOY_HEADSCALE:-false}" != "true" ] && rm -f oauth2-proxy/nginx/conf.d/headscale.conf
            [ "${DEPLOY_VAULTWARDEN:-false}" != "true" ] && rm -f oauth2-proxy/nginx/conf.d/vaultwarden.conf
            # portal config.json
            if [ -f portal/www/config.json.template ]; then
                export BUILD_DATE=$(date '+%Y-%m-%d %H:%M')
                export PORTAL_ADMIN_GROUP="${PORTAL_ADMIN_GROUP:-admin}"
                export VAULTWARDEN_ENABLED="${VAULTWARDEN_ENABLED:-false}"
                process_template portal/www/config.json.template portal/www/config.json
                echo -e "${GREEN}✓${NC} portal/config.json régénéré"
            fi
            ;;
        guacamole)
            # guacamole.properties
            if [ -f guacamole/guacamole.properties.template ]; then
                export GUACAMOLE_OIDC_CLIENT_ID="${GUACAMOLE_OIDC_CLIENT_ID:-guacamole}"
                mkdir -p ${DATA_DIR}/guacamole
                process_template guacamole/guacamole.properties.template ${DATA_DIR}/guacamole/guacamole.properties
                echo -e "${GREEN}✓${NC} guacamole.properties régénéré"
            fi
            ;;
        linshare)
            # LinShare backend properties (OIDC config)
            if [ -f linshare/config/linshare.properties.template ]; then
                mkdir -p ${DATA_DIR}/linshare/config
                export LINSHARE_OIDC_CLIENT_ID="${LINSHARE_OIDC_CLIENT_ID:-linshare}"

                process_template linshare/config/linshare.properties.template ${DATA_DIR}/linshare/config/linshare.properties
                chmod 600 ${DATA_DIR}/linshare/config/linshare.properties
                echo -e "${GREEN}✓${NC} linshare.properties régénéré dans ${DATA_DIR}/linshare/config/"
            fi
            # Copier linshare-extra.properties
            if [ -f linshare/config/linshare-extra.properties ]; then
                cp linshare/config/linshare-extra.properties ${DATA_DIR}/linshare/config/
            fi
            # Générer config.js (UI user) depuis template
            if [ -f linshare/config/config.js.template ]; then
                process_template linshare/config/config.js.template ${DATA_DIR}/linshare/config/config.js
                echo -e "${GREEN}✓${NC} config.js (UI user) régénéré"
            fi
            # Générer config-admin.js (UI admin) depuis template
            if [ -f linshare/config/config-admin.js.template ]; then
                process_template linshare/config/config-admin.js.template ${DATA_DIR}/linshare/config/config-admin.js
                echo -e "${GREEN}✓${NC} config-admin.js (UI admin) régénéré"
            fi
            # Régénérer nginx pour les routes LinShare
            if [ -f oauth2-proxy/nginx/apps.conf.template ]; then
                mkdir -p oauth2-proxy/nginx/conf.d
                process_template oauth2-proxy/nginx/apps.conf.template oauth2-proxy/nginx/conf.d/apps.conf
                echo -e "${GREEN}✓${NC} nginx/conf.d/apps.conf régénéré"
            fi
            # Truststore Java (wildcard cert pour OIDC HTTPS)
            generate_linshare_truststore
            # Redémarrer nginx si en cours d'exécution
            if docker ps --format '{{.Names}}' | grep -q "^nginx-apps$"; then
                docker restart nginx-apps > /dev/null 2>&1
                echo -e "${GREEN}✓${NC} nginx-apps redémarré"
            fi
            ;;
        headscale)
            # Headscale config.yaml et acls.yaml
            generate_templates_in_dir "headscale"
            # Régénérer nginx
            if [ -f oauth2-proxy/nginx/apps.conf.template ]; then
                mkdir -p oauth2-proxy/nginx/conf.d
                process_template oauth2-proxy/nginx/apps.conf.template oauth2-proxy/nginx/conf.d/apps.conf
                echo -e "${GREEN}✓${NC} nginx/conf.d/apps.conf régénéré"
            fi
            if docker ps --format '{{.Names}}' | grep -q "^nginx-apps$"; then
                docker restart nginx-apps > /dev/null 2>&1
                echo -e "${GREEN}✓${NC} nginx-apps redémarré"
            fi
            ;;
        vaultwarden)
            # Vaultwarden gère les env vars nativement, juste nginx
            if [ -f oauth2-proxy/nginx/apps.conf.template ]; then
                mkdir -p oauth2-proxy/nginx/conf.d
                process_template oauth2-proxy/nginx/apps.conf.template oauth2-proxy/nginx/conf.d/apps.conf
                echo -e "${GREEN}✓${NC} nginx/conf.d/apps.conf régénéré"
            fi
            if docker ps --format '{{.Names}}' | grep -q "^nginx-apps$"; then
                docker restart nginx-apps > /dev/null 2>&1
                echo -e "${GREEN}✓${NC} nginx-apps redémarré"
            fi
            ;;
        *)
            # Pour tout autre service, chercher des templates dans son répertoire
            local svc_dir=$(find . -maxdepth 1 -type d -name "$service_name" 2>/dev/null | head -1)
            if [ -n "$svc_dir" ]; then
                generate_templates_in_dir "$svc_dir"
            fi
            ;;
    esac
}

# Crée les réseaux Docker nécessaires s'ils n'existent pas
# Liste centralisée - modifier ici ET dans show_info() si ajout/suppression
ensure_networks() {
    local networks="auth-net portal-net guacamole-net prod_apps-net linshare_linshare-net keycloak-net"
    for network in $networks; do
        if ! docker network ls --format '{{.Name}}' | grep -q "^${network}$"; then
            echo "   - Création du réseau ${network}"
            docker network create --driver bridge "${network}" 2>/dev/null || true
        fi
    done
}

deploy_service() {
    local service_name="$1"
    local force="${2:-false}"
    local profile=$(get_service_profile "$service_name")
    local compose_path=$(get_service_compose "$service_name")

    # S'assurer que les réseaux existent
    ensure_networks

    if [ -z "$compose_path" ]; then
        echo -e "${RED}✗${NC} Service inconnu: $service_name"
        return 1
    fi

    # Régénérer les configs depuis les templates
    regenerate_configs "$service_name"

    echo -e "${BLUE}Déploiement de ${service_name}...${NC}"

    # Construire la commande
    local cmd="docker compose"
    if [ "$profile" = "standalone" ]; then
        # Service standalone - utiliser son propre compose
        cmd="docker compose -f $compose_path --env-file .env"
    elif [ "$profile" != "core" ]; then
        # Service avec profile
        cmd="docker compose --profile $profile"
    fi

    # Ajouter --force-recreate si demandé
    if [ "$force" = "true" ]; then
        $cmd up -d --force-recreate
    else
        $cmd up -d
    fi

    echo -e "${GREEN}✓${NC} $service_name déployé"
}

stop_service() {
    local service_name="$1"
    local profile=$(get_service_profile "$service_name")
    local compose_path=$(get_service_compose "$service_name")

    echo -e "${BLUE}Arrêt de ${service_name}...${NC}"

    if [ "$profile" = "standalone" ]; then
        docker compose -f "$compose_path" --env-file .env down
    else
        # Arrêter les containers du service
        docker ps -a --format '{{.Names}}' | grep -E "^${service_name}" | xargs -r docker stop
    fi

    echo -e "${GREEN}✓${NC} $service_name arrêté"
}

restart_service() {
    local container_name="$1"
    echo -e "${BLUE}Redémarrage de ${container_name}...${NC}"
    docker restart "$container_name"
    echo -e "${GREEN}✓${NC} $container_name redémarré"
}

show_logs() {
    local service_name="$1"
    echo -e "${BLUE}Logs de ${service_name}:${NC}"
    docker logs "$service_name" --tail 100 -f
}

destroy_service() {
    local service_name="$1"
    local profile=$(get_service_profile "$service_name")
    local compose_path=$(get_service_compose "$service_name")

    echo -e "${RED}ATTENTION: Destruction de ${service_name}${NC}"
    echo "Cette action va supprimer:"
    echo "  - Tous les containers associés"
    echo "  - Tous les volumes Docker"
    echo "  - Les données seront PERDUES"
    echo ""
    read -p "Confirmer la destruction de ${service_name}? (tapez 'yes'): " confirm
    if [ "$confirm" != "yes" ]; then
        echo "Annulé"
        return 0
    fi

    echo -e "${BLUE}Suppression de ${service_name}...${NC}"

    if [ "$profile" = "standalone" ] && [ -n "$compose_path" ] && [ -f "$compose_path" ]; then
        # Service standalone avec son propre docker-compose
        docker compose -f "$compose_path" --env-file .env down -v
    elif [ -n "$compose_path" ] && [ -f "$compose_path" ]; then
        # Service avec docker-compose dédié (linshare, headscale, etc.)
        docker compose -f "$compose_path" --env-file .env down -v
    elif [ "$profile" != "core" ]; then
        # Service avec profile dans le compose principal - arrêter uniquement les containers du service
        docker ps -a --format '{{.Names}}' | grep -iE "^${service_name}" | xargs -r docker stop 2>/dev/null
        docker ps -a --format '{{.Names}}' | grep -iE "^${service_name}" | xargs -r docker rm -f 2>/dev/null
        docker volume ls --format '{{.Name}}' | grep -iE "${service_name}" | xargs -r docker volume rm 2>/dev/null
    else
        # Service core - arrêter les containers spécifiques
        docker ps -a --format '{{.Names}}' | grep -E "^${service_name}" | xargs -r docker rm -f
        # Supprimer les volumes associés
        docker volume ls --format '{{.Name}}' | grep -E "${service_name}" | xargs -r docker volume rm
    fi

    echo -e "${GREEN}✓${NC} $service_name détruit"
}

destroy_all() {
    echo -e "${RED}============================================${NC}"
    echo -e "${RED}  DESTRUCTION COMPLÈTE DU DÉPLOIEMENT${NC}"
    echo -e "${RED}============================================${NC}"
    echo ""
    echo "Cette action va SUPPRIMER:"
    echo "  - Tous les containers du portail"
    echo "  - Tous les volumes Docker"
    echo "  - Tous les réseaux Docker créés"
    echo ""
    echo -e "${RED}LES DONNÉES SERONT PERDUES!${NC}"
    echo ""
    echo "Containers concernés:"
    docker ps -a --format '{{.Names}}' | grep -E "(oauth2|nginx-apps|guacamole|linshare|headscale|vault|bookstack|credentials)" | head -20 || echo "  (aucun)"
    echo ""

    if [ "$YES_MODE" = true ]; then
        echo -e "${YELLOW}Mode --yes: confirmation automatique${NC}"
    else
        read -p "Tapez 'DESTROY' pour confirmer: " confirm
        if [ "$confirm" != "DESTROY" ]; then
            echo "Annulé"
            return 0
        fi
    fi

    echo ""
    echo -e "${BLUE}Suppression des services...${NC}"

    # Arrêter tous les services
    docker compose down -v --remove-orphans 2>/dev/null || true

    # Supprimer les containers orphelins
    echo "Suppression des containers orphelins..."
    docker ps -a --format '{{.Names}}' | grep -E "(oauth2|nginx-apps|guacamole|linshare|headscale|vault|bookstack|credentials|portal)" | xargs -r docker rm -f 2>/dev/null || true

    # Supprimer les volumes
    echo "Suppression des volumes..."
    docker volume ls --format '{{.Name}}' | grep -E "(oauth2|guacamole|linshare|headscale|vault|bookstack|credentials|portal|redis)" | xargs -r docker volume rm 2>/dev/null || true

    # Invalider HEADSCALE_API_KEY dans .env (la clé est liée à la DB headscale)
    if [ -f "$ENV_FILE" ]; then
        sed -i 's/^HEADSCALE_API_KEY=.*/HEADSCALE_API_KEY=/' "$ENV_FILE" 2>/dev/null || true
    fi

    # Supprimer les réseaux
    echo "Suppression des réseaux..."
    for network in auth-net portal-net guacamole-net prod_apps-net linshare_linshare-net keycloak-net headscale-net headscale_headscale-net bookstack-net; do
        docker network rm "$network" 2>/dev/null || true
    done

    # Supprimer les images buildées localement (optionnel)
    echo "Suppression des images locales..."
    docker images --format '{{.Repository}}:{{.Tag}}' | grep -E "^(guacamole|prod-|portal-)" | xargs -r docker rmi 2>/dev/null || true

    echo ""
    echo -e "${GREEN}✓${NC} Déploiement complètement supprimé"
    echo ""
    echo -e "${YELLOW}Note:${NC} Les données dans ${DATA_DIR:-/data} n'ont PAS été supprimées."
    echo "Pour supprimer les données:"
    echo "  rm -rf ${DATA_DIR:-/data}/guacamole ${DATA_DIR:-/data}/linshare ${DATA_DIR:-/data}/headscale"
}

# Nettoie et recrée un service (supprime container sans supprimer volumes)
clean_service() {
    local service_name="$1"
    echo -e "${BLUE}Nettoyage de ${service_name}...${NC}"

    # Trouver le compose file et le service
    local compose_path=""
    local service_type=""
    for svc in "${AVAILABLE_SERVICES[@]}"; do
        IFS=':' read -r name profile path desc <<< "$svc"
        if [ "$name" = "$service_name" ]; then
            compose_path="$path"
            service_type="$profile"
            break
        fi
    done

    if [ -n "$compose_path" ]; then
        # Arrêter et supprimer le container (sans volumes)
        docker compose --env-file "$ENV_FILE" -f "$compose_path" rm -sf "$service_name" 2>/dev/null || true
    fi

    # Supprimer aussi par nom de container si pas dans compose
    if docker ps -a --format '{{.Names}}' | grep -q "^${service_name}$"; then
        docker rm -f "$service_name" 2>/dev/null || true
    fi

    echo -e "${GREEN}✓${NC} $service_name nettoyé"

    # Redéployer
    deploy_service "$service_name"
}

# Nettoie les images Docker inutilisées
prune_images() {
    echo -e "${BLUE}Nettoyage des images Docker inutilisées...${NC}"

    # Images dangling (sans tag)
    echo "  - Suppression des images sans tag (<none>)..."
    docker images -f "dangling=true" -q | xargs -r docker rmi 2>/dev/null || true

    # Images anciennes de nos builds
    echo "  - Recherche d'anciennes versions de guacamole-daemon..."
    local old_daemon=$(docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | grep "guacamole-daemon" | tail -n +2 | awk '{print $2}')
    if [ -n "$old_daemon" ]; then
        echo "$old_daemon" | xargs -r docker rmi 2>/dev/null || true
        echo -e "    ${GREEN}✓${NC} Anciennes images guacamole-daemon supprimées"
    fi

    echo "  - Recherche d'anciennes versions de guacamole-web..."
    local old_web=$(docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | grep "guacamole-web" | tail -n +2 | awk '{print $2}')
    if [ -n "$old_web" ]; then
        echo "$old_web" | xargs -r docker rmi 2>/dev/null || true
        echo -e "    ${GREEN}✓${NC} Anciennes images guacamole-web supprimées"
    fi

    # Espace disque récupéré
    echo ""
    echo "  - Exécution de docker system prune (containers arrêtés, réseaux inutilisés)..."
    docker system prune -f 2>/dev/null || true

    echo ""
    echo -e "${GREEN}✓${NC} Nettoyage terminé"
    echo ""
    echo "Espace disque Docker:"
    docker system df
}

# Vérifie que Keycloak est accessible (prérequis pour oauth2-proxy)
# Utilise KEYCLOAK_HOST_BACKEND_URL pour les checks depuis l'hôte
check_keycloak() {
    local issuer="${KEYCLOAK_ISSUER:-}"
    local realm="${KEYCLOAK_REALM:-poc}"
    local host_url="${KEYCLOAK_HOST_BACKEND_URL:-http://localhost:${KEYCLOAK_HTTP_PORT:-8080}}"

    if [ -z "$issuer" ]; then
        echo -e "${YELLOW}⚠${NC} KEYCLOAK_ISSUER non défini dans .env"
        return 1
    fi

    local health_url="${host_url}/realms/${realm}/.well-known/openid-configuration"

    echo -e "${BLUE}Vérification de Keycloak...${NC}"
    echo "  Health check: $health_url"
    echo "  Issuer public: $issuer"

    # Tenter de joindre Keycloak (timeout 5s, -k pour certificats auto-signés)
    if curl -skf --connect-timeout 5 "$health_url" > /dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} Keycloak accessible"
        return 0
    else
        echo -e "  ${RED}✗${NC} Keycloak non accessible"
        echo ""
        echo -e "${YELLOW}Vérifiez que Keycloak est démarré et accessible.${NC}"
        echo "Pour un Keycloak local:"
        echo "  ./deploy.sh --service keycloak"
        echo ""
        return 1
    fi
}

# Attend que Keycloak soit prêt (avec retry)
# Utilise KEYCLOAK_HOST_BACKEND_URL pour les checks depuis l'hôte
wait_for_keycloak() {
    local max_attempts="${1:-30}"
    local attempt=1
    local host_url="${KEYCLOAK_HOST_BACKEND_URL:-http://localhost:${KEYCLOAK_HTTP_PORT:-8080}}"

    # Vérifier sur le realm master (toujours présent, même sur installation fraîche)
    local health_url="${host_url}/realms/master"

    echo -e "${BLUE}Attente de Keycloak...${NC}"

    while [ $attempt -le $max_attempts ]; do
        if curl -skf --connect-timeout 2 "$health_url" > /dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} Keycloak prêt (après ${attempt}s)"
            return 0
        fi
        echo -n "."
        sleep 1
        ((attempt++))
    done

    echo ""
    echo -e "  ${RED}✗${NC} Keycloak non disponible après ${max_attempts}s"
    return 1
}

# Affiche les URLs et identifiants configurés (admin only)
show_info() {
    # Charger .env
    if [ -f "$ENV_FILE" ]; then
        export $(grep -v '^#' "$ENV_FILE" | xargs)
    fi

    local server_ip="${POC_IP:-$(hostname -I | awk '{print $1}')}"

    echo -e "${BLUE}============================================================${NC}"
    echo -e "${BLUE}  INFORMATIONS DE CONFIGURATION${NC}"
    echo -e "${BLUE}============================================================${NC}"
    echo ""
    echo -e "${BLUE}Domaine:${NC} ${DOMAIN:-non configuré}"
    echo -e "${BLUE}Serveur IP:${NC} ${server_ip}"
    echo -e "${BLUE}DATA_DIR:${NC} ${DATA_DIR:-/data}"
    echo ""
    echo -e "${BLUE}┌─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BLUE}│ URLS D'ACCÈS                                                │${NC}"
    echo -e "${BLUE}├─────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${BLUE}│${NC} Portail SSO     : https://portail.${DOMAIN:-example.com}                  ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC} Portail HTTP    : http://${server_ip}:80                          ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC} Guacamole       : https://guacamole.${DOMAIN:-example.com}                ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC} Guacamole HTTP  : http://${server_ip}:8081/guacamole              ${BLUE}│${NC}"
    if [ "${DEPLOY_LINSHARE:-false}" = "true" ]; then
    echo -e "${BLUE}│${NC} LinShare        : https://linshare.${DOMAIN:-example.com}                 ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC} LinShare HTTP   : http://${server_ip}:8082                        ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC} LinShare Admin  : http://${server_ip}:8083                        ${BLUE}│${NC}"
    fi
    if [ "${DEPLOY_HEADSCALE:-false}" = "true" ]; then
    echo -e "${BLUE}│${NC} Headscale       : https://vpn.${DOMAIN:-example.com}                      ${BLUE}│${NC}"
    fi
    if [ "${DEPLOY_BOOKSTACK:-false}" = "true" ]; then
    echo -e "${BLUE}│${NC} BookStack       : https://wiki.${DOMAIN:-example.com}                     ${BLUE}│${NC}"
    fi
    if [ "${DEPLOY_VAULTWARDEN:-false}" = "true" ]; then
    echo -e "${BLUE}│${NC} Vaultwarden     : https://vault.${DOMAIN:-example.com}                    ${BLUE}│${NC}"
    fi
    echo -e "${BLUE}└─────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${BLUE}┌─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BLUE}│ KEYCLOAK (Identity Provider)                                │${NC}"
    echo -e "${BLUE}├─────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${BLUE}│${NC} Admin URL       : ${KEYCLOAK_URL:-http://localhost:8080}/admin          ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC} Issuer URL      : ${KEYCLOAK_ISSUER:-non configuré}      ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC} Realm           : ${KEYCLOAK_REALM:-poc}                                  ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC} Admin User      : ${KEYCLOAK_ADMIN:-admin}                                ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC} Admin Password  : ${KEYCLOAK_ADMIN_PASSWORD:-***}                         ${BLUE}│${NC}"
    echo -e "${BLUE}└─────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${BLUE}┌─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BLUE}│ IDENTIFIANTS POC (à créer dans Keycloak)                    │${NC}"
    echo -e "${BLUE}├─────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${BLUE}│${NC} admin-infra / ${POC_ADMIN_INFRA_PASSWORD:-poc-admin-123}     → groupe: admin-infra      ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC} admin-std / ${POC_ADMIN_STD_PASSWORD:-poc-std-123}           → groupe: admin-standard   ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC} user-test / ${POC_USER_TEST_PASSWORD:-poc-user-123}          → groupe: utilisateurs     ${BLUE}│${NC}"
    echo -e "${BLUE}└─────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${BLUE}┌─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BLUE}│ CLIENTS OIDC (à créer dans Keycloak)                        │${NC}"
    echo -e "${BLUE}├─────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${BLUE}│${NC} oauth2-proxy    : ${OIDC_CLIENT_ID:-oauth2-proxy} (confidential)        ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC} guacamole       : ${GUACAMOLE_OIDC_CLIENT_ID:-guacamole} (public)       ${BLUE}│${NC}"
    if [ "${DEPLOY_LINSHARE:-false}" = "true" ]; then
    echo -e "${BLUE}│${NC} linshare        : ${LINSHARE_OIDC_CLIENT_ID:-linshare} (confidential)   ${BLUE}│${NC}"
    fi
    if [ "${DEPLOY_HEADSCALE:-false}" = "true" ]; then
    echo -e "${BLUE}│${NC} headscale       : headscale (confidential)                  ${BLUE}│${NC}"
    fi
    echo -e "${BLUE}└─────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${BLUE}┌─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BLUE}│ POST LOGOUT REDIRECT URIs (configurées dans Keycloak)       │${NC}"
    echo -e "${BLUE}├─────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${BLUE}│${NC} oauth2-proxy : https://portail.${DOMAIN}/oauth2/sign_in       ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC} guacamole    : https://guacamole.${DOMAIN}/                   ${BLUE}│${NC}"
    if [ "${DEPLOY_LINSHARE:-false}" = "true" ]; then
    echo -e "${BLUE}│${NC} linshare     : https://linshare.${DOMAIN}/                    ${BLUE}│${NC}"
    fi
    if [ "${DEPLOY_VAULTWARDEN:-false}" = "true" ]; then
    echo -e "${BLUE}│${NC} vaultwarden  : https://vault.${DOMAIN}/                       ${BLUE}│${NC}"
    fi
    echo -e "${BLUE}└─────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${BLUE}┌─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BLUE}│ SECRETS (depuis .env)                                       │${NC}"
    echo -e "${BLUE}├─────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${BLUE}│${NC} OIDC_CLIENT_SECRET   : ${OIDC_CLIENT_SECRET:0:8}...                      ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC} COOKIE_SECRET        : ${COOKIE_SECRET:0:8}...                          ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC} GUACAMOLE_DB_PASS    : ${GUACAMOLE_DB_PASSWORD:0:8}...                   ${BLUE}│${NC}"
    if [ -n "$LINSHARE_DB_PASSWORD" ]; then
    echo -e "${BLUE}│${NC} LINSHARE_DB_PASS     : ${LINSHARE_DB_PASSWORD:0:8}...                    ${BLUE}│${NC}"
    fi
    echo -e "${BLUE}└─────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${BLUE}┌─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BLUE}│ RÉSEAUX DOCKER                                              │${NC}"
    echo -e "${BLUE}├─────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${BLUE}│${NC} Nom réseau              │ Usage                            ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC} ────────────────────────┼────────────────────────────────  ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC} auth-net                │ oauth2-proxy, redis, nginx-apps  ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC} portal-net              │ credentials-api, vaultwarden     ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC} guacamole-net           │ guacamole-web, guacamole-db      ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC} prod_apps-net           │ nginx-apps ↔ services backend    ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC} linshare_linshare-net   │ linshare-* (si activé)           ${BLUE}│${NC}"
    echo -e "${BLUE}│${NC} keycloak-net            │ keycloak, keycloak-db            ${BLUE}│${NC}"
    echo -e "${BLUE}└─────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    # Afficher l'état réel des réseaux
    echo -e "${BLUE}État actuel des réseaux:${NC}"
    for net in auth-net portal-net guacamole-net prod_apps-net linshare_linshare-net keycloak-net; do
        if docker network ls --format '{{.Name}}' | grep -q "^${net}$"; then
            local containers=$(docker network inspect "$net" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | xargs)
            if [ -n "$containers" ]; then
                echo -e "  ${GREEN}✓${NC} $net : $containers"
            else
                echo -e "  ${YELLOW}○${NC} $net : (aucun container)"
            fi
        else
            echo -e "  ${RED}✗${NC} $net : non créé"
        fi
    done
    echo ""
    echo -e "${YELLOW}Note: Ces informations sont sensibles. Ne pas partager.${NC}"
}

# =============================================================================
# PARSING DES ARGUMENTS
# =============================================================================
ACTION="deploy_all"
SERVICES=()
FORCE=false
YES_MODE=false  # Mode non-interactif (--yes ou -y)
ENV_FILE=".env"  # Défaut, peut être changé avec --env

# Fonction pour les confirmations (respecte --yes et détecte mode non-interactif)
confirm_action() {
    local prompt="${1:-Continuer?}"
    local default="${2:-n}"  # n = Non par défaut, y = Oui par défaut

    # Mode --yes : toujours oui
    if [ "$YES_MODE" = "true" ]; then
        return 0
    fi

    # Mode non-interactif (stdin n'est pas un terminal) : utiliser défaut
    if [ ! -t 0 ]; then
        if [ "$default" = "y" ]; then
            return 0
        else
            echo -e "${YELLOW}Mode non-interactif détecté, utiliser --yes pour confirmer automatiquement${NC}"
            return 1
        fi
    fi

    # Mode interactif : demander
    read -p "$prompt (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            show_help
            exit 0
            ;;
        --list|-l)
            # Charger .env pour vérifier les activations
            if [ -f .env ]; then
                export $(grep -v '^#' "$ENV_FILE" | xargs)
            fi
            list_services
            exit 0
            ;;
        --status|-s)
            show_status
            exit 0
            ;;
        --service)
            ACTION="deploy_services"
            shift
            while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
                SERVICES+=("$1")
                shift
            done
            ;;
        --stop)
            ACTION="stop_services"
            shift
            while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
                SERVICES+=("$1")
                shift
            done
            ;;
        --restart)
            ACTION="restart_services"
            shift
            while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
                SERVICES+=("$1")
                shift
            done
            ;;
        --clean)
            ACTION="clean_services"
            shift
            while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
                SERVICES+=("$1")
                shift
            done
            ;;
        --prune)
            ACTION="prune_images"
            shift
            ;;
        --info)
            ACTION="show_info"
            shift
            ;;
        --logs)
            ACTION="show_logs"
            shift
            if [[ $# -gt 0 ]]; then
                SERVICES+=("$1")
                shift
            fi
            ;;
        --destroy)
            ACTION="destroy_services"
            shift
            while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
                SERVICES+=("$1")
                shift
            done
            ;;
        --destroy-all)
            ACTION="destroy_all"
            shift
            ;;
        --force|-f)
            FORCE=true
            shift
            ;;
        --yes|-y)
            YES_MODE=true
            shift
            ;;
        --env)
            # Utiliser un fichier .env spécifique (pour multi-serveur)
            shift
            if [[ $# -gt 0 ]]; then
                ENV_FILE="$1"
                shift
            fi
            ;;
        *)
            echo -e "${RED}Option inconnue: $1${NC}"
            show_help
            exit 1
            ;;
    esac
done

# Vérifier que le fichier .env existe
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}Fichier .env non trouvé: $ENV_FILE${NC}"
    exit 1
fi

# =============================================================================
# EXÉCUTION DES ACTIONS SPÉCIFIQUES
# =============================================================================
case "$ACTION" in
    deploy_services)
        if [ ${#SERVICES[@]} -eq 0 ]; then
            echo -e "${RED}Aucun service spécifié${NC}"
            exit 1
        fi
        # Charger .env
        if [ -f .env ]; then
            export $(grep -v '^#' "$ENV_FILE" | xargs)
        fi
        for svc in "${SERVICES[@]}"; do
            deploy_service "$svc" "$FORCE"
        done
        exit 0
        ;;
    stop_services)
        if [ ${#SERVICES[@]} -eq 0 ]; then
            echo -e "${RED}Aucun service spécifié${NC}"
            exit 1
        fi
        # Charger .env
        if [ -f .env ]; then
            export $(grep -v '^#' "$ENV_FILE" | xargs)
        fi
        for svc in "${SERVICES[@]}"; do
            stop_service "$svc"
        done
        exit 0
        ;;
    restart_services)
        if [ ${#SERVICES[@]} -eq 0 ]; then
            echo -e "${RED}Aucun container spécifié${NC}"
            exit 1
        fi
        for svc in "${SERVICES[@]}"; do
            restart_service "$svc"
        done
        exit 0
        ;;
    show_logs)
        if [ ${#SERVICES[@]} -eq 0 ]; then
            echo -e "${RED}Aucun service spécifié${NC}"
            exit 1
        fi
        show_logs "${SERVICES[0]}"
        exit 0
        ;;
    destroy_services)
        if [ ${#SERVICES[@]} -eq 0 ]; then
            echo -e "${RED}Aucun service spécifié${NC}"
            exit 1
        fi
        # Charger .env
        if [ -f .env ]; then
            export $(grep -v '^#' "$ENV_FILE" | xargs)
        fi
        for svc in "${SERVICES[@]}"; do
            destroy_service "$svc"
        done
        exit 0
        ;;
    destroy_all)
        # Charger .env
        if [ -f .env ]; then
            export $(grep -v '^#' "$ENV_FILE" | xargs)
        fi
        destroy_all
        exit 0
        ;;
    clean_services)
        if [ ${#SERVICES[@]} -eq 0 ]; then
            echo -e "${RED}Aucun service spécifié${NC}"
            echo "Usage: $0 --clean SERVICE [SERVICE...]"
            exit 1
        fi
        # Charger .env
        if [ -f .env ]; then
            export $(grep -v '^#' "$ENV_FILE" | xargs)
        fi
        for svc in "${SERVICES[@]}"; do
            clean_service "$svc"
        done
        exit 0
        ;;
    prune_images)
        prune_images
        exit 0
        ;;
    show_info)
        show_info
        exit 0
        ;;
esac

# =============================================================================
# DÉPLOIEMENT COMPLET (action par défaut)
# =============================================================================
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Portail Sécurisé - Déploiement${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Afficher information architecture
echo -e "${YELLOW}Note:${NC} Architecture oauth2-proxy + nginx + Guacamole (v2.0)"
echo ""

# 1. Charger variables d'environnement
echo -e "${BLUE}[1/8]${NC} Chargement de la configuration..."
if [ -f .env ]; then
    export $(grep -v '^#' "$ENV_FILE" | xargs)
    echo -e "${GREEN}✓${NC} Fichier .env chargé depuis environments/prod/.env"
else
    echo -e "${RED}✗${NC} Erreur: Fichier .env manquant"
    echo ""
    echo "Étapes à suivre:"
    echo "  1. cp .env.example .env"
    echo "  2. Éditer .env avec vos valeurs (sections oauth2-proxy et Guacamole)"
    echo "  3. Relancer: ./deploy.sh"
    exit 1
fi

# Variables avec valeurs par défaut
DOMAIN=${DOMAIN:-"example.com"}
DATA_DIR=${DATA_DIR:-"/data"}
CERT_PATH="${TLS_CERT_FILE:-${DATA_DIR}/certs/wildcard.${DOMAIN}.crt}"
KEY_PATH="${TLS_KEY_FILE:-${DATA_DIR}/certs/wildcard.${DOMAIN}.key}"

# 2. Vérifier prérequis
echo -e "${BLUE}[2/8]${NC} Vérification des prérequis..."

# Vérifier DATA_DIR accessible
if [ ! -d "$DATA_DIR" ]; then
    echo -e "${RED}✗${NC} DATA_DIR non accessible: $DATA_DIR"
    if [ -L "$DATA_DIR" ]; then
        TARGET=$(readlink -f "$DATA_DIR" 2>/dev/null || readlink "$DATA_DIR")
        echo -e "${YELLOW}  → Lien symbolique vers: $TARGET${NC}"
        echo -e "${YELLOW}  → Le disque cible n'est probablement pas monté${NC}"
        echo ""
        echo "Solution:"
        echo "  sudo mount /dev/nvme0n1 /media/timo/data0"
        echo ""
        echo "Ou modifier DATA_DIR dans .env pour utiliser un autre emplacement"
    fi
    exit 1
else
    echo -e "${GREEN}✓${NC} DATA_DIR accessible: $DATA_DIR"
fi

# Vérifier certificats SSL
if [ ! -f "$CERT_PATH" ]; then
    echo -e "${RED}✗${NC} Certificat SSL manquant: $CERT_PATH"
    exit 1
else
    echo -e "${GREEN}✓${NC} Certificat SSL trouvé: $CERT_PATH"
fi

if [ ! -f "$KEY_PATH" ]; then
    echo -e "${RED}✗${NC} Clé privée SSL manquante: $KEY_PATH"
    exit 1
else
    echo -e "${GREEN}✓${NC} Clé privée SSL trouvée: $KEY_PATH"
fi

# Vérifier Keycloak issuer
if [ -z "$KEYCLOAK_ISSUER" ]; then
    echo -e "${RED}✗${NC} KEYCLOAK_ISSUER non défini dans .env"
    exit 1
else
    echo -e "${GREEN}✓${NC} KEYCLOAK_ISSUER: $KEYCLOAK_ISSUER"
fi

# Auto-dériver les variables Keycloak depuis KEYCLOAK_ISSUER si vides
# Ex: https://keycloak.example.com:8443/realms/portal
#     -> KEYCLOAK_HOST = keycloak.example.com
#     -> KEYCLOAK_REALM = portal
#     -> KEYCLOAK_URL = https://keycloak.example.com:8443
#     -> KEYCLOAK_BACKEND_URL = https://keycloak.example.com:8443
#
# Les valeurs dérivées sont écrites dans .env pour les autres scripts
derive_and_save() {
    local var_name="$1"
    local var_value="$2"
    export "${var_name}=${var_value}"
    # Ajouter au .env si pas déjà présent
    if ! grep -q "^${var_name}=" .env 2>/dev/null; then
        echo "${var_name}=${var_value}" >> .env
    fi
    echo -e "${GREEN}✓${NC} ${var_name} dérivé: ${var_value}"
}

if [ -z "$KEYCLOAK_HOST" ]; then
    KEYCLOAK_HOST=$(echo "$KEYCLOAK_ISSUER" | sed -E 's|^https?://([^:/]+).*|\1|')
    derive_and_save "KEYCLOAK_HOST" "$KEYCLOAK_HOST"
else
    export KEYCLOAK_HOST
fi
if [ -z "$KEYCLOAK_REALM" ]; then
    KEYCLOAK_REALM=$(echo "$KEYCLOAK_ISSUER" | sed -E 's|.*/realms/([^/]+).*|\1|')
    derive_and_save "KEYCLOAK_REALM" "$KEYCLOAK_REALM"
else
    export KEYCLOAK_REALM
fi
if [ -z "$KEYCLOAK_URL" ]; then
    # Extraire scheme://host:port (sans /realms/...)
    KEYCLOAK_URL=$(echo "$KEYCLOAK_ISSUER" | sed -E 's|(https?://[^/]+).*|\1|')
    derive_and_save "KEYCLOAK_URL" "$KEYCLOAK_URL"
else
    export KEYCLOAK_URL
fi
if [ -z "$KEYCLOAK_BACKEND_URL" ]; then
    # Par défaut, utilise la même URL que KEYCLOAK_URL (scheme://host:port)
    KEYCLOAK_BACKEND_URL="$KEYCLOAK_URL"
    derive_and_save "KEYCLOAK_BACKEND_URL" "$KEYCLOAK_BACKEND_URL"
else
    export KEYCLOAK_BACKEND_URL
fi

# Vérifier OIDC client ID (valeur par défaut pour compatibilité)
if [ -z "$OIDC_CLIENT_ID" ]; then
    echo -e "${YELLOW}⚠${NC} OIDC_CLIENT_ID non défini, utilisation de la valeur par défaut: oauth2-proxy"
    OIDC_CLIENT_ID="oauth2-proxy"
fi
# Exporter pour envsubst et autres sous-processus
export OIDC_CLIENT_ID

# Vérifier OIDC client secret
if [ -z "$OIDC_CLIENT_SECRET" ]; then
    echo -e "${RED}✗${NC} OIDC_CLIENT_SECRET non défini dans .env"
    echo "Récupérer le secret depuis Keycloak: Clients → oauth2-proxy → Credentials"
    exit 1
else
    echo -e "${GREEN}✓${NC} OIDC_CLIENT_SECRET configuré"
fi

# Vérifier Guacamole DB password
if [ -z "$GUACAMOLE_DB_PASSWORD" ]; then
    echo -e "${YELLOW}⚠${NC} GUACAMOLE_DB_PASSWORD non défini, utilisation valeur par défaut"
else
    echo -e "${GREEN}✓${NC} GUACAMOLE_DB_PASSWORD configuré"
fi

# Définir les groupes Keycloak (valeurs par défaut si non définies dans .env)
export ADMIN_GROUP="${ADMIN_GROUP:-admin-infra}"
export ADMIN_APP_GROUP="${ADMIN_APP_GROUP:-admin-app}"
export USER_GROUP="${USER_GROUP:-utilisateurs}"
echo -e "${GREEN}✓${NC} Groupes: ADMIN_GROUP=$ADMIN_GROUP, ADMIN_APP_GROUP=$ADMIN_APP_GROUP, USER_GROUP=$USER_GROUP"

# Définir les hostnames des services (valeurs par défaut: <service>.${DOMAIN})
export PORTAL_HOSTNAME="${PORTAL_HOSTNAME:-portail.${DOMAIN}}"
export GUACAMOLE_HOSTNAME="${GUACAMOLE_HOSTNAME:-guacamole.${DOMAIN}}"
export VAULTWARDEN_HOSTNAME="${VAULTWARDEN_HOSTNAME:-vault.${DOMAIN}}"
export LINSHARE_HOSTNAME="${LINSHARE_HOSTNAME:-linshare.${DOMAIN}}"
export LINSHARE_ADMIN_HOSTNAME="${LINSHARE_ADMIN_HOSTNAME:-linshare-admin.${DOMAIN}}"
export HEADSCALE_HOSTNAME="${HEADSCALE_HOSTNAME:-vpn.${DOMAIN}}"
export BOOKSTACK_HOSTNAME="${BOOKSTACK_HOSTNAME:-wiki.${DOMAIN}}"
export KEYCLOAK_PROXY_HOSTNAME="${KEYCLOAK_PROXY_HOSTNAME:-keycloak.${DOMAIN}}"
echo -e "${GREEN}✓${NC} Hostnames configurés (PORTAL=$PORTAL_HOSTNAME, GUACAMOLE=$GUACAMOLE_HOSTNAME, ...)"

# Définir les variables oauth2-proxy (valeurs par défaut)
export OAUTH2_PROXY_REDIRECT_URL="${OAUTH2_PROXY_REDIRECT_URL:-https://${PORTAL_HOSTNAME}/oauth2/callback}"
export OAUTH2_PROXY_COOKIE_DOMAINS="${OAUTH2_PROXY_COOKIE_DOMAINS:-.${DOMAIN}}"
export OAUTH2_PROXY_COOKIE_SECURE="${OAUTH2_PROXY_COOKIE_SECURE:-true}"
echo -e "${GREEN}✓${NC} oauth2-proxy configuré (redirect=${OAUTH2_PROXY_REDIRECT_URL})"

# Vérifier Docker
if ! command -v docker &> /dev/null; then
    echo -e "${RED}✗${NC} Docker n'est pas installé"
    exit 1
else
    echo -e "${GREEN}✓${NC} Docker installé: $(docker --version | head -1)"
fi

# 3. Créer structure de répertoires
echo -e "${BLUE}[3/8]${NC} Création de la structure de répertoires..."
mkdir -p "${DATA_DIR}/certs"
mkdir -p "${DATA_DIR}/guacamole/postgres"
mkdir -p "${DATA_DIR}/guacamole/drive"
mkdir -p "${DATA_DIR}/guacamole/record"
mkdir -p "${DATA_DIR}/guacamole/extensions"
mkdir -p "${DATA_DIR}/logs/nginx"
mkdir -p "${DATA_DIR}/logs/guacamole"
mkdir -p "${DATA_DIR}/portal"
mkdir -p oauth2-proxy/nginx
echo -e "${GREEN}✓${NC} Répertoires créés dans ${DATA_DIR}"

# 4. Copier certificats (si nécessaire)
echo -e "${BLUE}[4/8]${NC} Installation des certificats..."

# Copier uniquement si source != destination
CERT_DEST="${DATA_DIR}/certs/$(basename "$CERT_PATH")"
KEY_DEST="${DATA_DIR}/certs/$(basename "$KEY_PATH")"

if [ "$CERT_PATH" != "$CERT_DEST" ]; then
    cp "$CERT_PATH" "${DATA_DIR}/certs/"
    echo -e "${GREEN}✓${NC} Certificat copié: $CERT_PATH → ${DATA_DIR}/certs/"
else
    echo -e "${GREEN}✓${NC} Certificat déjà en place: $CERT_PATH"
fi

if [ "$KEY_PATH" != "$KEY_DEST" ]; then
    cp "$KEY_PATH" "${DATA_DIR}/certs/"
    echo -e "${GREEN}✓${NC} Clé privée copiée: $KEY_PATH → ${DATA_DIR}/certs/"
else
    echo -e "${GREEN}✓${NC} Clé privée déjà en place: $KEY_PATH"
fi

# Permissions: 644 pour certificats (lecture publique), 640 pour clés (lecture groupe)
chmod 644 "${DATA_DIR}/certs/"*.crt 2>/dev/null || true
chmod 644 "${DATA_DIR}/certs/"*.key 2>/dev/null || true
echo -e "${GREEN}✓${NC} Permissions certificats configurées (644/644)"

# Symlinks tls.crt/tls.key pour Keycloak (attend /opt/keycloak/certs/tls.crt)
ln -sf "wildcard.${DOMAIN}.crt" "${DATA_DIR}/certs/tls.crt"
ln -sf "wildcard.${DOMAIN}.key" "${DATA_DIR}/certs/tls.key"
echo -e "${GREEN}✓${NC} Symlinks tls.crt/tls.key créés"

# =============================================================================
# Génération du CA bundle (système + CA personnalisés)
# =============================================================================
# Ce bundle est monté dans les containers pour valider les certificats SSL
# (ex: Vaultwarden -> Keycloak, LinShare -> Keycloak)
#
# CERTIFICATS CA PERSONNALISES :
# ------------------------------
# Emplacement : /data/certs/custom-ca/
# Formats acceptés : .crt, .pem, .cer (format PEM uniquement, pas DER/binaire)
#
# Cas d'usage :
#   - CA interne d'entreprise (Active Directory CS, PKI interne)
#   - CA intermédiaire non inclus dans le système (Sectigo E46/R46, etc.)
#   - Certificat auto-signé (POC uniquement, via setup-poc.sh)
#
# Format PEM attendu (texte, pas binaire) :
#   -----BEGIN CERTIFICATE-----
#   MIIDxxxxxx...
#   -----END CERTIFICATE-----
#
# Conversion DER -> PEM si nécessaire :
#   openssl x509 -inform DER -in ca.der -out ca.crt
#
# Exemple d'ajout d'un CA :
#   cp /chemin/vers/ca-entreprise.crt /data/certs/custom-ca/
#   ./deploy.sh  # Régénère automatiquement le bundle
#
# POC avec certificat auto-signé :
#   ./setup-poc.sh  # Copie ca.crt dans custom-ca/ et régénère le bundle
# =============================================================================
CUSTOM_CA_DIR="${DATA_DIR}/certs/custom-ca"
CA_BUNDLE="${DATA_DIR}/certs/ca-bundle.crt"

mkdir -p "$CUSTOM_CA_DIR"
if [ -f /etc/ssl/certs/ca-certificates.crt ]; then
    cp /etc/ssl/certs/ca-certificates.crt "$CA_BUNDLE"

    # Ajouter les CA personnalisés (Sectigo E46/R46, CA internes, etc.)
    # Accepte .crt, .pem, .cer (tous formats PEM)
    custom_ca_count=0
    for ext in crt pem cer; do
        if ls "$CUSTOM_CA_DIR"/*.$ext 1>/dev/null 2>&1; then
            if [ $custom_ca_count -eq 0 ]; then
                echo "" >> "$CA_BUNDLE"
                echo "# === Custom CA certificates ===" >> "$CA_BUNDLE"
            fi
            for ca_file in "$CUSTOM_CA_DIR"/*.$ext; do
                echo "# $(basename "$ca_file")" >> "$CA_BUNDLE"
                cat "$ca_file" >> "$CA_BUNDLE"
                echo "" >> "$CA_BUNDLE"
                ((custom_ca_count++)) || true
            done
        fi
    done

    # Ajouter le certificat wildcard self-signed pour POC (si présent)
    WILDCARD_CERT="${DATA_DIR}/certs/wildcard.${DOMAIN}.crt"
    if [ -f "$WILDCARD_CERT" ]; then
        # Vérifier si c'est un certificat self-signed (issuer == subject)
        issuer=$(openssl x509 -in "$WILDCARD_CERT" -noout -issuer 2>/dev/null | sed 's/issuer=//')
        subject=$(openssl x509 -in "$WILDCARD_CERT" -noout -subject 2>/dev/null | sed 's/subject=//')
        if [ "$issuer" = "$subject" ]; then
            echo "" >> "$CA_BUNDLE"
            echo "# === Self-signed wildcard certificate (POC) ===" >> "$CA_BUNDLE"
            echo "# $(basename "$WILDCARD_CERT")" >> "$CA_BUNDLE"
            cat "$WILDCARD_CERT" >> "$CA_BUNDLE"
            ((custom_ca_count++)) || true
            # Copier comme ca.crt (le cert self-signed EST son propre CA)
            # Utilisé par les entrypoints Java (Guacamole, etc.)
            cp "$WILDCARD_CERT" "${DATA_DIR}/certs/ca.crt"
        fi
    fi

    if [ $custom_ca_count -gt 0 ]; then
        echo -e "${GREEN}✓${NC} CA bundle généré (système + $custom_ca_count CA personnalisés)"
    else
        echo -e "${GREEN}✓${NC} CA bundle généré (système uniquement)"
        echo -e "   ${YELLOW}Astuce:${NC} Placez vos CA personnalisés (.crt/.pem) dans $CUSTOM_CA_DIR/"
    fi
else
    echo -e "${YELLOW}⚠${NC} /etc/ssl/certs/ca-certificates.crt non trouvé, CA bundle non généré"
fi

# 5. Auto-génération des secrets si vides
echo -e "${BLUE}[5/8]${NC} Vérification et génération des secrets..."

# Fonction helper pour générer un secret et l'ajouter au .env
generate_secret() {
    local var_name="$1"
    local var_value="${!var_name}"
    local secret_type="${2:-base64}"  # base64, base64-48, ou hex-16

    if [ -z "$var_value" ]; then
        echo -e "${YELLOW}⚠${NC} ${var_name} non défini, génération..."
        case "$secret_type" in
            base64-48)
                var_value=$(openssl rand -base64 48)
                ;;
            hex-16)
                # 16 bytes = 32 hex characters (pour Headplane cookie_secret)
                var_value=$(openssl rand -hex 16)
                ;;
            *)
                var_value=$(python3 -c 'import os,base64; print(base64.urlsafe_b64encode(os.urandom(32)).decode())')
                ;;
        esac
        echo "${var_name}=${var_value}" >> .env
        export "${var_name}=${var_value}"
        echo -e "${GREEN}✓${NC} ${var_name} généré et ajouté à .env"
    else
        echo -e "${GREEN}✓${NC} ${var_name} déjà configuré"
    fi
}

# Secrets oauth2-proxy
generate_secret "COOKIE_SECRET"

# Secrets Guacamole
generate_secret "GUACAMOLE_DB_PASSWORD"
if [ -n "$GUACAMOLE_ADMIN_PASSWORD" ] || [ "${DEPLOY_GUACAMOLE:-true}" = "true" ]; then
    generate_secret "GUACAMOLE_ADMIN_PASSWORD"
fi

# Secrets LinShare (si activé)
if [ "${DEPLOY_LINSHARE:-false}" = "true" ]; then
    generate_secret "LINSHARE_DB_PASSWORD"
    generate_secret "LINSHARE_MONGO_PASSWORD"
fi

# Secrets Vaultwarden (si activé)
if [ "${DEPLOY_VAULTWARDEN:-false}" = "true" ]; then
    generate_secret "VAULTWARDEN_ADMIN_TOKEN" "base64-48"
fi

# Secrets Headscale (si activé)
if [ "${DEPLOY_HEADSCALE:-false}" = "true" ]; then
    # Headplane exige exactement 32 caractères (hex-16 = 16 bytes = 32 hex chars)
    generate_secret "HEADPLANE_COOKIE_SECRET" "hex-16"
fi

# Secrets Credentials API (si activé)
if [ "${DEPLOY_CREDENTIALS_API:-true}" = "true" ]; then
    generate_secret "CREDENTIALS_ENCRYPTION_KEY"
fi

# Secrets Keycloak autonome (si déployé)
if [ -f "keycloak/docker-compose.yml" ]; then
    generate_secret "KEYCLOAK_ADMIN_PASSWORD"
    generate_secret "KEYCLOAK_DB_PASSWORD"
fi

echo -e "${GREEN}✓${NC} Tous les secrets vérifiés"

# Nettoyage des conteneurs et réseaux Docker existants pour éviter les conflits
echo -e "${BLUE}[6/9]${NC} Nettoyage des conteneurs/réseaux existants..."

# Liste des conteneurs à nettoyer avant déploiement
# Inclut les services core et les services optionnels (LinShare, etc.)
CONTAINERS_TO_CLEAN="oauth2-proxy oauth2-redis nginx-apps guacamole-web guacamole-daemon guacamole-db credentials-api linshare-backend linshare-ui-user linshare-ui-admin linshare-thumbnail linshare-postgres linshare-mongodb linshare-clamav"

# Arrêter et supprimer les conteneurs existants
for container in $CONTAINERS_TO_CLEAN; do
    if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
        echo "   - Suppression du conteneur existant: ${container}"
        docker rm -f "${container}" 2>/dev/null || true
    fi
done

# Arrêter les stacks docker compose si elles existent
echo "   - Arrêt des stacks docker compose..."
docker compose -f oauth2-proxy/docker-compose.yml down 2>/dev/null || true
docker compose -f guacamole/docker-compose.yml down 2>/dev/null || true
docker compose -f credentials-api/docker-compose.yml down 2>/dev/null || true

# Nettoyer les réseaux Docker orphelins (uniquement si vides)
for network in portal-net guacamole-net linshare-net linshare_linshare-net; do
    if docker network ls --format '{{.Name}}' | grep -q "^${network}$"; then
        # Vérifier si le réseau est utilisé
        CONNECTED=$(docker network inspect "${network}" -f '{{len .Containers}}' 2>/dev/null || echo "0")
        if [ "$CONNECTED" = "0" ]; then
            echo "   - Suppression du réseau inutilisé: ${network}"
            docker network rm "${network}" 2>/dev/null || true
        else
            echo "   - Réseau ${network} en cours d'utilisation (${CONNECTED} conteneurs)"
        fi
    fi
done

echo -e "${GREEN}✓${NC} Nettoyage terminé"

# Création des réseaux Docker (sans subnet specifique - Docker gere automatiquement)
echo -e "${BLUE}[7/10]${NC} Création des réseaux Docker..."

for network in auth-net portal-net guacamole-net prod_apps-net linshare_linshare-net keycloak-net headscale-net; do
    if ! docker network ls --format '{{.Name}}' | grep -q "^${network}$"; then
        echo "   - Création du réseau ${network}"
        docker network create --driver bridge "${network}"
    else
        echo -e "   ${GREEN}✓${NC} ${network} existe déjà"
    fi
done

echo -e "${GREEN}✓${NC} Réseaux Docker prêts"

# Vérifier envsubst
if ! command -v envsubst &> /dev/null; then
    echo -e "${RED}✗${NC} envsubst non disponible (installer gettext-base)"
    exit 1
fi

# Initialiser la liste des variables envsubst (auto-construite depuis .env)
build_envsubst_vars
echo -e "${GREEN}✓${NC} Variables envsubst: $(echo "$_ENVSUBST_VARS" | wc -w) clés chargées depuis .env"

# Générer oauth2-proxy.cfg
if [ -f oauth2-proxy/templates/oauth2-proxy.cfg.template ]; then
    process_template oauth2-proxy/templates/oauth2-proxy.cfg.template oauth2-proxy/oauth2-proxy.cfg
    echo -e "${GREEN}✓${NC} oauth2-proxy.cfg généré"
else
    echo -e "${RED}✗${NC} Template oauth2-proxy.cfg.template non trouvé"
    exit 1
fi

# Générer nginx apps.conf
mkdir -p oauth2-proxy/nginx/conf.d
if [ -f oauth2-proxy/nginx/apps.conf.template ]; then
    process_template oauth2-proxy/nginx/apps.conf.template oauth2-proxy/nginx/conf.d/apps.conf
    echo -e "${GREEN}✓${NC} nginx/apps.conf généré"
else
    echo -e "${YELLOW}⚠${NC} Template nginx/apps.conf.template non trouvé"
fi

# Générer nginx linshare.conf uniquement si LinShare est activé
if [ "${DEPLOY_LINSHARE:-false}" = "true" ]; then
    if [ -f oauth2-proxy/nginx/linshare.conf.template ]; then
        process_template oauth2-proxy/nginx/linshare.conf.template oauth2-proxy/nginx/conf.d/linshare.conf
        echo -e "${GREEN}✓${NC} nginx/linshare.conf généré (DEPLOY_LINSHARE=true)"
    fi
else
    rm -f oauth2-proxy/nginx/conf.d/linshare.conf
    echo -e "${GREEN}✓${NC} nginx/linshare.conf supprimé (DEPLOY_LINSHARE=false)"
fi

# Générer portal config.json
if [ -f portal/www/config.json.template ]; then
    export BUILD_DATE=$(date '+%Y-%m-%d %H:%M')
    export PORTAL_ADMIN_GROUP="${PORTAL_ADMIN_GROUP:-admin-infra}"
    export VAULTWARDEN_ENABLED="${DEPLOY_VAULTWARDEN:-false}"
    export POC_IP="${POC_IP:-$(hostname -I | awk '{print $1}')}"
    export OIDCWARDEN_CLIENT_ID="${OIDCWARDEN_CLIENT_ID:-vaultwarden}"
    export LINSHARE_OIDC_CLIENT_ID="${LINSHARE_OIDC_CLIENT_ID:-linshare}"
    process_template portal/www/config.json.template portal/www/config.json
    echo -e "${GREEN}✓${NC} portal/config.json généré"
else
    echo -e "${YELLOW}⚠${NC} Template portal/config.json.template non trouvé"
fi

# Générer guacamole.properties si template existe
# Architecture OIDC native : Guacamole -> Keycloak directement (sans oauth2-proxy)
if [ -f guacamole/guacamole.properties.template ]; then
    export GUACAMOLE_OIDC_CLIENT_ID="${GUACAMOLE_OIDC_CLIENT_ID:-guacamole}"
    process_template guacamole/guacamole.properties.template ${DATA_DIR}/guacamole/guacamole.properties
    echo -e "${GREEN}✓${NC} guacamole.properties généré (OIDC client: $GUACAMOLE_OIDC_CLIENT_ID)"
else
    echo -e "${YELLOW}⚠${NC} Template guacamole.properties.template non trouvé (utiliser config existante)"
fi

# 7. Build des images Docker custom
echo ""
echo -e "${BLUE}[7/9]${NC} Build des images Docker..."
echo "Building Guacamole custom images (daemon + web)..."
docker compose build guacamole-daemon guacamole-web
echo -e "${GREEN}✓${NC} Images Guacamole buildées"
echo "Building Portal API..."
docker compose build portal-api
echo -e "${GREEN}✓${NC} Image Portal API buildée"

# 8. Démarrer services avec docker compose
echo ""
echo -e "${BLUE}[8/9]${NC} Démarrage des services..."
echo -e "${YELLOW}========================================${NC}"
echo "Services à déployer:"
echo "  ✓ oauth2-proxy (authentification OIDC)"
echo "  ✓ nginx (reverse proxy multi-applications)"
echo "  ✓ guacamole-db (PostgreSQL)"
echo "  ✓ guacamole-daemon (guacd RDP/VNC/SSH - custom build)"
echo "  ✓ guacamole-web (interface web Tomcat - custom build)"
echo "  ✓ portal-api (API gestion applications)"
echo -e "${YELLOW}========================================${NC}"
echo ""

if ! confirm_action "Continuer le déploiement?"; then
    echo -e "${YELLOW}Déploiement annulé${NC}"
    exit 0
fi

# Construire la liste des profiles à activer
COMPOSE_PROFILES=""

if [ "${DEPLOY_LINSHARE:-false}" = "true" ]; then
    # Créer répertoires LinShare
    mkdir -p "${DATA_DIR}/linshare/postgres"
    mkdir -p "${DATA_DIR}/linshare/mongodb"
    mkdir -p "${DATA_DIR}/linshare/files"
    mkdir -p "${DATA_DIR}/linshare/clamav"
    mkdir -p "${DATA_DIR}/linshare/logs"
    mkdir -p "${DATA_DIR}/linshare/config"
    mkdir -p "${DATA_DIR}/linshare/certs"

    # Générer le truststore Java pour LinShare (OIDC HTTPS vers Keycloak)
    generate_linshare_truststore

    # L'image linagora/linshare-database:6.x inclut les scripts d'init SQL
    # Nettoyage des répertoires fantômes créés par Docker lors de mounts échoués
    for f in linshare/createSchema.sql linshare/import-postgresql.sql; do
        [ -d "$f" ] && rm -rf "$f"
    done

    # Générer linshare.properties depuis template
    if [ -f linshare/config/linshare.properties.template ]; then
        export LINSHARE_OIDC_CLIENT_ID="${LINSHARE_OIDC_CLIENT_ID:-linshare}"
        process_template linshare/config/linshare.properties.template ${DATA_DIR}/linshare/config/linshare.properties
        chmod 600 ${DATA_DIR}/linshare/config/linshare.properties
        echo -e "${GREEN}✓${NC} linshare.properties généré dans ${DATA_DIR}/linshare/config/"
    fi

    # Copier linshare-extra.properties si existe
    if [ -f linshare/config/linshare-extra.properties ]; then
        cp linshare/config/linshare-extra.properties ${DATA_DIR}/linshare/config/
        echo -e "${GREEN}✓${NC} linshare-extra.properties copié"
    fi

    # Générer config.js (UI user) depuis template
    if [ -f linshare/config/config.js.template ]; then
        process_template linshare/config/config.js.template ${DATA_DIR}/linshare/config/config.js
        echo -e "${GREEN}✓${NC} config.js (UI user) généré"
    elif [ -f linshare/config/config.js ]; then
        cp linshare/config/config.js "${DATA_DIR}/linshare/config/"
    fi

    # Générer config-admin.js (UI admin) depuis template
    if [ -f linshare/config/config-admin.js.template ]; then
        process_template linshare/config/config-admin.js.template ${DATA_DIR}/linshare/config/config-admin.js
        echo -e "${GREEN}✓${NC} config-admin.js (UI admin) généré"
    elif [ -f linshare/config/config-admin.js ]; then
        cp linshare/config/config-admin.js "${DATA_DIR}/linshare/config/"
    fi
    COMPOSE_PROFILES="$COMPOSE_PROFILES --profile linshare"
    echo -e "${GREEN}✓${NC} LinShare activé (profile linshare)"
else
    echo -e "${YELLOW}⚠${NC} LinShare désactivé (DEPLOY_LINSHARE=false)"
fi

if [ "${DEPLOY_HEADSCALE:-false}" = "true" ]; then
    # Créer répertoires Headscale
    mkdir -p "${DATA_DIR}/headscale/data"
    mkdir -p "${DATA_DIR}/headscale/run"
    mkdir -p "${DATA_DIR}/headscale/caddy"
    mkdir -p "${DATA_DIR}/headplane"

    # Générer les configs depuis templates (config.yaml, acls.yaml, headplane.yaml, Caddyfile)
    echo -e "${BLUE}Génération des configurations Headscale...${NC}"
    generate_templates_in_dir "headscale"

    COMPOSE_PROFILES="$COMPOSE_PROFILES --profile headscale"
    echo -e "${GREEN}✓${NC} Headscale activé (profile headscale)"
else
    echo -e "${YELLOW}⚠${NC} Headscale désactivé (DEPLOY_HEADSCALE=false)"
fi

if [ "${DEPLOY_BOOKSTACK:-false}" = "true" ]; then
    # Créer répertoires Bookstack
    mkdir -p "${DATA_DIR}/bookstack_config"
    COMPOSE_PROFILES="$COMPOSE_PROFILES --profile bookstack"
    echo -e "${GREEN}✓${NC} Bookstack activé (profile bookstack)"
else
    echo -e "${YELLOW}⚠${NC} Bookstack désactivé (DEPLOY_BOOKSTACK=false)"
fi

if [ "${DEPLOY_VAULTWARDEN:-false}" = "true" ]; then
    # Créer répertoires Vaultwarden
    mkdir -p "${DATA_DIR}/vaultwarden"
    COMPOSE_PROFILES="$COMPOSE_PROFILES --profile vault"
    echo -e "${GREEN}✓${NC} Vaultwarden activé (profile vault)"
else
    echo -e "${YELLOW}⚠${NC} Vaultwarden désactivé (DEPLOY_VAULTWARDEN=false)"
fi

# Vérifier que Keycloak est accessible avant de démarrer les services OIDC
echo ""
echo -e "${BLUE}[8/10]${NC} Vérification des dépendances..."
if ! check_keycloak; then
    echo ""
    echo -e "${YELLOW}Les services OIDC (oauth2-proxy, guacamole, linshare) ne peuvent pas démarrer sans Keycloak.${NC}"
    echo ""
    if confirm_action "Démarrer Keycloak maintenant?"; then
        echo "Démarrage de Keycloak..."
        deploy_service "keycloak"
        echo "Attente du démarrage de Keycloak..."
        if ! wait_for_keycloak 60; then
            echo -e "${RED}Keycloak n'a pas démarré dans les temps. Abandon.${NC}"
            exit 1
        fi
        # Creation du realm si necessaire
        if [ -x "keycloak/scripts/setup-realm.sh" ]; then
            echo ""
            echo -e "${BLUE}Creation du realm Keycloak...${NC}"
            ./keycloak/scripts/setup-realm.sh 2>&1 | grep -E "^\[|OK|ERROR|WARNING|==" || true
        fi
        # Configuration automatique des clients Keycloak
        if [ -x "keycloak/scripts/setup-all.sh" ]; then
            echo ""
            echo -e "${BLUE}Configuration des clients Keycloak...${NC}"
            ./keycloak/scripts/setup-all.sh 2>&1 | grep -E "^\[|OK|ERROR|WARNING|==" || true
        fi
    else
        echo -e "${RED}Abandon du déploiement. Keycloak est requis.${NC}"
        exit 1
    fi
fi

# Lancer docker compose en phases (résout les dépendances circulaires OIDC)
# Phase 1: Keycloak est déjà démarré (section précédente)
# Phase 2: Infrastructure (redis + nginx) - nginx peut proxier Keycloak sur 443
# Phase 3: Authentification (oauth2-proxy) - OIDC discovery via nginx → keycloak
# Phase 4: Applications (tout le reste avec profiles)
echo ""
echo -e "${BLUE}[9/10]${NC} Lancement des services (déploiement phasé)..."

# Phase 2: Infrastructure
echo -e "${BLUE}  Phase 2/4:${NC} Infrastructure (redis + nginx-apps)..."
docker compose up -d redis nginx-apps
echo -e "  ${GREEN}✓${NC} redis + nginx-apps démarrés"

# Attendre que nginx soit prêt (il doit proxier Keycloak pour oauth2-proxy)
echo "  Attente de nginx..."
sleep 3
if docker compose ps nginx-apps 2>/dev/null | grep -q "Up"; then
    echo -e "  ${GREEN}✓${NC} nginx-apps opérationnel"
else
    echo -e "  ${YELLOW}⚠${NC} nginx-apps pas encore prêt, poursuite..."
fi

# Phase 3: Authentification
echo -e "${BLUE}  Phase 3/4:${NC} Authentification (oauth2-proxy)..."
docker compose up -d oauth2-proxy
echo -e "  ${GREEN}✓${NC} oauth2-proxy démarré"
sleep 2

# Phase 4: Toutes les applications (avec profiles)
echo -e "${BLUE}  Phase 4/4:${NC} Applications..."
echo "  Commande: docker compose $COMPOSE_PROFILES up -d"
docker compose $COMPOSE_PROFILES up -d

# Note: credentials-api est inclus dans docker-compose.yml principal (ligne include)
# Ne PAS le relancer séparément (doublon supprimé le 2026-01-25)

# Attendre démarrage complet
echo "Attente du démarrage des services..."
sleep 5

# 9. Vérification déploiement
echo ""
echo -e "${BLUE}[9/9]${NC} Vérification du déploiement..."

# Vérifier oauth2-proxy
if curl -k https://localhost:44180/ping > /dev/null 2>&1; then
    echo -e "${GREEN}✓${NC} oauth2-proxy opérationnel (port 44180)"
else
    echo -e "${YELLOW}⚠${NC} oauth2-proxy non accessible (vérifier logs)"
fi

# Vérifier nginx
if docker compose ps nginx-apps 2>/dev/null | grep -q "Up"; then
    echo -e "${GREEN}✓${NC} nginx opérationnel"
else
    echo -e "${YELLOW}⚠${NC} nginx non démarré (vérifier logs)"
fi

# Vérifier Guacamole
if docker compose ps guacamole-web 2>/dev/null | grep -q "Up"; then
    echo -e "${GREEN}✓${NC} guacamole-web opérationnel"
else
    echo -e "${YELLOW}⚠${NC} guacamole-web non démarré (vérifier logs)"
fi

if docker compose ps guacamole-db 2>/dev/null | grep -q "Up"; then
    echo -e "${GREEN}✓${NC} guacamole-db opérationnel"
else
    echo -e "${YELLOW}⚠${NC} guacamole-db non démarré (vérifier logs)"
fi

if docker compose ps portal-api 2>/dev/null | grep -q "Up"; then
    echo -e "${GREEN}✓${NC} portal-api opérationnel"
else
    echo -e "${YELLOW}⚠${NC} portal-api non démarré (vérifier logs)"
fi

# Vérifier LinShare si activé
if [ "${DEPLOY_LINSHARE:-false}" = "true" ]; then
    if docker ps --format '{{.Names}}' | grep -q "linshare-ui-user"; then
        echo -e "${GREEN}✓${NC} linshare-ui-user opérationnel"
    else
        echo -e "${YELLOW}⚠${NC} linshare-ui-user non démarré (vérifier logs)"
    fi
    if docker ps --format '{{.Names}}' | grep -q "linshare-postgres"; then
        echo -e "${GREEN}✓${NC} linshare-postgres opérationnel"
    else
        echo -e "${YELLOW}⚠${NC} linshare-postgres non démarré (vérifier logs)"
    fi
    # Configurer le domaine OIDC si LinShare backend est démarré
    if docker ps --format '{{.Names}}' | grep -q "linshare-backend"; then
        echo -e "${BLUE}Configuration du domaine OIDC LinShare...${NC}"
        if [ -x "linshare/configure-linshare-oidc.sh" ]; then
            ./linshare/configure-linshare-oidc.sh 2>&1 | grep -E "INFO|OK|ERROR|WARNING|TERMINEE" || true
        fi
    fi
fi

# Vérifier Headscale si activé
if [ "${DEPLOY_HEADSCALE:-false}" = "true" ]; then
    if docker ps --format '{{.Names}}' | grep -q "^headscale$"; then
        echo -e "${GREEN}✓${NC} headscale opérationnel"

        # Générer API key si non configurée (nécessaire pour Headplane)
        if [ -z "$HEADSCALE_API_KEY" ]; then
            echo -e "${BLUE}Génération de l'API key Headscale pour Headplane...${NC}"

            # Attendre que Headscale soit prêt (max 30s)
            for i in {1..30}; do
                if docker exec headscale headscale apikeys list >/dev/null 2>&1; then
                    break
                fi
                sleep 1
            done

            # Générer l'API key
            API_KEY=$(docker exec headscale headscale apikeys create --expiration 365d 2>/dev/null)
            if [ -n "$API_KEY" ]; then
                # Mettre à jour la ligne existante (pas d'append pour éviter les doublons)
                sed -i "s|^HEADSCALE_API_KEY=.*|HEADSCALE_API_KEY=${API_KEY}|" "$ENV_FILE"
                export HEADSCALE_API_KEY="${API_KEY}"
                echo -e "${GREEN}✓${NC} API key générée et ajoutée à .env"

                # Régénérer headplane.yaml avec la nouvelle API key
                if [ -f headscale/headplane.yaml.template ]; then
                    set -a && source .env && set +a
                    _ENVSUBST_VARS=""  # Forcer reconstruction (nouvelle clé dans .env)
                    process_template headscale/headplane.yaml.template headscale/headplane.yaml
                    echo -e "${GREEN}✓${NC} headplane.yaml régénéré"

                    # Redémarrer Headplane
                    if docker ps --format '{{.Names}}' | grep -q "^headplane$"; then
                        docker restart headplane >/dev/null 2>&1
                        echo -e "${GREEN}✓${NC} headplane redémarré avec API key"
                    fi
                fi
            else
                echo -e "${YELLOW}⚠${NC} Impossible de générer l'API key (vérifier logs headscale)"
            fi
        else
            echo -e "${GREEN}✓${NC} API key Headscale déjà configurée"
        fi
    else
        echo -e "${YELLOW}⚠${NC} headscale non démarré (vérifier logs)"
    fi
fi

# Vérifier Bookstack si activé
if [ "${DEPLOY_BOOKSTACK:-false}" = "true" ]; then
    if docker ps --format '{{.Names}}' | grep -q "bookstack"; then
        echo -e "${GREEN}✓${NC} bookstack opérationnel"
    else
        echo -e "${YELLOW}⚠${NC} bookstack non démarré (vérifier logs)"
    fi
fi

# Vérifier Vaultwarden si activé
if [ "${DEPLOY_VAULTWARDEN:-false}" = "true" ]; then
    if docker ps --format '{{.Names}}' | grep -q "vaultwarden"; then
        echo -e "${GREEN}✓${NC} vaultwarden opérationnel"
    else
        echo -e "${YELLOW}⚠${NC} vaultwarden non démarré (vérifier logs)"
    fi
fi

# =============================================================================
# RÉSUMÉ ET INFORMATIONS D'ACCÈS
# =============================================================================
# Utiliser POC_IP si défini dans .env, sinon détecter automatiquement
SERVER_IP="${POC_IP:-$(hostname -I | awk '{print $1}')}"

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  DÉPLOIEMENT TERMINÉ - INFORMATIONS D'ACCÈS${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""

# Services Core
echo -e "${BLUE}Services Core:${NC}"
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │ Portail (SSO)     : http://${SERVER_IP}:4180                 │"
echo "  │ Portail HTTPS     : https://portail.${DOMAIN}               │"
echo "  │ Guacamole         : http://${SERVER_IP}:8081/guacamole      │"
echo "  │ Guacamole HTTPS   : https://guacamole.${DOMAIN}             │"
echo "  └─────────────────────────────────────────────────────────────┘"

# Services Optionnels
echo ""
echo -e "${BLUE}Services Optionnels:${NC}"
echo "  ┌─────────────────────────────────────────────────────────────┐"
if [ "${DEPLOY_LINSHARE:-false}" = "true" ]; then
echo "  │ LinShare (User)   : http://${SERVER_IP}:${LINSHARE_USER_PORT:-8082}                  │"
echo "  │ LinShare (Admin)  : http://${SERVER_IP}:${LINSHARE_ADMIN_PORT:-8083}                  │"
echo "  │ LinShare HTTPS    : https://linshare.${DOMAIN}              │"
else
echo "  │ LinShare          : ${YELLOW}Non déployé${NC}                           │"
fi
if [ "${DEPLOY_HEADSCALE:-false}" = "true" ]; then
echo "  │ Headscale VPN     : https://${SERVER_IP}:${HEADSCALE_HTTPS_PORT:-8443}               │"
echo "  │ Headplane UI      : http://${SERVER_IP}:${HEADPLANE_PORT:-3000}                  │"
else
echo "  │ Headscale         : ${YELLOW}Non déployé${NC}                           │"
fi
if [ "${DEPLOY_VAULTWARDEN:-false}" = "true" ]; then
echo "  │ Vaultwarden       : http://${SERVER_IP}:${VAULTWARDEN_PORT:-8222}                  │"
echo "  │ Vaultwarden HTTPS : https://vault.${DOMAIN}                 │"
else
echo "  │ Vaultwarden       : ${YELLOW}Non déployé${NC}                           │"
fi
if [ "${DEPLOY_BOOKSTACK:-false}" = "true" ]; then
echo "  │ Bookstack Wiki    : http://${SERVER_IP}:${BOOKSTACK_PORT:-80}                    │"
else
echo "  │ Bookstack         : ${YELLOW}Non déployé${NC}                           │"
fi
echo "  └─────────────────────────────────────────────────────────────┘"

# Infrastructure
echo ""
echo -e "${BLUE}Infrastructure (prérequis):${NC}"
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │ Keycloak Admin    : http://${SERVER_IP}:8080/admin          │"
echo "  │ Keycloak Issuer   : ${KEYCLOAK_ISSUER:-Non configuré}        │"
echo "  │ Realm             : ${KEYCLOAK_REALM:-Non configuré}                           │"
echo "  └─────────────────────────────────────────────────────────────┘"

# Monitoring
echo ""
echo -e "${BLUE}Monitoring & Debug:${NC}"
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │ oauth2-proxy metrics : http://${SERVER_IP}:9090/metrics     │"
echo "  │ oauth2-proxy ping    : http://${SERVER_IP}:4180/ping        │"
echo "  │ État des containers  : ./deploy.sh --status                │"
echo "  │ Logs                 : ./deploy.sh --logs <service>        │"
echo "  └─────────────────────────────────────────────────────────────┘"

# Identifiants POC
echo ""
echo -e "${BLUE}Identifiants POC (à créer dans Keycloak):${NC}"
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │ admin-infra / poc-admin-123     → groupe: admin-infra      │"
echo "  │ admin-std / poc-std-123         → groupe: admin-standard   │"
echo "  │ user-test / poc-user-123        → groupe: utilisateurs     │"
echo "  └─────────────────────────────────────────────────────────────┘"

# Commandes utiles
echo ""
echo -e "${BLUE}Commandes utiles:${NC}"
echo "  ./deploy.sh --status           # État des services"
echo "  ./deploy.sh --list             # Services disponibles"
echo "  ./deploy.sh --service linshare # Déployer un service"
echo "  ./deploy.sh --stop linshare    # Arrêter un service"
echo "  ./deploy.sh --destroy linshare # Supprimer un service + données"
echo "  ./deploy.sh --destroy-all      # Supprimer tout le déploiement"
echo ""

# Notes
echo -e "${YELLOW}Notes importantes:${NC}"
echo "  • Configuration Keycloak: keycloak/scripts/setup-all.sh (auto si premier déploiement)"
echo "  • DNS: Configurer *.${DOMAIN} → ${SERVER_IP}"
echo "  • Configuration Guacamole: ${DATA_DIR}/guacamole/guacamole.properties"
echo "  • Logs: docker compose logs -f <service>"
echo ""
