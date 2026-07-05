#!/usr/bin/env bash
# Применяет declarative user-profile к realm (по умолчанию su10) ПРЯМЫМ Admin API PUT /users/profile.
# Зачем отдельно: keycloak-config-cli 6.x секцию `userProfile` НЕ применяет (adorsys #979) — оставляет
# профиль дефолтным. Поэтому маппер идёт через realm-as-code (config-cli), а профиль — этим скриптом,
# ПОСЛЕ наката realm. Идемпотентно. Меняет user-profile ЖИВОГО realm — показывает текущий профиль до PUT.
#
#   bash keycloak/realm/apply-userprofile.sh              # su10 + su10-userprofile.json
#   REALM=up-poc PROFILE_JSON=/path.json bash …           # переопределить
#
# Доказано на тест-realm up-poc (keycloak/realm/verify-userprofile-poc.sh, 2026-07-05).
set -euo pipefail
set +x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KC_DIR="${KC_DIR:-/opt/infra/keycloak}"
KC_CONTAINER="${KC_CONTAINER:-keycloak}"
EDGE_NET="${EDGE_NET:-edge}"
REALM="${REALM:-su10}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:latest}"
PROFILE_JSON="${PROFILE_JSON:-${SCRIPT_DIR}/su10-userprofile.json}"

fail() { echo "!! $*" >&2; exit 1; }
info() { echo "==> $*"; }

command -v docker >/dev/null || fail "docker не найден"
[[ -f "${KC_DIR}/.env" ]] || fail "нет ${KC_DIR}/.env"
[[ -f "${PROFILE_JSON}" ]] || fail "нет файла профиля ${PROFILE_JSON}"
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

api_get() { docker run --rm --network "${EDGE_NET}" -e ATOKEN "${CURL_IMAGE}" sh -c \
  'curl -s -H "Authorization: Bearer $ATOKEN" http://'"${KC_CONTAINER}"':8080/admin/realms/'"$1"; }

info "ТЕКУЩИЙ user-profile realm ${REALM} (до изменения):"
api_get "${REALM}/users/profile" | tr -d ' \n' \
  | grep -oE '"unmanagedAttributePolicy":"[^"]*"|"name":"[^"]*"' | tr '\n' ' '; echo

info "применяю ${PROFILE_JSON} → PUT /admin/realms/${REALM}/users/profile"
CODE="$(docker run --rm -i --network "${EDGE_NET}" -e ATOKEN "${CURL_IMAGE}" sh -c \
  'curl -s -o /dev/null -w "%{http_code}" -X PUT \
   -H "Authorization: Bearer $ATOKEN" -H "Content-Type: application/json" --data-binary @- \
   http://'"${KC_CONTAINER}"':8080/admin/realms/'"${REALM}"'/users/profile' \
  < "${PROFILE_JSON}")"
[[ "${CODE}" == "200" || "${CODE}" == "204" ]] || fail "PUT вернул HTTP ${CODE} (проверьте формат профиля/права manage-realm)"

NEW="$(api_get "${REALM}/users/profile" | tr -d ' \n')"
printf '%s' "${NEW}" | grep -q '"unmanagedAttributePolicy":"ADMIN_EDIT"' || fail "после PUT нет ADMIN_EDIT"
printf '%s' "${NEW}" | grep -q '"name":"billhub_user_id"' || fail "после PUT нет атрибута billhub_user_id"
info "[ok] user-profile применён к ${REALM}. Атрибуты: $(printf '%s' "${NEW}" | grep -oE '"name":"[^"]*"' | tr '\n' ' ')"
info "    unmanagedAttributePolicy: $(printf '%s' "${NEW}" | grep -oE '"unmanagedAttributePolicy":"[^"]*"')"
