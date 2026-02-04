# Guacamole Role

Deploys Apache Guacamole bastion with native OIDC authentication via Keycloak.

## Description

This role deploys a complete Guacamole bastion infrastructure including:

- **guacamole-web**: Web application with OIDC authentication
- **guacamole-daemon**: RDP/SSH/VNC protocol handler (network_mode: host)
- **guacamole-db**: PostgreSQL database for connection storage

Guacamole authenticates users directly with Keycloak using OpenID Connect, providing seamless SSO integration.

## Requirements

### Collections

- `community.docker` (for docker_compose_v2, docker_network, docker_container modules)

### System Requirements

- Docker and Docker Compose installed on target host
- Keycloak realm configured with OIDC client for Guacamole
- Network access to Keycloak issuer endpoint

### Keycloak Configuration

Create an OIDC client in Keycloak:

```yaml
Client ID: guacamole
Access Type: public (Authorization Code with PKCE recommended)
Valid Redirect URIs: https://guacamole.example.com/*
Web Origins: https://guacamole.example.com
```

Required mappers:
- `preferred_username` (User Property → username)
- `groups` (Group Membership → groups claim)

## Role Variables

### Required Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `keycloak_issuer` | Full OIDC issuer URL | `https://keycloak.example.com/realms/portal` |
| `domain` | Base domain | `example.com` |
| `guacamole_oidc_client_id` | Keycloak client ID | `guacamole` |
| `guacamole_db_password` | PostgreSQL password | (secret) |

### Optional Variables (defaults in defaults/main.yml)

| Variable | Default | Description |
|----------|---------|-------------|
| `guacamole_state` | `present` | Role state: `present` or `absent` |
| `guacamole_hostname` | `guacamole.{{ domain }}` | Public hostname |
| `guacamole_http_port` | `8081` | Container HTTP port |
| `guacamole_oidc_scope` | `openid email profile groups` | OIDC scopes |
| `guacamole_api_session_timeout` | `28800` | Session timeout (8 hours) |
| `guacamole_extension_priority` | `openid, jdbc` | Auth priority |

See `defaults/main.yml` for complete variable list.

## Dependencies

None. This role is self-contained.

## Example Playbook

### Basic Usage

```yaml
---
- name: Deploy Guacamole bastion
  hosts: bastion_servers
  become: true

  vars:
    keycloak_issuer: "https://keycloak.example.com/realms/portal"
    domain: "example.com"
    guacamole_oidc_client_id: "guacamole"

  tasks:
    - name: Retrieve Guacamole database password
      ansible.builtin.include_tasks: tasks/infisical-secret-lookup.yml
      vars:
        secret_name: 'GUACAMOLE_DB_PASSWORD'
        secret_var_name: 'guacamole_db_password'

    - name: Deploy Guacamole
      ansible.builtin.include_role:
        name: guacamole
```

### With Custom Configuration

```yaml
---
- name: Deploy Guacamole with custom settings
  hosts: bastion_servers
  become: true

  vars:
    guacamole_hostname: "bastion.example.com"
    guacamole_api_session_timeout: 14400  # 4 hours
    guacamole_oidc_allowed_clock_skew: 60

  tasks:
    - name: Get secrets
      ansible.builtin.include_tasks: tasks/infisical-secret-lookup.yml
      vars:
        secret_name: 'GUACAMOLE_DB_PASSWORD'
        secret_var_name: 'guacamole_db_password'

    - name: Deploy Guacamole
      ansible.builtin.include_role:
        name: guacamole
```

### Removal

```yaml
---
- name: Remove Guacamole
  hosts: bastion_servers
  become: true

  tasks:
    - name: Remove Guacamole services
      ansible.builtin.include_role:
        name: guacamole
      vars:
        guacamole_state: absent
```

## Architecture Notes

### Network Mode: Host

The `guacamole-daemon` container uses `network_mode: host` to enable direct access to the local network for establishing RDP, SSH, and VNC connections to physical or virtual machines.

This is necessary because:
- Docker bridge networks are isolated from the host's network
- RDP/SSH/VNC connections require direct IP access to target machines
- Host network mode bypasses Docker's network isolation

The `guacamole-web` container uses `extra_hosts: guacamole-daemon:host-gateway` to reach the daemon.

### OIDC Authentication Flow

```
User → nginx (SSL) → guacamole-web → Keycloak OIDC → Authentication
                          ↓
                      guacamole-daemon → RDP/SSH/VNC targets
```

Guacamole handles OIDC authentication natively using the `guacamole-auth-sso-openid` extension, providing:
- Direct integration with Keycloak (no proxy manipulation)
- Complete SSO logout flow
- Standard OIDC protocol support
- Group-based authorization

## Handlers

- `restart guacamole-web` - Restarts web container (triggered on config change)
- `restart guacamole-daemon` - Restarts protocol daemon
- `restart guacamole-db` - Restarts PostgreSQL database

## Files Generated

| File | Purpose |
|------|---------|
| `/data/guacamole/guacamole.properties` | Main configuration (OIDC, DB, settings) |
| `/data/guacamole/postgres/` | PostgreSQL data directory |
| `/data/guacamole/drive/` | User file sharing storage |
| `/data/guacamole/record/` | Session recordings |
| `/data/logs/guacamole/` | Application logs |

## Troubleshooting

### OIDC Authentication Fails

Check:
1. Keycloak client `guacamole` exists and is configured correctly
2. Redirect URI matches: `https://guacamole.example.com/guacamole/`
3. Certificate trust (if using self-signed certs)
4. Keycloak issuer is reachable from guacamole-web container

### Database Connection Issues

```bash
# Check guacamole-db health
docker inspect guacamole-postgres --format='{{.State.Health.Status}}'

# View database logs
docker logs guacamole-postgres
```

### Cannot Connect to RDP/SSH Targets

Verify:
1. `guacamole-daemon` is using `network_mode: host`
2. Firewall allows connections from Docker host to targets
3. Target services (RDP/SSH/VNC) are listening
4. Test connectivity: `telnet target-ip 3389` (RDP) or `telnet target-ip 22` (SSH)

### Health Checks

```bash
# Check all container health
docker ps --filter name=guacamole

# Test web interface
curl http://localhost:8081/

# Check daemon connectivity
docker exec guacamole-web bash -c 'timeout 2 bash -c "</dev/tcp/guacamole-daemon/4822"'
```

## License

MIT

## Author

Portail Securise Team
