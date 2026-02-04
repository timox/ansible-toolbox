-- Schema pour stockage credentials chiffres
-- A executer dans la base guacamole_db

-- Table des credentials utilisateur
CREATE TABLE IF NOT EXISTS user_credentials (
    id SERIAL PRIMARY KEY,
    username VARCHAR(255) NOT NULL UNIQUE,
    -- Mot de passe chiffre en AES-256 (base64)
    encrypted_password TEXT NOT NULL,
    -- IV pour le chiffrement AES (base64)
    encryption_iv VARCHAR(32) NOT NULL,
    -- Date de creation/mise a jour
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    -- Expiration (optionnel, en heures depuis updated_at)
    expires_in_hours INTEGER DEFAULT 8,
    -- Statut
    is_active BOOLEAN DEFAULT TRUE
);

-- Index pour recherche rapide
CREATE INDEX IF NOT EXISTS idx_user_credentials_username ON user_credentials(username);
CREATE INDEX IF NOT EXISTS idx_user_credentials_active ON user_credentials(is_active);

-- Fonction pour mettre a jour updated_at automatiquement
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Trigger pour updated_at
DROP TRIGGER IF EXISTS update_user_credentials_updated_at ON user_credentials;
CREATE TRIGGER update_user_credentials_updated_at
    BEFORE UPDATE ON user_credentials
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Vue pour credentials valides (non expires)
CREATE OR REPLACE VIEW valid_credentials AS
SELECT
    username,
    encrypted_password,
    encryption_iv,
    updated_at,
    expires_in_hours
FROM user_credentials
WHERE is_active = TRUE
AND (updated_at + (expires_in_hours || ' hours')::INTERVAL) > CURRENT_TIMESTAMP;
