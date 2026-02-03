#!/bin/bash
################################################################################
# Script: check-http-response-time.sh
# Description: Mesure le temps de réponse HTTP pour métriques Zabbix
# Usage: ./check-http-response-time.sh <url> [timeout]
# Return: Temps total en millisecondes (format float) ou -1 si erreur
################################################################################

set -o pipefail

# Paramètres
URL="$1"
TIMEOUT="${2:-5}"

################################################################################
# Fonction: measure_http_time
# Description: Mesure le temps de réponse HTTP avec curl
# Return: Temps en ms ou -1 si erreur
################################################################################
measure_http_time() {
    local url="$1"
    local timeout="$2"
    local time_total

    # Vérifier que curl est installé
    if ! command -v curl &>/dev/null; then
        echo "-1"
        return 1
    fi

    # Mesurer avec curl (time_total en secondes avec 3 décimales)
    time_total=$(curl -s -o /dev/null \
                      -w "%{time_total}" \
                      --connect-timeout "$timeout" \
                      --max-time "$((timeout + 2))" \
                      -L \
                      "$url" 2>/dev/null)

    local exit_code=$?

    # Vérifier si curl a réussi
    if [ $exit_code -eq 0 ] && [ -n "$time_total" ]; then
        # Convertir en millisecondes (multiplier par 1000)
        if command -v bc &>/dev/null; then
            echo "scale=3; $time_total * 1000" | bc
        else
            # Fallback sans bc (approximatif)
            echo "$time_total" | awk '{printf "%.0f", $1 * 1000}'
        fi
        return 0
    else
        echo "-1"
        return 1
    fi
}

################################################################################
# Main
################################################################################
main() {
    # Vérifier que l'URL est fournie
    if [ -z "$URL" ]; then
        echo "-1"
        return 1
    fi

    measure_http_time "$URL" "$TIMEOUT"
}

main "$@"
