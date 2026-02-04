#!/bin/bash
# Script optimisé de démarrage guacd
# Supporte l'isolation des lecteurs réseau par utilisateur

set -euo pipefail

# Vérification binaires
if [ ! -x "/opt/guacamole/sbin/guacd" ]; then
    echo "ERREUR: guacd non trouvé ou non exécutable"
    exit 1
fi

# Mise à jour des certificats CA (pour RDS Gateway, etc.)
if [ -d "/usr/local/share/ca-certificates/custom" ] && [ "$(ls -A /usr/local/share/ca-certificates/custom/*.crt 2>/dev/null)" ]; then
    echo " Mise à jour des certificats CA..."
    update-ca-certificates --fresh 2>/dev/null || true
    echo "   - Certificats CA installés depuis /usr/local/share/ca-certificates/custom/"
fi

# Configuration runtime
export GUACD_LOG_LEVEL="${GUACD_LOG_LEVEL:-info}"
PID_FILE="${GUACD_PID_FILE:-/run/guacd/guacd.pid}"
PID_DIR="$(dirname "${PID_FILE}")"

# Configuration des lecteurs réseau
DRIVE_BASE_PATH="${GUACD_DRIVE_PATH:-/drive}"
RECORD_BASE_PATH="${GUACD_RECORD_PATH:-/record}"

# Initialisation des répertoires de stockage
init_storage_directories() {
    echo " Initialisation des répertoires de stockage..."

    # Créer les répertoires de base s'ils n'existent pas
    for dir in "${DRIVE_BASE_PATH}" "${RECORD_BASE_PATH}"; do
        if [ ! -d "${dir}" ]; then
            echo "   Création de ${dir}"
            mkdir -p "${dir}"
        fi

        # S'assurer que guacd peut écrire (pour create-drive-path)
        if [ "$(id -u)" -eq 0 ]; then
            chown guacd:guacd "${dir}"
            chmod 755 "${dir}"
        fi
    done

    # Mode isolation par utilisateur activé
    # Les sous-répertoires /drive/${GUAC_USERNAME} sont créés automatiquement
    # par guacd quand create-drive-path=true dans la connexion RDP
    echo "   Mode isolation utilisateur: les lecteurs seront créés dans ${DRIVE_BASE_PATH}/\${GUAC_USERNAME}"
}

if [ "$(id -u)" -eq 0 ]; then
    install -d -m 755 -o guacd -g guacd "${PID_DIR}"
    init_storage_directories
else
    mkdir -p "${PID_DIR}"
fi

# S'assurer que le répertoire PID est accessible
if [ ! -w "${PID_DIR}" ]; then
    echo "ERREUR: Répertoire PID (${PID_DIR}) inaccessible"
    exit 1
fi

# Optimisations performances
ulimit -n 65536
ulimit -u 32768

echo " Démarrage Guacamole Daemon optimisé"
echo "   - Version FreeRDP: $(pkg-config --modversion freerdp2 2>/dev/null || echo 'Custom build')"
echo "   - PID file: ${PID_FILE}"
echo "   - Log level: ${GUACD_LOG_LEVEL}"
echo "   - Ulimits: $(ulimit -n) files, $(ulimit -u) processes"

# Nettoyage PID existant
if [ -e "${PID_FILE}" ] && ! rm -f "${PID_FILE}" 2>/dev/null; then
    echo "AVERTISSEMENT: impossible de supprimer l'ancien PID (${PID_FILE})"
fi

GUACD_ARGS=(
    -b 0.0.0.0
    -l 4822
    -L "${GUACD_LOG_LEVEL}"
    -p "${PID_FILE}"
    -f
)

if [ "$(id -u)" -eq 0 ]; then
    exec su -s /bin/sh -c "exec /opt/guacamole/sbin/guacd ${GUACD_ARGS[*]}" guacd
else
    exec /opt/guacamole/sbin/guacd "${GUACD_ARGS[@]}"
fi
