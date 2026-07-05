#!/usr/bin/env bash
# Проверка: перехэшировался ли пароль перечисленных пользователей su10 в argon2. Штатное поведение
# Keycloak при первом успешном входе (наш bcrypt-провайдер верифицирует импортированный хэш → KC сам
# перехэширует в дефолтный алгоритм realm-policy). algorithm=argon2 — прямое доказательство, что
# bcrypt-verify реально отработал на БОЕВОМ импортированном credential (не только на bcrypt-poc).
# Read-only, live-данные не трогает.
#
#   bash keycloak/realm/verify-rehash.sh sample.txt   # username/email по строке
set -euo pipefail
set +x

KC_DIR="${KC_DIR:-/opt/infra/keycloak}"
KC_CONTAINER="${KC_CONTAINER:-keycloak}"
EDGE_NET="${EDGE_NET:-edge}"
REALM="${REALM:-su10}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:latest}"
LIST_FILE="${1:-}"

fail() { echo "!! $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ -n "${LIST_FILE}" && -f "${LIST_FILE}" ]] || { echo "Usage: $0 <файл со списком username/email, по одному на строку>" >&2; exit 1; }
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

info "realm ${REALM} — алгоритм credential по $(wc -l < "${LIST_FILE}") записям из ${LIST_FILE}"
ARGON2=0; BCRYPT=0; OTHER=0
while IFS= read -r U; do
  [[ -z "${U}" ]] && continue
  UJSON="$(adm_get "users?username=${U}&exact=true")"
  if [[ "${UJSON}" == "[]" ]]; then
    UJSON="$(adm_get "users?email=${U}&exact=true")"
  fi
  UID_KC="$(printf '%s' "${UJSON}" | grep -oE '"id":"[0-9a-f-]{36}"' | head -1 | cut -d'"' -f4)"
  if [[ -z "${UID_KC}" ]]; then
    echo "  ${U}: пользователь не найден в KC"
    OTHER=$((OTHER+1)); continue
  fi
  CREDS="$(adm_get "users/${UID_KC}/credentials")"
  ALG="$(printf '%s' "${CREDS}" | grep -oE 'algorithm\\?"[[:space:]]*:[[:space:]]*\\?"[a-zA-Z0-9]+' | grep -oE '[a-zA-Z0-9]+$' | head -1)"
  case "${ALG}" in
    argon2) echo "  [ok]      ${U}: algorithm=argon2 (перехэш подтверждён — вход был успешен)"; ARGON2=$((ARGON2+1)) ;;
    bcrypt) echo "  [не был]  ${U}: algorithm=bcrypt (входа ещё не было, либо не прошёл)"; BCRYPT=$((BCRYPT+1)) ;;
    "")     echo "  [?]       ${U}: password-credential не найден"; OTHER=$((OTHER+1)) ;;
    *)      echo "  [?]       ${U}: algorithm=${ALG}"; OTHER=$((OTHER+1)) ;;
  esac
done < "${LIST_FILE}"

info "итог: argon2(перехэшировано)=${ARGON2} bcrypt(не входил/не прошёл)=${BCRYPT} прочее=${OTHER}"
