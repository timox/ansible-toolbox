// ============================================
// VAULTWARDEN INTEGRATION - Module BYOV
// ============================================
// Integration optionnelle avec Vaultwarden pour
// recuperer les credentials depuis le vault personnel
// de l'utilisateur.
//
// Usage:
//   1. Utilisateur se connecte via SSO
//   2. Utilisateur deverrouille son vault Vaultwarden
//   3. Portal recupere les credentials pour Guacamole
// ============================================

const VaultwardenIntegration = (function() {
    'use strict';

    // Configuration
    let config = {
        enabled: false,
        vaultUrl: null,
        apiPort: 8087,  // Port par defaut de 'bw serve'
        sessionKey: null,
        unlocked: false
    };

    // Status du vault
    const STATUS = {
        DISCONNECTED: 'disconnected',
        LOCKED: 'locked',
        UNLOCKED: 'unlocked',
        ERROR: 'error'
    };

    let currentStatus = STATUS.DISCONNECTED;

    // ============================================
    // INITIALISATION
    // ============================================

    function init(options = {}) {
        config = { ...config, ...options };

        // Detecter Vaultwarden depuis la config
        if (window.portalConfig && window.portalConfig.vaultwarden) {
            config.enabled = window.portalConfig.vaultwarden.enabled || false;
            config.vaultUrl = window.portalConfig.vaultwarden.url || null;
        }

        // Charger session depuis localStorage
        const savedSession = localStorage.getItem('vaultwarden_session');
        if (savedSession) {
            try {
                const session = JSON.parse(savedSession);
                if (session.expires > Date.now()) {
                    config.sessionKey = session.key;
                    currentStatus = STATUS.UNLOCKED;
                    config.unlocked = true;
                }
            } catch (e) {
                localStorage.removeItem('vaultwarden_session');
            }
        }

        console.log('[Vaultwarden] Integration initialized:', config.enabled ? 'enabled' : 'disabled');
        return config.enabled;
    }

    // ============================================
    // API BITWARDEN CLI (bw serve)
    // ============================================

    async function checkLocalApi() {
        try {
            const response = await fetch(`http://localhost:${config.apiPort}/status`, {
                method: 'GET',
                headers: { 'Content-Type': 'application/json' }
            });
            if (response.ok) {
                const data = await response.json();
                return data.status === 'unlocked';
            }
        } catch (e) {
            console.log('[Vaultwarden] Local API not available:', e.message);
        }
        return false;
    }

    async function getCredentialsFromLocalApi(search) {
        if (!config.unlocked) {
            throw new Error('Vault is locked');
        }

        try {
            const response = await fetch(
                `http://localhost:${config.apiPort}/list/items?search=${encodeURIComponent(search)}`,
                {
                    method: 'GET',
                    headers: {
                        'Content-Type': 'application/json',
                        'Authorization': `Bearer ${config.sessionKey}`
                    }
                }
            );

            if (!response.ok) {
                throw new Error(`API error: ${response.status}`);
            }

            const items = await response.json();
            return items.data || [];
        } catch (e) {
            console.error('[Vaultwarden] Error fetching credentials:', e);
            throw e;
        }
    }

    // ============================================
    // RECHERCHE CREDENTIALS
    // ============================================

    async function findCredentials(hostname, username = null) {
        if (!config.enabled || !config.unlocked) {
            return null;
        }

        // Rechercher par hostname
        const items = await getCredentialsFromLocalApi(hostname);

        if (items.length === 0) {
            return null;
        }

        // Si username specifie, filtrer
        if (username) {
            const match = items.find(item =>
                item.login && item.login.username === username
            );
            if (match) {
                return {
                    username: match.login.username,
                    password: match.login.password,
                    source: 'vaultwarden',
                    itemName: match.name
                };
            }
        }

        // Retourner le premier resultat
        const first = items[0];
        if (first.login) {
            return {
                username: first.login.username,
                password: first.login.password,
                source: 'vaultwarden',
                itemName: first.name
            };
        }

        return null;
    }

    // ============================================
    // UI COMPONENTS
    // ============================================

    function renderStatusBadge() {
        const statusColors = {
            [STATUS.DISCONNECTED]: '#666',
            [STATUS.LOCKED]: '#f39c12',
            [STATUS.UNLOCKED]: '#27ae60',
            [STATUS.ERROR]: '#e74c3c'
        };

        const statusLabels = {
            [STATUS.DISCONNECTED]: 'Vault non connecte',
            [STATUS.LOCKED]: 'Vault verrouille',
            [STATUS.UNLOCKED]: 'Vault deverrouille',
            [STATUS.ERROR]: 'Erreur vault'
        };

        return `
            <div class="vault-status" style="
                display: inline-flex;
                align-items: center;
                gap: 8px;
                padding: 6px 12px;
                border-radius: 20px;
                background: ${statusColors[currentStatus]}20;
                border: 1px solid ${statusColors[currentStatus]};
                font-size: 12px;
                color: ${statusColors[currentStatus]};
            ">
                <span style="
                    width: 8px;
                    height: 8px;
                    border-radius: 50%;
                    background: ${statusColors[currentStatus]};
                "></span>
                ${statusLabels[currentStatus]}
            </div>
        `;
    }

    function renderUnlockButton() {
        if (!config.enabled) {
            return '';
        }

        if (currentStatus === STATUS.UNLOCKED) {
            return `
                <button onclick="VaultwardenIntegration.lock()" class="vault-btn vault-btn-secondary">
                    Verrouiller Vault
                </button>
            `;
        }

        return `
            <button onclick="VaultwardenIntegration.showUnlockDialog()" class="vault-btn vault-btn-primary">
                Deverrouiller Vault
            </button>
        `;
    }

    function showUnlockDialog() {
        const dialog = document.createElement('div');
        dialog.id = 'vault-unlock-dialog';
        dialog.innerHTML = `
            <div style="
                position: fixed;
                top: 0;
                left: 0;
                right: 0;
                bottom: 0;
                background: rgba(0,0,0,0.5);
                display: flex;
                align-items: center;
                justify-content: center;
                z-index: 10000;
            ">
                <div style="
                    background: white;
                    padding: 24px;
                    border-radius: 8px;
                    max-width: 400px;
                    width: 90%;
                ">
                    <h3 style="margin: 0 0 16px 0;">Deverrouiller Vaultwarden</h3>
                    <p style="color: #666; font-size: 14px;">
                        Pour utiliser vos credentials depuis Vaultwarden, vous devez :
                    </p>
                    <ol style="color: #666; font-size: 14px; padding-left: 20px;">
                        <li>Ouvrir Bitwarden CLI</li>
                        <li>Executer: <code>bw serve --port ${config.apiPort}</code></li>
                        <li>Deverrouiller votre vault</li>
                    </ol>
                    <div style="display: flex; gap: 12px; margin-top: 20px;">
                        <button onclick="VaultwardenIntegration.checkAndUnlock()" style="
                            flex: 1;
                            padding: 10px;
                            background: #3498db;
                            color: white;
                            border: none;
                            border-radius: 4px;
                            cursor: pointer;
                        ">Verifier connexion</button>
                        <button onclick="VaultwardenIntegration.closeDialog()" style="
                            flex: 1;
                            padding: 10px;
                            background: #95a5a6;
                            color: white;
                            border: none;
                            border-radius: 4px;
                            cursor: pointer;
                        ">Annuler</button>
                    </div>
                </div>
            </div>
        `;
        document.body.appendChild(dialog);
    }

    function closeDialog() {
        const dialog = document.getElementById('vault-unlock-dialog');
        if (dialog) {
            dialog.remove();
        }
    }

    async function checkAndUnlock() {
        const isUnlocked = await checkLocalApi();
        if (isUnlocked) {
            currentStatus = STATUS.UNLOCKED;
            config.unlocked = true;

            // Sauvegarder session (8h)
            localStorage.setItem('vaultwarden_session', JSON.stringify({
                key: 'local-api',
                expires: Date.now() + (8 * 60 * 60 * 1000)
            }));

            closeDialog();

            // Refresh UI
            if (typeof displayApplications === 'function') {
                displayApplications();
            }

            showNotification('Vault deverrouille avec succes', 'success');
        } else {
            showNotification('API Vaultwarden non disponible. Verifiez que bw serve est lance.', 'error');
        }
    }

    function lock() {
        currentStatus = STATUS.LOCKED;
        config.unlocked = false;
        config.sessionKey = null;
        localStorage.removeItem('vaultwarden_session');

        if (typeof displayApplications === 'function') {
            displayApplications();
        }

        showNotification('Vault verrouille', 'info');
    }

    function showNotification(message, type = 'info') {
        const colors = {
            success: '#27ae60',
            error: '#e74c3c',
            info: '#3498db'
        };

        const notification = document.createElement('div');
        notification.style.cssText = `
            position: fixed;
            top: 20px;
            right: 20px;
            padding: 12px 24px;
            background: ${colors[type]};
            color: white;
            border-radius: 4px;
            z-index: 10001;
            animation: slideIn 0.3s ease;
        `;
        notification.textContent = message;
        document.body.appendChild(notification);

        setTimeout(() => notification.remove(), 3000);
    }

    // ============================================
    // PUBLIC API
    // ============================================

    return {
        init,
        findCredentials,
        renderStatusBadge,
        renderUnlockButton,
        showUnlockDialog,
        closeDialog,
        checkAndUnlock,
        lock,
        isEnabled: () => config.enabled,
        isUnlocked: () => config.unlocked,
        getStatus: () => currentStatus
    };

})();

// Auto-init si config disponible
if (typeof window !== 'undefined') {
    window.VaultwardenIntegration = VaultwardenIntegration;
}
