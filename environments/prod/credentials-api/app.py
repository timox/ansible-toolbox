#!/usr/bin/env python3
"""
API de gestion des credentials pour Guacamole
Stocke les mots de passe chiffres en AES-256
Supporte plusieurs credentials par utilisateur (un par connexion)
"""

import os
import sys
import base64
import hashlib
import secrets
import logging
from datetime import datetime, timedelta
from functools import wraps

from flask import Flask, request, jsonify
import requests as http_requests

# Configuration logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    stream=sys.stdout
)
logger = logging.getLogger(__name__)
from flask_cors import CORS
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.backends import default_backend
import psycopg2
from psycopg2.extras import RealDictCursor

app = Flask(__name__)
CORS(app, origins=['*'], supports_credentials=True)

# Configuration
DB_HOST = os.environ.get('DB_HOST', 'guacamole-postgres')
DB_PORT = os.environ.get('DB_PORT', '5432')
DB_NAME = os.environ.get('DB_NAME', 'guacamole_db')
DB_USER = os.environ.get('DB_USER', 'guacamole_user')
DB_PASS = os.environ.get('DB_PASS', 'touktouk')

# Cle de chiffrement (32 bytes pour AES-256)
ENCRYPTION_KEY = os.environ.get('ENCRYPTION_KEY', 'ChangezCetteCleEnProduction!!')
ENCRYPTION_KEY = hashlib.sha256(ENCRYPTION_KEY.encode()).digest()

# Duree de validite des credentials (heures)
CREDENTIALS_EXPIRY_HOURS = int(os.environ.get('CREDENTIALS_EXPIRY_HOURS', '8'))

# Configuration Keycloak pour API clients
KEYCLOAK_URL = os.environ.get('KEYCLOAK_URL', '')  # Ex: https://kc.example.com
KEYCLOAK_AUTH_REALM = os.environ.get('KEYCLOAK_AUTH_REALM', 'master')  # Realm pour auth service account
KEYCLOAK_REALMS = [r.strip() for r in os.environ.get('KEYCLOAK_REALMS', 'oidc').split(',') if r.strip()]  # Realms a interroger
KEYCLOAK_SERVICE_CLIENT_ID = os.environ.get('KEYCLOAK_SERVICE_CLIENT_ID', 'portal-api')
KEYCLOAK_SERVICE_CLIENT_SECRET = os.environ.get('KEYCLOAK_SERVICE_CLIENT_SECRET', '')

# Cache token service account (eviter appels repetitifs)
_keycloak_token_cache = {'token': None, 'expires_at': None}


def get_db_connection():
    """Connexion a la base PostgreSQL"""
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASS,
        cursor_factory=RealDictCursor
    )


def encrypt_password(password: str) -> tuple:
    """Chiffre un mot de passe avec AES-256-CBC"""
    iv = secrets.token_bytes(16)
    cipher = Cipher(algorithms.AES(ENCRYPTION_KEY), modes.CBC(iv), backend=default_backend())
    encryptor = cipher.encryptor()

    # Padding PKCS7
    block_size = 16
    padding_length = block_size - (len(password) % block_size)
    padded_password = password + chr(padding_length) * padding_length

    encrypted = encryptor.update(padded_password.encode()) + encryptor.finalize()

    return base64.b64encode(encrypted).decode(), base64.b64encode(iv).decode()


def decrypt_password(encrypted_password: str, iv: str) -> str:
    """Dechiffre un mot de passe"""
    encrypted_data = base64.b64decode(encrypted_password)
    iv_bytes = base64.b64decode(iv)

    cipher = Cipher(algorithms.AES(ENCRYPTION_KEY), modes.CBC(iv_bytes), backend=default_backend())
    decryptor = cipher.decryptor()

    decrypted_padded = decryptor.update(encrypted_data) + decryptor.finalize()

    # Remove PKCS7 padding
    padding_length = decrypted_padded[-1]
    decrypted = decrypted_padded[:-padding_length]

    return decrypted.decode()


def verify_user_header(f):
    """Decorator pour verifier le header X-Forwarded-User"""
    @wraps(f)
    def decorated(*args, **kwargs):
        # Le username vient de oauth2-proxy via nginx
        username = request.headers.get('X-Forwarded-Preferred-Username') or \
                   request.headers.get('X-Forwarded-User') or \
                   request.headers.get('X-Forwarded-Email', '').split('@')[0]

        if not username:
            return jsonify({'error': 'Non authentifie'}), 401

        request.username = username
        return f(*args, **kwargs)
    return decorated


@app.route('/health', methods=['GET'])
def health():
    """Health check"""
    return jsonify({'status': 'ok'})


# ============================================
# API KEYCLOAK CLIENTS
# ============================================

def get_keycloak_service_token():
    """Obtient un token service account pour l'API Admin Keycloak"""
    global _keycloak_token_cache

    # Verifier cache
    if _keycloak_token_cache['token'] and _keycloak_token_cache['expires_at']:
        if datetime.now() < _keycloak_token_cache['expires_at']:
            return _keycloak_token_cache['token']

    if not KEYCLOAK_URL or not KEYCLOAK_SERVICE_CLIENT_SECRET:
        logger.warning("Keycloak service account non configure")
        return None

    try:
        # Authentification via le realm master (ou auth_realm configure)
        token_url = f"{KEYCLOAK_URL}/realms/{KEYCLOAK_AUTH_REALM}/protocol/openid-connect/token"
        response = http_requests.post(
            token_url,
            data={
                'grant_type': 'client_credentials',
                'client_id': KEYCLOAK_SERVICE_CLIENT_ID,
                'client_secret': KEYCLOAK_SERVICE_CLIENT_SECRET
            },
            timeout=10
        )
        response.raise_for_status()
        data = response.json()

        # Mettre en cache avec marge de securite
        expires_in = data.get('expires_in', 300) - 30
        _keycloak_token_cache['token'] = data['access_token']
        _keycloak_token_cache['expires_at'] = datetime.now() + timedelta(seconds=expires_in)

        logger.info(f"Token service account Keycloak obtenu (realm: {KEYCLOAK_AUTH_REALM})")
        return data['access_token']

    except Exception as e:
        logger.error(f"Erreur obtention token Keycloak: {e}")
        return None


@app.route('/api/keycloak/clients', methods=['GET'])
@verify_user_header
def get_keycloak_clients():
    """Liste les clients Keycloak marques portal.visible=true depuis tous les realms configures"""
    token = get_keycloak_service_token()
    if not token:
        return jsonify({'error': 'Keycloak API non configure'}), 503

    portal_apps = []
    errors = []

    # Interroger chaque realm configure
    for realm in KEYCLOAK_REALMS:
        try:
            clients_url = f"{KEYCLOAK_URL}/admin/realms/{realm}/clients"
            response = http_requests.get(
                clients_url,
                headers={'Authorization': f'Bearer {token}'},
                timeout=10
            )
            response.raise_for_status()
            clients = response.json()

            # Filtrer et formater pour le portail
            for client in clients:
                attrs = client.get('attributes', {})

                # Seulement les clients marques visibles dans le portail
                if attrs.get('portal.visible') != 'true':
                    continue

                # Construire l'app pour le portail
                app_data = {
                    'id': client['clientId'],
                    'name': client.get('name') or client['clientId'],
                    'description': client.get('description', ''),
                    'icon': attrs.get('portal.icon', client['clientId'][0].upper()),
                    'url': client.get('baseUrl', ''),
                    'groups': [g.strip() for g in attrs.get('portal.groups', '').split(',') if g.strip()] or ['tous'],
                    'order': int(attrs.get('portal.order', '99')),
                    'realm': realm,  # Indiquer le realm source
                    'oidc': {
                        'enabled': True,
                        'realm': realm,
                        'clientId': client['clientId'],
                        'redirectUri': client.get('baseUrl', ''),
                        'idpHint': attrs.get('portal.idp_hint', 'poga-idp')
                    }
                }
                portal_apps.append(app_data)

            logger.info(f"Realm {realm}: {len([a for a in portal_apps if a['realm'] == realm])} apps")

        except http_requests.exceptions.HTTPError as e:
            logger.error(f"Erreur HTTP Keycloak realm {realm}: {e.response.status_code}")
            errors.append(f"{realm}: HTTP {e.response.status_code}")
        except Exception as e:
            logger.error(f"Erreur API Keycloak realm {realm}: {e}")
            errors.append(f"{realm}: {str(e)}")

    # Trier par ordre
    portal_apps.sort(key=lambda x: x['order'])

    logger.info(f"Total: {len(portal_apps)} apps depuis {len(KEYCLOAK_REALMS)} realms")

    result = {'applications': portal_apps}
    if errors:
        result['errors'] = errors

    return jsonify(result)


# ============================================
# API CONNEXIONS GUACAMOLE
# ============================================

@app.route('/api/connections', methods=['GET'])
@verify_user_header
def list_connections():
    """Liste toutes les connexions Guacamole disponibles"""
    try:
        conn = get_db_connection()
        cur = conn.cursor()

        cur.execute("""
            SELECT connection_id, connection_name, protocol
            FROM guacamole_connection
            ORDER BY connection_name
        """)

        connections = cur.fetchall()
        cur.close()
        conn.close()

        return jsonify({'connections': connections})

    except Exception as e:
        return jsonify({'error': str(e)}), 500


# ============================================
# API CREDENTIALS PAR CONNEXION
# ============================================

@app.route('/api/credentials', methods=['GET'])
@verify_user_header
def list_credentials():
    """Liste tous les credentials de l'utilisateur"""
    username = request.username

    try:
        conn = get_db_connection()
        cur = conn.cursor()

        cur.execute("""
            SELECT
                ucc.id,
                ucc.connection_id,
                gc.connection_name,
                gc.protocol,
                ucc.ad_login,
                ucc.updated_at,
                ucc.expires_in_hours,
                (ucc.updated_at + (ucc.expires_in_hours || ' hours')::INTERVAL) as expires_at,
                (ucc.updated_at + (ucc.expires_in_hours || ' hours')::INTERVAL) > CURRENT_TIMESTAMP as is_valid
            FROM user_connection_credentials ucc
            JOIN guacamole_connection gc ON gc.connection_id = ucc.connection_id
            WHERE ucc.username = %s AND ucc.is_active = TRUE
            ORDER BY gc.connection_name
        """, (username,))

        credentials = cur.fetchall()
        cur.close()
        conn.close()

        # Convertir datetime en ISO string
        for cred in credentials:
            cred['updated_at'] = cred['updated_at'].isoformat() if cred['updated_at'] else None
            cred['expires_at'] = cred['expires_at'].isoformat() if cred['expires_at'] else None

        return jsonify({'credentials': credentials})

    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/credentials/<int:connection_id>', methods=['GET'])
@verify_user_header
def get_credential(connection_id):
    """Recupere le credential pour une connexion specifique"""
    username = request.username

    try:
        conn = get_db_connection()
        cur = conn.cursor()

        cur.execute("""
            SELECT
                ucc.id,
                ucc.connection_id,
                gc.connection_name,
                ucc.ad_login,
                ucc.updated_at,
                ucc.expires_in_hours,
                (ucc.updated_at + (ucc.expires_in_hours || ' hours')::INTERVAL) as expires_at,
                (ucc.updated_at + (ucc.expires_in_hours || ' hours')::INTERVAL) > CURRENT_TIMESTAMP as is_valid
            FROM user_connection_credentials ucc
            JOIN guacamole_connection gc ON gc.connection_id = ucc.connection_id
            WHERE ucc.username = %s AND ucc.connection_id = %s AND ucc.is_active = TRUE
        """, (username, connection_id))

        row = cur.fetchone()
        cur.close()
        conn.close()

        if not row:
            return jsonify({
                'has_credentials': False,
                'connection_id': connection_id
            })

        return jsonify({
            'has_credentials': True,
            'credential': {
                'id': row['id'],
                'connection_id': row['connection_id'],
                'connection_name': row['connection_name'],
                'ad_login': row['ad_login'],
                'is_valid': row['is_valid'],
                'updated_at': row['updated_at'].isoformat() if row['updated_at'] else None,
                'expires_at': row['expires_at'].isoformat() if row['expires_at'] else None
            }
        })

    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/credentials/<int:connection_id>', methods=['POST'])
@verify_user_header
def save_credential(connection_id):
    """Sauvegarde un credential pour une connexion"""
    data = request.get_json()

    if not data or 'password' not in data or 'login' not in data:
        return jsonify({'error': 'Login et mot de passe requis'}), 400

    password = data['password']
    ad_login = data['login']
    username = request.username

    # Chiffrer le mot de passe
    encrypted_password, iv = encrypt_password(password)

    try:
        conn = get_db_connection()
        cur = conn.cursor()

        # Verifier que la connexion existe
        cur.execute("SELECT connection_name FROM guacamole_connection WHERE connection_id = %s", (connection_id,))
        connection = cur.fetchone()
        if not connection:
            cur.close()
            conn.close()
            return jsonify({'error': 'Connexion non trouvee'}), 404

        # Upsert credential
        cur.execute("""
            INSERT INTO user_connection_credentials
                (username, connection_id, ad_login, encrypted_password, encryption_iv, expires_in_hours)
            VALUES (%s, %s, %s, %s, %s, %s)
            ON CONFLICT (username, connection_id) DO UPDATE SET
                ad_login = EXCLUDED.ad_login,
                encrypted_password = EXCLUDED.encrypted_password,
                encryption_iv = EXCLUDED.encryption_iv,
                expires_in_hours = EXCLUDED.expires_in_hours,
                updated_at = CURRENT_TIMESTAMP,
                is_active = TRUE
        """, (username, connection_id, ad_login, encrypted_password, iv, CREDENTIALS_EXPIRY_HOURS))

        conn.commit()

        # Mettre a jour Guacamole immediatement
        update_single_connection(cur, connection_id, ad_login, password)
        conn.commit()

        cur.close()
        conn.close()

        return jsonify({
            'success': True,
            'message': f'Credentials enregistres pour {connection["connection_name"]}',
            'connection_id': connection_id,
            'login': ad_login,
            'expires_in_hours': CREDENTIALS_EXPIRY_HOURS
        })

    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/credentials/<int:connection_id>', methods=['DELETE'])
@verify_user_header
def delete_credential(connection_id):
    """Supprime un credential pour une connexion"""
    username = request.username

    try:
        conn = get_db_connection()
        cur = conn.cursor()

        cur.execute("""
            UPDATE user_connection_credentials
            SET is_active = FALSE
            WHERE username = %s AND connection_id = %s
        """, (username, connection_id))

        conn.commit()

        # Vider le password dans Guacamole pour cette connexion
        clear_single_connection(cur, connection_id)
        conn.commit()

        cur.close()
        conn.close()

        return jsonify({'success': True, 'message': 'Credential supprime'})

    except Exception as e:
        return jsonify({'error': str(e)}), 500


# ============================================
# FONCTIONS GUACAMOLE
# ============================================

def update_single_connection(cur, connection_id: int, ad_login: str, password: str):
    """Met a jour une seule connexion Guacamole avec username ET password"""
    logger.info(f"Mise a jour connexion {connection_id} avec login {ad_login}")

    params = [
        ('username', ad_login),
        ('password', password),
        ('gateway-username', ad_login),
        ('gateway-password', password)
    ]

    for param_name, param_value in params:
        try:
            cur.execute("""
                INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
                VALUES (%s, %s, %s)
                ON CONFLICT (connection_id, parameter_name) DO UPDATE SET parameter_value = EXCLUDED.parameter_value
            """, (connection_id, param_name, param_value))
            logger.info(f"  - {param_name} = {'***' if 'password' in param_name else param_value}")
        except Exception as e:
            logger.error(f"Erreur insertion {param_name}: {e}")
            raise

    logger.info(f"Connexion {connection_id} mise a jour avec succes")


def clear_single_connection(cur, connection_id: int):
    """Vide les credentials d'une connexion Guacamole"""
    try:
        cur.execute("""
            DELETE FROM guacamole_connection_parameter
            WHERE connection_id = %s
            AND parameter_name IN ('username', 'password', 'gateway-username', 'gateway-password')
        """, (connection_id,))
        logger.info(f"Credentials supprimes pour connexion {connection_id}")
    except Exception as e:
        logger.error(f"Erreur clear Guacamole: {e}")
        raise


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)
