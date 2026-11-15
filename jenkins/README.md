# Jenkins en Docker (tâches #04 et #05)

Jenkins LTS (JDK 25) construit sur mesure avec Maven, Node, Trivy, la CLI Docker, Docker Compose et le plugin `docker-rollout`, accompagné d'un **SonarQube** local (avec sa base PostgreSQL) pour l'analyse de code des pipelines CI.
Jenkins pilote le démon Docker de la machine hôte via le socket `/var/run/docker.sock` : les conteneurs déployés par `deployment-cd` apparaissent dans le même Docker Desktop.

## Contenu du dossier

| Fichier | Rôle |
|---|---|
| `Dockerfile` | Image `jenkins-custom:jdk25` : Maven 3.9.9, Node 22, Trivy, docker-ce-cli, docker-compose-plugin, docker-rollout |
| `docker-compose.yml` | Lance Jenkins (ports 8080 et 50000), SonarQube (9000) et sa base `sonar-db` ; volumes nommés, socket Docker, `group_add`, DNS, `extra_hosts` |
| `.env.example` | Modèle du fichier `.env` (mot de passe de la base SonarQube) |
| `settings.xml` | Réglage Maven du Jenkins : miroir de la base NVD pour Dependency-Check (voir plus bas) |
| `plugins.txt` | Liste des plugins utilisés (déjà installés dans le volume ; sert à une installation neuve) |
| `Jenkinsfile.test` | Pipeline de test #04 : vérifie les outils et l'accès à Docker |
| `Jenkinsfile.test-push` | Pipeline de test #05 : pousse une image sur Docker Hub |
| `CREDENTIALS.md` | Liste des credentials Jenkins et de leur usage (sans valeur secrète) |

## Machine

Poste d'un membre de l'équipe (Docker Desktop, WSL2), **8 Go de RAM minimum alloués à WSL2**. SonarQube (Elasticsearch) exige en plus `vm.max_map_count = 262144`. Dans `C:\Users\<nom>\.wslconfig` :

```ini
[wsl2]
memory=8GB
kernelCommandLine = sysctl.vm.max_map_count=262144
```

Puis `wsl --shutdown` et redémarrer Docker Desktop.

## Démarrage

```bash
cd jenkins
cp .env.example .env        # puis renseigner SONAR_DB_PASSWORD (16 caractères ou plus, lettres et chiffres)
docker compose up -d --build
```

Le fichier `.env` ne doit pas être versionné : dans `.gitignore`, écrire `jenkins/.env` (et non `.env`, qui exclurait aussi celui de la pile de déploiement).

| Service | Adresse |
|---|---|
| Jenkins | http://localhost:8080 |
| SonarQube | http://localhost:9000 (premier accès : `admin` / `admin`, à changer aussitôt) |

## Versions installées

| Outil | Version |
|---|---|
| Java | Temurin 25.0.5 |
| Maven | 3.9.9 |
| Node / npm | 22.23.4 / 10.9.9 |
| Trivy | 0.76.2 |
| Docker CLI | 29.9.3 |
| Docker Compose | v5.7.0 |
| docker-rollout | dernière version du dépôt wowu/docker-rollout |
| SonarQube | Community Build 26.11 |

## Configuration de Jenkins après installation

À faire une fois dans l'interface (les réglages sont conservés dans le volume `jenkins_home`).

1. **Plugins** (Manage Jenkins > Plugins) : ceux de `plugins.txt`, dont *SonarQube Scanner*, *OWASP Dependency-Check* et *NodeJS*.
2. **Outils** (Manage Jenkins > Tools) :
   - JDK nommé `jdk25`, avec le `JAVA_HOME` de l'image (`docker exec jenkins bash -c 'echo $JAVA_HOME'`) ;
   - NodeJS nommé `node26` (nom attendu par le Jenkinsfile du frontend), **Install automatically décoché**, Home `/usr` : on réutilise le Node 22 de l'image (le projet exige `^22.22.3`), sans téléchargement.
3. **Credentials** : voir `CREDENTIALS.md` (`dockerhub-credentials`, `nvd-api-key`, `sonar-token`, `postgres-password`, `samatur-jwt-secret`).
4. **SonarQube** :
   - dans SonarQube : My Account > Security > jeton `jenkins` ; Administration > Configuration > Webhooks > nom `jenkins`, URL `http://jenkins:8080/sonarqube-webhook/` (avec la barre finale) ;
   - dans Jenkins (Manage Jenkins > System > SonarQube servers) : nom `SonarQube` (exactement), URL **`http://host.docker.internal:9000`**, jeton `sonar-token`.

   Pourquoi pas `http://sonarqube:9000` ? Le scanner du frontend tourne dans un conteneur lancé par `docker run`, sur le réseau Docker par défaut, qui ne connaît pas le nom `sonarqube`. `host.docker.internal` est comprise par les deux types de scanner (conteneur Jenkins grâce à `extra_hosts`, conteneur `docker run` grâce à Docker Desktop). Le webhook retour, lui, reste `http://jenkins:8080/...` car SonarQube et Jenkins partagent le même réseau Compose.
5. **Miroir de la base NVD** (Dependency-Check) : l'API NVD répond souvent en erreur 503. Copier `settings.xml` dans le Jenkins :
   ```powershell
   docker cp settings.xml jenkins:/var/jenkins_home/.m2/settings.xml
   docker exec -u root jenkins chown jenkins:jenkins /var/jenkins_home/.m2/settings.xml
   ```
   Le profil actif par défaut définit `nvdDatafeedUrl` (miroir du projet DependencyCheck, mis à jour environ toutes les 24 h) et `nvdValidForHours=24`. Vérification : `docker exec jenkins bash -c 'cd /var/jenkins_home/workspace/backend-ci && ./mvnw -B help:active-profiles'` doit lister `nvd-miroir`.
   Premier remplissage de la base si le miroir n'a jamais été chargé : lancer `./mvnw -B org.owasp:dependency-check-maven:update-only` dans le dossier du workspace de `backend-ci`.

## Jobs de l'équipe

| Job | Rôle | Source |
|---|---|---|
| `test-outils` | Critère de fin de #04 | `Jenkinsfile.test` |
| `test-push-dockerhub` | Critère de fin de #05 | `Jenkinsfile.test-push` |
| `backend-ci` | CI du backend (tests, Dependency-Check, SonarQube, Docker, Trivy, push, CD) | dépôt `backend-ci`, déclenchement par sondage `H/2 * * * *` |
| `frontend-ci` | CI du frontend (tests, audit npm, SonarQube, Docker, Trivy, push, CD) | dépôt `frontend-ci`, même sondage |
| `deployment-cd` | Déploiement sans coupure (Traefik, docker-rollout) | dépôt `deployment-cd` (README du dépôt) |

Le sondage Git n'est actif qu'**après un premier build manuel** (Jenkins lit alors le déclencheur déclaré dans le Jenkinsfile).

## Vérification (critère de fin de #04)

Job Pipeline `test-outils` (contenu de `Jenkinsfile.test`) : le build est en **SUCCÈS** et affiche `docker version` (Client et Server), `docker compose version`, `trivy --version` et l'aide de `docker rollout`.

## Réseau du conteneur

Le `docker-compose.yml` impose deux réglages, nés de problèmes constatés :
- `dns: [1.1.1.1, 8.8.8.8]` : le DNS de Docker Desktop est instable (échecs de téléchargement des plugins et de Maven) ;
- `extra_hosts: ["host.docker.internal:host-gateway"]` : sans lui, le DNS imposé ne résout plus `host.docker.internal`, ce qui casse les tests du backend (Testcontainers) et le scanner Sonar.

## Accès au socket Docker

Avec Docker Desktop, le socket appartient à `root:root` (GID 0, droits 660). Le conteneur utilise donc `group_add: ["0"]`, ce qui évite de lancer Jenkins en root.
Sur un serveur Linux, remplacer `"0"` par le GID du groupe docker :

```bash
docker exec jenkins ls -ln /var/run/docker.sock
```

## Sécurité

- Le socket monté donne à Jenkins un contrôle quasi total de Docker sur l'hôte : l'accès à Jenkins doit être protégé par mot de passe, surtout s'il est exposé via ngrok.
- Aucun secret dans ce dépôt : mots de passe et tokens vont dans Jenkins > Credentials, et le mot de passe de la base SonarQube dans un `.env` non versionné.
- Un secret collé dans un chat ou une capture doit être régénéré.

## Dépannage

| Symptôme | Cause et solution |
|---|---|
| `permission denied` sur `/var/run/docker.sock` | Vérifier `group_add` (voir ci-dessus) puis `docker compose up -d` |
| Échec de `jenkins-plugin-cli` pendant le build | Réseau instable. Les plugins sont déjà dans le volume : l'étape est commentée dans le `Dockerfile` |
| Téléchargements très lents | Relancer la commande : les couches déjà téléchargées sont en cache. Précharger les grosses images (`docker pull postgres:18`, `sonarqube:community`) |
| `UnknownHostException: host.docker.internal` dans les tests du backend | Vérifier `extra_hosts` dans `docker-compose.yml` puis `docker compose up -d` |
| Dependency-Check : erreur 503 de l'API NVD | Utiliser le miroir (`settings.xml`, voir plus haut) |
| Dependency-Check bloqué (« waiting for lock ») | Un ancien processus tient `odc.update.lock` : `docker restart jenkins` (Ctrl+C sur `docker exec` n'arrête pas le processus du conteneur) |
| SonarQube ne démarre pas (`max virtual memory areas`) | Régler `vm.max_map_count` dans `.wslconfig` (voir « Machine ») |
| `Failed to query server version ... sonarqube:9000` | L'URL du serveur Sonar dans Jenkins doit être `http://host.docker.internal:9000` |
| `Tool type "nodejs" does not have an install of "node26"` | Créer l'outil NodeJS `node26` (voir « Configuration ») |
| Quality Gate en attente puis échec par délai | Webhook SonarQube absent ou mal écrit (`http://jenkins:8080/sonarqube-webhook/`) |

## Ports utilisés sur la machine

8080 et 50000 (Jenkins), 9000 (SonarQube), 8088 et 8081 (application et tableau de bord Traefik de `deployment-cd`). Ne pas utiliser 80, 443 et 8000, déjà pris par d'autres conteneurs.
