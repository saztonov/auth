#!/usr/bin/env bash
# ОТКАТ (по решению, НЕ автоматически): удаляет из su10 KC пользователей из списка. Используется, если
# после отката AUTH_MODE=keycloak→standalone решено вычистить импортированные KC-записи (напр. перед
# повторной попыткой миграции). Если откат постоянный — возможно, безопаснее ОСТАВИТЬ KC-записи как есть
# (AUTH_MODE=standalone их больше не читает; удаление стирает след реальных входов, если кто-то успел
# войти через Keycloak до отката — credential к тому моменту уже мог перехэшироваться в argon2).
#
# Список — по одному username ИЛИ email на строку. Постройте его из отчёта импорта (kc-import.json),
# например: jq -r '.imported[].username' kc-import.json > to-delete.txt (поле подставить под реальную
# схему отчёта — сообщите структуру, подгоню скрипт под неё напрямую).
#
#   bash keycloak/realm/rollback-delete-kc-users.sh to-delete.txt
set -euo pipefail
set +x

LIST_FILE="${1:-}"
[[ -n "${LIST_FILE}" ]] || { echo "Usage: $0 <файл со списком username/email, по одному на строку>" >&2; exit 1; }
[[ -f "${LIST_FILE}" ]] || { echo "!! файл не найден: ${LIST_FILE}" >&2; exit 1; }

KC_DIR="${KC_DIR:-/opt/infra/keycloak}"
KC_CONTAINER="${KC_CONTAINER:-keycloak}"
EDGE_NET="${EDGE_NET:-edge}"
REALM="${REALM:-su10}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:latest}"

fail() { echo "!! $*" >&2; exit 1; }
info() { echo "==> $*"; }

command -v docker >/dev/null || fail "docker не найден"
[[ -f "${KC_DIR}/.env" ]] || fail "нет ${KC_DIR}/.env"

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
adm_delete() { printf '' | docker run --rm -i --network "${EDGE_NET}" -e ATOKEN "${CURL_IMAGE}" sh -c \
  'curl -s -o /dev/null -w "%{http_code}" -X DELETE -H "Authorization: Bearer $ATOKEN" \
   "http://'"${KC_CONTAINER}"':8080/admin/realms/'"${REALM}"'/users/'"$1"'"'; }

info "realm ${REALM} — удаление $(wc -l < "${LIST_FILE}") записей из ${LIST_FILE}"
DELETED=0; MISSING=0
while IFS= read -r U; do
  [[ -z "${U}" ]] && continue
  UID_KC="$(adm_get "users?username=${U}&exact=true" | grep -oE '"id":"[0-9a-f-]{36}"' | head -1 | cut -d'"' -f4)"
  if [[ -z "${UID_KC}" ]]; then
    UID_KC="$(adm_get "users?email=${U}&exact=true" | grep -oE '"id":"[0-9a-f-]{36}"' | head -1 | cut -d'"' -f4)"
  fi
  if [[ -n "${UID_KC}" ]]; then
    CODE="$(adm_delete "${UID_KC}")"
    echo "  ${U}: id=${UID_KC} DELETE→${CODE}"
    DELETED=$((DELETED+1))
  else
    echo "  ${U}: не найден в KC (уже удалён?)"
    MISSING=$((MISSING+1))
  fi
done < "${LIST_FILE}"

info "готово: удалено=${DELETED} не найдено=${MISSING}"
