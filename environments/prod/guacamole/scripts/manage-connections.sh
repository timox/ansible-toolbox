#!/bin/bash
# =============================================================================
# GESTION DES CONNEXIONS GUACAMOLE VIA POSTGRESQL
# =============================================================================
# Usage:
#   ./manage-connections.sh list                    - Lister les connexions
#   ./manage-connections.sh show <id>               - Voir les paramètres
#   ./manage-connections.sh create-rdp <name> <host> [user] [pass]
#   ./manage-connections.sh enable-drive <id>       - Activer drive isolation
#   ./manage-connections.sh set-param <id> <name> <value>
#   ./manage-connections.sh delete <id>             - Supprimer connexion
# =============================================================================

set -e

DB_CONTAINER="guacamole-postgres"
DB_USER="guacamole_user"
DB_NAME="guacamole_db"

psql_exec() {
    docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -t -A -c "$1"
}

psql_query() {
    docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c "$1"
}

case "${1:-help}" in
    list)
        echo "=== Connexions Guacamole ==="
        psql_query "
            SELECT
                c.connection_id AS id,
                c.connection_name AS name,
                c.protocol,
                (SELECT parameter_value FROM guacamole_connection_parameter
                 WHERE connection_id = c.connection_id AND parameter_name = 'hostname') AS host,
                (SELECT parameter_value FROM guacamole_connection_parameter
                 WHERE connection_id = c.connection_id AND parameter_name = 'enable-drive') AS drive
            FROM guacamole_connection c
            ORDER BY c.connection_name;
        "
        ;;

    show)
        if [ -z "$2" ]; then
            echo "Usage: $0 show <connection_id>"
            exit 1
        fi
        echo "=== Paramètres connexion ID $2 ==="
        psql_query "
            SELECT parameter_name, parameter_value
            FROM guacamole_connection_parameter
            WHERE connection_id = $2
            ORDER BY parameter_name;
        "
        ;;

    create-rdp)
        NAME="${2:?Nom requis}"
        HOST="${3:?Hostname requis}"
        USER="${4:-}"
        PASS="${5:-}"

        echo "Création connexion RDP: $NAME -> $HOST"

        # Créer la connexion
        CONN_ID=$(psql_exec "
            INSERT INTO guacamole_connection (connection_name, protocol)
            VALUES ('$NAME', 'rdp')
            RETURNING connection_id;
        ")

        echo "Connexion créée avec ID: $CONN_ID"

        # Paramètres de base
        psql_exec "
            INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value) VALUES
            ($CONN_ID, 'hostname', '$HOST'),
            ($CONN_ID, 'port', '3389'),
            ($CONN_ID, 'security', 'any'),
            ($CONN_ID, 'ignore-cert', 'true'),
            ($CONN_ID, 'enable-drive', 'true'),
            ($CONN_ID, 'drive-path', '/drive/\${GUAC_USERNAME}'),
            ($CONN_ID, 'drive-name', 'Guacamole'),
            ($CONN_ID, 'create-drive-path', 'true');
        "

        # Credentials si fournis
        if [ -n "$USER" ]; then
            psql_exec "INSERT INTO guacamole_connection_parameter VALUES ($CONN_ID, 'username', '$USER');"
        fi
        if [ -n "$PASS" ]; then
            psql_exec "INSERT INTO guacamole_connection_parameter VALUES ($CONN_ID, 'password', '$PASS');"
        fi

        echo "Connexion RDP '$NAME' créée avec drive isolation activé"
        ;;

    enable-drive)
        CONN_ID="${2:?ID connexion requis}"

        echo "Activation drive isolation pour connexion $CONN_ID..."

        psql_exec "
            INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
            VALUES
                ($CONN_ID, 'enable-drive', 'true'),
                ($CONN_ID, 'drive-path', '/drive/\${GUAC_USERNAME}'),
                ($CONN_ID, 'drive-name', 'Guacamole'),
                ($CONN_ID, 'create-drive-path', 'true')
            ON CONFLICT (connection_id, parameter_name)
            DO UPDATE SET parameter_value = EXCLUDED.parameter_value;
        "

        echo "Drive isolation activé pour connexion $CONN_ID"
        ;;

    set-param)
        CONN_ID="${2:?ID connexion requis}"
        PARAM_NAME="${3:?Nom paramètre requis}"
        PARAM_VALUE="${4:?Valeur requise}"

        psql_exec "
            INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
            VALUES ($CONN_ID, '$PARAM_NAME', '$PARAM_VALUE')
            ON CONFLICT (connection_id, parameter_name)
            DO UPDATE SET parameter_value = EXCLUDED.parameter_value;
        "

        echo "Paramètre '$PARAM_NAME' = '$PARAM_VALUE' pour connexion $CONN_ID"
        ;;

    delete)
        CONN_ID="${2:?ID connexion requis}"

        NAME=$(psql_exec "SELECT connection_name FROM guacamole_connection WHERE connection_id = $CONN_ID;")

        if [ -z "$NAME" ]; then
            echo "Connexion $CONN_ID non trouvée"
            exit 1
        fi

        read -p "Supprimer connexion '$NAME' (ID $CONN_ID) ? [y/N] " confirm
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            psql_exec "DELETE FROM guacamole_connection WHERE connection_id = $CONN_ID;"
            echo "Connexion '$NAME' supprimée"
        else
            echo "Annulé"
        fi
        ;;

    users)
        echo "=== Utilisateurs Guacamole ==="
        psql_query "
            SELECT
                e.entity_id,
                u.user_id,
                e.name AS username,
                u.disabled,
                u.expired
            FROM guacamole_user u
            JOIN guacamole_entity e ON u.entity_id = e.entity_id
            ORDER BY e.name;
        "
        ;;

    grant)
        CONN_ID="${2:?ID connexion requis}"
        USERNAME="${3:?Username requis}"

        ENTITY_ID=$(psql_exec "SELECT entity_id FROM guacamole_entity WHERE name = '$USERNAME' AND type = 'USER';")

        if [ -z "$ENTITY_ID" ]; then
            echo "Utilisateur '$USERNAME' non trouvé"
            exit 1
        fi

        psql_exec "
            INSERT INTO guacamole_connection_permission (entity_id, connection_id, permission)
            VALUES ($ENTITY_ID, $CONN_ID, 'READ')
            ON CONFLICT DO NOTHING;
        "

        echo "Accès accordé à '$USERNAME' pour connexion $CONN_ID"
        ;;

    help|*)
        echo "Usage: $0 <command> [options]"
        echo ""
        echo "Commands:"
        echo "  list                          - Lister toutes les connexions"
        echo "  show <id>                     - Voir les paramètres d'une connexion"
        echo "  create-rdp <name> <host> [user] [pass] - Créer connexion RDP avec drive"
        echo "  enable-drive <id>             - Activer drive isolation"
        echo "  set-param <id> <name> <value> - Définir un paramètre"
        echo "  delete <id>                   - Supprimer une connexion"
        echo "  users                         - Lister les utilisateurs"
        echo "  grant <conn_id> <username>    - Accorder accès à un utilisateur"
        echo ""
        echo "Paramètres drive disponibles:"
        echo "  enable-drive       - true/false"
        echo "  drive-path         - /drive/\${GUAC_USERNAME} (isolation par user)"
        echo "  drive-name         - Nom affiché dans Windows"
        echo "  create-drive-path  - true/false"
        echo "  disable-download   - true/false"
        echo "  disable-upload     - true/false"
        ;;
esac
