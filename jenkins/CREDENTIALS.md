# Credentials Jenkins (tâche #05)

Ce fichier liste les **identifiants** des credentials et leur usage. Il ne contient aucune valeur secrète.
Les secrets sont stockés uniquement dans Jenkins (Manage Jenkins > Credentials > Global).

| ID | Type | Contenu | Utilisé par |
|---|---|---|---|
| `dockerhub-creds` | Username with password | Compte Docker Hub + access token (droits Read, Write, Delete) | Jobs CI (push des images), job de déploiement (pull) |
| `postgres-password` | Secret text | Mot de passe PostgreSQL de Sama Tur | Job `deployment-cd` (génération du fichier `.env` au déploiement) |

Les dépôts GitHub étant publics, aucun credential GitHub n'est nécessaire.

## Utilisation dans un Jenkinsfile

```groovy
withCredentials([usernamePassword(credentialsId: 'dockerhub-creds',
                                  usernameVariable: 'DH_USER',
                                  passwordVariable: 'DH_TOKEN')]) {
  sh 'echo "$DH_TOKEN" | docker login -u "$DH_USER" --password-stdin'
  sh 'docker push $IMAGE:$TAG'
  sh 'docker logout'
}

withCredentials([string(credentialsId: 'postgres-password', variable: 'POSTGRES_PASSWORD')]) {
  sh 'docker compose up -d'
}
```

Règles : utiliser des apostrophes simples autour des commandes `sh` (pas de guillemets doubles Groovy) pour que le secret ne soit jamais interpolé dans le script, et toujours terminer par `docker logout`.

## Test (critère de fin)

Job `test-push-dockerhub` (`Jenkinsfile.test-push`) : récupère `alpine:3.20`, le tague `<compte>/jenkins-test:<n° de build>` et le pousse sur Docker Hub. Résultat : build en SUCCÈS, image visible sur Docker Hub.

## Rotation

Le token Docker Hub expire à la date choisie à sa création. Le régénérer sur Docker Hub, puis mettre à jour `dockerhub-creds` dans Jenkins (Update). Aucun fichier du dépôt n'est à modifier.
