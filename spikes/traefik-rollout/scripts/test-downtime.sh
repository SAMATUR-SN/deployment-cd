#!/usr/bin/env bash
# Envoie des requêtes en continu pendant un déploiement et produit un bilan détaillé.
# Usage : bash scripts/test-downtime.sh [url] [durée_en_secondes]
set -uo pipefail

URL="${1:-http://localhost:8088/}"
DURATION="${2:-60}"
ok=0
ko=0
first_ko=""
last_ko=""
declare -A versions
end=$((SECONDS + DURATION))

# Horodatage en millisecondes (indépendant de la version de "date")
now() {
  local t="${EPOCHREALTIME/,/.}" f
  f="${t#*.}"
  printf '%(%T)T.%s' "${t%.*}" "${f:0:3}"
}

echo "Test sur ${URL} pendant ${DURATION}s (début : $(now))"

while [ "$SECONDS" -lt "$end" ]; do
  ts=$(now)
  out=$(curl -s -m 2 -w $'\n%{http_code}' "$URL" || true)
  code="${out##*$'\n'}"
  body="${out%$'\n'*}"
  body="${body%$'\n'}"   # retire le saut de ligne final de la page

  if [ "$code" = "200" ]; then
    ok=$((ok + 1))
    ver=$(echo "$body" | grep -oE 'Application v[0-9A-Za-z._-]+' | head -1)
    ver="${ver:-inconnue}"
    versions["$ver"]=$(( ${versions["$ver"]:-0} + 1 ))
    echo "${ts}  200  ${body}"
  else
    ko=$((ko + 1))
    [ -z "$first_ko" ] && first_ko="$ts"
    last_ko="$ts"
    echo "${ts}  ${code:-000}  ECHEC"
  fi
  sleep 0.2
done

echo
echo "Fin : $(now)"
echo "Requêtes réussies : ${ok}"
echo "Requêtes en échec : ${ko}"
for v in "${!versions[@]}"; do
  echo "  ${v} : ${versions[$v]} réponses"
done
if [ "$ko" -gt 0 ]; then
  echo "Premier échec : ${first_ko} / dernier échec : ${last_ko}"
  echo "RÉSULTAT : coupure détectée."
else
  echo "RÉSULTAT : aucune coupure détectée."
fi
