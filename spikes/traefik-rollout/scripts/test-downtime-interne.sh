#!/usr/bin/env bash
# Même test, mais exécuté DANS le réseau Docker (depuis le conteneur traefik).
# Il mesure la chaîne Traefik -> conteneurs web sans passer par la publication
# de ports de Docker Desktop. Utile pour distinguer un problème de rollout
# d'un problème du poste de travail.
# Usage : bash scripts/test-downtime-interne.sh [durée_en_secondes]
set -uo pipefail

DURATION="${1:-60}"

docker exec traefik sh -c '
DURATION="$1"
end=$(( $(date +%s) + DURATION ))
ok=0
ko=0
echo "Test interne (Traefik -> web) pendant ${DURATION}s"
while [ "$(date +%s)" -lt "$end" ]; do
  ts=$(date +%T)
  if body=$(wget -q -T 2 -O- http://127.0.0.1:80/ 2>/dev/null); then
    ok=$((ok + 1))
    echo "${ts}  200  ${body}"
  else
    ko=$((ko + 1))
    echo "${ts}  ECHEC"
  fi
  sleep 0.2
done
echo
echo "Requêtes réussies : ${ok}"
echo "Requêtes en échec : ${ko}"
[ "$ko" -eq 0 ] && echo "RÉSULTAT : aucune coupure détectée." || echo "RÉSULTAT : coupure détectée."
' sh "$DURATION"
