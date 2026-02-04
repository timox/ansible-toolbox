# Keycloak autonome (environnement prod/test)

Ce dossier fournit un déploiement Keycloak autonome, paramétré via le fichier
`environments/prod/.env`, afin de s'adapter à un environnement inconnu.

## Prérequis

| Élément | Détail |
| --- | --- |
| Docker | Docker Engine + Docker Compose v2 |
| Variables | `environments/prod/.env` configuré |
| DNS | `KEYCLOAK_HOSTNAME` résout vers l'hôte |

## Variables minimales

| Variable | Rôle |
| --- | --- |
| `KEYCLOAK_ADMIN` | Compte admin initial |
| `KEYCLOAK_ADMIN_PASSWORD` | Mot de passe admin |
| `KEYCLOAK_DB_NAME` | Base PostgreSQL |
| `KEYCLOAK_DB_USER` | Utilisateur PostgreSQL |
| `KEYCLOAK_DB_PASSWORD` | Mot de passe PostgreSQL |
| `KEYCLOAK_HOSTNAME` | Hostname public |

## Déploiement

| Étape | Action |
| --- | --- |
| 1 | Copier `.env.example` vers `.env` dans `environments/prod` |
| 2 | Renseigner les variables Keycloak dans `.env` |
| 3 | Lancer `docker compose --env-file ../.env -f docker-compose.yml up -d` depuis `environments/prod/keycloak` |

## Mode demo (démarrage rapide)

Ce mode permet un démarrage rapide pour une démonstration locale. Il n'est pas
adapté à la production.

| Condition | Détail |
| --- | --- |
| Réseau | Accès local uniquement |
| Données | Volatiles ou non critiques |
| Sécurité | Secrets temporaires |
| TLS | Non requis pour un accès local |

### Variables minimales pour une demo

| Variable | Valeur suggérée |
| --- | --- |
| `KEYCLOAK_ADMIN` | `admin` |
| `KEYCLOAK_ADMIN_PASSWORD` | `demo-admin-change-me` |
| `KEYCLOAK_DB_NAME` | `keycloak` |
| `KEYCLOAK_DB_USER` | `keycloak` |
| `KEYCLOAK_DB_PASSWORD` | `demo-db-change-me` |
| `KEYCLOAK_HOSTNAME` | `localhost` |
| `KEYCLOAK_PROXY_MODE` | `edge` |
| `KEYCLOAK_HTTP_ENABLED` | `true` |
| `KEYCLOAK_HTTP_PORT` | `8080` |

### Démarrage demo

| Étape | Action |
| --- | --- |
| 1 | Copier `.env.example` vers `.env` |
| 2 | Renseigner les variables de la section demo |
| 3 | Lancer `docker compose --env-file ../.env -f docker-compose.yml up -d` |

### Conditions de fonctionnement

| Point | Exigence |
| --- | --- |
| Accès | `http://localhost:8080` |
| Usage | Tests rapides et démos |
| Durée | Sessions courtes, données non persistées |
| Sécurité | Ne pas exposer sur Internet |

## Configuration des Clients OIDC

### Script Automatique (Recommande)

Le script `setup-clients.sh` configure automatiquement tous les clients OIDC.

| Prerequis | Detail |
| --- | --- |
| Keycloak | Demarre et accessible |
| Realm | Cree (ex: `poc`) |
| Variables | Definies dans `../.env` |

#### Execution

```bash
cd environments/prod/keycloak
chmod +x setup-clients.sh
./setup-clients.sh
```

#### Actions du script

| Etape | Description |
| --- | --- |
| 1 | Authentification admin via API |
| 2 | Creation client scope `groups` avec mapper Group Membership |
| 3 | Configuration client `guacamole` (public, implicit flow) |
| 4 | Configuration client `oauth2-proxy` (confidential) |
| 5 | Configuration client `headscale` (optionnel) |

#### Clients configures

| Client | Type | Flow | Usage |
| --- | --- | --- | --- |
| `guacamole` | Public | Implicit | Extension OIDC Guacamole |
| `oauth2-proxy` | Confidential | Authorization Code | Portail SSO |
| `headscale` | Confidential | Authorization Code | VPN mesh (optionnel) |

#### Variables utilisees

| Variable | Description |
| --- | --- |
| `KEYCLOAK_URL` | URL Keycloak (ex: `http://192.168.122.1:8080`) |
| `KEYCLOAK_REALM` | Nom du realm |
| `KEYCLOAK_ADMIN` | Username admin |
| `KEYCLOAK_ADMIN_PASSWORD` | Password admin |
| `OIDC_CLIENT_SECRET` | Secret pour oauth2-proxy |
| `HEADSCALE_OIDC_CLIENT_SECRET` | Secret pour headscale (optionnel) |
| `POC_IP` | IP serveur pour redirect URIs |
| `DOMAIN` | Domaine pour URLs production |

### Configuration Manuelle

Si configuration manuelle preferee, creer dans Keycloak Admin UI :

#### Client Scope "groups"

| Parametre | Valeur |
| --- | --- |
| Name | `groups` |
| Protocol | openid-connect |
| Mapper | Group Membership → claim `groups` |

#### Client "oauth2-proxy"

| Parametre | Valeur |
| --- | --- |
| Client ID | `oauth2-proxy` |
| Access Type | confidential |
| Standard Flow | ON |
| Redirect URIs | `http://<IP>:4180/oauth2/callback` |
| Default Scopes | + groups |

#### Client "guacamole"

| Parametre | Valeur |
| --- | --- |
| Client ID | `guacamole` |
| Access Type | public |
| Implicit Flow | ON |
| Standard Flow | OFF |
| Redirect URIs | `http://<IP>:8081/guacamole/*`, `https://guacamole.<DOMAIN>/*` |
| Default Scopes | + groups |

**Note importante :** Le redirect URI dans `guacamole.properties` doit pointer vers `/guacamole/` (context path Tomcat), pas vers la racine `/`.

## Import de realms (optionnel)

Le répertoire `realm-federation/` est monté dans
`/opt/keycloak/data/import`.

| Étape | Action |
| --- | --- |
| 1 | Déposer les fichiers JSON dans `realm-federation/` |
| 2 | Activer `KEYCLOAK_IMPORT_REALM=true` dans `.env` |
| 3 | Redémarrer le service Keycloak |

## Troubleshooting

### Erreur "password authentication failed"

| Etape | Action |
| --- | --- |
| 1 | `docker exec keycloak-db psql -U keycloak -c "ALTER USER keycloak WITH PASSWORD '<password>';"` |
| 2 | `docker restart keycloak` |

### Erreur "Token admin non obtenu"

| Verification | Commande |
| --- | --- |
| Keycloak accessible | `curl http://<IP>:8080/health` |
| Credentials corrects | Verifier `KEYCLOAK_ADMIN_PASSWORD` dans .env |

### Relancer la configuration

Le script est idempotent (peut etre relance plusieurs fois sans effet de bord).

## Arret

| Commande |
| --- |
| `docker compose --env-file ../.env -f docker-compose.yml down` |
