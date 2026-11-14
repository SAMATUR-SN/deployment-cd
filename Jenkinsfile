// =============================================================================
// Sama Tur - deployment-cd - Jenkinsfile
// Déploie backend et/ou frontend SANS COUPURE (Traefik + docker-rollout).
// Appelé par backend-ci et frontend-ci avec BACKEND_TAG ou FRONTEND_TAG ;
// peut aussi être lancé à la main (Build with Parameters).
//
// Un paramètre laissé VIDE signifie « ne pas toucher à ce service » (il garde sa version
// actuelle). S'il n'est pas encore déployé, il est démarré en « latest ».
// =============================================================================

pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()          // un seul déploiement à la fois, les autres attendent
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timeout(time: 40, unit: 'MINUTES')
    }

    parameters {
        string(name: 'BACKEND_TAG', defaultValue: '',
               description: 'Tag de l\'image backend à déployer (ex : 12-eea92cd). Vide = backend inchangé.')
        string(name: 'FRONTEND_TAG', defaultValue: '',
               description: 'Tag de l\'image frontend à déployer (ex : 2-49b3548). Vide = frontend inchangé.')
    }

    environment {
        COMPOSE_PROJECT_NAME = 'samatur'
        DOCKERHUB_CREDS      = 'dockerhub-credentials'   // Username + password (token Docker Hub)
        POSTGRES_PWD_CREDS   = 'postgres-password'       // Secret text
        JWT_SECRET_CREDS     = 'samatur-jwt-secret'      // Secret text (32 caractères minimum)
        ROLLOUT_TIMEOUT      = '180'                     // secondes d'attente d'un conteneur "healthy"
        DRAIN_SECONDS        = '3'                       // pause de drainage du frontend avant arrêt
        BACKEND_DRAIN_SECONDS = '10'                     // idem backend (2 contrôles de santé de 2 s + marge)
        CHECK_BASE_URL       = ''                        // vide = http://host.docker.internal:<port Traefik>
    }

    stages {

        stage('Préparation') {
            steps {
                checkout scm
                sh '''
                    docker compose version
                    docker rollout --help > /dev/null
                '''
                script {
                    def back  = resolveTag(params.BACKEND_TAG,  'backend')
                    def front = resolveTag(params.FRONTEND_TAG, 'frontend')
                    env.BACKEND_TAG_EFFECTIVE  = back.tag
                    env.FRONTEND_TAG_EFFECTIVE = front.tag
                    env.DEPLOY_BACKEND         = back.deploy.toString()
                    env.DEPLOY_FRONTEND        = front.deploy.toString()
                    echo "Backend  : ${back.tag}  -> ${back.deploy ? 'DÉPLOIEMENT' : 'inchangé'}"
                    echo "Frontend : ${front.tag} -> ${front.deploy ? 'DÉPLOIEMENT' : 'inchangé'}"
                    currentBuild.description = "backend=${back.tag} frontend=${front.tag}"
                }
            }
        }

        stage('Récupération des images') {
            when { expression { env.DEPLOY_BACKEND == 'true' || env.DEPLOY_FRONTEND == 'true' } }
            steps {
                withCredentials([usernamePassword(credentialsId: env.DOCKERHUB_CREDS,
                                                  usernameVariable: 'DH_USER',
                                                  passwordVariable: 'DH_PASS')]) {
                    withStack {
                        sh '''
                            echo "$DH_PASS" | docker login -u "$DH_USER" --password-stdin
                            docker compose config -q
                            services=""
                            [ "$DEPLOY_BACKEND"  = "true" ] && services="$services backend"
                            [ "$DEPLOY_FRONTEND" = "true" ] && services="$services frontend"
                            docker compose pull $services
                        '''
                    }
                }
            }
        }

        stage('Base de données et Traefik') {
            steps {
                withStack {
                    // Ne touche pas aux données : le volume pgdata est conservé.
                    sh 'docker compose up -d --wait postgres traefik'
                }
            }
        }

        stage('Déploiement backend') {
            when { expression { env.DEPLOY_BACKEND == 'true' } }
            steps {
                withStack {
                    // Si le nouveau conteneur ne devient pas "healthy", docker-rollout le supprime
                    // et l'ancien continue de servir : l'échec ne coupe rien.
                    // Drainage : /tmp/draining rend l'ancien conteneur "unhealthy" ; Traefik cesse alors
                    // de lui envoyer du trafic, puis il est arrêté (arrêt en douceur de Spring Boot).
                    sh '''
                        docker rollout --timeout "$ROLLOUT_TIMEOUT" \\
                          --pre-stop-hook "touch /tmp/draining; sleep $BACKEND_DRAIN_SECONDS" \\
                          -f docker-compose.yml backend
                    '''
                }
            }
        }

        stage('Déploiement frontend') {
            when { expression { env.DEPLOY_FRONTEND == 'true' } }
            steps {
                withStack {
                    // Drainage : /health du frontend répond 503, Traefik le retire du routage,
                    // puis l'ancien conteneur est arrêté.
                    sh '''
                        docker rollout --timeout "$ROLLOUT_TIMEOUT" \
                          --pre-stop-hook "touch /tmp/draining; sleep $DRAIN_SECONDS" \
                          -f docker-compose.yml frontend
                    '''
                }
            }
        }

        stage('Vérification') {
            steps {
                withStack {
                    sh '''
                        if [ -n "$CHECK_BASE_URL" ]; then
                            BASE="$CHECK_BASE_URL"
                        else
                            PORT=$(docker compose port traefik 80 | sed 's/.*://')
                            BASE="http://host.docker.internal:${PORT}"
                        fi
                        echo "Adresse testée : $BASE"

                        # check <url> <code accepté> [<autre code accepté> ...] : 24 essais, 5 s d'écart
                        check() {
                            url="$1"; shift
                            i=0
                            while [ "$i" -lt 24 ]; do
                                code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$url" || true)
                                for ok in "$@"; do
                                    if [ "$code" = "$ok" ]; then echo "OK  $url -> $code"; return 0; fi
                                done
                                i=$((i + 1))
                                echo "attente ($i/24) $url -> ${code:-000}"
                                sleep 5
                            done
                            echo "ÉCHEC $url"
                            return 1
                        }

                        # Frontend via Traefik : /health répond 200 « ok »
                        check "$BASE/health" 200
                        # Backend via Traefik : /api/dossiers exige un jeton, donc 401 ou 403 prouve
                        # que la requête atteint bien Spring Boot (200 si un jeton était fourni)
                        check "$BASE/api/dossiers" 200 401 403

                        echo
                        docker compose ps
                        echo
                        docker ps --filter label=com.docker.compose.project=samatur \
                                  --format 'table {{.Label "com.docker.compose.service"}}\t{{.Image}}\t{{.Status}}'
                    '''
                }
            }
        }
    }

    post {
        success {
            echo "Déploiement terminé : backend ${env.BACKEND_TAG_EFFECTIVE}, frontend ${env.FRONTEND_TAG_EFFECTIVE}."
        }
        failure {
            echo "ÉCHEC du déploiement (backend ${env.BACKEND_TAG_EFFECTIVE}, frontend ${env.FRONTEND_TAG_EFFECTIVE}). " +
                 "Si un conteneur n'est pas devenu sain, l'ancienne version est restée en service."
            sh '''
                for s in backend frontend traefik postgres; do
                    for c in $(docker ps -aq --filter label=com.docker.compose.project=samatur \
                                            --filter label=com.docker.compose.service=$s); do
                        echo "===== $s ($c) : 30 dernières lignes ====="
                        docker logs --tail 30 "$c" 2>&1 || true
                    done
                done
            '''
        }
        always {
            sh 'docker logout || true'
        }
    }
}

// Exécute le bloc avec les secrets et les tags effectifs dans l'environnement.
// Les secrets sont masqués dans le journal et ne sont écrits dans aucun fichier.
def withStack(Closure body) {
    withCredentials([string(credentialsId: env.POSTGRES_PWD_CREDS, variable: 'POSTGRES_PASSWORD'),
                     string(credentialsId: env.JWT_SECRET_CREDS,   variable: 'SAMATUR_JWT_SECRET')]) {
        withEnv(["BACKEND_TAG=${env.BACKEND_TAG_EFFECTIVE}",
                 "FRONTEND_TAG=${env.FRONTEND_TAG_EFFECTIVE}"]) {
            body()
        }
    }
}

// Tag demandé -> [tag, deploy]. Vide : on garde la version en cours (deploy=false),
// ou « latest » si le service n'est pas encore déployé.
def resolveTag(String requested, String service) {
    def tag = (requested ?: '').trim()
    if (tag) {
        if (!(tag ==~ /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$/)) {
            error("Tag invalide pour ${service} : '${tag}'")
        }
        return [tag: tag, deploy: true]
    }
    def current = sh(returnStdout: true, script: """
        cid=\$(docker ps -q --filter label=com.docker.compose.project=samatur \
                          --filter label=com.docker.compose.service=${service} | head -n1)
        if [ -n "\$cid" ]; then docker inspect --format '{{.Config.Image}}' "\$cid" | sed 's/.*://'; fi
    """).trim()
    return current ? [tag: current, deploy: false] : [tag: 'latest', deploy: true]
}
