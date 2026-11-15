# Credentials Jenkins (tâche #05, mis à jour)

Ce fichier liste les **identifiants** des credentials et leur usage. Il ne contient aucune valeur secrète.
Les secrets sont stockés uniquement dans Jenkins (Manage Jenkins > Credentials > Global).

| ID | Type | Contenu | Utilisé par |
|---|---|---|---|
| `dockerhub-credentials` | Username with password | Compte Docker Hub + access token (droits Read, Write, Delete) | `backend-ci` et `frontend-ci` (push des images), `deployment-cd` (pull) |
| `postgres-password` | **Secret text** | Mot de passe PostgreSQL de Sama Tur | `deployment-cd` (variable `POSTGRES_PASSWORD` injectée au déploiement) |
| `samatur-jwt-secret` | **Secret text** | Clé de signature des jetons du backend, 32 caractères minimum | `deployment-cd` (variable `SAMATUR_JWT_SECRET`) |
| `nvd-api-key` | Secret text | Clé d'API de la base de vulnérabilités NVD | `backend-ci` (étape OWASP Dependency-Check) |
| `sonar-token` | Secret text | Jeton d'un utilisateur SonarQube (nom `jenkins`) | Configuration du serveur `SonarQube` (jobs `backend-ci` et `frontend-ci`) |

Les dépôts GitHub étant publics, aucun credential GitHub n'est nécessaire.

> L'ancien identifiant `dockerhub-creds` n'existe plus : il a été remplacé par `dockerhub-credentials` (nom utilisé dans les Jenkinsfile de l'équipe). Supprimer l'ancien token sur Docker Hub s'il traîne encore.

## Utilisation dans un Jenkinsfile

```groovy
withCredentials([usernamePassword(credentialsId: 'dockerhub-credentials',
                                  usernameVariable: 'DH_USER',
                                  passwordVariable: 'DH_PASS')]) {
  sh 'echo "$DH_PASS" | docker login -u "$DH_USER" --password-stdin'
  sh 'docker push $IMAGE:$TAG'
  sh 'docker logout'
}

withCredentials([string(credentialsId: 'postgres-password', variable: 'POSTGRES_PASSWORD'),
                 string(credentialsId: 'samatur-jwt-secret', variable: 'SAMATUR_JWT_SECRET')]) {
  sh 'docker compose up -d'
}
```

Règles : utiliser des apostrophes simples autour des commandes `sh` (pas de guillemets doubles Groovy) pour que le secret ne soit jamais interpolé dans le script, et toujours terminer par `docker logout`. Ne jamais afficher de variables secrètes (`echo`, `docker compose config` sans `-q`).

## Créer les secrets

- **`postgres-password`** : 16 caractères ou plus, lettres et chiffres. Il ne s'applique qu'à la **première** création de la base : PostgreSQL l'enregistre dans le volume `pgdata`.
- **`samatur-jwt-secret`** (PowerShell) :
  ```powershell
  $b = New-Object byte[] 48; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); [Convert]::ToBase64String($b)
  ```
- **`nvd-api-key`** : demande gratuite sur https://nvd.nist.gov/developers/request-an-api-key (lien d'activation à usage unique).
- **`sonar-token`** : SonarQube > My Account > Security > Generate token (type User Token, nom `jenkins`).

Ne jamais coller un secret dans un chat, une capture ou un commit. Un secret exposé doit être régénéré.

## Test (critère de fin de #05)

Job `test-push-dockerhub` (`Jenkinsfile.test-push`) : récupère `alpine:3.20`, le tague `<compte>/jenkins-test:<n° de build>` et le pousse sur Docker Hub. Résultat : build en SUCCÈS, image visible sur Docker Hub.

## Rotation

| Credential | Comment le changer |
|---|---|
| `dockerhub-credentials` | Le token expire à la date choisie à sa création : en générer un autre sur Docker Hub, puis Update dans Jenkins |
| `nvd-api-key`, `sonar-token` | Régénérer côté NVD ou SonarQube, puis Update dans Jenkins |
| `samatur-jwt-secret` | Update dans Jenkins puis redéployer le backend : les jetons déjà émis deviennent invalides, les utilisateurs doivent se reconnecter |
| `postgres-password` | Ne change pas le mot de passe de la base existante. Pour le modifier : `ALTER USER` dans PostgreSQL, puis Update dans Jenkins et redéploiement |

Aucun fichier du dépôt n'est à modifier.
