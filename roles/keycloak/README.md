# Ansible Role: keycloak

Deploys Keycloak Identity Provider as a standalone service using Docker Compose.

## Description

This role manages the deployment of Keycloak via the existing docker-compose.yml configuration. It handles:

- Network creation (keycloak-net)
- Certificate validation
- Docker Compose deployment
- Readiness checking via OIDC discovery endpoint
- Service removal (state: absent)

## Requirements

- Docker and Docker Compose installed on target host
- Ansible collection: `community.docker`
- TLS certificates at `{{ data_dir }}/certs/tls.crt` and `tls.key`
- `.env` file at `{{ prod_dir }}/.env` with required variables
- `common` role (for shared variables and prerequisites)

## Role Variables

### Required Variables

These must be defined in group_vars or inventory:

```yaml
# Keycloak OIDC issuer URL (required)
keycloak_issuer: "https://keycloak.example.com/realms/portal"

# Secrets (from vault.yml)
vault_keycloak_admin_password: "admin-password"
vault_keycloak_db_password: "db-password"

# Shared variables (from common role)
domain: "example.com"
data_dir: "/data"
prod_dir: "/path/to/prod"
keycloak_admin: "admin"
keycloak_host_backend_url: "http://localhost:8080"
```

### Optional Variables (defaults/main.yml)

```yaml
# Service state
keycloak_state: present  # or absent

# Readiness check timeouts
keycloak_readiness_timeout: 300
keycloak_readiness_delay: 10
keycloak_readiness_retries: 30

# Backend URL for health checks
keycloak_backend_url: "{{ keycloak_host_backend_url }}"

# Ports
keycloak_http_port: 8080
keycloak_https_port: 8443

# Docker Compose paths
keycloak_compose_project_src: "{{ prod_dir }}/keycloak"
keycloak_compose_file: "docker-compose.yml"
keycloak_compose_env_file: "{{ prod_dir }}/.env"
```

## Dependencies

This role depends on:

- `common` - Provides shared variables and directory structure

## Example Playbook

### Basic Usage

```yaml
---
- name: Deploy Keycloak
  hosts: keycloak_servers
  become: true

  roles:
    - role: keycloak
```

### With Custom Variables

```yaml
---
- name: Deploy Keycloak with custom timeout
  hosts: keycloak_servers
  become: true

  roles:
    - role: keycloak
      vars:
        keycloak_readiness_retries: 60
        keycloak_readiness_delay: 5
```

### Remove Keycloak

```yaml
---
- name: Remove Keycloak deployment
  hosts: keycloak_servers
  become: true

  roles:
    - role: keycloak
      vars:
        keycloak_state: absent
```

## Tags

This role supports the following tags:

- `keycloak` - All keycloak tasks
- `keycloak-validate` - Validation tasks only
- `keycloak-deploy` - Deployment tasks only
- `keycloak-network` - Network creation only
- `keycloak-dirs` - Directory creation only
- `keycloak-certs` - Certificate validation only
- `keycloak-compose` - Docker Compose operations only
- `keycloak-readiness` - Readiness check only
- `keycloak-remove` - Removal tasks only
- `keycloak-restart` - Restart handler only

### Usage Examples

```bash
# Deploy only
uv run ansible-playbook playbooks/keycloak.yml --tags keycloak-deploy

# Check readiness only
uv run ansible-playbook playbooks/keycloak.yml --tags keycloak-readiness

# Skip readiness check
uv run ansible-playbook playbooks/keycloak.yml --skip-tags keycloak-readiness
```

## Architecture

### Deployment Flow

```
1. Validate inputs (state, issuer)
2. Create keycloak-net network
3. Ensure directories exist
4. Validate TLS certificates
5. Deploy via docker compose
6. Wait for OIDC discovery endpoint
7. Verify issuer matches expected value
```

### Readiness Check

The role polls the OIDC discovery endpoint:

```
GET {{ keycloak_backend_url }}/realms/{{ realm }}/.well-known/openid-configuration
```

It validates:
- HTTP 200 response
- Response contains valid JSON
- Issuer field matches `keycloak_issuer`

### Docker Compose Integration

The role uses the existing `keycloak/docker-compose.yml` with:

- `env_file: ../.env` - All environment variables
- `volumes: /data/certs:/opt/keycloak/certs:ro` - TLS certificates
- `networks: keycloak-net` - Isolated network

## Handlers

- `keycloak deployed` - Triggered after successful deployment
- `restart keycloak` - Restarts Keycloak services

## Idempotency

This role is fully idempotent:

- Network creation uses `state: present` (no-op if exists)
- Directory creation checks before creating
- Docker Compose only reports changed if services are modified
- Readiness check has `changed_when: false`
- Removal is idempotent via `state: absent`

## Error Handling

The role will fail if:

- `keycloak_state` is not `present` or `absent`
- `keycloak_issuer` is undefined or empty (when state=present)
- TLS certificates are missing
- Keycloak does not respond within timeout period
- OIDC discovery issuer doesn't match expected value

## Integration with deploy.sh

This role replaces the following deploy.sh sections:

```bash
# deploy.sh lines 1485-1488 (secret generation)
generate_secret "KEYCLOAK_ADMIN_PASSWORD"
generate_secret "KEYCLOAK_DB_PASSWORD"

# deploy.sh lines 1532-1537 (network creation)
docker network create keycloak-net

# deploy.sh lines 1730-1758 (keycloak deployment and wait)
check_keycloak
deploy_service "keycloak"
wait_for_keycloak 60
```

## Related Roles

- `common` - Shared prerequisites and variables
- `oauth2-proxy` - Depends on Keycloak for OIDC

## License

MIT

## Author

Portail Securise Team
