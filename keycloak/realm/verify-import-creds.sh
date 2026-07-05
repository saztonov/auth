#!/usr/bin/env bash
# Проверка import-кредов `billhub-import` (manage-realm) на ЖИВОМ su10: что под client_credentials этого
# клиента реально проходит `partialImport`. Временно включает клиент, импортирует ОДНОГО throwaway-юзера
# (только атрибут billhub_user_id, БЕЗ пароля), проверяет что атрибут сохранён, УДАЛЯЕТ юзера и ВЫКЛЮЧАЕТ
# клиент обратно (даже при ошибке — через trap). Логин/перехэш доказаны отдельно; тут только authz+атрибут.
#
#   bash keycloak/realm/verify-import-creds.sh
#
# Предпосылки: клиент billhub-import создан config-cli (enabled:false), секрет в /opt/infra/keycloak/.env.
set -euo pipefail
set +x

KC_DIR="${KC_DIR:-/opt/infra/keycloak}"
KC_CONTAINER="${KC_CONTAINER:-keycloak}"
EDGE_NET="${EDGE_NET:-edge}"
REALM="${REALM:-su10}"
IMPORT_CLIENT="${IMPORT_CLIENT:-billhub-import}"
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
IMPORT_SECRET="$(getenv BILLHUB_IMPORT_CLIENT_SECRET)"
[[ -n "${ADMIN_USER}" && -n "${ADMIN_PASS}" ]] || fail "нет admin-creds в .env"
[[ -n "${IMPORT_SECRET}" ]] || fail "нет BILLHUB_IMPORT_CLIENT_SECRET в .env"
export ADMIN_USER ADMIN_PASS IMPORT_SECRET

# --- токены/хелперы (токены не печатаем) ---
token() { # $1=client_id $2=grant(password|client_credentials) [uses ADMIN_* or IMPORT_SECRET]
  local cid="$1" grant="$2"
  if [[ "${grant}" == password ]]; then
    docker run --rm --network "${EDGE_NET}" -e ADMIN_USER -e ADMIN_PASS "${CURL_IMAGE}" sh -c \
      'curl -s -d grant_type=password -d client_id='"${cid}"' -d "username=$ADMIN_USER" -d "password=$ADMIN_PASS" \
       http://'"${KC_CONTAINER}"':8080/realms/master/protocol/openid-connect/token'
  else
    docker run --rm --network "${EDGE_NET}" -e IMPORT_SECRET "${CURL_IMAGE}" sh -c \
      'curl -s -d grant_type=client_credentials -d client_id='"${cid}"' -d "client_secret=$IMPORT_SECRET" \
       http://'"${KC_CONTAINER}"':8080/realms/'"${REALM}"'/protocol/openid-connect/token'
  fi | grep -oE '"access_token":"[^"]+"' | cut -d'"' -f4
}
adm_get() { docker run --rm --network "${EDGE_NET}" -e AT="${ADMIN_TOKEN}" "${CURL_IMAGE}" sh -c \
  'curl -s -H "Authorization: Bearer $AT" http://'"${KC_CONTAINER}"':8080/admin/realms/'"${REALM}"'/'"$1"; }
adm_send() { # $1=method $2=path ; body on stdin ; prints http code
  docker run --rm -i --network "${EDGE_NET}" -e AT="${ADMIN_TOKEN}" "${CURL_IMAGE}" sh -c \
    'curl -s -o /dev/null -w "%{http_code}" -X '"$1"' -H "Authorization: Bearer $AT" -H "Content-Type: application/json" \
     --data-binary @- http://'"${KC_CONTAINER}"':8080/admin/realms/'"${REALM}"'/'"$2"; }
set_enabled() { # $1=true|false — GET клиента, флипнуть enabled (node), PUT обратно (полный rep)
  local val="$1"
  adm_get "clients/${IMP_ID}" \
    | EN="${val}" docker run --rm -i -e EN "${NODE_IMAGE}" node -e \
       'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const o=JSON.parse(d);o.enabled=(process.env.EN==="true");process.stdout.write(JSON.stringify(o))})' \
    | adm_send PUT "clients/${IMP_ID}" >/dev/null
}

info "admin-токен"
ADMIN_TOKEN="$(token admin-cli password)"; [[ -n "${ADMIN_TOKEN}" ]] || fail "admin-токен не получен"
export ADMIN_TOKEN

IMP_ID="$(adm_get "clients?clientId=${IMPORT_CLIENT}" | grep -oE '"id":"[0-9a-f-]{36}"' | head -1 | cut -d'"' -f4)"
[[ -n "${IMP_ID}" ]] || fail "клиент ${IMPORT_CLIENT} не найден на ${REALM} — сначала накатите config-cli"
info "клиент ${IMPORT_CLIENT} найден (id=${IMP_ID})"

TEST_USER="imp-selftest-$(head -c6 /dev/urandom | base64 | tr -dc a-z0-9 | head -c6)"
TEST_UID="$(cat /proc/sys/kernel/random/uuid)"

cleanup() {
  set +e
  # удалить throwaway-юзера (если создан)
  local uid; uid="$(adm_get "users?username=${TEST_USER}&exact=true" | grep -oE '"id":"[0-9a-f-]{36}"' | head -1 | cut -d'"' -f4)"
  [[ -n "${uid}" ]] && printf '' | adm_send DELETE "users/${uid}" >/dev/null
  # выключить клиент обратно
  [[ -n "${IMP_ID:-}" ]] && set_enabled false
  info "cleanup: throwaway-юзер удалён, ${IMPORT_CLIENT} снова enabled:false"
}
trap cleanup EXIT

info "временно включаю ${IMPORT_CLIENT}"
set_enabled true

info "client_credentials под ${IMPORT_CLIENT}"
IMPORT_TOKEN="$(token "${IMPORT_CLIENT}" client_credentials)"
[[ -n "${IMPORT_TOKEN}" ]] || fail "client_credentials не отдал токен (клиент выключен? неверный секрет?)"
export IMPORT_TOKEN
info "[ok] токен по client_credentials получен"

info "partialImport одного throwaway-юзера ПОД import-токеном (проверка manage-realm authz)"
PI_CODE="$(docker run --rm -i --network "${EDGE_NET}" -e IMPORT_TOKEN "${CURL_IMAGE}" sh -c \
  'curl -s -o /dev/null -w "%{http_code}" -X POST -H "Authorization: Bearer $IMPORT_TOKEN" -H "Content-Type: application/json" \
   --data-binary @- http://'"${KC_CONTAINER}"':8080/admin/realms/'"${REALM}"'/partialImport' <<JSON
{ "ifResourceExists": "SKIP", "users": [
  { "username": "${TEST_USER}", "enabled": false, "email": "${TEST_USER}@example.invalid", "emailVerified": true,
    "firstName": "Imp", "lastName": "Selftest", "attributes": { "billhub_user_id": ["${TEST_UID}"] } } ] }
JSON
)"
[[ "${PI_CODE}" == "200" ]] || fail "[FAIL] partialImport под ${IMPORT_CLIENT} вернул HTTP ${PI_CODE} (403 = manage-realm не хватает)"
info "[ok] partialImport принят (HTTP 200) — manage-realm авторизует импорт"

info "проверяю, что throwaway-юзер создан и атрибут billhub_user_id сохранён"
UID_KC="$(adm_get "users?username=${TEST_USER}&exact=true" | grep -oE '"id":"[0-9a-f-]{36}"' | head -1 | cut -d'"' -f4)"
[[ -n "${UID_KC}" ]] || fail "[FAIL] throwaway-юзер не найден после partialImport"
if adm_get "users/${UID_KC}" | grep -q "${TEST_UID}"; then
  info "[ok] атрибут billhub_user_id сохранён в su10 (профиль работает на боевом realm)"
else
  fail "[FAIL] атрибут billhub_user_id не сохранён — проверьте user-profile su10"
fi

echo
info "РЕЗУЛЬТАТ: import-креды рабочие — billhub-import (manage-realm) делает partialImport, атрибут"
info "          billhub_user_id сохраняется на боевом su10. Throwaway-юзер удаляется, клиент → enabled:false."
