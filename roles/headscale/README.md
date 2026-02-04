# Ansible Role: Headscale

Deploy and manage Headscale VPN mesh with Headplane UI and Keycloak OIDC authentication.

## Description

This role deploys Headscale (open-source Tailscale control plane) with:

- Headscale v0.27.1 VPN control plane
- Headplane web UI with OIDC authentication
- Keycloak OIDC integration for user authentication
- Automatic API key generation for Headplane
- Docker Compose deployment with external networks

## Requirements

- Docker and Docker Compose installed
- Keycloak instance accessible (for OIDC)
- Wildcard SSL certificate in `/data/certs/`
- Docker networks created: `headscale-net`, `prod_apps-net`, `keycloak-net`

## Role Variables

### Required Variables

These variables must be defined (typically in `group_vars/all/vars.yml` or `vault.yml`):

```yaml
# Domain configuration
domain: example.com
keycloak_issuer: https://keycloak.example.com/realms/portal

# Secrets (in vault.yml)
vault_headscale_oidc_client_secret: "your-secret"
vault_headplane_cookie_secret: "random-32-chars"
```

### Optional Variables (defaults/main.yml)

```yaml
# Service state
headscale_state: present  # or absent

# Docker versions
headscale_version: "0.27.1"
headscale_headplane_version: "latest"

# Network ports
headscale_https_port: 9443
headscale_metrics_port: 9091
headscale_headplane_port: 3000

# Directories
headscale_data_dir: "/data/headscale"
headscale_config_dir: "{{ prod_dir }}/headscale"

# OIDC client ID
headscale_oidc_client_id: "headscale"

# API key settings
headscale_api_key_expiration: "365d"
```

### Computed Variables

The role computes these variables internally:

```yaml
headscale_hostname_resolved: "{{ headscale_hostname | default('vpn.' + domain, true) }}"
```

## Dependencies

None. This role is self-contained.

## Example Playbook

### Basic Usage

```yaml
---
- name: Deploy Headscale VPN
  hosts: vpn_servers
  become: true

  roles:
    - role: headscale
```

### With Custom Variables

```yaml
---
- name: Deploy Headscale with custom hostname
  hosts: vpn_servers
  become: true

  vars:
    headscale_hostname: "mesh.example.com"
    headscale_version: "0.27.1"

  roles:
    - role: headscale
```

### Remove Headscale

```yaml
---
- name: Remove Headscale deployment
  hosts: vpn_servers
  become: true

  vars:
    headscale_state: absent
    headscale_purge_data: true  # Also remove data directories

  roles:
    - role: headscale
```

## Keycloak Configuration

Before running this role, configure Keycloak:

### 1. Create Client

```
Client ID: headscale
Access Type: confidential
Valid Redirect URIs:
  - https://vpn.example.com/oidc/callback
  - https://vpn.example.com/admin/oidc/callback
```

### 2. Create Mappers

Add these client mappers:

- **groups**: Group Membership → Token Claim Name: `groups`
- **email**: User Property → Token Claim Name: `email`
- **profile**: User Property → Token Claim Name: `preferred_username`

### 3. Retrieve Secret

Go to `Clients → headscale → Credentials` and copy the Client Secret to `vault_headscale_oidc_client_secret`.

## Generated Files

The role generates these configuration files:

| Template | Output | Purpose |
|----------|--------|---------|
| config.yaml.template | config.yaml | Headscale server config |
| headplane.yaml.template | headplane.yaml | Headplane UI config |
| Caddyfile.template | Caddyfile | Caddy reverse proxy (if used) |
| acls.yaml.template | acls.yaml | ACL definitions (legacy) |

## API Key Generation

The role automatically generates a Headscale API key for Headplane if not already configured:

1. Waits for Headscale container to be ready
2. Runs `docker exec headscale headscale apikeys create --expiration 365d`
3. Updates `.env` file with `HEADSCALE_API_KEY=...`
4. Regenerates `headplane.yaml` with the new key
5. Restarts Headplane container

This is idempotent - the key is only generated once.

## Tags

No tags are currently defined. All tasks run sequentially.

## Handlers

| Handler | Trigger | Action |
|---------|---------|--------|
| restart headscale | Config changes | Restart headscale container |
| restart headplane | Config changes | Restart headplane container |
| regenerate nginx configs | Deploy/remove | Trigger nginx role handler |

## Testing

### Verify Deployment

```bash
# Check container status
docker ps | grep headscale

# Check Headscale logs
docker logs headscale

# Check Headplane logs
docker logs headplane

# Test OIDC discovery
curl https://keycloak.example.com/realms/portal/.well-known/openid-configuration

# Access Headplane UI
curl https://vpn.example.com/admin/
```

### Verify API Key

```bash
# Check if API key exists
grep HEADSCALE_API_KEY /path/to/.env

# List API keys in Headscale
docker exec headscale headscale apikeys list
```

## Troubleshooting

### Issue: Headscale container fails to start

**Check:**

1. Verify Keycloak is accessible: `curl {{ keycloak_issuer }}/.well-known/openid-configuration`
2. Check OIDC client secret is correct
3. Review logs: `docker logs headscale`

### Issue: API key generation fails

**Check:**

1. Headscale container is running: `docker ps | grep headscale`
2. Run manually: `docker exec headscale headscale apikeys create`
3. Check logs: `docker logs headscale`

### Issue: Headplane cannot connect to Headscale

**Check:**

1. Docker networks exist: `docker network ls | grep headscale`
2. API key is set in headplane.yaml
3. Headscale API is accessible: `curl http://headscale:8080/health`

## Directory Structure

```
roles/headscale/
├── defaults/
│   └── main.yml           # User-configurable variables
├── tasks/
│   ├── main.yml           # Task router
│   ├── deploy.yml         # Deployment tasks
│   ├── generate_configs.yml  # Template processing
│   ├── generate_api_key.yml  # API key generation
│   └── remove.yml         # Removal tasks
├── templates/
│   ├── config.yaml.j2     # Headscale config
│   └── headplane.yaml.j2  # Headplane config
├── handlers/
│   └── main.yml           # Service restart handlers
├── meta/
│   └── main.yml           # Role metadata
└── README.md              # This file
```

## License

MIT

## Author Information

Created for Portail Sécurisé infrastructure automation with Ansible.

## Related Roles

- **oauth2_proxy** - Reverse proxy with OIDC authentication
- **common** - Common infrastructure tasks (networks, directories)
