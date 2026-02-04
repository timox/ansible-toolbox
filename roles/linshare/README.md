# Ansible Role: linshare

Deploy and configure LinShare secure file sharing platform with Keycloak OIDC authentication.

## Description

This role deploys the complete LinShare stack including:
- PostgreSQL database for metadata
- MongoDB for file storage
- LinShare backend API with OIDC authentication
- LinShare user interface
- LinShare admin interface
- ClamAV antivirus scanning
- Thumbnail generation service

LinShare uses native OIDC authentication with Keycloak and requires:
1. Configuration files generated from templates
2. Java truststore with Keycloak certificates
3. OIDC domain configuration via LinShare Admin API

## Requirements

- Docker and Docker Compose installed
- Keycloak instance running and accessible
- Wildcard SSL certificate at `{{ data_dir }}/certs/wildcard.{{ domain }}.crt`
- Ansible collections:
  - `community.docker`
  - `community.general`

## Role Variables

### Required Variables

Variables that MUST be defined in group_vars or vault:

```yaml
# OIDC secrets (in vault.yml)
vault_linshare_oidc_client_secret: "your-keycloak-client-secret"
vault_linshare_db_password: "postgres-password"
vault_linshare_mongo_password: "mongodb-password"

# From group_vars/all/vars.yml
domain: "example.com"
keycloak_issuer: "https://keycloak.example.com/realms/portal"
data_dir: "/data"
```

### Optional Variables

Variables with defaults in `defaults/main.yml`:

```yaml
# Deployment control
linshare_state: present  # or absent

# Version
linshare_version: "6.0"

# OIDC Configuration
linshare_oidc_client_id: linshare

# Admin credentials
linshare_admin_user: "root@localhost.localdomain"
linshare_admin_password: adminlinshare
linshare_admin_email: "admin@{{ domain }}"

# Storage limits
linshare_max_file_size: 104857600  # 100MB
linshare_quota_default: 10737418240  # 10GB

# Service ports
linshare_user_port: 8082
linshare_admin_port: 8083

# Database
linshare_postgres_host: linshare-db
linshare_postgres_user: linshare

# MongoDB
linshare_mongodb_host: linshare-mongodb
linshare_mongodb_user: linshare

# SMTP
linshare_smtp_host: "smtp.{{ domain }}"
linshare_smtp_port: 587
linshare_smtp_from: "noreply@{{ domain }}"
```

## Dependencies

None.

## Example Playbook

### Basic Deployment

```yaml
---
- name: Deploy LinShare
  hosts: all
  become: true

  roles:
    - role: linshare
```

### With Custom Variables

```yaml
---
- name: Deploy LinShare with custom config
  hosts: all
  become: true

  vars:
    linshare_max_file_size: 209715200  # 200MB
    linshare_quota_default: 53687091200  # 50GB
    linshare_admin_email: "support@example.com"

  roles:
    - role: linshare
```

### Remove LinShare

```yaml
---
- name: Remove LinShare
  hosts: all
  become: true

  roles:
    - role: linshare
      vars:
        linshare_state: absent
```

## Architecture

### Generated Configuration Files

The role generates these files from templates:

| File | Purpose | Contains Secrets |
|------|---------|------------------|
| `linshare.properties` | Backend OIDC config | Yes (passwords, client secret) |
| `config.js` | User UI OIDC config | Yes (client secret) |
| `config-admin.js` | Admin UI OIDC config | Yes (client secret) |

### Java Truststore Generation

LinShare backend requires a Java truststore to trust Keycloak's certificate for HTTPS OIDC calls:

1. Copies base truststore from Keycloak container
2. Uses `docker run` with `eclipse-temurin:17-jre-jammy` for keytool
3. Imports wildcard certificate as trusted CA
4. Idempotent - skips if truststore exists

### OIDC Domain Configuration

LinShare requires an OIDC User Provider configured via API:

1. Creates a TOPDOMAIN with name = `{{ domain }}`
2. Creates OIDC User Provider with `domainDiscriminator = {{ domain }}`
3. Idempotent - handles 409 Conflict responses

The `domainDiscriminator` must match the value sent by Keycloak's `domain_discriminator` mapper.

## Patterns Applied

This role follows repository conventions:

- **FQCN**: All modules use fully-qualified collection names
- **Idempotency**:
  - Truststore generation checks if file exists
  - API calls handle 409 Conflict for existing resources
  - Docker compose state management
- **Secrets**: `no_log: true` on all tasks with vault variables
- **changed_when**: Explicit change detection on shell/command tasks
- **Handlers**: Service restarts only when configs change

## Keycloak Configuration

Before using this role, configure Keycloak:

1. Create client `linshare` (confidential, PKCE enabled)
2. Add redirect URIs: `https://linshare.{{ domain }}/*`
3. Create mapper `domain_discriminator` (hardcoded claim) with value = `{{ domain }}`
4. Add standard mappers: email, preferred_username, groups

## Troubleshooting

### PKIX Certificate Error

**Symptom**: LinShare backend logs show "PKIX path building failed"

**Solution**: Truststore generation failed or doesn't include Keycloak cert

```bash
# Check truststore
ls -la /data/linshare/certs/cacerts

# Manually regenerate if needed
ansible-playbook playbooks/linshare.yml --tags truststore
```

### Domain Discriminator Mismatch

**Symptom**: "Can not find domain using domain discriminators: [example.com]"

**Solution**: OIDC User Provider not configured or domainDiscriminator mismatch

```bash
# Check OIDC provider
docker exec linshare-backend curl -s -u 'root@localhost.localdomain:adminlinshare' \
  http://localhost:8080/linshare/webservice/rest/admin/v5/domains | jq

# Rerun OIDC configuration
ansible-playbook playbooks/linshare.yml --tags oidc
```

### Backend Not Healthy

**Symptom**: Deployment times out waiting for backend health check

**Check logs**:
```bash
docker logs linshare-backend --tail 50
```

Common causes:
- Database not ready (PostgreSQL or MongoDB)
- Invalid OIDC credentials
- Missing truststore

## Tags

This role supports these tags:

- `linshare` - Full LinShare deployment
- `linshare-config` - Generate configs only
- `linshare-truststore` - Generate truststore only
- `linshare-oidc` - Configure OIDC domain only

## License

MIT

## Author

Portail Securise Team
