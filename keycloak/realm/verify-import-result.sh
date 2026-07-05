#!/usr/bin/env bash
# Пост-импортная сверка su10 после массового импорта BillHub: счётчики юзеров/групп + опциональная
# выборочная проверка атрибута billhub_user_id. Read-only, live-данные не трогает.
#
#   bash keycloak/realm/verify-import-result.sh                     # только счётчики
#   bash keycloak/realm/verify-import-result.sh sample.txt          # + spot-check (username/email построчно)
set -euo pipefail
set +x

KC_DIR="${KC_DIR:-/opt/infra/keycloak}"
KC_CONTAINER="${KC_CONTAINER:-keycloak}"
EDGE_NET="${EDGE_NET:-edge}"
REALM="${REALM:-su10}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:latest}"
SAMPLE_FILE="${1:-}"

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

info "realm ${REALM} — общие счётчики"
TOTAL="$(adm_get 'users/count')"
echo "  всего пользователей: ${TOTAL}"

for GRP in billhub-pending billhub-active; do
  GID="$(adm_get "groups?search=${GRP}" | grep -oE '"id":"[0-9a-f-]{36}"' | head -1 | cut -d'"' -f4)"
  if [[ -n "${GID}" ]]; then
    CNT="$(adm_get "groups/${GID}/members?max=2000" | grep -oE '"id":"[0-9a-f-]{36}"' | wc -l)"
    echo "  группа ${GRP}: id=${GID} count=${CNT}"
  else
    echo "  группа ${GRP}: НЕ НАЙДЕНА"
  fi
done

if [[ -n "${SAMPLE_FILE}" ]]; then
  [[ -f "${SAMPLE_FILE}" ]] || fail "файл сэмпла не найден: ${SAMPLE_FILE}"
  info "spot-check billhub_user_id по $(wc -l < "${SAMPLE_FILE}") записям из ${SAMPLE_FILE}"
  OK=0; MISS=0
  while IFS= read -r U; do
    [[ -z "${U}" ]] && continue
    UJSON="$(adm_get "users?username=${U}&exact=true")"
    if [[ "${UJSON}" == "[]" ]]; then
      UJSON="$(adm_get "users?email=${U}&exact=true")"
    fi
    if printf '%s' "${UJSON}" | grep -q '"billhub_user_id"'; then
      OK=$((OK+1))
    else
      echo "    [MISS] ${U}: billhub_user_id не найден"
      MISS=$((MISS+1))
    fi
  done < "${SAMPLE_FILE}"
  echo "  spot-check: ok=${OK} miss=${MISS}"
fi

info "готово"
