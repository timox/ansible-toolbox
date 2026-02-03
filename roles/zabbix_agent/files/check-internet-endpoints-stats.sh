#!/bin/bash
################################################################################
# Script: check-internet-endpoints-stats.sh
# Description: Collecte les statistiques détaillées sur tous les endpoints
# Usage: ./check-internet-endpoints-stats.sh [timeout]
# Return: JSON avec statistiques complètes
################################################################################

set -o pipefail

# Configuration
TIMEOUT="${1:-5}"

# Endpoints publics fiables à tester
declare -a ENDPOINTS=(
    "https://www.cloudflare.com/cdn-cgi/trace"
    "https://dns.google/resolve?name=google.com&type=A"
    "https://1.1.1.1"
    "http://detectportal.firefox.com/success.txt"
)

# Compteurs
TOTAL_ENDPOINTS=${#ENDPOINTS[@]}
SUCCESS_COUNT=0
FAILED_COUNT=0
declare -A RESPONSE_TIMES
declare -A HTTP_CODES

################################################################################
# Fonction: test_endpoint_with_metrics
# Description: Teste un endpoint et collecte les métriques
# Arguments:
#   $1 - URL de l'endpoint
# Return: 0 = Success, 1 = Failure
################################################################################
test_endpoint_with_metrics() {
    local url="$1"
    local http_code
    local time_total

    # Mesurer temps de réponse avec curl
    local curl_output
    curl_output=$(curl -s -o /dev/null \
                       -w "%{http_code}|%{time_total}" \
                       --connect-timeout "$TIMEOUT" \
                       --max-time $((TIMEOUT + 2)) \
                       -L \
                       "$url" 2>/dev/null)

    local exit_code=$?

    if [ $exit_code -eq 0 ] && [ -n "$curl_output" ]; then
        http_code=$(echo "$curl_output" | cut -d'|' -f1)
        time_total=$(echo "$curl_output" | cut -d'|' -f2)

        # Stocker les métriques
        HTTP_CODES["$url"]="$http_code"
        RESPONSE_TIMES["$url"]="$time_total"

        # Vérifier code HTTP 2xx ou 3xx
        if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 400 ]; then
            return 0
        else
            return 1
        fi
    else
        HTTP_CODES["$url"]="0"
        RESPONSE_TIMES["$url"]="-1"
        return 1
    fi
}

################################################################################
# Fonction: output_json
# Description: Génère sortie JSON avec toutes les métriques
################################################################################
output_json() {
    echo "{"
    echo "  \"total_endpoints\": $TOTAL_ENDPOINTS,"
    echo "  \"successful\": $SUCCESS_COUNT,"
    echo "  \"failed\": $FAILED_COUNT,"
    echo "  \"success_rate\": $(echo "scale=2; ($SUCCESS_COUNT * 100) / $TOTAL_ENDPOINTS" | bc 2>/dev/null || echo "0"),"
    echo "  \"endpoints\": ["

    local first=1
    for endpoint in "${ENDPOINTS[@]}"; do
        if [ $first -eq 0 ]; then
            echo ","
        fi
        first=0

        local http_code="${HTTP_CODES[$endpoint]:-0}"
        local response_time="${RESPONSE_TIMES[$endpoint]:--1}"
        local status="failed"

        if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 400 ]; then
            status="ok"
        fi

        echo "    {"
        echo "      \"url\": \"$endpoint\","
        echo "      \"status\": \"$status\","
        echo "      \"http_code\": $http_code,"
        echo "      \"response_time_sec\": $response_time"
        echo -n "    }"
    done

    echo ""
    echo "  ]"
    echo "}"
}

################################################################################
# Fonction: output_simple
# Description: Génère sortie simple pour UserParameter
# Arguments:
#   $1 - Métrique demandée (successful|failed|success_rate)
################################################################################
output_simple() {
    local metric="$1"

    case "$metric" in
        successful)
            echo "$SUCCESS_COUNT"
            ;;
        failed)
            echo "$FAILED_COUNT"
            ;;
        success_rate)
            if command -v bc &>/dev/null; then
                echo "scale=2; ($SUCCESS_COUNT * 100) / $TOTAL_ENDPOINTS" | bc
            else
                echo "$(( (SUCCESS_COUNT * 100) / TOTAL_ENDPOINTS ))"
            fi
            ;;
        *)
            echo "0"
            ;;
    esac
}

################################################################################
# Main
################################################################################
main() {
    # Vérifier curl
    if ! command -v curl &>/dev/null; then
        if [ "${OUTPUT_FORMAT:-json}" = "json" ]; then
            echo '{"error": "curl not installed"}'
        else
            echo "-1"
        fi
        exit 2
    fi

    # Tester tous les endpoints
    for endpoint in "${ENDPOINTS[@]}"; do
        if test_endpoint_with_metrics "$endpoint"; then
            ((SUCCESS_COUNT++))
        else
            ((FAILED_COUNT++))
        fi
    done

    # Générer sortie selon format demandé
    if [ "${OUTPUT_FORMAT:-json}" = "json" ]; then
        output_json
    else
        # Format simple pour UserParameter
        output_simple "${METRIC_NAME:-successful}"
    fi
}

main "$@"
