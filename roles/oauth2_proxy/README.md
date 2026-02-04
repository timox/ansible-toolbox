# Ansible Role: oauth2_proxy

Deploys oauth2-proxy authentication proxy with nginx multi-application reverse proxy and Redis session storage.

## Description

This role manages the complete oauth2-proxy authentication stack including:

- **oauth2-proxy**: OIDC authentication proxy (Keycloak integration)
- **nginx-apps**: Multi-application reverse proxy with conditional service routing
- **redis**: Session storage backend (avoids cookie size issues)

The role generates configuration from Jinja2 templates and conditionally enables/disables service-specific nginx configs based on deployment flags.

## Requirements

- Docker and docker compose v2 installed
- Keycloak realm configured with oauth2-proxy client
- Valid SSL certificates in `/data/certs/`
- Docker networks: auth-net, prod_apps-net, guacamole-net, portal-net, keycloak-net

## Role Variables

### Required Variables (from vault.yml)

```yaml
vault_oidc_client_secret: "secret-from-keycloak"
vault_cookie_secret: "base64-encoded-32-byte-secret"
```

### Core Variables (from group_vars/all/vars.yml)

```yaml
# Domain and hostnames
domain: example.com
portal_hostname_resolved: "portail.{{ domain }}"
guacamole_hostname_resolved: "guacamole.{{ domain }}"
keycloak_issuer: "https://keycloak.{{ domain }}/realms/portal"

# OIDC configuration
oidc_client_id: oauth2-proxy

# Feature flags (control nginx config generation)
deploy_linshare: false
deploy_headscale: true
deploy_vaultwarden: true
deploy_bookstack: false

# Ports
oauth2_proxy_http_port: 4180
oauth2_proxy_https_port: 44180
nginx_http_port: 80
nginx_https_port: 443
```

### Defaults (overridable)

See `defaults/main.yml` for full list. Notable defaults:

```yaml
oauth2_proxy_image: "quay.io/oauth2-proxy/oauth2-proxy:v7.6.0"
nginx_apps_image: "nginx:1.27-alpine"
redis_image: "redis:7.4-alpine"
oauth2_proxy_session_store_type: redis
oauth2_proxy_ssl_insecure_skip_verify: true
oauth2_proxy_restart_policy: unless-stopped
```

## Dependencies

This role depends on the `common` role for:
- Docker network creation
- Base directory structure
- Certificate management

## Example Playbook

```yaml
---
- name: Deploy oauth2-proxy authentication stack
  hosts: all
  become: true

  roles:
    - role: oauth2_proxy
      tags:
        - oauth2_proxy
```

### With Variable Overrides

```yaml
---
- name: Deploy oauth2-proxy with custom config
  hosts: all
  become: true

  vars:
    oauth2_proxy_deploy_linshare: true
    oauth2_proxy_deploy_bookstack: true

  roles:
    - role: oauth2_proxy
```

## Template Conversion

This role converts the original `envsubst` templates to Jinja2:

| Original | Jinja2 Template | Output |
|----------|-----------------|--------|
| `${DOMAIN}` | `{{ domain }}` | Variable substitution |
| `${KEYCLOAK_ISSUER}` | `{{ keycloak_issuer }}` | Variable substitution |
| `$host`, `$remote_addr` | `$host`, `$remote_addr` | **Preserved** (nginx runtime vars) |

**Critical**: Nginx runtime variables like `$host`, `$proxy_add_x_forwarded_for`, `$upstream_http_x_auth_request_user`, etc. are preserved as-is because they are evaluated by nginx at request time, not during template processing.

## Conditional Nginx Configs

The role manages nginx configs for optional services based on deploy flags:

- `deploy_linshare: true` → generates `nginx/conf.d/linshare.conf`
- `deploy_headscale: true` → generates `nginx/conf.d/headscale.conf`
- `deploy_vaultwarden: true` → generates `nginx/conf.d/vaultwarden.conf`
- `deploy_bookstack: true` → generates `nginx/conf.d/bookstack.conf`

When a service is disabled (flag = false), the role removes the corresponding nginx config and triggers nginx reload.

## Handlers

- `restart oauth2-proxy`: Restarts oauth2-proxy container (throttled to 1 at a time)
- `reload nginx-apps`: Graceful nginx reload without connection drops
- `restart nginx-apps`: Full nginx restart (throttled)

## Tags

- `oauth2_proxy`: All oauth2_proxy tasks
- `oauth2_proxy_config`: Config generation only
- `oauth2_proxy_nginx`: Nginx config management only
- `oauth2_proxy_deploy`: Docker compose deployment only

## Directory Structure

```
roles/oauth2_proxy/
├── defaults/main.yml
├── tasks/
│   ├── main.yml
│   ├── generate_configs.yml
│   ├── manage_nginx_configs.yml
│   └── deploy.yml
├── templates/
│   ├── oauth2-proxy.cfg.j2
│   ├── apps.conf.j2
│   ├── linshare.conf.j2
│   ├── headscale.conf.j2
│   ├── vaultwarden.conf.j2
│   ├── bookstack.conf.j2
│   └── config.json.j2
├── handlers/main.yml
├── meta/main.yml
└── README.md
```

## Security Notes

- `no_log: true` applied to tasks handling secrets (oauth2-proxy.cfg generation)
- Cookie secret must be 32 bytes, base64-encoded
- OIDC client secret retrieved from Keycloak Credentials tab
- Session data stored in Redis (not in cookies) for security and size limits

## Validation

The role includes automatic validation:

1. Nginx config syntax check after generation
2. Health checks on oauth2-proxy `/ping` endpoint
3. Container running state verification
4. Redis connectivity check

## Troubleshooting

### oauth2-proxy not starting

```bash
# Check oauth2-proxy logs
docker logs oauth2-proxy

# Verify OIDC client secret
grep "client_secret" /path/to/oauth2-proxy.cfg

# Test OIDC discovery
curl https://keycloak.example.com/realms/portal/.well-known/openid-configuration
```

### Nginx config errors

```bash
# Validate nginx config
docker exec nginx-apps nginx -t

# Check nginx logs
docker logs nginx-apps

# Verify generated configs
ls -la /path/to/oauth2-proxy/nginx/conf.d/
```

### Service not appearing in nginx

Check deployment flag in vars:
```yaml
deploy_linshare: true  # Must be true to generate linshare.conf
```

## Architecture

```
User → nginx-apps (443) → oauth2-proxy (4180) → Keycloak OIDC
                   ↓
          Backend services (conditional routing)
                   ↓
      oauth2-proxy sessions → Redis (6379)
```

## License

MIT

## Author

Pomeguac Team
