# Rundeck - Runbook Automation

Alternative à Semaphore avec une UI plus riche.

## Fonctionnalités vs Semaphore

| Fonctionnalité | Rundeck | Semaphore |
|----------------|---------|-----------|
| Navigateur de fichiers Git | ✅ Oui | ❌ Non |
| Workflows visuels | ✅ Oui | ❌ Non |
| Formulaires (Survey) | ✅ Complet | ⚠️ Basique |
| RBAC | ✅ Complet | ⚠️ Limité |
| Inventaire dynamique | ✅ Plugins | ❌ Non |
| Notifications | ✅ Email, Slack, Webhook | ✅ Webhook |
| API REST | ✅ Complète | ✅ Complète |
| Ressources | ~1-2 GB RAM | ~256 MB RAM |

## Installation

```bash
# 1. Copier et configurer l'environnement
cp .env.example .env

# Générer un mot de passe DB
echo "RUNDECK_DB_PASS=$(openssl rand -base64 24)" >> .env

# Éditer .env pour changer RUNDECK_ADMIN_PASS
nano .env

# 2. Démarrer
docker compose up -d

# 3. Attendre l'initialisation (~2 minutes)
docker compose logs -f rundeck

# 4. Accéder
# http://localhost:4440
# Login: admin / <RUNDECK_ADMIN_PASS>
```

## Configuration Ansible

### Créer un projet Ansible

1. **New Project** → Nom: `infrastructure`
2. **Default Node Executor**: `Ansible Ad-Hoc Node Executor`
3. **Default File Copier**: `Ansible File Copier`
4. **Node Source**: `Ansible Resource Model Source`
   - Ansible inventory: `/home/rundeck/ansible-toolbox/inventory/hosts.yml`

### Créer un Job (équivalent Template Semaphore)

1. **Create Job**
2. **Workflow** → Add Step → **Ansible Playbook**
   - Playbook: `/home/rundeck/ansible-toolbox/playbooks/check.yml`
   - Extra Variables: (optionnel)
3. **Nodes** → Dispatch to Nodes: sélectionner les cibles
4. **Save**

## Structure des dossiers

```
/home/rundeck/
├── ansible-toolbox/     # Monté depuis le host (lecture seule)
│   ├── inventory/
│   ├── playbooks/
│   └── roles/
├── .ssh/                # Clés SSH pour les nodes
├── projects/            # Définitions des projets
└── server/data/         # Données Rundeck
```

## Ajout de clés SSH

```bash
# Copier une clé SSH dans le container
docker cp ~/.ssh/id_ansible_toolbox rundeck:/home/rundeck/.ssh/

# Ou via l'interface: Gear Icon → Key Storage → Add Key
```

## Accès externe (reverse proxy)

Pour exposer Rundeck derrière nginx:

```nginx
server {
    listen 443 ssl;
    server_name rundeck.example.com;

    location / {
        proxy_pass http://localhost:4440;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Puis dans `.env`:
```
RUNDECK_URL=https://rundeck.example.com
```

## Troubleshooting

### Rundeck ne démarre pas
```bash
# Vérifier les logs
docker compose logs rundeck

# Vérifier la DB
docker compose logs rundeck-db
```

### Erreur de connexion aux nodes
```bash
# Vérifier les permissions SSH
docker exec rundeck ls -la /home/rundeck/.ssh/

# Tester la connexion
docker exec rundeck ssh -i /home/rundeck/.ssh/id_rsa user@host
```

### Reset complet
```bash
docker compose down -v
docker compose up -d
```

## Liens

- [Documentation officielle](https://docs.rundeck.com/)
- [Ansible Plugin](https://docs.rundeck.com/docs/manual/plugins/ansible-plugins-overview.html)
- [API Reference](https://docs.rundeck.com/docs/api/)
