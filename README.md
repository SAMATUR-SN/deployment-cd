# Sama Tur — deployment-cd

Ce dépôt déploie l'application **Sama Tur** (frontend Angular, API Spring Boot, base PostgreSQL 18) derrière **Traefik**, avec une **mise à jour sans coupure** grâce à `docker-rollout`. Le déploiement est exécuté par le job Jenkins **`deployment-cd`**, que les pipelines `backend-ci` et `frontend-ci` déclenchent après chaque image construite, scannée et poussée sur Docker Hub.

## 1. Architecture

```
                navigateur
                    │  http://localhost:8088
                    ▼
              ┌───────────┐
              │  Traefik  │  seul port publié (8088) ; tableau de bord sur 8081
              └─────┬─────┘
        /           │            /api
   ┌────────────────┴───────────────┐
   ▼                                ▼
┌──────────┐                  ┌──────────┐      ┌─────────────┐
│ frontend │                  │ backend  │─────▶│ PostgreSQL  │
│ nginx    │                  │ Spring   │      │ 18          │
│ :8080    │                  │ :8080    │      │ volume pgdata│
└──────────┘                  └──────────┘      └─────────────┘
```

- Traefik détecte les conteneurs par leurs labels Docker : `/` va au frontend, `/api` au backend (la route la plus précise l'emporte).
- Le frontend et le backend écoutent tous deux sur le port 8080 **dans leur conteneur** ; aucun des deux ne publie de port sur la machine. Il n'y a donc pas de conflit avec Jenkins (8080) ni avec SonarQube (9000).
- La base n'est pas joignable de l'extérieur. Ses données vivent dans le volume nommé `pgdata` et survivent aux mises à jour.

## 2. Contenu

| Fichier | Rôle |
|---|---|
| `docker-compose.yml` | La pile : Traefik, PostgreSQL 18, backend, frontend (labels de routage, healthchecks, volume) |
| `.env` | Valeurs **non secrètes** : ports, noms d'images, tags par défaut. Versionné |
| `Jenkinsfile` | Pipeline du job `deployment-cd` (paramètres `BACKEND_TAG` et `FRONTEND_TAG`) |
| `scripts/test-zero-downtime.sh` | Preuve de mise à jour sans coupure (boucle de requêtes pendant un déploiement) |
| `jenkins/` | Jenkins en Docker (JDK 25, Maven, Node, Trivy, docker-rollout) et SonarQube |
| `spikes/traefik-rollout/` | Spike #09 : Traefik et docker-rollout sur une application de test |

## 3. Prérequis

- **Docker Desktop** (Compose v2) ; le Jenkins de `jenkins/` pilote le Docker de la machine par `docker.sock`. Les conteneurs déployés apparaissent donc dans Docker Desktop, à côté de ceux de Jenkins.
- Le **plugin `docker-rollout`**, déjà installé dans l'image Jenkins de `jenkins/` (vérification : `docker exec jenkins docker rollout --help`).
- Les images `salioudiop/samatur-backend` et `salioudiop/samatur-frontend` **poussées sur Docker Hub** par les pipelines CI (paramètre `PUSH_AND_DEPLOY` vrai).
- Les ports **8088** (application) et **8081** (tableau de bord Traefik) libres. Si le spike #09 tourne encore, l'arrêter d'abord : `docker compose -f spikes/traefik-rollout/docker-compose.yml down`.

## 4. Credentials Jenkins

À créer dans **Manage Jenkins → Credentials → (global)**. Aucun secret ne figure dans ce dépôt.

| ID | Type | Contenu |
|---|---|---|
| `dockerhub-credentials` | Username with password | Compte Docker Hub et son token d'accès |
| `postgres-password` | **Secret text** | Mot de passe de la base |
| `samatur-jwt-secret` | **Secret text** | Clé de signature des jetons, **32 caractères au minimum** |

Choisir un mot de passe de base long (16 caractères ou plus, lettres et chiffres). **Il ne s'applique qu'à la première création de la base** : PostgreSQL l'enregistre dans le volume `pgdata`. Changer ensuite le credential ne change pas le mot de passe de la base déjà créée ; pour repartir de zéro : `docker compose -p samatur down -v` (efface les données).

Générer la clé JWT (PowerShell) :

```powershell
$b = New-Object byte[] 48; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); [Convert]::ToBase64String($b)
```

## 5. Créer le job `deployment-cd`

1. **New Item** → nom **`deployment-cd`** (exactement : les CI l'appellent par ce nom) → **Pipeline**.
2. **Pipeline → Definition : Pipeline script from SCM** → Git → URL de ce dépôt → branche `*/main` → Script Path `Jenkinsfile`.
3. Enregistrer et lancer un premier **Build Now**. Jenkins lit les paramètres du Jenkinsfile : à partir du build suivant, le bouton devient **Build with Parameters**.

## 6. Utilisation

### Déclenché par les CI (cas normal)

À la fin d'un pipeline `backend-ci` ou `frontend-ci` (`PUSH_AND_DEPLOY` vrai), l'étape *Déclenchement du CD* lance ce job avec le tag de l'image qui vient d'être poussée (`<n° de build>-<sha court>`, par exemple `12-eea92cd`).

### À la main

**Build with Parameters** :

| Paramètre | Rôle |
|---|---|
| `BACKEND_TAG` | Tag de l'image backend à déployer |
| `FRONTEND_TAG` | Tag de l'image frontend à déployer |

**Un paramètre laissé vide veut dire « ne pas toucher à ce service »** : il garde la version en cours. Ainsi, un déploiement déclenché par `backend-ci` ne redémarre pas le frontend. Si le service n'est pas encore déployé, il est démarré en `latest`.

## 7. Déroulement d'un déploiement

1. **Préparation** : lit les tags demandés, repère ce qui tourne déjà, vérifie que Compose et docker-rollout sont présents.
2. **Récupération des images** : connexion à Docker Hub et `docker compose pull` des seuls services à déployer.
3. **Base de données et Traefik** : `docker compose up -d --wait postgres traefik` (sans toucher aux données).
4. **Déploiement backend** : `docker rollout` (voir ci-dessous).
5. **Déploiement frontend** : `docker rollout` avec drainage.
6. **Vérification** : requêtes sur `/health` (attendu 200) et `/api/dossiers` (200, 401 ou 403 : la requête a atteint Spring Boot), jusqu'à 2 minutes, puis état des conteneurs.
7. **Notification** : le journal et la description du build indiquent `backend=… frontend=…` ; en cas d'échec, les 30 dernières lignes de chaque conteneur sont affichées. Pour une alerte par courriel ou Slack, ajouter le plugin correspondant et une étape dans `post`.

Les déploiements ne se chevauchent pas : `disableConcurrentBuilds()` met les suivants en file d'attente.

## 8. Comment la mise à jour évite la coupure

`docker rollout <service>` fait passer le service de 1 à 2 conteneurs : le nouveau démarre à côté de l'ancien, qui continue de servir. Une fois le nouveau **sain** (healthcheck Docker), l'ancien est arrêté et supprimé.

- **Frontend** : juste avant l'arrêt, un *hook* crée `/tmp/draining` dans l'ancien conteneur. Son `/health` répond alors `503`, Traefik le retire du routage en environ 1 seconde, puis il est arrêté sans requête en cours.
- **Backend** : pas de drainage par fichier. Spring Boot reçoit `SIGTERM`, et un **middleware de nouvelle tentative** de Traefik (3 essais) rejoue les rares requêtes refusées pendant l'arrêt. Pour terminer proprement les requêtes déjà en cours, l'équipe backend peut ajouter `server.shutdown=graceful` dans `application.properties`.
- Si le nouveau conteneur **ne devient pas sain** dans les 180 secondes (`ROLLOUT_TIMEOUT`), docker-rollout abandonne et retire le nouveau : l'ancienne version reste en service et le build échoue.
- La mémoire du backend est bornée (`-Xmx512m`) : deux instances coexistent brièvement.

Mesures du spike #09 : 0 requête perdue sur 383 requêtes (poste) et 428 (réseau Docker) avec drainage, contre 1 à 2 échecs sans drainage. Voir `spikes/traefik-rollout/`.

## 9. Vérifier le déploiement

```bash
docker ps                          # traefik, postgres, backend, frontend : « healthy »
docker compose -p samatur ps
```

| Adresse | Contenu |
|---|---|
| http://localhost:8088/ | Application (page de connexion) |
| http://localhost:8088/health | `ok` (frontend) |
| http://localhost:8088/api/dossiers | `401` sans jeton (réponse du backend) |
| http://localhost:8081/ | Tableau de bord Traefik : routes `/` → frontend et `/api` → backend |

Pour se connecter : comptes de démonstration `ecole1@samatur.sn`, `etatcivil1@samatur.sn`, `tribunal1@samatur.sn`, `superviseur@samatur.sn` ; les mots de passe sont communiqués hors du dépôt.

## 10. Preuve de mise à jour sans coupure (#26)

Depuis un terminal **bash (WSL)** :

```bash
# 1. S'assurer qu'une version tourne déjà (premier déploiement du job)
# 2. Lancer la mesure (4 minutes) :
bash scripts/test-zero-downtime.sh http://localhost:8088 240
# 3. Pendant ce temps, dans Jenkins : deployment-cd → Build with Parameters
#    avec un NOUVEAU tag (backend et/ou frontend)
```

Le script envoie une requête toutes les 0,2 s à `/health` (frontend) et à `/api/dossiers` (backend), compte les réponses valides et les échecs (`000` = connexion coupée, `502`, `503`, `504`, `404` Traefik) et conclut **« aucune coupure détectée »** ou **« coupure détectée »** avec l'heure des échecs. Pour tester `/api/dossiers` avec un vrai jeton (réponse 200) : `TEST_USER=etatcivil1@samatur.sn TEST_PASSWORD=… bash scripts/test-zero-downtime.sh …`.

Pour la preuve du dossier : conserver la sortie du script et la capture du build `deployment-cd` terminé pendant la mesure, dans `preuves/`.

## 11. Retour arrière

Relancer `deployment-cd` avec le **tag précédent** (visible dans l'historique des builds, colonne « description », ou sur Docker Hub). Le retour arrière suit le même chemin sans coupure.

## 12. Déploiement à la main (sans Jenkins)

```bash
export POSTGRES_PASSWORD='...'            # jamais dans un fichier versionné
export SAMATUR_JWT_SECRET='...'           # 32 caractères au minimum
export BACKEND_TAG=12-eea92cd FRONTEND_TAG=2-49b3548

docker compose pull backend frontend
docker compose up -d --wait postgres traefik
docker rollout --timeout 180 -f docker-compose.yml backend
docker rollout --timeout 180 --pre-stop-hook "touch /tmp/draining; sleep 3" -f docker-compose.yml frontend
```

## 13. Sécurité et limites

- **Secrets** : jamais dans `.env` ni dans le dépôt ; Jenkins les masque dans le journal. `docker compose config` (sans `-q`) afficherait les valeurs : ne pas le lancer avec les secrets exportés.
- **Tableau de bord Traefik** (`--api.insecure=true`, port 8081) : pratique pour la démonstration, à retirer hors démonstration.
- **`docker.sock`** : Traefik le lit en lecture seule pour découvrir les conteneurs ; Jenkins l'utilise pour piloter Docker. Quiconque contrôle Jenkins contrôle donc le Docker de la machine.
- **HTTP seulement** : pas de certificat dans cette démonstration (pilote à Bambey sur données fictives).
- Le fichier `.env` est versionné et ne contient que des valeurs non secrètes. Dans `.gitignore`, ignorer uniquement le `.env` de `jenkins/` (`jenkins/.env`) pour ne pas exclure celui-ci.

## 14. Dépannage

| Symptôme | Cause probable et correction |
|---|---|
| `POSTGRES_PASSWORD manquant` | Credential `postgres-password` absent, ou de type « Username with password » : le recréer en **Secret text** |
| `docker: 'rollout' is not a docker command` | Plugin absent de l'image Jenkins : reconstruire `jenkins/` (`docker compose build`) |
| `port is already allocated` (8088, 8081) | Le spike #09 ou un autre conteneur occupe le port : `docker ps` puis l'arrêter, ou changer le port dans `.env` |
| `pull access denied` / `not found` | Le tag n'existe pas sur Docker Hub : le pipeline CI n'a pas poussé (`PUSH_AND_DEPLOY` faux), ou tag mal saisi |
| Le backend reste « unhealthy » | `docker logs <conteneur>` : mot de passe de base différent de celui du volume `pgdata`, ou clé JWT de moins de 32 caractères |
| Vérification : `000` sur `host.docker.internal` | Renseigner `CHECK_BASE_URL` dans le Jenkinsfile, ou vérifier `extra_hosts` dans `jenkins/docker-compose.yml` |
| `/api/...` renvoie 404 « page not found » | Le backend n'est pas encore enregistré par Traefik : attendre quelques secondes, vérifier le tableau de bord (8081) |
