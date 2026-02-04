// ============================================
// PORTAIL - Console d'administration
// ============================================

// Configuration applications par defaut
// Note: Seules les applications deployees et configurees dans nginx sont listees
const defaultApplications = {
    guacamole: {
        name: "Guacamole",
        description: "Acces bureaux distants (RDP, VNC, SSH)",
        icon: "G",
        url: "https://guacamole.${DOMAIN}/guacamole/",
        groups: ["admin", "guac", "app-guacamole"],
        // Guacamole gère OIDC nativement - pas besoin de passthrough portal
        oidc: {
            enabled: false
        }
    },
    linshare: {
        name: "LinShare",
        description: "Partage de fichiers securise",
        icon: "L",
        url: "https://linshare.${DOMAIN}",
        groups: ["admin", "utilisateur", "user", "app-linshare"],
        // LinShare gère OIDC nativement - pas besoin de passthrough portal
        oidc: {
            enabled: false
        }
    },
    linshareAdmin: {
        name: "LinShare Admin",
        description: "Administration LinShare",
        icon: "LA",
        url: "https://linshare-admin.${DOMAIN}",
        groups: ["admin-infra", "app-linshare-admin"],
        // LinShare Admin gère OIDC nativement
        oidc: {
            enabled: false
        }
    },
    vaultwarden: {
        name: "Vaultwarden",
        description: "Gestionnaire de mots de passe",
        icon: "🔑",
        url: "https://vault.${DOMAIN}",
        groups: ["admin", "utilisateur", "user", "app-vaultwarden"],
        // Vaultwarden gère OIDC nativement - pas besoin de passthrough portal
        // L'utilisateur accède directement à vault.${DOMAIN} et Vaultwarden redirige vers Keycloak
        oidc: {
            enabled: false
        }
    },
    keycloakAccount: {
        name: "Mon Compte",
        description: "Gerer votre compte et securite",
        icon: "👤",
        url: "https://keycloak.${DOMAIN}/realms/${REALM}/account/",
        groups: ["tous"]
    },
    headscaleUI: {
        name: "VPN Management",
        description: "Gestion du VPN mesh Headscale",
        icon: "🌐",
        url: "https://vpn.${DOMAIN}/admin",
        groups: ["admin-infra"],
        // Headplane gère OIDC nativement
        oidc: {
            enabled: false
        }
    }
    // Applications non deployees (a ajouter quand configurees):
    // nextcloud: { name: "Nextcloud", url: "https://nextcloud.${DOMAIN}", groups: ["admin", "utilisateur"] }
    // glpi: { name: "GLPI", url: "https://glpi.${DOMAIN}", groups: ["admin"] }
    // zabbix: { name: "Zabbix", url: "https://zabbix.${DOMAIN}", groups: ["admin-infra"] }
};

// Charger applications depuis l'API (avec fallback localStorage)
async function loadApplicationsFromAPI() {
    try {
        const response = await fetch('/api/applications', { credentials: 'same-origin' });
        if (response.ok) {
            const apiApps = await response.json();
            // Convertir tableau en objet indexe par id
            const appsObj = {};
            apiApps.forEach(app => {
                appsObj[app.id] = app;
            });
            console.log(`Applications chargees depuis API: ${apiApps.length}`);
            return { ...defaultApplications, ...appsObj };
        }
    } catch (error) {
        console.warn('API indisponible, fallback localStorage:', error);
    }
    // Fallback localStorage
    const customApps = localStorage.getItem('customApplications');
    if (customApps) {
        return { ...defaultApplications, ...JSON.parse(customApps) };
    }
    return { ...defaultApplications };
}

// Sauvegarder applications vers l'API (avec fallback localStorage)
async function saveApplicationsToAPI(apps) {
    // Convertir objet en tableau pour l'API
    const appsArray = Object.entries(apps).map(([id, app]) => ({
        ...app,
        id: id
    }));

    try {
        const response = await fetch('/api/applications', {
            method: 'POST',
            credentials: 'same-origin',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(appsArray)
        });
        if (response.ok) {
            console.log('Applications sauvegardees via API');
            return true;
        }
    } catch (error) {
        console.warn('API indisponible, fallback localStorage:', error);
    }
    // Fallback localStorage
    const customOnly = {};
    Object.entries(apps).forEach(([key, app]) => {
        if (!defaultApplications[key] || app._custom) {
            customOnly[key] = { ...app, _custom: true };
        }
    });
    localStorage.setItem('customApplications', JSON.stringify(customOnly));
    return false;
}

// Wrapper synchrone pour compatibilite (charge depuis cache/default)
function loadApplications() {
    const customApps = localStorage.getItem('customApplications');
    if (customApps) {
        return { ...defaultApplications, ...JSON.parse(customApps) };
    }
    return { ...defaultApplications };
}

// Wrapper pour sauvegarder (appelle API en async)
function saveCustomApplications(apps) {
    saveApplicationsToAPI(apps);
}

let applications = loadApplications();
let keycloakApplications = {};  // Apps chargees depuis Keycloak API
let currentUser = null;
let currentView = 'dashboard';
let portalAdminGroup = null;
let keycloakHost = null;
let keycloakRealm = null;

// Generer l'URL de l'application (avec OIDC si configure)
function getAppUrl(app) {
    const domain = window.location.hostname.split('.').slice(-2).join('.');
    let baseUrl = app.url.replace('${DOMAIN}', domain);
    // Remplacer aussi KEYCLOAK_HOST si disponible
    if (keycloakHost) {
        baseUrl = baseUrl.replace('${KEYCLOAK_HOST}', keycloakHost);
    }
    // Remplacer REALM si disponible
    if (keycloakRealm) {
        baseUrl = baseUrl.replace('${REALM}', keycloakRealm);
    }

    // Si OIDC est configure, generer l'URL Keycloak avec kc_idp_hint
    if (app.oidc && app.oidc.enabled && keycloakHost) {
        const redirectUri = app.oidc.redirectUri.replace('${DOMAIN}', domain);
        const params = new URLSearchParams({
            client_id: app.oidc.clientId,
            redirect_uri: redirectUri,
            response_type: 'code',
            scope: 'openid'
        });
        // Ajouter kc_idp_hint seulement si defini
        if (app.oidc.idpHint) {
            params.append('kc_idp_hint', app.oidc.idpHint);
        }
        return `${keycloakHost}/realms/${app.oidc.realm}/protocol/openid-connect/auth?${params.toString()}`;
    }

    return baseUrl;
}

// ============================================
// INITIALISATION
// ============================================

document.addEventListener('DOMContentLoaded', async function() {
    // Recherche
    const searchInput = document.getElementById('search');
    if (searchInput) {
        searchInput.addEventListener('input', () => displayApplications());
    }

    // Date courante
    const dateElement = document.getElementById('current-date');
    if (dateElement) {
        const options = { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' };
        dateElement.textContent = new Date().toLocaleDateString('fr-FR', options);
    }

    // Charger applications depuis API (async)
    applications = await loadApplicationsFromAPI();

    loadKeycloakConfig();
    loadUserInfo();
    loadKeycloakApplications();
});

// ============================================
// NAVIGATION
// ============================================

function showView(viewName) {
    // Masquer toutes les vues
    document.querySelectorAll('.view').forEach(v => v.classList.add('hidden'));

    // Afficher la vue demandee
    const view = document.getElementById('view-' + viewName);
    if (view) {
        view.classList.remove('hidden');
    }

    // Mettre a jour navigation active
    document.querySelectorAll('.nav-item').forEach(item => {
        item.classList.remove('active');
        if (item.dataset.view === viewName) {
            item.classList.add('active');
        }
    });

    currentView = viewName;

    // Actions specifiques par vue
    if (viewName === 'apps') {
        displayApplications();
    } else if (viewName === 'admin-apps') {
        renderAdminAppsTable();
    } else if (viewName === 'admin-config') {
        loadSystemConfig();
    } else if (viewName === 'dashboard') {
        displayQuickApps();
    } else if (viewName === 'credentials') {
        loadConnections();
        loadCredentialsList();
    }
}

// ============================================
// GESTION UTILISATEUR
// ============================================

async function loadUserInfo() {
    try {
        const response = await fetch('/api/user', { credentials: 'same-origin' });

        if (response.ok) {
            const data = await response.json();
            currentUser = {
                email: data.email || '',
                name: data.name || data.email?.split('@')[0] || 'Utilisateur',
                user: data.user || '',
                groups: parseGroups(data.groups),
                rawData: data
            };
            displayUserInfo();
            updateDashboardStats();
            displayQuickApps();
        } else {
            loadUserFromMetaTags();
        }
    } catch (error) {
        console.error('Erreur chargement user:', error);
        loadUserFromMetaTags();
    }
}

function parseGroups(groups) {
    if (!groups) return [];
    if (Array.isArray(groups)) return groups;
    if (typeof groups === 'string') {
        return groups.split(',').map(g => g.trim());
    }
    return [];
}

function loadUserFromMetaTags() {
    const email = document.querySelector('meta[name="x-forwarded-email"]')?.content;
    const groups = document.querySelector('meta[name="x-forwarded-groups"]')?.content;

    if (email) {
        currentUser = {
            email: email,
            name: email.split('@')[0],
            groups: parseGroups(groups)
        };
    } else {
        currentUser = {
            email: 'user@example.com',
            name: 'Utilisateur',
            groups: ['tous']
        };
    }
    displayUserInfo();
    updateDashboardStats();
    displayQuickApps();
}

function displayUserInfo() {
    const usernameElement = document.getElementById('username');
    const emailElement = document.getElementById('user-email');
    const avatarElement = document.getElementById('user-avatar');

    if (currentUser) {
        usernameElement.textContent = currentUser.name;
        emailElement.textContent = currentUser.email;

        // Avatar avec initiales
        const initials = currentUser.name
            .split(' ')
            .map(n => n[0])
            .join('')
            .toUpperCase()
            .substring(0, 2);
        avatarElement.textContent = initials || '--';

        // Afficher menu admin si necessaire
        if (isAdmin()) {
            document.getElementById('admin-nav').style.display = 'block';
        }
    }
}

function updateDashboardStats() {
    const statApps = document.getElementById('stat-apps');
    const statGroups = document.getElementById('stat-groups');

    if (currentUser) {
        const accessibleApps = Object.values(applications).filter(canAccessApp).length;
        statApps.textContent = accessibleApps;
        statGroups.textContent = currentUser.groups.length;
    }
}

// ============================================
// AFFICHAGE APPLICATIONS
// ============================================

function displayQuickApps() {
    const container = document.getElementById('quick-apps');
    if (!container) return;

    container.innerHTML = '';
    const accessibleApps = Object.entries(applications)
        .filter(([, app]) => canAccessApp(app))
        .slice(0, 6);

    accessibleApps.forEach(([, app]) => {
        container.appendChild(createAppCard(app));
    });

    if (accessibleApps.length === 0) {
        container.innerHTML = '<div class="empty-state"><h3>Aucune application</h3><p>Aucune application disponible pour votre compte.</p></div>';
    }
}

function displayApplications() {
    const container = document.getElementById('apps-grid');
    if (!container) return;

    const searchTerm = getSearchTerm();
    container.innerHTML = '';

    const visibleApps = Object.entries(applications)
        .filter(([, app]) => canAccessApp(app) && matchesSearch(app, searchTerm));

    visibleApps.forEach(([, app]) => {
        container.appendChild(createAppCard(app));
    });

    if (visibleApps.length === 0) {
        container.innerHTML = `
            <div class="empty-state">
                <h3>Aucun resultat</h3>
                <p>${searchTerm ? 'Aucune application ne correspond a "' + escapeHtml(searchTerm) + '".' : 'Aucune application disponible.'}</p>
            </div>
        `;
    }
}

function createAppCard(app) {
    const card = document.createElement('a');
    const url = getAppUrl(app);
    card.href = url;
    card.className = 'app-card';
    card.target = '_blank';

    card.innerHTML = `
        <div class="app-icon-small">${escapeHtml(app.icon)}</div>
        <div class="app-card-content">
            <div class="app-name">${escapeHtml(app.name)}</div>
            <div class="app-description">${escapeHtml(app.description)}</div>
        </div>
    `;

    return card;
}

function canAccessApp(app) {
    if (!currentUser || !currentUser.groups) return false;
    if (app.groups.includes('tous')) return true;

    return app.groups.some(requiredGroup =>
        currentUser.groups.some(userGroup =>
            userGroup.toLowerCase().includes(requiredGroup.toLowerCase()) ||
            requiredGroup.toLowerCase().includes(userGroup.toLowerCase())
        )
    );
}

function getSearchTerm() {
    const search = document.getElementById('search');
    return search ? search.value.trim().toLowerCase() : '';
}

function matchesSearch(app, searchTerm) {
    if (!searchTerm) return true;
    const haystack = `${app.name} ${app.description}`.toLowerCase();
    return haystack.includes(searchTerm);
}

// ============================================
// ADMINISTRATION
// ============================================

function isAdmin() {
    if (!currentUser || !currentUser.groups) return false;

    if (portalAdminGroup) {
        return currentUser.groups.some(g =>
            g.toLowerCase() === portalAdminGroup.toLowerCase() ||
            g.toLowerCase().includes(portalAdminGroup.toLowerCase())
        );
    }

    return currentUser.groups.some(g => g.toLowerCase().includes('admin'));
}

function renderAdminAppsTable() {
    const tbody = document.getElementById('admin-apps-table');
    if (!tbody) return;

    tbody.innerHTML = '';

    Object.entries(applications).forEach(([key, app]) => {
        const isCustom = app._custom || false;
        const isDefault = !!defaultApplications[key];
        const url = getAppUrl(app);
        const hasOidc = app.oidc && app.oidc.enabled;

        const tr = document.createElement('tr');
        tr.innerHTML = `
            <td>
                <div class="app-cell">
                    <div class="app-icon-small">${escapeHtml(app.icon)}</div>
                    <div class="app-info">
                        <div class="app-name">${escapeHtml(app.name)}</div>
                        <div class="app-description">${escapeHtml(app.description)}</div>
                    </div>
                </div>
            </td>
            <td class="url-cell">
                <a href="${escapeHtml(url)}" target="_blank">${escapeHtml(url)}</a>
            </td>
            <td>
                <div class="group-tags">
                    ${app.groups.map(g => `<span class="group-tag">${escapeHtml(g)}</span>`).join('')}
                </div>
            </td>
            <td>
                ${app._keycloak ? '<span class="badge badge-keycloak">Keycloak</span>' :
                  (isDefault && !isCustom ? '<span class="badge badge-default">Defaut</span>' : '<span class="badge badge-custom">Custom</span>')}
                ${hasOidc ? '<span class="badge badge-oidc">OIDC</span>' : ''}
            </td>
            <td>
                <div class="actions-cell">
                    <button class="btn-icon" onclick="editApp('${key}')" title="Modifier">
                        <svg width="16" height="16" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"/>
                        </svg>
                    </button>
                    ${!isDefault || isCustom ? `
                    <button class="btn-icon danger" onclick="deleteApp('${key}')" title="Supprimer">
                        <svg width="16" height="16" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/>
                        </svg>
                    </button>
                    ` : ''}
                </div>
            </td>
        `;
        tbody.appendChild(tr);
    });
}

async function loadKeycloakConfig() {
    try {
        const response = await fetch('/config.json');
        if (response.ok) {
            const config = await response.json();
            if (config.keycloak?.issuer) {
                // Extraire l'origin depuis l'issuer (ex: http://192.168.122.1:8080/realms/poc -> http://192.168.122.1:8080)
                const url = new URL(config.keycloak.issuer);
                keycloakHost = url.origin;  // Inclut le protocole (http:// ou https://)
            }
            if (config.keycloak?.realm) {
                keycloakRealm = config.keycloak.realm;
            }
            if (config.portal?.adminGroup) {
                portalAdminGroup = config.portal.adminGroup;
            }
        }
    } catch (error) {
        console.log('Config not available:', error);
    }
}

async function loadKeycloakApplications() {
    try {
        const response = await fetch('/api/keycloak/clients', { credentials: 'same-origin' });
        if (response.ok) {
            const data = await response.json();
            const kcApps = data.applications || [];

            // Convertir en objet indexe par id
            keycloakApplications = {};
            kcApps.forEach(app => {
                keycloakApplications[app.id] = {
                    ...app,
                    _keycloak: true  // Marquer comme venant de Keycloak
                };
            });

            // Fusionner avec les applications existantes (Keycloak prioritaire)
            applications = { ...loadApplications(), ...keycloakApplications };

            console.log(`Charge ${kcApps.length} apps depuis Keycloak API`);

            // Rafraichir l'affichage si deja charge
            if (currentUser) {
                updateDashboardStats();
                if (currentView === 'dashboard') {
                    displayQuickApps();
                } else if (currentView === 'apps') {
                    displayApplications();
                } else if (currentView === 'admin-apps') {
                    renderAdminAppsTable();
                }
            }
        }
    } catch (error) {
        console.log('Keycloak API not available:', error);
    }
}

async function loadSystemConfig() {
    const container = document.getElementById('admin-config');
    if (!container) return;

    try {
        const response = await fetch('/config.json');
        if (response.ok) {
            const config = await response.json();

            if (config.portal?.adminGroup) {
                portalAdminGroup = config.portal.adminGroup;
            }

            const infra = config.infrastructure || {};
            const services = infra.services || {};

            let html = '';

            // Section Configuration Generale
            html += '<div class="config-section"><h4>Configuration Generale</h4><div class="config-grid">';
            const generalItems = [
                { label: 'Domaine', value: config.domain },
                { label: 'IP Serveur', value: infra.serverIp },
                { label: 'Data Directory', value: infra.dataDir },
                { label: 'Version', value: config.version },
                { label: 'Derniere MAJ', value: config.lastUpdate }
            ];
            html += generalItems.filter(i => i.value).map(item => `
                <div class="config-item"><label>${escapeHtml(item.label)}</label><span>${escapeHtml(item.value)}</span></div>
            `).join('');
            html += '</div></div>';

            // Section Keycloak
            html += '<div class="config-section"><h4>Keycloak OIDC</h4><div class="config-grid">';
            const kcItems = [
                { label: 'Issuer', value: config.keycloak?.issuer },
                { label: 'Realm', value: config.keycloak?.realm },
                { label: 'Client ID (oauth2-proxy)', value: config.keycloak?.clientId }
            ];
            html += kcItems.filter(i => i.value).map(item => `
                <div class="config-item"><label>${escapeHtml(item.label)}</label><span class="value-mono">${escapeHtml(item.value)}</span></div>
            `).join('');
            html += '</div></div>';

            // Section Services
            html += '<div class="config-section"><h4>Services Deployes</h4><div class="services-table"><table class="data-table">';
            html += '<thead><tr><th>Service</th><th>URL HTTPS</th><th>Port HTTP</th><th>Client OIDC</th><th>Statut</th></tr></thead><tbody>';

            const servicesList = [
                { name: 'Portail', svc: services.portal, enabled: true },
                { name: 'Guacamole', svc: services.guacamole, enabled: true },
                { name: 'Vaultwarden', svc: services.vaultwarden, enabled: services.vaultwarden?.enabled },
                { name: 'LinShare', svc: services.linshare, enabled: services.linshare?.enabled },
                { name: 'LinShare Admin', svc: { url: services.linshare?.url?.replace('linshare', 'linshare-admin'), httpPort: services.linshare?.adminPort }, enabled: services.linshare?.enabled },
                { name: 'Headscale', svc: services.headscale, enabled: services.headscale?.enabled },
                { name: 'Credentials API', svc: services.credentialsApi, enabled: services.credentialsApi?.enabled }
            ];

            for (const s of servicesList) {
                const statusBadge = s.enabled
                    ? '<span class="badge badge-success">Actif</span>'
                    : '<span class="badge badge-disabled">Desactive</span>';
                const url = s.svc?.url || '-';
                const httpPort = s.svc?.httpPort || s.svc?.httpsPort || '-';
                const oidcClient = s.svc?.oidcClient || '-';
                const ipPort = infra.serverIp && httpPort !== '-' ? `${infra.serverIp}:${httpPort}` : '-';

                html += `<tr>
                    <td><strong>${escapeHtml(s.name)}</strong></td>
                    <td><a href="${escapeHtml(url)}" target="_blank">${escapeHtml(url)}</a></td>
                    <td class="value-mono">${escapeHtml(ipPort)}</td>
                    <td class="value-mono">${escapeHtml(oidcClient)}</td>
                    <td>${statusBadge}</td>
                </tr>`;
            }
            html += '</tbody></table></div></div>';

            // Section Groupes
            html += '<div class="config-section"><h4>Groupes Keycloak</h4><div class="config-grid">';
            const groups = infra.groups || {};
            const groupItems = [
                { label: 'Admin Infrastructure', value: groups.adminInfra },
                { label: 'Admin Applicatif', value: groups.adminApp },
                { label: 'Utilisateurs', value: groups.users }
            ];
            html += groupItems.filter(i => i.value).map(item => `
                <div class="config-item"><label>${escapeHtml(item.label)}</label><span class="group-tag">${escapeHtml(item.value)}</span></div>
            `).join('');
            html += '</div></div>';

            container.innerHTML = html;
        }
    } catch (error) {
        console.log('Config not available:', error);
        container.innerHTML = '<div class="empty-state"><p>Configuration non disponible</p></div>';
    }
}

// ============================================
// MODALS
// ============================================

function toggleOidcFields() {
    const enabled = document.getElementById('app-oidc-enabled').checked;
    document.getElementById('oidc-fields').style.display = enabled ? 'block' : 'none';
}

function showAddAppModal() {
    document.getElementById('modal-title').textContent = 'Ajouter une application';
    document.getElementById('app-id').value = '';
    document.getElementById('app-name').value = '';
    document.getElementById('app-description').value = '';
    document.getElementById('app-icon').value = 'A';
    document.getElementById('app-url').value = '';
    document.getElementById('app-groups').value = '';
    // OIDC fields
    document.getElementById('app-oidc-enabled').checked = false;
    document.getElementById('app-oidc-realm').value = '';
    document.getElementById('app-oidc-client-id').value = '';
    document.getElementById('app-oidc-idp-hint').value = '';
    document.getElementById('app-oidc-redirect-uri').value = '';
    document.getElementById('oidc-fields').style.display = 'none';
    document.getElementById('app-modal').style.display = 'flex';
}

function editApp(appId) {
    const app = applications[appId];
    if (!app) return;

    document.getElementById('modal-title').textContent = 'Modifier ' + app.name;
    document.getElementById('app-id').value = appId;
    document.getElementById('app-name').value = app.name;
    document.getElementById('app-description').value = app.description;
    document.getElementById('app-icon').value = app.icon;
    document.getElementById('app-url').value = app.url;
    document.getElementById('app-groups').value = app.groups.join(', ');
    // OIDC fields
    const hasOidc = app.oidc && app.oidc.enabled;
    document.getElementById('app-oidc-enabled').checked = hasOidc;
    document.getElementById('app-oidc-realm').value = app.oidc?.realm || '';
    document.getElementById('app-oidc-client-id').value = app.oidc?.clientId || '';
    document.getElementById('app-oidc-idp-hint').value = app.oidc?.idpHint || '';
    document.getElementById('app-oidc-redirect-uri').value = app.oidc?.redirectUri || '';
    document.getElementById('oidc-fields').style.display = hasOidc ? 'block' : 'none';
    document.getElementById('app-modal').style.display = 'flex';
}

function closeModal() {
    document.getElementById('app-modal').style.display = 'none';
}

function saveApp(event) {
    event.preventDefault();

    const appId = document.getElementById('app-id').value ||
                  document.getElementById('app-name').value.toLowerCase().replace(/\s+/g, '-');

    const app = {
        name: document.getElementById('app-name').value,
        description: document.getElementById('app-description').value,
        icon: document.getElementById('app-icon').value || 'A',
        url: document.getElementById('app-url').value,
        groups: document.getElementById('app-groups').value.split(',').map(g => g.trim()).filter(g => g),
        _custom: true
    };

    // OIDC config
    if (document.getElementById('app-oidc-enabled').checked) {
        app.oidc = {
            enabled: true,
            realm: document.getElementById('app-oidc-realm').value,
            clientId: document.getElementById('app-oidc-client-id').value,
            idpHint: document.getElementById('app-oidc-idp-hint').value,
            redirectUri: document.getElementById('app-oidc-redirect-uri').value
        };
    }

    if (app.groups.length === 0) {
        app.groups = ['tous'];
    }

    applications[appId] = app;
    saveCustomApplications(applications);

    closeModal();
    renderAdminAppsTable();
    updateDashboardStats();
}

function deleteApp(appId) {
    if (!confirm('Supprimer cette application ?')) return;

    delete applications[appId];
    saveCustomApplications(applications);

    renderAdminAppsTable();
    updateDashboardStats();
}

// ============================================
// MODAL PROFIL
// ============================================

function showProfileModal() {
    const profileDetails = document.getElementById('profile-details');
    const modal = document.getElementById('profile-modal');

    if (!profileDetails || !modal) return;

    if (!currentUser) {
        profileDetails.innerHTML = '<div class="groups-empty">Aucune information disponible</div>';
    } else {
        const groupsCount = currentUser.groups.length;
        const groupsLabel = groupsCount === 0 ? 'Aucun groupe' :
                           groupsCount === 1 ? '1 groupe' :
                           `${groupsCount} groupes`;

        const attributes = [
            { label: 'Nom', value: currentUser.name },
            { label: 'Email', value: currentUser.email },
            { label: 'Identifiant', value: currentUser.user },
            { label: 'Groupes', value: groupsLabel, clickable: true, onclick: 'showGroupsModal()' }
        ];

        if (currentUser.rawData) {
            Object.entries(currentUser.rawData).forEach(([key, value]) => {
                if (['email', 'name', 'user', 'groups'].includes(key)) return;
                if (value && value !== '') {
                    attributes.push({
                        label: key,
                        value: typeof value === 'object' ? JSON.stringify(value) : String(value)
                    });
                }
            });
        }

        profileDetails.innerHTML = attributes
            .filter(attr => attr.value && attr.value !== '')
            .map(attr => `
                <div class="profile-item">
                    <span class="profile-item-label">${escapeHtml(attr.label)}</span>
                    ${attr.clickable
                        ? `<span class="profile-item-value clickable" onclick="${attr.onclick}">${escapeHtml(attr.value)}</span>`
                        : `<span class="profile-item-value">${escapeHtml(attr.value)}</span>`
                    }
                </div>
            `).join('');
    }

    modal.style.display = 'flex';
}

function closeProfileModal() {
    const modal = document.getElementById('profile-modal');
    if (modal) modal.style.display = 'none';
}

// ============================================
// MODAL GROUPES
// ============================================

function showGroupsModal() {
    const groupsList = document.getElementById('groups-list');
    const modal = document.getElementById('groups-modal');

    if (!groupsList || !modal) return;

    if (!currentUser || !currentUser.groups || currentUser.groups.length === 0) {
        groupsList.innerHTML = '<div class="groups-empty">Aucun groupe attribue</div>';
    } else {
        const sortedGroups = [...currentUser.groups].sort((a, b) =>
            a.toLowerCase().localeCompare(b.toLowerCase())
        );

        groupsList.innerHTML = sortedGroups
            .map(group => `<div class="group-item">${escapeHtml(group)}</div>`)
            .join('');
    }

    modal.style.display = 'flex';
}

function closeGroupsModal() {
    const modal = document.getElementById('groups-modal');
    if (modal) modal.style.display = 'none';
}

// ============================================
// CREDENTIALS RDP (Multi-connexions)
// ============================================

let availableConnections = [];

async function loadCredentialsList() {
    const listDiv = document.getElementById('credentials-list');
    if (!listDiv) return;

    try {
        const response = await fetch('/api/credentials', {
            credentials: 'same-origin'
        });

        if (response.ok) {
            const data = await response.json();
            const credentials = data.credentials || [];

            if (credentials.length === 0) {
                listDiv.innerHTML = `
                    <div class="credentials-none">
                        <svg width="24" height="24" fill="none" stroke="currentColor" viewBox="0 0 24 24" style="color: var(--text-secondary);">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"/>
                        </svg>
                        <div>
                            <strong>Aucun credential configure</strong>
                            <p class="text-small text-muted">Cliquez sur "Ajouter" pour configurer vos identifiants</p>
                        </div>
                    </div>
                `;
                return;
            }

            let html = '<div class="credentials-grid">';
            for (const cred of credentials) {
                const expiresAt = new Date(cred.expires_at);
                const statusClass = cred.is_valid ? 'credentials-valid' : 'credentials-expired';
                const statusIcon = cred.is_valid
                    ? '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/>'
                    : '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"/>';
                const statusColor = cred.is_valid ? 'var(--success)' : 'var(--warning)';

                html += `
                    <div class="${statusClass} credential-card">
                        <div class="credential-header">
                            <svg width="20" height="20" fill="none" stroke="currentColor" viewBox="0 0 24 24" style="color: ${statusColor};">
                                ${statusIcon}
                            </svg>
                            <strong>${escapeHtml(cred.connection_name)}</strong>
                            <span class="badge badge-${cred.protocol}">${cred.protocol.toUpperCase()}</span>
                        </div>
                        <div class="credential-details">
                            <p><strong>Login:</strong> ${escapeHtml(cred.ad_login)}</p>
                            <p class="text-small text-muted">
                                ${cred.is_valid ? 'Expire le ' + expiresAt.toLocaleString('fr-FR') : 'Expire - a renouveler'}
                            </p>
                        </div>
                        <div class="credential-actions">
                            <button class="btn btn-sm btn-secondary" onclick="editCredential(${cred.connection_id}, '${escapeHtml(cred.ad_login)}')">Modifier</button>
                            <button class="btn btn-sm btn-danger" onclick="deleteCredential(${cred.connection_id})">Supprimer</button>
                        </div>
                    </div>
                `;
            }
            html += '</div>';
            listDiv.innerHTML = html;
        } else {
            listDiv.innerHTML = '<p class="text-muted">Service indisponible</p>';
        }
    } catch (error) {
        console.error('Erreur chargement credentials:', error);
        listDiv.innerHTML = '<p class="text-muted">Erreur de connexion au service</p>';
    }
}

async function loadConnections() {
    try {
        const response = await fetch('/api/connections', {
            credentials: 'same-origin'
        });
        if (response.ok) {
            const data = await response.json();
            availableConnections = data.connections || [];
        }
    } catch (error) {
        console.error('Erreur chargement connexions:', error);
    }
}

function showAddCredentialModal() {
    const modal = document.getElementById('credential-modal');
    const select = document.getElementById('cred-connection');

    // Remplir le select avec les connexions
    if (availableConnections.length === 0) {
        select.innerHTML = '<option value="">Aucune connexion disponible</option>';
    } else {
        select.innerHTML = '<option value="">-- Selectionnez --</option>';
        for (const conn of availableConnections) {
            select.innerHTML += `<option value="${conn.connection_id}">${escapeHtml(conn.connection_name)} (${conn.protocol.toUpperCase()})</option>`;
        }
    }

    // Reset form
    document.getElementById('cred-login').value = currentUser?.name || '';
    document.getElementById('cred-password').value = '';
    document.getElementById('cred-password-confirm').value = '';

    modal.style.display = 'flex';
}

function editCredential(connectionId, currentLogin) {
    const modal = document.getElementById('credential-modal');
    const select = document.getElementById('cred-connection');

    // Remplir le select et selectionner la connexion
    select.innerHTML = '';
    for (const conn of availableConnections) {
        const selected = conn.connection_id === connectionId ? 'selected' : '';
        select.innerHTML += `<option value="${conn.connection_id}" ${selected}>${escapeHtml(conn.connection_name)} (${conn.protocol.toUpperCase()})</option>`;
    }

    // Pre-remplir le login
    document.getElementById('cred-login').value = currentLogin;
    document.getElementById('cred-password').value = '';
    document.getElementById('cred-password-confirm').value = '';

    modal.style.display = 'flex';
}

function closeCredentialModal() {
    const modal = document.getElementById('credential-modal');
    if (modal) modal.style.display = 'none';
}

async function saveCredential(event) {
    event.preventDefault();

    const connectionId = document.getElementById('cred-connection').value;
    const login = document.getElementById('cred-login').value.trim();
    const password = document.getElementById('cred-password').value;
    const passwordConfirm = document.getElementById('cred-password-confirm').value;

    if (!connectionId) {
        alert('Selectionnez une connexion');
        return;
    }

    if (!login) {
        alert('Le login AD est requis');
        return;
    }

    if (password !== passwordConfirm) {
        alert('Les mots de passe ne correspondent pas');
        return;
    }

    if (password.length < 1) {
        alert('Le mot de passe ne peut pas etre vide');
        return;
    }

    try {
        const response = await fetch(`/api/credentials/${connectionId}`, {
            method: 'POST',
            credentials: 'same-origin',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({ login, password })
        });

        const data = await response.json();

        if (response.ok && data.success) {
            alert('Credential enregistre avec succes');
            closeCredentialModal();
            loadCredentialsList();
        } else {
            alert('Erreur: ' + (data.error || 'Erreur inconnue'));
        }
    } catch (error) {
        console.error('Erreur sauvegarde credential:', error);
        alert('Erreur de connexion au service');
    }
}

async function deleteCredential(connectionId) {
    if (!confirm('Supprimer ce credential ?')) {
        return;
    }

    try {
        const response = await fetch(`/api/credentials/${connectionId}`, {
            method: 'DELETE',
            credentials: 'same-origin'
        });

        const data = await response.json();

        if (response.ok && data.success) {
            loadCredentialsList();
        } else {
            alert('Erreur: ' + (data.error || 'Erreur inconnue'));
        }
    } catch (error) {
        console.error('Erreur suppression credential:', error);
        alert('Erreur de connexion au service');
    }
}

// ============================================
// UTILITAIRES
// ============================================

function escapeHtml(text) {
    if (!text) return '';
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

function logout() {
    window.location.href = '/logout';
}

// Fermer modals en cliquant a l'exterieur
window.onclick = function(event) {
    const modals = ['app-modal', 'groups-modal', 'profile-modal'];
    modals.forEach(id => {
        const modal = document.getElementById(id);
        if (event.target === modal) {
            modal.style.display = 'none';
        }
    });
};
