# Installation de Jenkins en Docker (JDK 25, Maven, Node, Trivy)

## Contenu
- `Dockerfile` : image Jenkins LTS (JDK 25) + Maven + Node.js + Trivy
- `plugins.txt` : plugins préinstallés
- `docker-compose.yml` : lancement avec volume persistant

## Prérequis
- Docker et Docker Compose installés (`docker --version`, `docker compose version`)

## Installation
```bash
docker compose up -d --build
```

## Mot de passe initial
```bash
docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```
Puis ouvrir http://localhost:8080 et choisir « Installer les plugins suggérés » (ou garder ceux déjà présents).

## Vérification des outils
```bash
docker exec jenkins java -version
docker exec jenkins mvn -v
docker exec jenkins node -v && docker exec jenkins npm -v
docker exec jenkins trivy --version
```

## Exemple de Jenkinsfile (test rapide)
```groovy
pipeline {
  agent any
  stages {
    stage('Versions') {
      steps {
        sh 'java -version && mvn -v && node -v && trivy --version'
      }
    }
    stage('Scan Trivy') {
      steps {
        sh 'trivy fs --severity HIGH,CRITICAL --exit-code 0 .'
      }
    }
  }
}
```

## Commandes utiles
```bash
docker compose logs -f jenkins   # logs
docker compose down              # arrêt (données conservées)
docker compose down -v           # arrêt + suppression des données
```

## Remarques
- Si le tag `lts-jdk25` n'est pas disponible, vérifier les tags sur https://hub.docker.com/r/jenkins/jenkins/tags.
- Si les pipelines doivent construire des images Docker, ajouter `docker-ce-cli` dans le Dockerfile et monter `/var/run/docker.sock`.
- La première exécution de Trivy télécharge sa base de vulnérabilités (connexion Internet requise).
