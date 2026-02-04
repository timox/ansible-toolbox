-- Migration vers le systeme de connexions dynamiques v2
-- A executer dans guacamole_db

-- ============================================
-- 1. NOUVELLES TABLES
-- ============================================

-- Table de mapping utilisateur -> connexion clonee
CREATE TABLE IF NOT EXISTS user_connection_mapping (
    id SERIAL PRIMARY KEY,
    username VARCHAR(255) NOT NULL,
    template_connection_id INTEGER NOT NULL,
    user_connection_id INTEGER NOT NULL,
    ad_login VARCHAR(255),
    encrypted_password TEXT,
    encryption_iv VARCHAR(32),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    expires_in_hours INTEGER DEFAULT 8,
    is_active BOOLEAN DEFAULT TRUE,
    CONSTRAINT unique_user_template UNIQUE (username, template_connection_id)
);

-- Index
CREATE INDEX IF NOT EXISTS idx_ucm_username ON user_connection_mapping(username);
CREATE INDEX IF NOT EXISTS idx_ucm_template ON user_connection_mapping(template_connection_id);
CREATE INDEX IF NOT EXISTS idx_ucm_user_conn ON user_connection_mapping(user_connection_id);
CREATE INDEX IF NOT EXISTS idx_ucm_active ON user_connection_mapping(is_active);

-- Table des connexions templates
CREATE TABLE IF NOT EXISTS connection_templates (
    connection_id INTEGER PRIMARY KEY,
    is_template BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ============================================
-- 2. FONCTION TRIGGER
-- ============================================

CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Trigger
DROP TRIGGER IF EXISTS update_ucm_updated_at ON user_connection_mapping;
CREATE TRIGGER update_ucm_updated_at
    BEFORE UPDATE ON user_connection_mapping
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ============================================
-- 3. VUE
-- ============================================

CREATE OR REPLACE VIEW valid_user_connections AS
SELECT
    ucm.id,
    ucm.username,
    ucm.template_connection_id,
    ucm.user_connection_id,
    ucm.ad_login,
    ucm.encrypted_password,
    ucm.encryption_iv,
    ucm.updated_at,
    ucm.expires_in_hours,
    (ucm.updated_at + (ucm.expires_in_hours || ' hours')::INTERVAL) as expires_at,
    (ucm.updated_at + (ucm.expires_in_hours || ' hours')::INTERVAL) > CURRENT_TIMESTAMP as is_valid,
    gc_template.connection_name as template_name,
    gc_template.protocol,
    gc_user.connection_name as user_connection_name
FROM user_connection_mapping ucm
JOIN guacamole_connection gc_template ON gc_template.connection_id = ucm.template_connection_id
JOIN guacamole_connection gc_user ON gc_user.connection_id = ucm.user_connection_id
WHERE ucm.is_active = TRUE;

-- ============================================
-- 4. MIGRATION DONNEES EXISTANTES (optionnel)
-- ============================================
-- Si vous avez des donnees dans user_connection_credentials,
-- elles peuvent etre migrees manuellement si necessaire.
-- L'ancienne table reste intacte pour reference.

-- Verification
SELECT 'Migration v2 terminee' as status;
SELECT
    (SELECT COUNT(*) FROM user_connection_mapping) as mappings,
    (SELECT COUNT(*) FROM connection_templates) as templates;
