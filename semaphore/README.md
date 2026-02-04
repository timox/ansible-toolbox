# Semaphore UI - Ansible Management

Interface web pour deployer et gerer l'infrastructure via les playbooks Ansible, organisee en 4 projets distincts.

```
Administrateur --> Semaphore (port 3000)
                        |
        +---------------+---------------+---------------+
        |               |               |               |
  Infrastructure   Portail Securise  Monitoring    Network Backup
   bootstrap.yml    portal-site      zabbix-agent   backup-cisco
   check.yml        deploy-service   (dry run)      (no push)
   (dry run)        destroy
```

---

## Installation

### Prerequis

| Element | Verification |
|---------|--------------|
| Docker + Compose | `docker compose version` |
| jq | `jq --version` |
| curl | `curl --version` |
| Acces reseau | Depot Git accessible depuis le serveur |

### Configuration

```bash
cd semaphore
cp .env.example .env
```

Editer `.env` avec les valeurs requises (mots de passe, cle de chiffrement).

**Generer les secrets :**

```bash
# Mot de passe admin
openssl rand -base64 24

# Cle de chiffrement
head -c32 /dev/urandom | base64

# Mot de passe PostgreSQL
openssl rand -base64 16
```

### Build et demarrage

L'image custom inclut les collections Galaxy (`requirements.yml`) et les packages Python requis (`docker`, `jmespath`).

```bash
docker compose build
docker compose up -d
```

### Verification

```bash
docker compose ps
curl http://localhost:3000/api/ping
```

Acces : `http://<ip-serveur>:3000`

### Arret

```bash
# Arret simple
docker compose down

# Arret + suppression des donnees
docker compose down -v
```

---

## Configuration automatique des projets

Le script `setup-semaphore.sh` configure automatiquement les 4 projets via l'API Semaphore.

```bash
./setup-semaphore.sh
```

Le script cree pour chaque projet : keys, repository, inventaire, environnement et templates.

### 4 projets

| Projet | Playbooks | Groupe cible | Keys |
|--------|-----------|--------------|------|
| **Infrastructure** | bootstrap.yml, check.yml | `remote` | SSH, vault |
| **Portail Securise** | portal-site.yml, portal-deploy-service.yml, portal-destroy.yml | `portal_servers` | SSH, vault |
| **Monitoring** | deploy-zabbix-agent.yml | `zabbix_agents` | SSH |
| **Network Backup** | backup-cisco.yml | `network` | Cisco |

### Templates par projet

#### Infrastructure (3 templates)

| Template | Playbook | Vault |
|----------|----------|-------|
| Bootstrap - Server | bootstrap.yml | oui |
| Bootstrap - Dry Run | bootstrap.yml | oui |
| Check - Server state | check.yml | non |

#### Portail Securise (4 templates)

| Template | Playbook | Vault | Particularite |
|----------|----------|-------|---------------|
| Portal - Deploy Stack Complete | portal-site.yml | oui | Deploiement complet |
| Portal - Dry Run | portal-site.yml | oui | `--check --diff` |
| Portal - Deploy Service | portal-deploy-service.yml | oui | Survey : service |
| Portal - Destroy Service | portal-destroy.yml | oui | Survey : service + confirm |

#### Monitoring (2 templates)

| Template | Playbook | Vault |
|----------|----------|-------|
| Deploy - Zabbix Agent 2 | deploy-zabbix-agent.yml | non |
| Deploy - Zabbix Agent 2 (Dry Run) | deploy-zabbix-agent.yml | non |

#### Network Backup (2 templates)

| Template | Playbook | Vault |
|----------|----------|-------|
| Backup - Network configs | backup-cisco.yml | non |
| Backup - Network configs (no push) | backup-cisco.yml | non |

### Relancer le setup

Le script est idempotent : les ressources existantes sont detectees et conservees. Relancer le script n'ecrase pas les projets deja crees.

```bash
./setup-semaphore.sh
```

---

## Utilisation

### Deployer la stack portail

1. Projet **Portail Securise** -> **Task Templates**
2. **Run** sur `Portal - Deploy Stack Complete`
3. Suivre les logs en temps reel

### Deployer un service specifique

1. Projet **Portail Securise** -> **Run** sur `Portal - Deploy Service`
2. Remplir le survey : nom du service (ex: `guacamole`)

### Verifier sans modifier (dry run)

1. **Run** sur `Portal - Dry Run` ou `Bootstrap - Dry Run`
2. Affiche les changements qui seraient appliques

### Redeployer apres modification

1. Modifier les variables dans le depot Git
2. Commit + push
3. Dans Semaphore : **Run** sur le template concerne
4. Semaphore pull le depot et applique les changements

### Planifier des executions

1. Editer un template -> **Schedules** -> **Add Schedule**
2. Configurer la frequence (format cron)

---

## Image custom

Le `Dockerfile` construit une image basee sur `semaphoreui/semaphore:latest` avec :

- Collections Ansible Galaxy depuis `requirements.yml` :
  - `community.docker` (gestion containers)
  - `community.general` (utilitaires)
  - `ansible.posix` (modules POSIX)
  - `cisco.ios` (equipements reseau)
  - `ansible.netcommon` (connexions reseau)
- Packages Python :
  - `docker` (requis par `community.docker`)
  - `jmespath` (requis par `json_query`)

Rebuilder apres modification de `requirements.yml` :

```bash
docker compose build --no-cache
docker compose up -d
```

---

## Gestion des secrets

Les secrets sont dans `inventory/group_vars/*/vault.yml` (chiffre Ansible Vault).
Semaphore fournit le mot de passe via la Vault Key du Key Store.

### Modifier un secret

```bash
ansible-vault edit inventory/group_vars/all/vault.yml
# Modifier, sauvegarder, commit, push
```

### Override ponctuel via Semaphore

Dans le template, ajouter une Extra Variable :

```json
{
  "vault_oidc_client_secret": "nouveau-secret"
}
```

---

## Troubleshooting

### Semaphore ne demarre pas

```bash
docker compose logs semaphore
```

| Cause | Solution |
|-------|----------|
| `SEMAPHORE_ACCESS_KEY_ENCRYPTION` vide | Generer : `head -c32 /dev/urandom \| base64` |
| `SEMAPHORE_DB_PASS` incorrect | Verifier coherence avec la base |
| Port 3000 occupe | Changer `SEMAPHORE_PORT` dans `.env` |

### setup-semaphore.sh echoue

| Erreur | Cause | Solution |
|--------|-------|----------|
| Connexion refusee | Semaphore pas demarre | `docker compose up -d` |
| Token invalide | Mauvais credentials | Verifier `SEMAPHORE_ADMIN_USER/PASSWORD` dans `.env` |
| `jq: command not found` | jq absent | `apt install jq` |

### Le playbook echoue

| Erreur | Cause | Solution |
|--------|-------|----------|
| `vault password not provided` | Vault Key non configuree | Verifier vault-password dans le projet |
| `Permission denied` | Pas de sudo | Configurer sudo sans mot de passe |
| `Could not match supplied host pattern` | Mauvais chemin inventaire | Verifier File path dans Inventory |

### Tester en CLI avant Semaphore

```bash
ansible-playbook playbooks/check.yml --limit vps-ovh
```

---

## Fichiers

```
semaphore/
├── Dockerfile            # Image custom (collections + Python packages)
├── docker-compose.yml    # Semaphore + PostgreSQL
├── setup-semaphore.sh    # Configuration automatique des 4 projets
├── .env.example          # Template de configuration
├── .env                  # Configuration active (gitignored)
└── README.md             # Ce fichier
```
