# ansible-toolbox

Reusable Ansible playbooks for server provisioning and management.

## Quick Start

```bash
# 1. Install dependencies
ansible-galaxy install -r requirements.yml

# 2. Configure vault password
cp .vault-password.example .vault-password
echo "your-vault-password" > .vault-password
chmod 600 .vault-password

# 3. First run (password authentication)
ansible-playbook playbooks/bootstrap.yml --ask-pass

# 4. Subsequent runs (key-based auth)
ansible-playbook playbooks/bootstrap.yml
```

## Structure

```
ansible-toolbox/
├── ansible.cfg              # Ansible configuration
├── requirements.yml         # Galaxy collections
├── inventory/
│   ├── hosts.yml            # Server inventory
│   └── group_vars/all/
│       ├── vars.yml         # Public variables
│       └── vault.yml        # Encrypted secrets
├── playbooks/
│   ├── bootstrap.yml        # Full server bootstrap
│   └── check.yml            # Verify server state
└── roles/
    ├── bootstrap/           # SSH key, packages, hardening, directories
    └── docker_setup/        # Docker CE + Compose plugin
```

## Playbooks

### bootstrap.yml

Prepares a fresh server: deploys SSH key, installs packages, configures system, creates directories, hardens SSH, and installs Docker.

```bash
# First run with password
ansible-playbook playbooks/bootstrap.yml --ask-pass

# Dry run
ansible-playbook playbooks/bootstrap.yml --check --diff

# Skip SSH hardening (deploy key only)
ansible-playbook playbooks/bootstrap.yml --ask-pass --skip-tags hardening

# Docker only
ansible-playbook playbooks/bootstrap.yml --tags docker
```

### check.yml

Verifies connectivity and displays server state (OS, resources, Docker, SSH config, directories).

```bash
ansible-playbook playbooks/check.yml
```

## SSH Strategy

1. Generate a dedicated SSH key: `ssh-keygen -t ed25519 -f ~/.ssh/id_ansible_toolbox`
2. First run uses `--ask-pass` to deploy the public key
3. Subsequent runs use key-based authentication
4. SSH hardening (disables password auth) runs after key deployment

## Vault

Secrets are stored in `inventory/group_vars/all/vault.yml` encrypted with `ansible-vault`.

```bash
# Edit secrets
ansible-vault edit inventory/group_vars/all/vault.yml

# View secrets
ansible-vault view inventory/group_vars/all/vault.yml

# Re-encrypt with new password
ansible-vault rekey inventory/group_vars/all/vault.yml
```

## Roles

### bootstrap

| Tag | Description |
|-----|-------------|
| `ssh` | Deploy SSH public key |
| `packages` | Install base packages |
| `system` | Timezone, hostname, swap |
| `directories` | Create /data tree |
| `hardening` | Harden sshd_config |

### docker_setup

| Tag | Description |
|-----|-------------|
| `verify` | Check Docker installation |
| `install` | Install Docker CE from official repo |
| `configure` | daemon.json + prune cron |
