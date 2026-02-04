#!/bin/bash
# Script de redéploiement avec options
# Usage: ./redeploy.sh [options]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Charger .env
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
else
    echo -e "${RED}Erreur: .env manquant${NC}"
    exit 1
fi

# Nettoyer les conteneurs orphelins avant redemarrage
cleanup_containers() {
    echo -e "${YELLOW}Nettoyage des conteneurs existants...${NC}"

    local containers=("oauth2-proxy" "oauth2-redis" "nginx-apps")

    for container in "${containers[@]}"; do
        if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
            echo -e "  Suppression de ${container}..."
            docker rm -f "${container}" 2>/dev/null || true
        fi
    done

    echo -e "${GREEN}Nettoyage OK${NC}"
}

# Creer les reseaux externes si necessaire
create_networks() {
    echo -e "${YELLOW}Verification des reseaux Docker...${NC}"

    # Reseaux externes requis par les docker-compose
    # Format: "nom_reseau:subnet" (subnet optionnel)
    local networks=(
        "guacamole-net:172.20.2.0/24"
        "portal-net:172.20.1.0/24"
        "prod_apps-net:172.20.3.0/24"
        "linshare_linshare-net:172.20.4.0/24"
    )

    for net_config in "${networks[@]}"; do
        local net="${net_config%%:*}"
        local subnet="${net_config##*:}"

        if ! docker network inspect "$net" >/dev/null 2>&1; then
            echo -e "  Creation du reseau $net ($subnet)..."
            docker network create --driver bridge --subnet "$subnet" "$net"
        else
            echo -e "  ${GREEN}✓${NC} $net existe"
        fi
    done

    echo -e "${GREEN}Reseaux OK${NC}"
}

# Demarrer les backends (guacamole, linshare, credentials-api, etc.)
start_backends() {
    echo -e "${YELLOW}Demarrage des backends...${NC}"

    local PROD_DIR="$(dirname "$SCRIPT_DIR")"

    # Guacamole
    if [ -f "$PROD_DIR/guacamole/docker-compose.yml" ]; then
        echo -e "  Guacamole..."
        docker-compose -f "$PROD_DIR/guacamole/docker-compose.yml" up -d 2>/dev/null || true
    fi

    # LinShare
    if [ -f "$PROD_DIR/linshare/docker-compose.linshare.yml" ]; then
        echo -e "  LinShare..."
        docker-compose -f "$PROD_DIR/linshare/docker-compose.linshare.yml" up -d 2>/dev/null || true
    fi

    # Credentials API
    if [ -f "$PROD_DIR/credentials-api/docker-compose.yml" ]; then
        echo -e "  Credentials API..."
        docker-compose -f "$PROD_DIR/credentials-api/docker-compose.yml" up -d 2>/dev/null || true
    fi

    # Portal (si docker-compose existe)
    if [ -f "$PROD_DIR/portal/docker-compose.yml" ]; then
        echo -e "  Portal..."
        docker-compose -f "$PROD_DIR/portal/docker-compose.yml" up -d 2>/dev/null || true
    fi

    echo -e "${GREEN}Backends demarres${NC}"
}

# Arreter les backends
stop_backends() {
    echo -e "${YELLOW}Arret des backends...${NC}"

    local PROD_DIR="$(dirname "$SCRIPT_DIR")"

    # Guacamole
    if [ -f "$PROD_DIR/guacamole/docker-compose.yml" ]; then
        echo "  Arret Guacamole..."
        docker-compose -f "$PROD_DIR/guacamole/docker-compose.yml" down 2>/dev/null || true
    fi
    # LinShare
    if [ -f "$PROD_DIR/linshare/docker-compose.linshare.yml" ]; then
        echo "  Arret LinShare..."
        docker-compose -f "$PROD_DIR/linshare/docker-compose.linshare.yml" down 2>/dev/null || true
    fi
    # Credentials API
    if [ -f "$PROD_DIR/credentials-api/docker-compose.yml" ]; then
        echo "  Arret Credentials API..."
        docker-compose -f "$PROD_DIR/credentials-api/docker-compose.yml" down 2>/dev/null || true
    fi
    # Portal
    if [ -f "$PROD_DIR/portal/docker-compose.yml" ]; then
        echo "  Arret Portal..."
        docker-compose -f "$PROD_DIR/portal/docker-compose.yml" down 2>/dev/null || true
    fi

    echo -e "${GREEN}Backends arretes${NC}"
}

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --all           Redeploy complet (config + tous les services)"
    echo "  --config        Regenerer les configs depuis les templates"
    echo "  --oauth2        Redemarrer oauth2-proxy seulement"
    echo "  --nginx         Redemarrer nginx-apps seulement"
    echo "  --redis         Redemarrer redis seulement"
    echo "  --portal        Recharger les fichiers du portail (nginx reload)"
    echo "  --linshare      Demarrer/redemarrer LinShare"
    echo "  --guacamole     Demarrer/redemarrer Guacamole"
    echo "  --logs [svc]    Afficher les logs (optionnel: oauth2-proxy, nginx-apps, redis)"
    echo "  --status        Afficher le statut des services"
    echo "  --stop          Arreter tous les services"
    echo "  --start         Demarrer tous les services"
    echo "  -h, --help      Afficher cette aide"
    echo ""
    echo "Exemples:"
    echo "  $0 --config --oauth2    # Regenerer config et redemarrer oauth2-proxy"
    echo "  $0 --nginx              # Redemarrer nginx seulement"
    echo "  $0 --portal             # Recharger le portail sans redemarrer"
    echo "  $0 --linshare           # Demarrer LinShare"
    echo "  $0 --logs oauth2-proxy  # Voir les logs oauth2-proxy"
}

# Regenerer les configs depuis templates
do_config() {
    echo -e "${YELLOW}Regeneration des configurations...${NC}"

    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}Erreur: DOMAIN non defini dans .env${NC}"
        exit 1
    fi

    # Extraire le realm depuis KEYCLOAK_ISSUER
    export KEYCLOAK_REALM=$(echo "$KEYCLOAK_ISSUER" | grep -oP 'realms/\K[^/]+' || echo "unknown")
    export BUILD_DATE=$(date -Iseconds)

    # oauth2-proxy.cfg
    if [ -f templates/oauth2-proxy.cfg.template ]; then
        envsubst < templates/oauth2-proxy.cfg.template > oauth2-proxy.cfg
        echo -e "${GREEN}  oauth2-proxy.cfg genere${NC}"
    fi

    # nginx apps.conf (substituer les variables de configuration)
    if [ -f nginx/apps.conf.template ]; then
        # Extraire KEYCLOAK_HOST depuis KEYCLOAK_ISSUER si non défini
        if [ -z "$KEYCLOAK_HOST" ] && [ -n "$KEYCLOAK_ISSUER" ]; then
            export KEYCLOAK_HOST=$(echo "$KEYCLOAK_ISSUER" | sed -E 's|https?://([^/]+)/.*|\1|')
        fi
        envsubst '$DOMAIN $KEYCLOAK_HOST $KEYCLOAK_REALM $OIDC_CLIENT_ID' < nginx/apps.conf.template > nginx/apps.conf
        echo -e "${GREEN}  nginx/apps.conf genere${NC}"
    fi

    # Portal config.json
    if [ -f ../portal/www/config.json.template ]; then
        envsubst < ../portal/www/config.json.template > ../portal/www/config.json
        echo -e "${GREEN}  portal/config.json genere${NC}"
    fi

    echo -e "${GREEN}Configuration terminee${NC}"
}

# Redemarrer un service specifique
restart_service() {
    local svc=$1
    echo -e "${YELLOW}Redemarrage de $svc...${NC}"
    docker-compose restart "$svc"
    echo -e "${GREEN}$svc redemarre${NC}"
}

# Recharger nginx (pour portal)
reload_nginx() {
    echo -e "${YELLOW}Rechargement nginx...${NC}"
    docker-compose exec -T nginx-apps nginx -s reload 2>/dev/null || {
        echo -e "${YELLOW}Nginx non demarre, demarrage...${NC}"
        docker-compose up -d nginx-apps
    }
    echo -e "${GREEN}Nginx recharge${NC}"
}

# Afficher les logs
show_logs() {
    local svc=${1:-""}
    if [ -n "$svc" ]; then
        docker-compose logs -f --tail=100 "$svc"
    else
        docker-compose logs -f --tail=50
    fi
}

# Afficher le statut
show_status() {
    echo -e "${YELLOW}Statut des services:${NC}"
    docker-compose ps
    echo ""
    echo -e "${YELLOW}Sante des conteneurs:${NC}"
    docker-compose ps --format "table {{.Name}}\t{{.Status}}"
}

# Redeploy complet
do_all() {
    echo -e "${YELLOW}Redeploy complet...${NC}"
    do_config
    create_networks
    stop_backends
    echo -e "${YELLOW}Arret des services oauth2-proxy...${NC}"
    docker-compose down 2>/dev/null || true
    cleanup_containers
    start_backends
    echo -e "${YELLOW}Demarrage des services oauth2-proxy...${NC}"
    docker-compose up -d
    echo -e "${GREEN}Redeploy termine${NC}"
    show_status
}

# Parser les arguments
if [ $# -eq 0 ]; then
    usage
    exit 0
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --all)
            do_all
            ;;
        --config)
            do_config
            ;;
        --oauth2)
            restart_service oauth2-proxy
            ;;
        --nginx)
            restart_service nginx-apps
            ;;
        --redis)
            restart_service redis
            ;;
        --portal)
            reload_nginx
            ;;
        --linshare)
            local PROD_DIR="$(dirname "$SCRIPT_DIR")"
            create_networks
            if [ -f "$PROD_DIR/linshare/docker-compose.linshare.yml" ]; then
                echo -e "${YELLOW}Demarrage de LinShare...${NC}"
                docker-compose -f "$PROD_DIR/linshare/docker-compose.linshare.yml" down 2>/dev/null || true
                docker-compose -f "$PROD_DIR/linshare/docker-compose.linshare.yml" up -d
                echo -e "${GREEN}LinShare demarre${NC}"
            else
                echo -e "${RED}Erreur: docker-compose.linshare.yml non trouve${NC}"
            fi
            ;;
        --guacamole)
            local PROD_DIR="$(dirname "$SCRIPT_DIR")"
            create_networks
            if [ -f "$PROD_DIR/guacamole/docker-compose.yml" ]; then
                echo -e "${YELLOW}Demarrage de Guacamole...${NC}"
                docker-compose -f "$PROD_DIR/guacamole/docker-compose.yml" down 2>/dev/null || true
                docker-compose -f "$PROD_DIR/guacamole/docker-compose.yml" up -d
                echo -e "${GREEN}Guacamole demarre${NC}"
            else
                echo -e "${RED}Erreur: guacamole/docker-compose.yml non trouve${NC}"
            fi
            ;;
        --logs)
            shift
            show_logs "$1"
            ;;
        --status)
            show_status
            ;;
        --stop)
            echo -e "${YELLOW}Arret des services...${NC}"
            docker-compose down
            stop_backends
            echo -e "${GREEN}Services arretes${NC}"
            ;;
        --start)
            create_networks
            cleanup_containers
            start_backends
            echo -e "${YELLOW}Demarrage des services...${NC}"
            docker-compose up -d
            echo -e "${GREEN}Services demarres${NC}"
            show_status
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo -e "${RED}Option inconnue: $1${NC}"
            usage
            exit 1
            ;;
    esac
    shift
done
