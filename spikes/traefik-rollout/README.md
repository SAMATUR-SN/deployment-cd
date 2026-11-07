# Spike #09 : Traefik et docker-rollout pour la mise à jour sans coupure

## 1. Objectif et résultat

**Objectif.** Vérifier qu'on peut mettre à jour un service Docker Compose **sans qu'aucune requête ne soit perdue**, en combinant :
- **Traefik** : reverse proxy qui détecte les conteneurs Docker et répartit le trafic ;
- **docker-rollout** : plugin Docker CLI (script bash) qui remplace `docker compose up -d <service>` par un déploiement sans coupure.

**Résultat.** Avec le drainage décrit en section 8, un redéploiement (v4 vers v5) a été mesuré **sans aucune requête en échec** : 383 requêtes depuis le poste de travail et 428 requêtes depuis le réseau Docker, 0 échec dans les deux cas. Sans drainage, le même test montrait 1 à 2 échecs, concentrés sur la seconde de l'arrêt de l'ancien conteneur. Le plan B (deux répliques redémarrées une par une) n'a pas été nécessaire.

## 2. Principe de fonctionnement

1. Traefik reçoit tout le trafic sur le port 8088 (port 80 du conteneur) et lit les conteneurs Docker via `docker.sock` (labels `traefik.*`).
2. `docker rollout web` fait passer le service `web` de 1 à 2 conteneurs : l'ancien continue de servir, le nouveau démarre à côté.
3. Le plugin attend que le nouveau conteneur soit **healthy** (healthcheck Docker), puis patiente 3 secondes.
4. Le plugin exécute le **hook de drainage** dans l'ancien conteneur : `/health` répond alors 503 et Traefik retire ce conteneur du routage.
5. Le plugin arrête puis supprime l'ancien conteneur, qui ne reçoit plus de trafic.

Chaque déploiement incrémente l'index du conteneur (`web-1`, `web-2`, `web-3`...).

## 3. Contenu du dossier

| Fichier | Rôle |
|---|---|
| `docker-compose.yml` | Traefik + service `web` (labels de routage, healthcheck Docker, sonde de santé Traefik) |
| `app/Dockerfile` | Application de test (nginx) : affiche sa version et le nom du conteneur |
| `app/default.conf` | Configuration nginx : route `/health` (200, ou 503 en mode drainage) |
| `scripts/deploy.sh` | Construit l'image, lance `docker rollout` avec le hook de drainage |
| `scripts/test-downtime.sh` | Boucle de requêtes depuis le poste, avec bilan par version et heure des échecs |
| `scripts/test-downtime-interne.sh` | Même boucle, lancée depuis le conteneur Traefik (sans la couche de ports de Docker Desktop) |

Le fichier `.gitattributes` (fins de ligne LF pour les scripts, important sous Windows) se trouve à la racine du dépôt.

## 4. Prérequis

- Docker Desktop avec Compose v2, **intégration WSL activée** pour votre distribution (*Settings → Resources → WSL integration*).
- **Un terminal bash (WSL).** `docker-rollout` est un script bash : il ne fonctionne pas depuis PowerShell.
- Le port **80 était déjà utilisé** sur la machine de test par un autre conteneur : le spike publie donc Traefik sur le port **8088** (et son tableau de bord sur 8081). Adapter si besoin dans `docker-compose.yml`.

## 5. Installation de docker-rollout

```bash
mkdir -p ~/.docker/cli-plugins
curl -fsSL https://raw.githubusercontent.com/wowu/docker-rollout/main/docker-rollout \
  -o ~/.docker/cli-plugins/docker-rollout
chmod +x ~/.docker/cli-plugins/docker-rollout
docker rollout --help
```

## 6. Procédure de test

Depuis WSL, dans `spikes/traefik-rollout` :

```bash
# 1. Démarrer une première version
APP_VERSION=v1 docker compose up -d --build
curl http://localhost:8088/          # -> Application v1 - conteneur <id>
curl http://localhost:8088/health    # -> ok
```

Pour mesurer, ouvrir **trois terminaux** dans ce dossier :

```bash
# Terminal A : boucle depuis le poste
bash scripts/test-downtime.sh http://localhost:8088/ 90 | tee preuve-hote.txt

# Terminal B : boucle depuis le réseau Docker
bash scripts/test-downtime-interne.sh 90 | tee preuve-interne.txt

# Terminal C : après une dizaine de secondes, déployer la version suivante
bash scripts/deploy.sh v2
```

Lecture des résultats :

| Boucle interne (B) | Boucle poste (A) | Conclusion |
|---|---|---|
| 0 échec | 0 échec | Déploiement sans coupure. |
| 0 échec | des échecs | Rollout correct ; problème de la couche de ports de l'hôte (Docker Desktop). |
| des échecs | des échecs | Problème de rollout ou de Traefik ; les heures indiquent l'étape en cause. |

Remarque : la première fois qu'on adopte la configuration de drainage, il faut installer une version avec `docker compose up -d --build` avant de tester un rollout, car l'ancien conteneur doit déjà contenir la logique de drainage.

## 7. Résultats mesurés (7 novembre 2026)

| Test | Passage | Boucle | Requêtes | Échecs | Détail |
|---|---|---|---|---|---|
| 1, sans drainage | v2 vers v3 | poste | 363 | **1** | échec à 22:32:43.787 |
| 1, sans drainage | v2 vers v3 | interne | 419 | **2** | échecs à 22:32:43 |
| 2, avec drainage | v4 vers v5 | poste | 383 | **0** | 187 réponses v4, 196 réponses v5 |
| 2, avec drainage | v4 vers v5 | interne | 428 | **0** | |

- Test 1 : rollout de 22:32:31.1 à 22:32:44.3. Les échecs des deux boucles tombent à la même seconde, celle de l'arrêt de l'ancien conteneur.
- Test 2 : rollout de 22:47:17.7 à 22:47:33.6. Les dernières réponses de l'ancienne version datent de 22:47:29.9, environ trois secondes avant la fin du rollout, ce qui est cohérent avec un conteneur sorti du routage avant d'être arrêté.
- Pendant la phase où les deux versions sont actives, les réponses alternent entre l'ancienne et la nouvelle : c'est le comportement attendu.

Limites de la mesure : environ 4 requêtes par seconde, un seul passage par configuration. Une défaillance très brève entre deux requêtes pourrait passer inaperçue, et le test mérite d'être répété pour consolider le résultat. Les fichiers de preuve sont conservés dans le dossier `preuves/`.

## 8. Problème rencontré et correction : le drainage

**Constat.** Sans précaution, `docker-rollout` arrête l'ancien conteneur alors que Traefik peut encore lui envoyer des requêtes pendant un très court instant. Résultat : quelques requêtes échouent (test 1).

**Correction en trois éléments.**
1. `app/default.conf` : si le fichier `/tmp/draining` existe, `/health` répond **503**.
2. `docker-compose.yml` : Traefik sonde lui-même `/health` chaque seconde (`loadbalancer.healthcheck.*`) et retire un serveur qui répond 503.
3. `scripts/deploy.sh` : le hook `--pre-stop-hook "touch /tmp/draining; sleep 3"` est exécuté par `docker-rollout` dans l'ancien conteneur, juste avant son arrêt (`docker exec ... sh -c`). Le délai de 3 secondes (`DRAIN_SECONDS`) laisse à Traefik le temps de retirer le serveur.

## 9. Difficultés d'environnement rencontrées

| Difficulté | Cause | Solution |
|---|---|---|
| `docker` introuvable ou `docker.sock` absent dans WSL | Intégration WSL de Docker Desktop inactive, ou moteur en cours de redémarrage après `wsl --shutdown` | Activer l'intégration pour la distribution, attendre « Engine running », éviter les `wsl --shutdown` répétés |
| Port 80 déjà utilisé | Autre conteneur sur la machine | Publier Traefik sur 8088 |
| `web` reste `unhealthy` | `localhost` résolu en IPv6 dans nginx:alpine alors que nginx n'écoutait qu'en IPv4 | `listen [::]:80;` dans nginx et healthcheck sur `127.0.0.1` |
| Port 8088 et 8081 sans réponse alors que Traefik répondait en interne | Publication des ports de Docker Desktop bloquée (cause non démontrée, après des redémarrages du moteur) | `docker restart traefik` ; le problème ne s'est pas reproduit ensuite |

## 10. Contraintes et limites de docker-rollout

- Le service ne doit **pas** avoir de `container_name` ni de `ports:` publiés. Seul Traefik expose un port.
- Un **reverse proxy est obligatoire** (Traefik, nginx-proxy, Caddy...).
- Un **healthcheck** est nécessaire pour une bascule fiable.
- Les deux versions tournent **en même temps** quelques secondes : l'application doit le tolérer.
- Fonctionne sur **un seul hôte** Docker Compose, pas sur un cluster.

## 11. Risques et points d'attention

| Risque | Mesure |
|---|---|
| Migrations de base de données : ancienne et nouvelle version utilisent la même base en même temps | Migrations rétrocompatibles (ajouter avant de supprimer) |
| Sessions utilisateur réparties sur deux versions | Sessions externes (Redis, JWT) ou sessions persistantes |
| `docker.sock` monté dans Traefik | Montage en lecture seule ; en production, un proxy de socket |
| Tableau de bord Traefik exposé (`--api.insecure=true`) | À retirer ou protéger en production |
| Pas de HTTPS dans ce spike | Ajouter un résolveur Let's Encrypt |
| Retour arrière | Relancer `bash scripts/deploy.sh <ancienne_version>` ; `docker-rollout` annule seul un nouveau conteneur qui ne devient pas sain |

## 12. Application à la pile réelle (tâches #20 et #21)

- Chaque service déployé via rollout (frontend, backend) doit exposer une route de santé (`/health`) et déclarer un `healthcheck`.
- Le drainage de ce spike repose sur nginx. Pour le **frontend**, s'il est servi par nginx, la même configuration est réutilisable. Pour le **backend**, il faudra un équivalent adapté à sa technologie (route de santé qui passe en erreur sur demande), à valider avec l'équipe concernée. À défaut, on peut s'appuyer sur la sonde de santé Traefik et un délai avant l'arrêt, puis mesurer de nouveau.
- Les noms d'image, les ports et les variables d'environnement sont à récupérer auprès des équipes CI.
- Le script de déploiement s'intègre à un `Jenkinsfile` (étape `sh 'bash scripts/deploy.sh ${TAG}'`). Cela suppose que Jenkins ait accès au démon Docker et au plugin `docker-rollout`.

## 13. Alternatives comparées

| Solution | Avantage | Inconvénient |
|---|---|---|
| **Traefik + docker-rollout** | Simple, reste sur Docker Compose | Un seul hôte ; drainage à configurer |
| Docker Swarm (`update_config`, `start-first`) | Natif, multi-hôtes | Passage à Swarm |
| Blue/green manuel avec Compose | Contrôle total | Scripts à écrire et maintenir |
| Kubernetes (rolling update) | Standard, complet | Complexité et ressources |
| Plan B : deux répliques redémarrées une par une | Sans plugin | Plus manuel, non retenu car inutile |

## 14. Conclusion

Pour un projet de cette taille sur un seul serveur, **Traefik + docker-rollout est adapté** : peu de configuration, aucun changement d'orchestrateur. Le drainage de l'ancien conteneur est nécessaire pour atteindre zéro requête perdue : sans lui, on mesure un à deux échecs à chaque bascule. Avec lui, deux mesures indépendantes (poste et réseau Docker) montrent 0 échec sur plus de 800 requêtes. Les limites (un seul hôte, applications tolérant deux versions simultanées, drainage à adapter à chaque service) sont acceptables pour le périmètre du projet.

## 15. Sources

- Plugin : https://github.com/wowu/docker-rollout (code lu pour le comportement du hook `--pre-stop-hook`)
- Documentation : https://docker-rollout.wowu.dev/
- Traefik, fournisseur Docker : https://doc.traefik.io/traefik/providers/docker/
- Traefik, sonde de santé des services : https://doc.traefik.io/traefik/routing/services/
