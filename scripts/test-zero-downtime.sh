#!/usr/bin/env bash
# Preuve de mise à jour sans coupure (tâche #26).
# Envoie des requêtes en continu sur la page d'accueil du frontend (/) et sur /api/dossiers
# (backend) PENDANT qu'un déploiement tourne, puis donne un bilan par adresse.
# /health du frontend est mesuré à titre INFORMATIF seulement : c'est le signal de drainage
# (503 voulu quelques centaines de ms avant l'arrêt de l'ancien conteneur), pas ce que voit
# un utilisateur.
#
# Usage : bash scripts/test-zero-downtime.sh [url_de_base] [durée_en_secondes]
#   ex  : bash scripts/test-zero-downtime.sh http://localhost:8088 240
#
# Variables facultatives (jeton réel, pour obtenir des 200 au lieu de 401) :
#   TEST_USER=etatcivil1@samatur.sn TEST_PASSWORD=...   (comptes de démonstration)
#   CURL_TIMEOUT=10   délai maximal par requête en secondes (3 par défaut)
#
# Codes comptés comme « service disponible » :
#   /               : 200 (page d'accueil Angular)
#   /api/dossiers   : 200 avec jeton ; 200, 401 ou 403 sans jeton (la requête a atteint le backend)
# Tout le reste (000 = connexion coupée, 404 Traefik, 502, 503, 504) est un échec.
set -uo pipefail

BASE="${1:-http://localhost:8088}"
DURATION="${2:-240}"
CURL_TIMEOUT="${CURL_TIMEOUT:-3}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

now() {
  local t="${EPOCHREALTIME/,/.}" f
  f="${t#*.}"
  printf '%(%T)T.%s' "${t%.*}" "${f:0:3}"
}

AUTH=(-H "X-Test: zero-downtime")
API_OK="200 401 403"
if [ -n "${TEST_USER:-}" ] && [ -n "${TEST_PASSWORD:-}" ]; then
  body=$(printf '{"identifiant":"%s","motDePasse":"%s"}' "$TEST_USER" "$TEST_PASSWORD")
  token=$(curl -s -m 10 -H 'Content-Type: application/json' -d "$body" "$BASE/api/auth/connexion" \
          | sed -n 's/.*"jeton" *: *"\([^"]*\)".*/\1/p')
  if [ -n "$token" ]; then
    AUTH=(-H "Authorization: Bearer $token")
    API_OK="200"
    echo "Connexion réussie : /api/dossiers testé avec un jeton (200 attendu)."
  else
    echo "Connexion impossible : /api/dossiers testé sans jeton (401 ou 403 attendus)."
  fi
fi

# probe <nom> <url> <codes acceptés...> : boucle pendant DURATION secondes
probe() {
  local name="$1" url="$2"; shift 2
  local ok=0 ko=0 first="" last="" code ts end line accepted
  end=$((SECONDS + DURATION))
  while [ "$SECONDS" -lt "$end" ]; do
    ts=$(now)
    out=$(curl -s -o /dev/null -m "$CURL_TIMEOUT" "${AUTH[@]}" -w '%{http_code} %{exitcode} %{time_total}' "$url" || true)
    read -r code cexit ctime <<< "$out"
    accepted=0
    for c in "$@"; do [ "$code" = "$c" ] && accepted=1; done
    if [ "$accepted" = 1 ]; then
      ok=$((ok + 1))
      line="${ts}  ${name}  ${code}"
    else
      ko=$((ko + 1))
      [ -z "$first" ] && first="$ts"
      last="$ts"
      # curl=28 : délai dépassé ; 7 : connexion refusée ; 52 : réponse vide ; 56 : connexion coupée
      line="${ts}  ${name}  ${code:-000}  curl=${cexit:-?}  ${ctime:-?}s  ECHEC"
    fi
    echo "$line" >> "$TMP/${name}.log"
    sleep 0.2
  done
  echo "${ok} ${ko} ${first:--} ${last:--}" > "$TMP/${name}.result"
}

echo "Début : $(now) - ${DURATION}s sur ${BASE}"
echo "Lancer MAINTENANT le job deployment-cd avec un nouveau tag (backend et/ou frontend)."
probe front "${BASE}/" 200 &
# shellcheck disable=SC2086
probe api "${BASE}/api/dossiers" $API_OK &
probe health "${BASE}/health" 200 &
wait
echo "Fin : $(now)"
echo

status=0
for name in front api; do
  read -r ok ko first last < "$TMP/${name}.result"
  printf '%-7s réussies : %s   échecs : %s\n' "$name" "$ok" "$ko"
  if [ "$ko" -gt 0 ]; then
    status=1
    echo "        premier échec : $first   dernier : $last"
    grep ECHEC "$TMP/${name}.log" | head -5 | sed 's/^/        /'
  fi
done
read -r ok ko first last < "$TMP/health.result"
printf '%-7s réussies : %s   503 de drainage ou échecs : %s   (informatif, non compté)\n' health "$ok" "$ko"
echo
if [ "$status" -eq 0 ]; then
  echo "RÉSULTAT : aucune coupure détectée."
else
  echo "RÉSULTAT : coupure détectée."
fi
exit "$status"
