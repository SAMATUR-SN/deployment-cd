# Jenkins en Docker (tâche #04)

Jenkins LTS (JDK 25) construit sur mesure avec Maven, Node, Trivy, la CLI Docker, Docker Compose et le plugin `docker-rollout`.
Jenkins pilote le démon Docker de la machine hôte via le socket `/var/run/docker.sock`.

## Contenu du dossier

| Fichier | Rôle |
|---|---|
| `Dockerfile` | Image `jenkins-custom:jdk25` : Maven 3.9.9, Node 22, Trivy, docker-ce-cli, docker-compose-plugin, docker-rollout |
| `docker-compose.yml` | Lance Jenkins (ports 8080 et 50000, volume `jenkins_home`, socket Docker, `group_add`) |
| `plugins.txt` | Liste des plugins utilisés (déjà installés dans le volume ; sert à une installation neuve) |
| `Jenkinsfile.test` | Pipeline de test : vérifie les outils et l'accès à Docker |

## Machine

Machine désignée : poste d'un membre de l'équipe (Docker Desktop, WSL2), **8 Go de RAM minimum**.

## Démarrage

```bash
cd jenkins
docker compose up -d --build
```

Interface : http://localhost:8080

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

## Vérification (critère de fin de la tâche)

Job Pipeline `test-outils` (contenu de `Jenkinsfile.test`) : le build est en **SUCCÈS** et affiche `docker version` (Client et Server), `docker compose version`, `trivy --version` et l'aide de `docker rollout`.

## Accès au socket Docker

Avec Docker Desktop, le socket appartient à `root:root` (GID 0, droits 660). Le conteneur utilise donc `group_add: ["0"]`, ce qui évite de lancer Jenkins en root.
Sur un serveur Linux, remplacer `"0"` par le GID du groupe docker :

```bash
docker exec jenkins ls -ln /var/run/docker.sock
```

## Sécurité

- Le socket monté donne à Jenkins un contrôle quasi total de Docker sur l'hôte : l'accès à Jenkins doit être protégé par mot de passe, surtout s'il est exposé via ngrok.
- Aucun secret dans ce dépôt : mots de passe et tokens vont dans Jenkins > Credentials (tâche #05).

## Dépannage

| Symptôme | Cause et solution |
|---|---|
| `permission denied` sur `/var/run/docker.sock` | Vérifier `group_add` (voir ci-dessus) puis `docker compose up -d` |
| Échec de `jenkins-plugin-cli` pendant le build | Réseau instable. Les plugins sont déjà dans le volume : l'étape est commentée dans le `Dockerfile` |
| Téléchargements très lents | Relancer la commande : les couches déjà téléchargées sont en cache |

## Ports utilisés sur la machine

8080 et 50000 (Jenkins). Ne pas utiliser 80, 443 et 8000, déjà pris par d'autres conteneurs.
