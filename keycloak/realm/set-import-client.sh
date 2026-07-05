#!/usr/bin/env bash
# Включает/выключает клиент billhub-import (manage-realm) на su10. Использовать ТОЛЬКО на окно
# массового импорта BillHub — включить перед реальным import (после dry-run), выключить сразу после.
#
#   bash keycloak/realm/set-import-client.sh enable
#   bash keycloak/realm/set-import-client.sh disable
set -euo pipefail
set +x

ACTION="${1:-}"
[[ "${ACTION}" == "enable" || "${ACTION}" == "disable" ]] || { echo "Usage: $0 enable|disable" >&2; exit 1; }
VAL="$([[ "${ACTION}" == "enable" ]] && echo true || echo false)"

KC_DIR="${KC_DIR:-/opt/infra/keycloak}"
KC_CONTAINER="${KC_CONTAINER:-keycloak}"
EDGE_NET="${EDGE_NET:-edge}"
REALM="${REALM:-su10}"
CLIENT_ID="${CLIENT_ID:-billhub-import}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:latest}"
NODE_IMAGE="${NODE_IMAGE:-node:20-alpine}"

fail() { echo "!! $*" >&2; exit 1; }
info() { echo "==> $*"; }

command -v docker >/dev/null || fail "docker не найден"
[[ -f "${KC_DIR}/.env" ]] || fail "нет ${KC_DIR}/.env"
docker ps --format '{{.Names}}' | grep -qx "${KC_CONTAINER}" || fail "контейнер '${KC_CONTAINER}' не запущен"

getenv() { grep -E "^$1=" "${KC_DIR}/.env" | tail -1 | cut -d= -f2- | sed -e 's/^["'\'']//' -e 's/["'\'']$//'; }
ADMIN_USER="$(getenv KEYCLOAK_ADMIN_USER)"; [[ -n "${ADMIN_USER}" ]] || ADMIN_USER="$(getenv KC_BOOTSTRAP_ADMIN_USERNAME)"
ADMIN_PASS="$(getenv KEYCLOAK_ADMIN_PASSWORD)"; [[ -n "${ADMIN_PASS}" ]] || ADMIN_PASS="$(getenv KC_BOOTSTRAP_ADMIN_PASSWORD)"
[[ -n "${ADMIN_USER}" && -n "${ADMIN_PASS}" ]] || fail "нет admin-creds в ${KC_DIR}/.env"
export ADMIN_USER ADMIN_PASS

ATOKEN="$(docker run --rm --network "${EDGE_NET}" -e ADMIN_USER -e ADMIN_PASS "${CURL_IMAGE}" sh -c \
  'curl -s -d grant_type=password -d client_id=admin-cli -d "username=$ADMIN_USER" -d "password=$ADMIN_PASS" \
   http://'"${KC_CONTAINER}"':8080/realms/master/protocol/openid-connect/token' \
  | grep -oE '"access_token":"[^"]+"' | cut -d'"' -f4)"
[[ -n "${ATOKEN}" ]] || fail "не получил admin-токен"
export ATOKEN

adm_get() { docker run --rm --network "${EDGE_NET}" -e ATOKEN "${CURL_IMAGE}" sh -c \
  'curl -s -H "Authorization: Bearer $ATOKEN" "http://'"${KC_CONTAINER}"':8080/admin/realms/'"${REALM}"'/'"$1"'"'; }
adm_send() { docker run --rm -i --network "${EDGE_NET}" -e ATOKEN "${CURL_IMAGE}" sh -c \
  'curl -s -o /dev/null -w "%{http_code}" -X '"$1"' -H "Authorization: Bearer $ATOKEN" -H "Content-Type: application/json" \
   --data-binary @- "http://'"${KC_CONTAINER}"':8080/admin/realms/'"${REALM}"'/'"$2"'"'; }

CID="$(adm_get "clients?clientId=${CLIENT_ID}" | grep -oE '"id":"[0-9a-f-]{36}"' | head -1 | cut -d'"' -f4)"
[[ -n "${CID}" ]] || fail "клиент ${CLIENT_ID} не найден на ${REALM} (сначала накатите config-cli)"

CUR="$(adm_get "clients/${CID}" | grep -oE '"enabled":[a-z]*' | cut -d: -f2)"
info "${CLIENT_ID} (id=${CID}): enabled=${CUR} → ${VAL}"

CODE="$(adm_get "clients/${CID}" \
  | EN="${VAL}" docker run --rm -i -e EN "${NODE_IMAGE}" node -e \
     'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const o=JSON.parse(d);o.enabled=(process.env.EN==="true");process.stdout.write(JSON.stringify(o))})' \
  | adm_send PUT "clients/${CID}")"
[[ "${CODE}" == "204" || "${CODE}" == "200" ]] || fail "PUT вернул HTTP ${CODE}"

NEW="$(adm_get "clients/${CID}" | grep -oE '"enabled":[a-z]*' | cut -d: -f2)"
[[ "${NEW}" == "${VAL}" ]] || fail "после PUT enabled=${NEW}, ожидалось ${VAL}"
info "[ok] ${CLIENT_ID} теперь enabled=${NEW}"
