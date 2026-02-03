#!/bin/bash
################################################################################
# Script: check-internet-connectivity.sh
# Description: Vérifie la connectivité Internet sans utiliser ICMP/ping
# Usage: ./check-internet-connectivity.sh [timeout]
# Return codes:
#   0 = Internet accessible
#   1 = Pas de connectivité Internet
#   2 = Erreur de configuration
################################################################################

set -o pipefail

# Configuration
TIMEOUT="${1:-5}"  # Timeout en secondes (par défaut: 5s)
VERBOSE="${VERBOSE:-0}"  # Mode verbeux si VERBOSE=1

# Endpoints publics fiables à tester
# On utilise plusieurs endpoints pour éviter les faux positifs
declare -a ENDPOINTS=(
    "https://www.cloudflare.com/cdn-cgi/trace"
    "https://dns.google/resolve?name=google.com&type=A"
    "https://1.1.1.1"
    "http://detectportal.firefox.com/success.txt"
)

# Compteurs
TOTAL_ENDPOINTS=${#ENDPOINTS[@]}
SUCCESS_COUNT=0
REQUIRED_SUCCESS=2  # Au moins 2 endpoints doivent répondre

# Couleurs pour output (si terminal supporté)
if [ -t 1 ] && command -v tput &>/dev/null; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    RESET=$(tput sgr0)
else
    RED=""
    GREEN=""
    YELLOW=""
    RESET=""
fi

################################################################################
# Fonction: log
# Description: Affiche un message si mode verbeux activé
################################################################################
log() {
    if [ "$VERBOSE" = "1" ]; then
        echo "$@" >&2
    fi
}

################################################################################
# Fonction: check_endpoint
# Description: Vérifie un endpoint HTTP/HTTPS
# Arguments:
#   $1 - URL de l'endpoint
# Return:
#   0 = Success
#   1 = Failure
################################################################################
check_endpoint() {
    local url="$1"
    local http_code

    log "Vérification: $url"

    # Utiliser curl avec timeout et suivre les redirections
    if http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                        --connect-timeout "$TIMEOUT" \
                        --max-time $((TIMEOUT + 2)) \
                        -L \
                        "$url" 2>/dev/null); then

        # Vérifier que le code HTTP est dans la plage 200-399
        if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 400 ]; then
            log "${GREEN}✓${RESET} $url - HTTP $http_code"
            return 0
        else
            log "${YELLOW}⚠${RESET} $url - HTTP $http_code (non-OK)"
            return 1
        fi
    else
        log "${RED}✗${RESET} $url - Échec connexion"
        return 1
    fi
}

################################################################################
# Fonction: check_dns
# Description: Vérifie la résolution DNS (alternative)
# Return:
#   0 = DNS fonctionne
#   1 = DNS ne fonctionne pas
################################################################################
check_dns() {
    log "Vérification DNS..."

    if command -v dig &>/dev/null; then
        if dig +short +timeout="$TIMEOUT" google.com @8.8.8.8 &>/dev/null; then
            log "${GREEN}✓${RESET} DNS - Résolution OK"
            return 0
        fi
    elif command -v nslookup &>/dev/null; then
        if nslookup -timeout="$TIMEOUT" google.com 8.8.8.8 &>/dev/null; then
            log "${GREEN}✓${RESET} DNS - Résolution OK"
            return 0
        fi
    fi

    log "${RED}✗${RESET} DNS - Échec résolution"
    return 1
}

################################################################################
# Fonction: main
# Description: Fonction principale
################################################################################
main() {
    # Vérifier que curl est installé
    if ! command -v curl &>/dev/null; then
        echo "${RED}ERREUR:${RESET} curl n'est pas installé" >&2
        exit 2
    fi

    log "Démarrage vérification connectivité Internet..."
    log "Timeout: ${TIMEOUT}s, Endpoints: $TOTAL_ENDPOINTS, Requis: $REQUIRED_SUCCESS"
    log ""

    # Tester TOUS les endpoints (pas d'early-exit) pour collecter les métriques
    for endpoint in "${ENDPOINTS[@]}"; do
        if check_endpoint "$endpoint"; then
            ((SUCCESS_COUNT++))
        fi
    done

    log ""
    log "Résultat: $SUCCESS_COUNT/$TOTAL_ENDPOINTS endpoints accessibles"

    # Vérifier si on a atteint le seuil minimum
    if [ "$SUCCESS_COUNT" -ge "$REQUIRED_SUCCESS" ]; then
        log "${GREEN}✓ Connectivité Internet: OK${RESET}"
        echo "1"  # Retour pour Zabbix (1 = OK)
        return 0
    else
        # Si aucun endpoint HTTP ne répond, tester DNS en dernier recours
        if [ "$SUCCESS_COUNT" -eq 0 ]; then
            log "${YELLOW}Aucun endpoint HTTP accessible, test DNS...${RESET}"
            if check_dns; then
                log "${YELLOW}⚠ DNS OK mais pas HTTP - Connectivité partielle${RESET}"
                echo "0.5"  # Connectivité partielle
                return 0
            fi
        fi

        log "${RED}✗ Connectivité Internet: ÉCHEC${RESET}"
        echo "0"  # Retour pour Zabbix (0 = KO)
        return 1
    fi
}

# Point d'entrée
main "$@"
