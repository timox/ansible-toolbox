#!/bin/bash
# Script de configuration dynamique Guacamole

set -euo pipefail

echo " Configuration Guacamole Web Application"

# Import certificat CA dans le truststore Java (pour OIDC HTTPS)
CA_CERT_FILE="/certs/ca.crt"
if [ -f "$CA_CERT_FILE" ]; then
    echo "🔐 Import certificat CA dans truststore Java..."
    # Trouver le truststore Java
    JAVA_HOME=${JAVA_HOME:-$(dirname $(dirname $(readlink -f $(which java))))}
    TRUSTSTORE="$JAVA_HOME/lib/security/cacerts"
    if [ -f "$TRUSTSTORE" ]; then
        # Supprimer l'ancien certificat s'il existe
        keytool -delete -alias poc-ca -keystore "$TRUSTSTORE" -storepass changeit 2>/dev/null || true
        # Importer le nouveau
        keytool -import -trustcacerts -alias poc-ca -file "$CA_CERT_FILE" -keystore "$TRUSTSTORE" -storepass changeit -noprompt
        echo "✅ Certificat CA importé"
    else
        echo "⚠️  Truststore Java non trouvé: $TRUSTSTORE"
    fi
else
    echo "⚠️  Certificat CA non trouvé: $CA_CERT_FILE (OIDC HTTPS peut échouer)"
fi

# Attendre PostgreSQL
echo "⏳ Attente PostgreSQL..."
while ! nc -z ${POSTGRES_HOSTNAME} 5432; do
    sleep 1
done
echo " PostgreSQL disponible"

# Synchronisation des extensions nécessaires
TARGET_EXT_DIR="${GUACAMOLE_HOME}/extensions"
DEFAULT_EXT_DIR="${GUACAMOLE_HOME}/defaults/extensions"
EXTRA_EXT_DIR="${GUACAMOLE_HOME}/extensions-extra"

mkdir -p "${TARGET_EXT_DIR}" "${GUACAMOLE_HOME}/lib"

sync_extension_dir() {
    local source_dir="$1"
    local label="$2"

    if [ ! -d "$source_dir" ]; then
        return
    fi

    shopt -s nullglob
    for jar in "$source_dir"/*.jar; do
        local dest="${TARGET_EXT_DIR}/$(basename "${jar}")"
        if [ ! -f "$dest" ] || ! cmp -s "$jar" "$dest"; then
            cp -f "$jar" "$dest"
            echo "   → Extension ${label}: $(basename "$jar") copiée"
        fi
    done
    shopt -u nullglob
}

sync_extension_dir "$DEFAULT_EXT_DIR" "de base"
sync_extension_dir "$EXTRA_EXT_DIR" "supplémentaire"

if ! ls "${TARGET_EXT_DIR}"/*.jar >/dev/null 2>&1; then
    echo "ERREUR: aucune extension Guacamole détectée dans ${TARGET_EXT_DIR}."
    echo "        Vérifiez les volumes montés ou fournissez l'extension JDBC."
    exit 1
fi

# Configuration guacamole.properties
# Normalisation des variables d'environnement:
# - Accepte POSTGRES_* (standard postgres:15-alpine) ou POSTGRESQL_* (alternative)
# - Normalise vers POSTGRESQL_* pour génération du fichier guacamole.properties
# Note: guacamole.properties requiert le format "postgresql-*" (avec trait d'union)
POSTGRESQL_HOSTNAME="${POSTGRESQL_HOSTNAME:-${POSTGRES_HOSTNAME}}"
POSTGRESQL_DATABASE="${POSTGRESQL_DATABASE:-${POSTGRES_DATABASE}}"
POSTGRESQL_USERNAME="${POSTGRESQL_USERNAME:-${POSTGRES_USER}}"
POSTGRESQL_PASSWORD="${POSTGRESQL_PASSWORD:-${POSTGRES_PASSWORD}}"

# Vérifier si le fichier guacamole.properties existe et est accessible en écriture
if [ -f "${GUACAMOLE_HOME}/guacamole.properties" ] && [ ! -w "${GUACAMOLE_HOME}/guacamole.properties" ]; then
    echo " Configuration guacamole.properties existe et est en lecture seule (configuré par deploy.sh)"
else
    echo " Génération guacamole.properties..."
    cat > ${GUACAMOLE_HOME}/guacamole.properties << EOF
# PostgreSQL configuration
postgresql-hostname: ${POSTGRESQL_HOSTNAME}
postgresql-port: 5432
postgresql-database: ${POSTGRESQL_DATABASE}
postgresql-username: ${POSTGRESQL_USERNAME}
postgresql-password: ${POSTGRESQL_PASSWORD}

# Guacd configuration
guacd-hostname: ${GUACD_HOSTNAME}
guacd-port: 4822

# Recording configuration
recording-search-path: /record

# Performance tuning
postgresql-max-connections: 20
postgresql-max-connections-per-user: 4

# Security
skip-if-unavailable: postgresql

# Logging
log-level: INFO
EOF
fi

# Vérification configuration
echo " Configuration:"
echo "   - Guacd: ${GUACD_HOSTNAME}:4822"
echo "   - PostgreSQL: ${POSTGRESQL_HOSTNAME}:5432"
echo "   - Database: ${POSTGRESQL_DATABASE}"
echo "   - User: ${POSTGRESQL_USERNAME}"
echo "   - Java Opts: ${JAVA_OPTS:-default}"

# Synchronisation des librairies d'extensions
EXTENSION_LIB_SOURCE="${GUACAMOLE_HOME}/extension-libs"
if [ -d "${EXTENSION_LIB_SOURCE}" ]; then
    echo " Synchronisation des dépendances d'extension..."
    shopt -s nullglob
    for jar in "${EXTENSION_LIB_SOURCE}"/*.jar; do
        dest="${GUACAMOLE_HOME}/lib/$(basename "${jar}")"
        if [ ! -f "${dest}" ] || ! cmp -s "${jar}" "${dest}"; then
            cp -f "${jar}" "${dest}"
        fi
    done
    shopt -u nullglob
fi

# Initialisation DB si nécessaire - vérifier si le schéma Guacamole existe
echo "🔍 Vérification du schéma Guacamole..."
SCHEMA_EXISTS=$(PGPASSWORD="${POSTGRESQL_PASSWORD}" psql -h "${POSTGRESQL_HOSTNAME}" -U "${POSTGRESQL_USERNAME}" -d "${POSTGRESQL_DATABASE}" -tAc \
    "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'guacamole_entity');" 2>/dev/null || echo "f")

if [ "$SCHEMA_EXISTS" != "t" ]; then
    echo "⚠️  Schéma Guacamole absent - Initialisation..."

    # Utiliser le schéma inclus dans l'image
    SCHEMA_DIR="${GUACAMOLE_HOME}/schema"
    if [ -d "$SCHEMA_DIR" ] && ls "$SCHEMA_DIR"/*.sql >/dev/null 2>&1; then
        echo "📝 Application du schéma depuis $SCHEMA_DIR..."
        for sql_file in "$SCHEMA_DIR"/*.sql; do
            echo "   → $(basename "$sql_file")"
            if ! PGPASSWORD="${POSTGRESQL_PASSWORD}" psql -h "${POSTGRESQL_HOSTNAME}" -U "${POSTGRESQL_USERNAME}" -d "${POSTGRESQL_DATABASE}" -f "$sql_file" 2>&1; then
                echo "❌ ERREUR lors de l'exécution de $(basename "$sql_file")"
                echo "   Vérifiez les logs ci-dessus pour plus de détails"
                exit 1
            fi
        done
        echo "✅ Schéma Guacamole initialisé"
    else
        echo "❌ ERREUR: Fichiers SQL non trouvés dans $SCHEMA_DIR"
        ls -la "$SCHEMA_DIR" 2>/dev/null || echo "   Le répertoire $SCHEMA_DIR n'existe pas"
        exit 1
    fi
else
    echo "✅ Schéma Guacamole présent"
fi

echo " Démarrage Tomcat..."
exec "$@"