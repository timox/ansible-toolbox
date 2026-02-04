# Portal API Role

Deploy the Portal API backend for managing portal applications.

## Description

This role deploys the Portal API Node.js backend via Docker Compose. The API provides:

- `GET/POST /api/applications` - Application management endpoints
- `GET /api/categories` - List application categories
- `GET /health` - Health check endpoint

## Requirements

- Docker and Docker Compose installed
- `common` role applied
- Network `portal-net` must exist (created by common role)
- Valid `.env` file at `{{ prod_dir }}/.env`

## Role Variables

### Required Variables (from group_vars)

| Variable | Description | Example |
|----------|-------------|---------|
| `domain` | Base domain | `example.com` |
| `data_dir` | Data directory | `/data` |
| `prod_dir` | Production directory | `/opt/prod` |
| `env_file` | Environment file path | `/opt/prod/.env` |
| `keycloak_issuer` | Keycloak OIDC issuer | `https://keycloak.example.com/realms/portal` |
| `oidc_client_id` | OAuth2 Proxy client ID | `oauth2-proxy` |

### Defaults (overridable)

| Variable | Default | Description |
|----------|---------|-------------|
| `portal_api_state` | `present` | Deployment state (`present`/`absent`) |
| `portal_api_project_name` | `portal-api` | Docker Compose project name |
| `portal_api_admin_group` | `admin-infra` | Portal admin group name |
| `portal_api_vaultwarden_enabled` | `{{ deploy_vaultwarden }}` | Enable Vaultwarden integration |
| `portal_api_health_check_retries` | `30` | Health check retry count |
| `portal_api_health_check_delay` | `10` | Health check delay (seconds) |

### Computed Variables

| Variable | Description |
|----------|-------------|
| `portal_api_build_date` | ISO 8601 timestamp of build |
| `portal_api_poc_ip` | Server IP address (detected) |

## Dependencies

This role depends on:

- `common` - Network creation, base system setup

## Tags

| Tag | Purpose |
|-----|---------|
| `portal-api` | All portal-api tasks |
| `portal-api-config` | Config generation only |
| `portal-api-deploy` | Deployment only |

## Example Playbook

```yaml
---
- name: Deploy Portal API
  hosts: all
  become: true

  roles:
    - role: portal_api
      vars:
        portal_api_state: present
```

### Deploy with specific admin group

```yaml
---
- name: Deploy Portal API with custom admin group
  hosts: all
  become: true

  roles:
    - role: portal_api
      vars:
        portal_api_admin_group: "admin-custom"
```

### Remove Portal API

```yaml
---
- name: Remove Portal API
  hosts: all
  become: true

  roles:
    - role: portal_api
      vars:
        portal_api_state: absent
```

## Configuration Template

The role generates `portal/www/config.json` from the template if `portal/www/config.json.template` exists.

Template variables are sourced from:

- `group_vars/all/vars.yml` - Global configuration
- Role defaults - Portal-specific defaults
- Facts - Computed values (IP, timestamp)

## Directory Structure

```
portal_api/
├── defaults/
│   └── main.yml          # Default variables
├── tasks/
│   ├── main.yml          # Task router
│   ├── generate_config.yml  # Config template processing
│   └── deploy.yml        # Docker Compose deployment
├── templates/
│   └── config.json.j2    # Portal config template
├── handlers/
│   └── main.yml          # Restart handler
├── meta/
│   └── main.yml          # Role metadata, dependencies
└── README.md             # This file
```

## Health Check

The role waits for the Portal API to be healthy after deployment by checking:

- URL: `http://localhost:3000/health`
- Expected: HTTP 200
- Retries: 30 (default)
- Delay: 10s (default)

Total wait time: up to 5 minutes by default.

## Docker Compose Files

This role uses:

- **Project source**: `{{ prod_dir }}/portal`
- **Compose file**: `docker-compose.api.yml`
- **Environment**: `{{ env_file }}`

## Network

The Portal API container connects to:

- `portal-net` - External network for portal services

## Data Persistence

Portal API stores data in:

- `{{ data_dir }}/portal` - Application data

## Troubleshooting

### Config not generated

**Symptom**: Warning about missing template

**Cause**: `portal/www/config.json.template` doesn't exist

**Solution**: Ensure template file exists in source repository

### Health check timeout

**Symptom**: Task fails waiting for health check

**Cause**: Container not starting or taking too long

**Solution**:

```bash
# Check container logs
docker logs portal-api

# Check container status
docker ps -a | grep portal-api

# Manually test health endpoint
curl http://localhost:3000/health
```

### Permission errors

**Symptom**: Container can't write to data directory

**Cause**: Incorrect permissions on `{{ data_dir }}/portal`

**Solution**:

```bash
# Fix permissions
sudo chown -R root:root {{ data_dir }}/portal
sudo chmod 755 {{ data_dir }}/portal
```

## Examples

### Deploy Portal API

```bash
cd ansible
uv run ansible-playbook playbooks/deploy-portal-api.yml
```

### Regenerate config only

```bash
cd ansible
uv run ansible-playbook playbooks/deploy-portal-api.yml --tags portal-api-config
```

### Check deployment status

```bash
# Container status
docker ps | grep portal-api

# Health check
curl http://localhost:3000/health

# Logs
docker logs portal-api --tail 50
```

## License

MIT

## Author Information

Portail Securise Team
