const express = require('express');
const fs = require('fs').promises;
const path = require('path');

const app = express();
const PORT = 3000;
const DATA_DIR = process.env.DATA_DIR || '/data';
const DATA_FILE = path.join(DATA_DIR, 'applications.json');

// Categories par defaut
const DEFAULT_CATEGORIES = [
    {
        id: 'admin',
        name: 'Administration',
        icon: 'fas fa-shield-alt',
        color: 'danger',
        description: 'Gestion systeme et infrastructure',
        order: 1
    },
    {
        id: 'collab',
        name: 'Collaboration',
        icon: 'fas fa-users',
        color: 'primary',
        description: 'Communication et travail d\'equipe',
        order: 2
    },
    {
        id: 'monitoring',
        name: 'Monitoring',
        icon: 'fas fa-chart-line',
        color: 'success',
        description: 'Supervision et metriques',
        order: 3
    },
    {
        id: 'storage',
        name: 'Stockage',
        icon: 'fas fa-cloud',
        color: 'info',
        description: 'Partage et archivage fichiers',
        order: 4
    },
    {
        id: 'dev',
        name: 'Developpement',
        icon: 'fas fa-code',
        color: 'warning',
        description: 'Outils developpeurs',
        order: 5
    },
    {
        id: 'other',
        name: 'Autres',
        icon: 'fas fa-folder',
        color: 'secondary',
        description: 'Applications non categorisees',
        order: 99
    }
];

// Middleware
app.use(express.json({ limit: '1mb' }));

// CORS pour autoriser les requetes depuis le portal
app.use((req, res, next) => {
    res.header('Access-Control-Allow-Origin', '*');
    res.header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.header('Access-Control-Allow-Headers', 'Content-Type');
    if (req.method === 'OPTIONS') {
        return res.sendStatus(200);
    }
    next();
});

// Logging
app.use((req, res, next) => {
    console.log(`${new Date().toISOString()} ${req.method} ${req.path}`);
    next();
});

// Initialiser le fichier de donnees si inexistant
async function ensureDataFile() {
    try {
        await fs.mkdir(DATA_DIR, { recursive: true });
        try {
            await fs.access(DATA_FILE);

            // Verifier si migration necessaire
            const data = await fs.readFile(DATA_FILE, 'utf8');
            const config = JSON.parse(data);

            // Si ancien format (array d'apps), migrer vers nouveau format
            if (Array.isArray(config)) {
                console.log('Migration vers nouveau format avec categories...');
                const newConfig = {
                    categories: DEFAULT_CATEGORIES,
                    applications: config.map(app => ({
                        ...app,
                        category: app.category || 'other',
                        tags: app.tags || []
                    }))
                };
                await fs.writeFile(DATA_FILE, JSON.stringify(newConfig, null, 2));
                console.log('Migration terminee');
            }
            // Si nouveau format mais sans categories
            else if (config && !config.categories) {
                console.log('Ajout des categories au format existant...');
                config.categories = DEFAULT_CATEGORIES;
                if (Array.isArray(config.applications)) {
                    config.applications = config.applications.map(app => ({
                        ...app,
                        category: app.category || 'other',
                        tags: app.tags || []
                    }));
                }
                await fs.writeFile(DATA_FILE, JSON.stringify(config, null, 2));
                console.log('Categories ajoutees');
            }
        } catch {
            // Fichier n'existe pas, creer avec nouveau format
            const defaultConfig = {
                categories: DEFAULT_CATEGORIES,
                applications: [
                    {
                        id: 'guacamole',
                        name: 'Guacamole',
                        description: 'Acces distant aux postes et serveurs',
                        icon: 'fas fa-desktop',
                        url: 'https://guacamole.example.com',
                        color: 'app-success',
                        groups: ['GG-POM-ADMINS'],
                        category: 'admin',
                        tags: ['rdp', 'ssh', 'vnc', 'bastion']
                    },
                    {
                        id: 'intranet',
                        name: 'Intranet',
                        description: 'Informations internes et actualites',
                        icon: 'fas fa-building',
                        url: 'https://intranet.example.com',
                        color: 'app-primary',
                        groups: ['GG-POM-USERS', 'GG-POM-ADMINS'],
                        category: 'collab',
                        tags: ['intranet', 'actualites', 'communication']
                    },
                    {
                        id: 'tickets',
                        name: 'Support & Tickets',
                        description: 'Declarer et suivre vos demandes',
                        icon: 'fas fa-ticket-alt',
                        url: 'https://tickets.example.com',
                        color: 'app-info',
                        groups: ['GG-POM-USERS', 'GG-POM-ADMINS'],
                        category: 'collab',
                        tags: ['support', 'helpdesk', 'glpi']
                    }
                ]
            };
            await fs.writeFile(DATA_FILE, JSON.stringify(defaultConfig, null, 2));
            console.log(`Fichier de donnees initialise: ${DATA_FILE}`);
        }
    } catch (error) {
        console.error('Erreur lors de l\'initialisation du fichier de donnees:', error);
        throw error;
    }
}

// GET /api/applications - Recuperer la liste des applications
app.get('/api/applications', async (req, res) => {
    try {
        const data = await fs.readFile(DATA_FILE, 'utf8');
        const config = JSON.parse(data);

        // Support ancien et nouveau format
        const applications = Array.isArray(config) ? config : (config.applications || []);

        res.json(applications);
    } catch (error) {
        console.error('Erreur lecture applications:', error);
        res.status(500).json({ error: 'Erreur lors de la lecture des applications' });
    }
});

// GET /api/user - Recuperer les informations utilisateur depuis les headers oauth2-proxy
app.get('/api/user', (req, res) => {
    try {
        // Headers injectes par oauth2-proxy via nginx
        const email = req.headers['x-forwarded-email'] || req.headers['x-auth-request-email'];
        const user = req.headers['x-forwarded-user'] || req.headers['x-auth-request-user'];
        const groups = req.headers['x-forwarded-groups'] || req.headers['x-auth-request-groups'];
        const preferredUsername = req.headers['x-forwarded-preferred-username'] || req.headers['x-auth-request-preferred-username'];

        // Si aucun header trouve, retourner une erreur
        if (!email && !user) {
            console.warn('Aucun header oauth2-proxy trouve dans la requete');
            return res.status(401).json({
                error: 'Non authentifie - aucun header oauth2-proxy trouve',
                hint: 'Verifier que nginx transmet les headers X-Forwarded-*'
            });
        }

        // Parser les groupes (comma-separated ou JSON array)
        let parsedGroups = [];
        if (groups) {
            if (groups.startsWith('[')) {
                try {
                    parsedGroups = JSON.parse(groups);
                } catch {
                    parsedGroups = groups.split(',').map(g => g.trim());
                }
            } else {
                parsedGroups = groups.split(',').map(g => g.trim());
            }
        }

        res.json({
            authenticated: true,
            email: email || null,
            user: user || preferredUsername || null,
            name: preferredUsername || (email ? email.split('@')[0] : null),
            groups: parsedGroups
        });
    } catch (error) {
        console.error('Erreur recuperation user:', error);
        res.status(500).json({ error: 'Erreur serveur' });
    }
});

// GET /api/groups - Recuperer la liste des groupes disponibles
app.get('/api/groups', async (req, res) => {
    try {
        const data = await fs.readFile(DATA_FILE, 'utf8');
        const config = JSON.parse(data);
        const applications = Array.isArray(config) ? config : (config.applications || []);

        // Extraire tous les groupes uniques depuis les applications
        const groupsSet = new Set();
        applications.forEach(app => {
            if (Array.isArray(app.groups)) {
                app.groups.forEach(group => {
                    if (group && typeof group === 'string') {
                        groupsSet.add(group.trim());
                    }
                });
            }
        });

        // Ajouter les groupes par defaut s'ils ne sont pas presents
        groupsSet.add('GG-POM-USERS');
        groupsSet.add('GG-POM-ADMINS');

        // Convertir en tableau trie
        const groups = Array.from(groupsSet).sort();

        res.json(groups);
    } catch (error) {
        console.error('Erreur lecture groupes:', error);
        res.status(500).json({ error: 'Erreur lors de la lecture des groupes' });
    }
});

// GET /api/categories - Recuperer les categories
app.get('/api/categories', async (req, res) => {
    try {
        const data = await fs.readFile(DATA_FILE, 'utf8');
        const config = JSON.parse(data);

        // Support ancien et nouveau format
        const categories = (config.categories) ? config.categories : DEFAULT_CATEGORIES;

        res.json(categories);
    } catch (error) {
        console.error('Erreur lecture categories:', error);
        // Fallback sur categories par defaut
        res.json(DEFAULT_CATEGORIES);
    }
});

// POST /api/categories - Sauvegarder les categories
app.post('/api/categories', async (req, res) => {
    try {
        const categories = req.body;

        // Validation
        if (!Array.isArray(categories)) {
            return res.status(400).json({ error: 'Format invalide - tableau attendu' });
        }

        // Lire config actuelle
        const data = await fs.readFile(DATA_FILE, 'utf8');
        const config = JSON.parse(data);

        // Support ancien format
        if (Array.isArray(config)) {
            // Migrer vers nouveau format
            const newConfig = {
                categories: categories,
                applications: config
            };
            await fs.writeFile(DATA_FILE, JSON.stringify(newConfig, null, 2));
        } else {
            // Mettre a jour les categories
            config.categories = categories;
            await fs.writeFile(DATA_FILE, JSON.stringify(config, null, 2));
        }

        console.log(`Categories sauvegardees: ${categories.length} entrees`);
        res.json({ success: true, count: categories.length });
    } catch (error) {
        console.error('Erreur sauvegarde categories:', error);
        res.status(500).json({ error: 'Erreur lors de la sauvegarde des categories' });
    }
});

// POST /api/applications - Sauvegarder la liste des applications
app.post('/api/applications', async (req, res) => {
    try {
        const applications = req.body;

        // Validation basique
        if (!Array.isArray(applications)) {
            return res.status(400).json({ error: 'Le corps de la requete doit etre un tableau' });
        }

        // Validation de chaque application
        for (const app of applications) {
            if (!app.id || !app.name || !app.url) {
                return res.status(400).json({
                    error: 'Chaque application doit avoir au moins: id, name, url'
                });
            }
        }

        // Lire config actuelle pour preserver les categories
        try {
            const data = await fs.readFile(DATA_FILE, 'utf8');
            const config = JSON.parse(data);

            if (config.categories) {
                // Nouveau format - preserver les categories
                config.applications = applications;
                await fs.writeFile(DATA_FILE, JSON.stringify(config, null, 2));
            } else {
                // Ancien format - juste sauvegarder les apps
                await fs.writeFile(DATA_FILE, JSON.stringify(applications, null, 2));
            }
        } catch {
            // Fichier n'existe pas, creer avec nouveau format
            const newConfig = {
                categories: DEFAULT_CATEGORIES,
                applications: applications
            };
            await fs.writeFile(DATA_FILE, JSON.stringify(newConfig, null, 2));
        }

        console.log(`Applications sauvegardees: ${applications.length} entrees`);
        res.json({ success: true, count: applications.length });
    } catch (error) {
        console.error('Erreur sauvegarde applications:', error);
        res.status(500).json({ error: 'Erreur lors de la sauvegarde des applications' });
    }
});

// Health check
app.get('/health', (req, res) => {
    res.json({ status: 'ok', dataFile: DATA_FILE });
});

// Demarrage du serveur
(async () => {
    try {
        await ensureDataFile();
        app.listen(PORT, '0.0.0.0', () => {
            console.log(`API Portal demarree sur le port ${PORT}`);
            console.log(`Fichier de donnees: ${DATA_FILE}`);
        });
    } catch (error) {
        console.error('Erreur au demarrage:', error);
        process.exit(1);
    }
})();
