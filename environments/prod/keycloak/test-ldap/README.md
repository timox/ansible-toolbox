# Test LDAP - Simulation AD

Environnement LDAP de test pour valider la fédération d'identité Keycloak.

## Démarrage rapide

```bash
cd environments/prod/keycloak/test-ldap
docker compose up -d
```

## Utilisateurs de test

| Utilisateur | Email | Mot de passe | Groupes |
|-------------|-------|--------------|---------|
| admin.infra | admin.infra@poc.local | Test123! | admin-infra, guacamole-users, linshare-users |
| admin.app | admin.app@poc.local | Test123! | admin-app, guacamole-users |
| user.test | user.test@poc.local | Test123! | utilisateurs, guacamole-users, linshare-users |
| user.multi | user.multi@poc.local | Test123! | admin-app, utilisateurs, guacamole-users, linshare-users |
| user.disabled | user.disabled@poc.local | Test123! | (aucun) - compte désactivé |

## Groupes

| Groupe | Description |
|--------|-------------|
| admin-infra | Administrateurs infrastructure - accès complet |
| admin-app | Administrateurs applicatifs - monitoring et services |
| utilisateurs | Utilisateurs standards - accès services métier |
| guacamole-users | Utilisateurs autorisés sur Guacamole |
| linshare-users | Utilisateurs LinShare |

## Configuration Keycloak

### Paramètres de connexion LDAP

| Paramètre | Valeur |
|-----------|--------|
| Connection URL | ldap://test-ldap:389 |
| Bind DN | cn=admin,dc=poc,dc=local |
| Bind Credential | admin123 |
| Edit Mode | READ_ONLY |
| Users DN | ou=users,dc=poc,dc=local |
| Username LDAP attribute | uid |
| RDN LDAP attribute | uid |
| UUID LDAP attribute | entryUUID |
| User Object Classes | inetOrgPerson, posixAccount |

### Mappers recommandés

1. **username** : uid → username
2. **email** : mail → email
3. **firstName** : givenName → firstName
4. **lastName** : sn → lastName
5. **groups** : Group membership (cn=*,ou=groups,dc=poc,dc=local)

## Interface d'administration

phpLDAPadmin est disponible sur : http://localhost:8089

- Login DN: `cn=admin,dc=poc,dc=local`
- Password: `admin123`

## Commandes utiles

```bash
# Vérifier la connexion LDAP
docker exec test-ldap ldapsearch -x -H ldap://localhost \
  -D "cn=admin,dc=poc,dc=local" -w admin123 \
  -b "dc=poc,dc=local" "(objectClass=*)"

# Lister les utilisateurs
docker exec test-ldap ldapsearch -x -H ldap://localhost \
  -D "cn=admin,dc=poc,dc=local" -w admin123 \
  -b "ou=users,dc=poc,dc=local" "(objectClass=inetOrgPerson)" uid mail

# Lister les groupes
docker exec test-ldap ldapsearch -x -H ldap://localhost \
  -D "cn=admin,dc=poc,dc=local" -w admin123 \
  -b "ou=groups,dc=poc,dc=local" "(objectClass=groupOfNames)" cn member

# Tester l'authentification d'un utilisateur
docker exec test-ldap ldapwhoami -x -H ldap://localhost \
  -D "uid=admin.infra,ou=users,dc=poc,dc=local" -w Test123!
```

## Nettoyage

```bash
docker compose down -v
```
