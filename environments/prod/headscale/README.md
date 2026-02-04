# Headscale - VPN Mesh Open Source

> **Version supportée** : Headscale 0.25+
> Voir [CHANGELOG](https://github.com/juanfont/headscale/releases) pour les mises à jour.

## Vue d'Ensemble

**Headscale** est une implémentation open-source du control plane Tailscale, permettant de créer un réseau VPN mesh WireGuard auto-configuré avec authentification centralisée.

### Pourquoi Headscale vs Tailscale SaaS ?

| Critère | Tailscale Gratuit | Tailscale Payant | Headscale |
|---------|-------------------|------------------|-----------|
| **Coût** | Gratuit (3 users, 100 devices) | $6-18/user/mois | **Gratuit illimité** |
| **Self-hosted** | ❌ SaaS uniquement | ❌ SaaS uniquement | ✅ **Contrôle total** |
| **RGPD** | ⚠️ Données USA | ⚠️ Données USA | ✅ **100% interne** |
| **SSO OIDC** | ❌ Premium only | ✅ | ✅ **Keycloak intégré** |
| **Utilisateurs illimités** | ❌ Max 3 | ✅ Payant | ✅ **Gratuit** |
| **Support** | Community | Business | Community |

**Choix Headscale = contrôle, conformité, coût.**

---

## Architecture

### Intégration dans le Portail Sécurisé

```
┌─────────────────────────────────────────────────────────────┐
│                    INTERNET                                  │
└─────────────────┬───────────────────────────────────────────┘
                  │
          ┌───────▼────────┐
          │  Kemp LM       │  Load Balancer
          └───────┬────────┘
                  │
        ┌─────────┴──────────────┐
        │                        │
┌───────▼─────────┐      ┌──────▼────────┐
│  oauth2-proxy   │      │  Headscale    │  Control Plane VPN
│  + nginx        │      │  + Keycloak   │  (vpn.example.com)
│  (VLAN-A DMZ)   │      │  (VLAN-A)     │
└─────────────────┘      └───────┬───────┘
                                 │ OIDC Auth
                         ┌───────▼────────┐
                         │   Keycloak     │
                         │   (VLAN-B)     │
                         └────────────────┘

┌─────────────────────────────────────────────────────────────┐
│              VPN MESH (100.64.0.0/10)                        │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │ Admin PC │  │ Laptop   │  │ Subnet   │  │ Exit     │   │
│  │ (client) │  │ (mobile) │  │ Router   │  │ Node     │   │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘   │
│       │             │             │             │           │
│       └─────────────┴─────────────┴─────────────┘           │
│                     Mesh WireGuard                          │
└─────────────────────────────────────────────────────────────┘
                         │
            ┌────────────┼────────────┐
            │            │            │
      ┌─────▼─────┐ ┌───▼────┐ ┌────▼─────┐
      │  VLAN-C   │ │ VLAN-D │ │ VLAN-E   │
      │ Monitoring│ │  Apps  │ │  Infra   │
      │ Zabbix    │ │ Guac   │ │ vCenter  │
      └───────────┘ └────────┘ └──────────┘
```

### Use Cases

#### 1. Accès VPN Administrateurs
- **Problème** : Accès distant aux services internes sans exposer sur Internet
- **Solution** : Clients Tailscale sur postes admin → mesh VPN → accès direct services
- **Sécurité** : MFA Keycloak + ACLs par groupes

#### 2. Subnet Routing (Accès VLANs)
- **Problème** : Accès aux VLANs internes (monitoring, infra) depuis l'extérieur
- **Solution** : Machine subnet router dans chaque VLAN → route le trafic VPN
- **Exemple** : `tailscale up --advertise-routes=10.0.2.0/24` (VLAN-C monitoring)

#### 3. Bastion Alternatif
- **Problème** : Guacamole via web = lourd pour simple SSH/RDP
- **Solution** : VPN mesh → accès direct SSH/RDP aux serveurs via réseau privé
- **Avantage** : Native tools (ssh, rdp) sans navigateur

#### 4. Exit Node (Optionnel)
- **Problème** : Besoin de sortie internet via infrastructure (IP fixe, filtrage)
- **Solution** : Exit node sur VM interne → tout le trafic passe par là
- **Exemple** : Utilisateurs nomades avec IP entreprise

---

## Installation et Configuration

### Prérequis

1. **Keycloak configuré** avec realm `portal`
2. **Certificats SSL** wildcard dans `/data/certs/`
3. **DNS configuré** : `vpn.example.com` → IP serveur Headscale
4. **Ports ouverts** sur firewall :
   - `8443/tcp` : API Headscale (via Kemp)
   - `41641/udp` : WireGuard (direct peer-to-peer, optionnel si DERP)
   - `3478/udp` : STUN (si DERP server privé)

### Étape 1 : Configuration Keycloak

#### Créer le Client OIDC

```bash
# Dans Keycloak Admin UI
# Realm: portal

# 1. Créer client
Clients → Create Client
  Client ID: headscale
  Client Protocol: openid-connect
  Access Type: confidential

# 2. Configurer URLs
Valid Redirect URIs:
  - https://vpn.example.com/oidc/callback
  - http://localhost:*/oidc/callback  # Pour CLI locale

Base URL: https://vpn.example.com

# 3. Scopes
Client Scopes → headscale → Add mapper:
  Mapper Type: Group Membership
  Name: groups
  Token Claim Name: groups
  Full group path: OFF
  Add to ID token: ON
  Add to access token: ON
  Add to userinfo: ON

# 4. Récupérer le secret
Clients → headscale → Credentials → Client Secret
# Copier dans .env → HEADSCALE_OIDC_CLIENT_SECRET
```

#### Créer les Groupes

```bash
# Realm portal → Groups → Create Group

admin-infra       # Accès total (vCenter, infra)
admin-standard    # Accès monitoring + services admin
utilisateurs      # Accès services métier uniquement
```

### Étape 2 : Configuration Variables d'Environnement

Ajouter dans `/home/user/pomeguac/environments/prod/.env` :

```bash
# =============================================================================
# HEADSCALE - VPN MESH
# =============================================================================

# Version Headscale
HEADSCALE_VERSION=0.25

# Ports
HEADSCALE_HTTPS_PORT=8443
HEADSCALE_METRICS_PORT=9091  # Éviter conflit avec oauth2-proxy:9090

# OIDC Keycloak
HEADSCALE_OIDC_CLIENT_SECRET=change-me-get-from-keycloak

# API Key (généré au premier démarrage)
# Exécuter: docker exec headscale headscale apikeys create
HEADSCALE_API_KEY=

# Optionnel: headscale-ui
HEADSCALE_UI_VERSION=latest
HEADSCALE_UI_PORT=8000
```

### Étape 3 : Déployer Headscale

```bash
cd /home/user/pomeguac/environments/prod/headscale

# 1. Créer répertoires de données
sudo mkdir -p /data/headscale/data
sudo chmod 755 /data/headscale/data

# 2. Générer configuration depuis templates
envsubst < config.yaml.template > config.yaml
envsubst < acls.yaml.template > acls.yaml

# 3. Démarrer Headscale
docker compose up -d headscale

# 4. Vérifier logs
docker logs headscale -f

# 5. Créer API key (pour headscale-ui)
docker exec headscale headscale apikeys create
# → Copier la clé dans .env → HEADSCALE_API_KEY

# 6. Optionnel: Démarrer UI
docker compose --profile ui up -d headscale-ui
```

### Étape 4 : Configurer Kemp LoadMaster

```bash
# Virtual Service
IP: 203.0.113.10
Port: 443
Protocol: HTTPS

# Real Server
IP: 10.0.0.20  # IP serveur Headscale
Port: 8443
Weight: 1000

# SSL
Certificate: wildcard.example.com
TLS 1.2/1.3 only

# Health Check
Type: HTTPS
URL: /health
Expect: 200 OK
```

---

## Utilisation

### Enregistrer un Client (Poste Admin)

#### Méthode 1 : OIDC (Recommandée)

```bash
# 1. Installer Tailscale client
# Linux
curl -fsSL https://tailscale.com/install.sh | sh

# macOS
brew install tailscale

# Windows
# Télécharger: https://tailscale.com/download/windows

# 2. Configurer l'URL control plane
sudo tailscale up \
  --login-server=https://vpn.example.com \
  --accept-routes \
  --accept-dns

# 3. Une URL s'ouvre → authentification Keycloak
# → Connexion avec identifiants Keycloak
# → Machine enregistrée automatiquement
```

#### Méthode 2 : Pré-auth Key (Serveurs)

```bash
# 1. Créer une clé pré-auth (expire 1h par défaut)
docker exec headscale headscale preauthkeys create \
  --expiration 1h \
  --reusable=false

# 2. Sur le serveur
sudo tailscale up \
  --login-server=https://vpn.example.com \
  --authkey=<KEY> \
  --advertise-routes=10.0.2.0/24

# 3. Approuver les routes (côté Headscale)
docker exec headscale headscale routes list
docker exec headscale headscale routes enable -r <ROUTE_ID>
```

### Configurer un Subnet Router

**Objectif** : Exposer un VLAN interne (ex: VLAN-C monitoring) via VPN

```bash
# 1. Sur une VM dans VLAN-C (10.0.2.0/24)
sudo tailscale up \
  --login-server=https://vpn.example.com \
  --advertise-routes=10.0.2.0/24 \
  --advertise-exit-node=false

# 2. Activer IP forwarding
sudo sysctl -w net.ipv4.ip_forward=1
sudo sysctl -w net.ipv6.conf.all.forwarding=1

# Permanent
echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
echo 'net.ipv6.conf.all.forwarding=1' | sudo tee -a /etc/sysctl.conf

# 3. Approuver la route (headscale)
docker exec headscale headscale nodes list
docker exec headscale headscale routes list
docker exec headscale headscale routes enable -i <NODE_ID> -r <ROUTE_ID>

# 4. Clients peuvent maintenant accéder 10.0.2.0/24
ping 10.0.2.10  # Zabbix
curl https://zabbix.example.com
```

### Configurer un Exit Node

**Objectif** : Tout le trafic internet passe par l'infrastructure

```bash
# 1. Sur une VM avec accès internet
sudo tailscale up \
  --login-server=https://vpn.example.com \
  --advertise-exit-node

# 2. Activer IP forwarding
sudo sysctl -w net.ipv4.ip_forward=1

# 3. Configurer NAT (iptables)
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
sudo iptables -A FORWARD -i tailscale0 -j ACCEPT

# 4. Approuver exit node (headscale)
docker exec headscale headscale routes enable -i <NODE_ID> -r 0.0.0.0/0

# 5. Clients utilisent l'exit node
sudo tailscale up --exit-node=<EXIT_NODE_NAME>
```

---

## Gestion et Administration

### Commandes CLI Courantes

```bash
# Lister les machines connectées
docker exec headscale headscale nodes list

# Détails d'une machine
docker exec headscale headscale nodes show <NODE_ID>

# Supprimer une machine
docker exec headscale headscale nodes delete -i <NODE_ID>

# Lister les routes annoncées
docker exec headscale headscale routes list

# Approuver une route
docker exec headscale headscale routes enable -i <NODE_ID> -r <ROUTE_ID>

# Tester les ACLs
docker exec headscale headscale policy check \
  --user user@example.com \
  --destination 10.0.4.10:443

# Recharger les ACLs
docker exec headscale headscale policy reload

# Créer une preauthkey
docker exec headscale headscale preauthkeys create \
  --expiration 24h \
  --reusable=true

# Lister les utilisateurs
docker exec headscale headscale users list

# Voir les logs
docker logs headscale -f --tail 100
```

### Interface Web (Headplane)

Headplane est l'interface web la plus complète pour Headscale, avec support OIDC intégré.

```bash
# Activer l'UI (Headplane + Caddy reverse proxy)
docker compose --profile ui up -d

# Accès
https://vpn.example.com/admin

# Authentification
# - OIDC Keycloak (même client que Headscale)
# - Connexion automatique si déjà authentifié sur Keycloak
```

**Fonctionnalités Headplane :**

| Fonction | Description |
|----------|-------------|
| Machine Management | Expiration, routes, renommage, propriétaire |
| ACL Configuration | Visualisation et modification des ACLs |
| DNS Settings | Configuration DNS avec provisioning automatique |
| OIDC Login | Authentification via Keycloak |
| Route Management | Approbation des subnet routes |
| User Management | Gestion des utilisateurs et namespaces |

**Configuration requise :**

1. Générer le cookie secret Headplane :
```bash
# Ajouter dans .env
HEADPLANE_COOKIE_SECRET=$(openssl rand -base64 32)
```

2. Configurer le client OIDC Keycloak :
```bash
# Le client "headscale" existant fonctionne
# Ajouter l'URI de callback :
# https://vpn.example.com/admin/oidc/callback
```

3. Générer la configuration :
```bash
cd environments/prod/headscale
envsubst < headplane.yaml.template > headplane.yaml
```

**Troubleshooting Headplane :**

```bash
# Vérifier logs Headplane
docker logs headplane -f

# Vérifier santé
curl http://localhost:3000/api/health

# Redémarrer UI
docker compose --profile ui restart headplane
```

### Monitoring Prometheus

```bash
# Metrics endpoint
http://headscale:9091/metrics

# Métriques disponibles
- headscale_nodes_total
- headscale_nodes_online
- headscale_routes_total
- headscale_users_total

# Intégration Zabbix
# Utiliser HTTP agent pour scraper /metrics
# Ou utiliser Prometheus → Zabbix bridge
```

---

## ACLs et Sécurité

### Philosophie des ACLs

Les ACLs Headscale fonctionnent par **groupes Keycloak** :

| Groupe Keycloak | Accès VPN | Services Accessibles |
|----------------|-----------|---------------------|
| `admin-infra` | ✅ Total | Tous VLANs, vCenter, infra |
| `admin-standard` | ✅ Partiel | Zabbix, Grafana, Guacamole, Keycloak |
| `utilisateurs` | ✅ Limité | Guacamole, GLPI, services métier |

### Modifier les ACLs

```bash
# 1. Éditer acls.yaml.template
vim environments/prod/headscale/acls.yaml.template

# 2. Régénérer acls.yaml
cd environments/prod/headscale
envsubst < acls.yaml.template > acls.yaml

# 3. Tester avant application
docker exec headscale headscale policy check \
  --user test-user@example.com \
  --destination vcenter:443

# 4. Appliquer
docker exec headscale headscale policy reload

# 5. Vérifier logs
docker logs headscale -f
```

### Tests ACLs Intégrés

Le fichier `acls.yaml` contient des tests automatiques :

```bash
# Exécuter les tests
docker exec headscale headscale policy test

# Résultat attendu :
# ✓ admin-infra can access vcenter:443
# ✓ admin-standard can access zabbix:443
# ✓ admin-standard CANNOT access vcenter:443
# ✓ utilisateurs can access guacamole:443
# ✓ utilisateurs CANNOT access zabbix:443
```

---

## Troubleshooting

### Problème : Machine ne se connecte pas

```bash
# 1. Vérifier logs client
sudo tailscale status --json
sudo tailscale netcheck

# 2. Vérifier connectivité control plane
curl -k https://vpn.example.com/health

# 3. Vérifier logs Headscale
docker logs headscale -f | grep ERROR

# 4. Forcer reconnexion
sudo tailscale down
sudo tailscale up --login-server=https://vpn.example.com
```

### Problème : OIDC Authentication Failed

```bash
# 1. Vérifier configuration Keycloak
# → Valid Redirect URIs doit inclure https://vpn.example.com/oidc/callback

# 2. Vérifier KEYCLOAK_ISSUER dans config.yaml
docker exec headscale cat /etc/headscale/config.yaml | grep issuer

# Doit être : https://keycloak.example.com/realms/portal

# 3. Tester endpoint OIDC
curl ${KEYCLOAK_ISSUER}/.well-known/openid-configuration

# 4. Vérifier client secret
# → Doit matcher Keycloak Clients → headscale → Credentials
```

### Problème : Routes non visibles

```bash
# 1. Vérifier annonce route
docker exec headscale headscale routes list

# 2. Approuver la route
docker exec headscale headscale routes enable -i <NODE_ID> -r <ROUTE_ID>

# 3. Vérifier ACLs (autoApprovers)
docker exec headscale cat /etc/headscale/acls.yaml | grep -A5 autoApprovers

# 4. Client : accepter les routes
sudo tailscale up --accept-routes

# 5. Vérifier routage
ip route show | grep 100.64
```

### Problème : Exit Node ne fonctionne pas

```bash
# 1. Vérifier IP forwarding sur exit node
sysctl net.ipv4.ip_forward
# Doit retourner : net.ipv4.ip_forward = 1

# 2. Vérifier iptables NAT
sudo iptables -t nat -L POSTROUTING -v

# 3. Approuver exit node
docker exec headscale headscale routes enable -i <NODE_ID> -r 0.0.0.0/0

# 4. Client : utiliser exit node
sudo tailscale up --exit-node=<EXIT_NODE_IP>

# 5. Tester
curl ifconfig.me
# Doit retourner l'IP publique de l'exit node
```

---

## Sécurité et Conformité

### Chiffrement

- **WireGuard** : Chiffrement moderne (ChaCha20-Poly1305)
- **TLS 1.3** : Communication control plane
- **Rotation automatique** : Clés WireGuard renouvelées régulièrement

### Authentification

- **MFA obligatoire** : Via Keycloak (RADIUS ManageEngine)
- **Expiration tokens** : 180 jours (configurable)
- **Révocation immédiate** : Suppression machine = déconnexion instantanée

### Audit

```bash
# Logs connexions
docker logs headscale | grep "node registered"
docker logs headscale | grep "authentication"

# Export pour SIEM
docker logs headscale --since 24h > /var/log/headscale-audit-$(date +%Y%m%d).log

# Intégration Zabbix
# → Monitorer headscale_nodes_online
# → Alerter sur changements suspects
```

### Conformité RGPD

- ✅ **Données hébergées en interne** (pas de SaaS USA)
- ✅ **Contrôle total des logs** (rétention configurable)
- ✅ **Droit à l'oubli** : Suppression machine = purge DB
- ✅ **Portabilité** : Export config JSON possible

---

## Comparaison avec Alternatives

| Fonctionnalité | Headscale | Teleport | Pomerium | OpenVPN | WireGuard Direct |
|----------------|-----------|----------|----------|---------|------------------|
| **Mesh VPN** | ✅ Auto | ❌ | ❌ | ❌ | ⚠️ Manuel |
| **NAT Traversal** | ✅ DERP | ✅ | ❌ | ❌ | ❌ |
| **Zero-config clients** | ✅ | ✅ | ❌ | ❌ | ❌ |
| **OIDC SSO** | ✅ | ✅ | ✅ | ❌ | ❌ |
| **Subnet Routing** | ✅ | ✅ | ⚠️ Limited | ✅ | ✅ |
| **Complexité** | 🟢 Faible | 🟡 Moyenne | 🔴 Élevée | 🟡 Moyenne | 🟢 Faible |
| **RAM Usage** | 128 MB | 256 MB | 2 GB | 64 MB | 32 MB |

**Verdict** : Headscale = simplicité + mesh + OIDC. Idéal pour 10-500 utilisateurs.

---

## Roadmap et Évolutions

### Phase 1 : Déploiement Initial ✅
- Headscale avec OIDC Keycloak
- ACLs par groupes
- Subnet routing VLAN-C (monitoring)

### Phase 2 : Expansion (À venir)
- [ ] Subnet routers dans tous les VLANs
- [ ] Exit node pour utilisateurs nomades
- [ ] Integration Zabbix monitoring
- [ ] DERP server privé (éviter relais publics)

### Phase 3 : Haute Disponibilité (Futur)
- [ ] Headscale en cluster (PostgreSQL + Redis)
- [ ] Load balancer control plane
- [ ] Backup/restore automatisé

---

## Support et Ressources

### Documentation Officielle
- **Headscale** : https://headscale.net/
- **Tailscale** : https://tailscale.com/kb/ (client compatible)
- **ACLs** : https://headscale.net/ref/acls/

### Dépannage
- **GitHub Issues** : https://github.com/juanfont/headscale/issues
- **Discord** : https://discord.gg/headscale

### Logs et Monitoring
```bash
# Logs en temps réel
docker logs headscale -f

# Logs avec niveau debug
docker exec headscale headscale serve --log-level debug

# Export logs pour analyse
docker logs headscale > /tmp/headscale-debug.log
```

---

**Version** : 1.0
**Date** : Janvier 2026
**Maintainer** : Équipe Infrastructure
