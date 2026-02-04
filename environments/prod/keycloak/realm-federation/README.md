# Keycloak Federation - POGA comme Realm Central

## Deux modes de fonctionnement

### Mode A : SSO uniquement (recommandé si même AD dans chaque realm)

```
POGA ─── LDAP ───► AD        oidc ─── LDAP ───► AD (même AD)
  │                            ▲
  └──── IdP broker ────────────┘
        (SSO session)

- Chaque realm a sa propre fédération LDAP vers le MÊME AD
- Les users/groupes viennent du LDAP local
- L'IdP sert UNIQUEMENT pour le SSO (pas de re-login)
- PAS DE MAPPERS IdP (données déjà dans LDAP)
```

### Mode B : Centralisation complète

```
POGA ─── LDAP ───► AD
  │
  └──── IdP broker ────► oidc (PAS de LDAP)
        (SSO + groupes)

- Seul POGA a la fédération LDAP
- Les groupes viennent via le token IdP
- Il FAUT mapper les groupes dans l'IdP
```

---

## Architecture

```
                    ┌─────────────────────────────────┐
                    │      Realm: POGA (Central)      │
                    │      https://kc.sdis25.fr       │
                    │                                 │
                    │  - LDAP/AD (users + groups)     │
                    │  - MFA RADIUS                   │
                    │  - Client: pogacli (oauth2-proxy)│
                    │                                 │
                    │  + Clients broker:              │
                    │    ├── oidc-broker              │
                    │    └── bookstack-broker         │
                    └───────────────┬─────────────────┘
                                    │
                         SSO (Identity Brokering)
                                    │
                    ┌───────────────┴───────────────┐
                    ▼                               ▼
┌───────────────────────────────┐   ┌───────────────────────────────┐
│ Realm: oidc                   │   │ Realm: BookStack              │
│                               │   │                               │
│ - LDAP/AD local (READ_ONLY)   │   │ - LDAP/AD local (READ_ONLY)   │
│ - Groupes via LDAP local      │   │ - Groupes via LDAP local      │
│ - IdP: poga-idp (SSO seul)    │   │ - IdP: poga-idp (SSO seul)    │
│                               │   │                               │
│ Clients:                      │   │ Clients:                      │
│ - guacamole, matrix, etc.     │   │ - wiki, wiki-test             │
└───────────────────────────────┘   └───────────────────────────────┘
```

---

## Configuration LDAP : Mode READ_ONLY

**Important** : Pour éviter que Keycloak écrive dans l'AD, configurer le LDAP en READ_ONLY.

### User Federation

```
User federation → [LDAP] → Settings

Edit Mode: READ_ONLY
```

### Group Mapper

```
User federation → [LDAP] → Mappers → groups

Mode: READ_ONLY
```

Avec READ_ONLY :
- Keycloak **lit** les users/groupes depuis l'AD
- Keycloak **n'écrit pas** dans l'AD
- Impossible de créer des groupes Keycloak qui iraient dans l'AD

---

## Quand mapper les groupes dans l'IdP ?

| Situation | Mapper les groupes ? |
|-----------|---------------------|
| Realm a son propre LDAP | **NON** - groupes via LDAP local |
| Realm sans LDAP | **OUI** - groupes via token IdP |
| Realm avec groupes Keycloak spécifiques | **OUI** - mapper ces groupes |

### Cas : Groupes Keycloak spécifiques

Si un realm utilise des groupes **créés dans Keycloak** (pas dans l'AD), il faut les mapper depuis le token IdP.

Exemple : Le realm `oidc` a un groupe `beta-testers` qui n'existe pas dans l'AD.

```
Dans POGA : Créer le groupe "beta-testers" (groupe Keycloak local)

Dans oidc : Mapper ce groupe via l'IdP
  Identity providers → poga-idp → Mappers → Add mapper

  Name: group-beta-testers
  Type: Advanced Claim to Group
  Claims: [{"key":"groups","value":"beta-testers"}]
  Group: /beta-testers   ← Créer ce groupe dans le realm oidc
```

---

## Fichiers

| Fichier | Où l'utiliser | Description |
|---------|---------------|-------------|
| `01-poga-broker-clients.json` | Realm POGA | Créer les clients broker |
| `02-oidc-realm-add-idp.json` | Realm oidc | Ajouter l'IdP (SSO) |
| `02-bookstack-realm-add-idp.json` | Realm BookStack | Ajouter l'IdP (SSO) |

---

## Étapes : Mode SSO uniquement

### Étape 1 : Dans POGA (realm central)

#### 1.1 Vérifier LDAP en READ_ONLY

```
User federation → [LDAP] → Settings
Edit Mode: READ_ONLY

User federation → [LDAP] → Mappers → groups
Mode: READ_ONLY
```

#### 1.2 Créer le client `oidc-broker`

```
Realm POGA → Clients → Create client

Client ID: oidc-broker
Client Authentication: ON
Standard Flow: ON
Direct Access Grants: OFF

Valid Redirect URIs:
https://kc.sdis25.fr/realms/oidc/broker/poga-idp/endpoint/*
```

**Noter le secret** : Credentials → Client Secret → COPIER

#### 1.3 Créer le client `bookstack-broker`

```
Client ID: bookstack-broker
Valid Redirect URIs:
https://kc.sdis25.fr/realms/BookStack/broker/poga-idp/endpoint/*
```

---

### Étape 2 : Dans le realm `oidc`

#### 2.1 Vérifier LDAP local en READ_ONLY

```
User federation → [LDAP] → Settings
Edit Mode: READ_ONLY

User federation → [LDAP] → Mappers → groups
Mode: READ_ONLY
```

#### 2.2 Ajouter l'Identity Provider

```
Identity providers → Add provider → Keycloak OpenID Connect

Alias: poga-idp
Display Name: Connexion POGA (SSO)

Authorization URL: https://kc.sdis25.fr/realms/POGA/protocol/openid-connect/auth
Token URL: https://kc.sdis25.fr/realms/POGA/protocol/openid-connect/token
Logout URL: https://kc.sdis25.fr/realms/POGA/protocol/openid-connect/logout
User Info URL: https://kc.sdis25.fr/realms/POGA/protocol/openid-connect/userinfo
Issuer: https://kc.sdis25.fr/realms/POGA

Client ID: oidc-broker
Client Secret: [SECRET COPIÉ]
Client Authentication: Client secret sent as post
Scopes: openid email profile
```

**Advanced settings** :
```
Sync Mode: force
Trust Email: ON
First Login Flow: first broker login
```

#### 2.3 Mappers IdP : AUCUN si même AD

**IMPORTANT** : Si les realms utilisent le **même AD**, ne créez **AUCUN mapper** dans l'IdP.

Pourquoi ?
- Les données user (username, email, groupes) viennent déjà du LDAP local
- Les mappers IdP essaient d'écrire sur l'utilisateur LDAP
- LDAP en READ_ONLY → erreur `Federated storage is not writable`

```
Identity providers → poga-idp → Mappers

→ LAISSER VIDE (aucun mapper)
```

L'IdP établit juste le **lien SSO** entre les sessions, pas de sync d'attributs.

---

### Étape 3 : Dans le realm `BookStack`

Même procédure que pour `oidc`.

---

## Test SSO

1. **Ouvrir Guacamole** : https://remote.sdis25.fr
   - Clic sur "Connexion POGA (SSO)"
   - Login AD + MFA dans POGA
   - Retour vers Guacamole
   - Groupes = LDAP local du realm oidc

2. **Ouvrir Wiki** (même navigateur) : https://wiki.sdis25.fr
   - Clic sur "Connexion POGA (SSO)"
   - **PAS DE RE-LOGIN** (session POGA existe)
   - Retour vers Wiki
   - Groupes = LDAP local du realm BookStack

---

## Troubleshooting

| Problème | Solution |
|----------|----------|
| "Invalid redirect URI" | Vérifier URL dans client broker |
| User non créé | First Login Flow = "first broker login" |
| Erreur "INSUFF_ACCESS_RIGHTS" | Passer LDAP/Group Mapper en READ_ONLY |
| `Federated storage is not writable` | **Supprimer les mappers IdP** (même AD = pas de mappers) |
| Groupes non visibles | Vérifier LDAP local du realm (pas l'IdP) |
| Double login | Vérifier l'issuer dans l'IdP |
| "Vérifier votre profil" + doublon | Créer flow `auto-link-idp` (voir ci-dessous) |

### Flow auto-link-idp (si user existe déjà dans LDAP)

Si le "first broker login" demande de vérifier le profil et trouve un doublon :

```
Authentication → Flows → Create flow

Name: auto-link-idp
Top Level Flow Type: basic-flow
```

Ajouter les étapes :
```
Add step → Idp Create User If Unique     [ALTERNATIVE]
Add step → Automatically Set Existing User [ALTERNATIVE]
```

Assigner à l'IdP :
```
Identity providers → poga-idp → First Login Flow: auto-link-idp
```

---

## Récapitulatif

| Élément | Mode SSO seul (même AD) | Mode centralisé |
|---------|-------------------------|-----------------|
| LDAP dans POGA | Oui | Oui |
| LDAP dans autres realms | Oui (même AD) | Non |
| Mappers IdP (username, email) | **Non** | Oui |
| Scope "groups" sur broker | Non | Oui |
| Mapper groupes dans IdP | Non | Oui |
| Groupes Keycloak spécifiques | Mapper si besoin | Mapper obligatoire |
