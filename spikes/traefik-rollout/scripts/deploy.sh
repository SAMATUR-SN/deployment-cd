#!/usr/bin/env bash
# Déploiement sans coupure du service "web".
# Usage : bash scripts/deploy.sh v2
#
# Avant d'arrêter l'ancien conteneur, un "hook" le met en mode drainage
# (/health répond 503, fichier /tmp/draining). Traefik le retire alors du
# routage, puis docker-rollout l'arrête sans requête en cours de route.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:?Usage: bash scripts/deploy.sh <version>  (ex : v2)}"
export APP_VERSION="$VERSION"
DRAIN_SECONDS="${DRAIN_SECONDS:-3}"

# Horodatage en millisecondes (indépendant de la version de "date")
now() {
  local t="${EPOCHREALTIME/,/.}" f
  f="${t#*.}"
  printf '%(%T)T.%s' "${t%.*}" "${f:0:3}"
}

if [ ! -x "${HOME}/.docker/cli-plugins/docker-rollout" ]; then
  echo "docker-rollout n'est pas installé. Voir le README (section Installation)." >&2
  exit 1
fi

echo ">> Construction de l'image spike-web:${VERSION}"
docker compose build web

echo ">> [$(now)] Début du rollout (drainage : ${DRAIN_SECONDS}s)"
docker rollout \
  --pre-stop-hook "touch /tmp/draining; sleep ${DRAIN_SECONDS}" \
  -f docker-compose.yml web

echo ">> [$(now)] Rollout terminé. Conteneurs actifs :"
docker compose ps
