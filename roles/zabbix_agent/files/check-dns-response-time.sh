#!/bin/bash
################################################################################
# Script: check-dns-response-time.sh
# Description: Mesure le temps de réponse DNS pour métriques Zabbix
# Usage: ./check-dns-response-time.sh [server] [domain]
# Return: Temps en millisecondes (format float)
################################################################################

set -o pipefail

# Paramètres
DNS_SERVER="${1:-8.8.8.8}"
DOMAIN="${2:-google.com}"

################################################################################
# Fonction: measure_dns_time
# Description: Mesure le temps de résolution DNS
# Return: Temps en ms ou -1 si erreur
################################################################################
measure_dns_time() {
    local dns_server="$1"
    local domain="$2"
    local start_time
    local end_time
    local elapsed_ms

    # Vérifier quel outil DNS est disponible
    if command -v dig &>/dev/null; then
        # Utiliser dig avec mesure de temps
        start_time=$(date +%s%N)
        if dig +short +timeout=5 "$domain" @"$dns_server" &>/dev/null; then
            end_time=$(date +%s%N)
            # Calculer différence en nanosecondes puis convertir en ms
            elapsed_ms=$(echo "scale=3; ($end_time - $start_time) / 1000000" | bc)
            echo "$elapsed_ms"
            return 0
        else
            echo "-1"
            return 1
        fi
    elif command -v nslookup &>/dev/null; then
        # Fallback sur nslookup
        start_time=$(date +%s%N)
        if nslookup -timeout=5 "$domain" "$dns_server" &>/dev/null; then
            end_time=$(date +%s%N)
            elapsed_ms=$(echo "scale=3; ($end_time - $start_time) / 1000000" | bc)
            echo "$elapsed_ms"
            return 0
        else
            echo "-1"
            return 1
        fi
    elif command -v host &>/dev/null; then
        # Fallback sur host
        start_time=$(date +%s%N)
        if host -W 5 "$domain" "$dns_server" &>/dev/null; then
            end_time=$(date +%s%N)
            elapsed_ms=$(echo "scale=3; ($end_time - $start_time) / 1000000" | bc)
            echo "$elapsed_ms"
            return 0
        else
            echo "-1"
            return 1
        fi
    else
        # Aucun outil DNS disponible
        echo "-1"
        return 1
    fi
}

################################################################################
# Main
################################################################################
main() {
    # Vérifier que bc est installé (pour calculs float)
    if ! command -v bc &>/dev/null; then
        # Fallback: utiliser date en secondes si bc n'est pas dispo
        start_time=$(date +%s)
        if command -v dig &>/dev/null && dig +short +timeout=5 "$DOMAIN" @"$DNS_SERVER" &>/dev/null; then
            end_time=$(date +%s)
            elapsed=$((end_time - start_time))
            echo "${elapsed}000"  # Convertir en ms (approximatif)
            return 0
        else
            echo "-1"
            return 1
        fi
    fi

    # Mesurer avec précision
    measure_dns_time "$DNS_SERVER" "$DOMAIN"
}

main "$@"
