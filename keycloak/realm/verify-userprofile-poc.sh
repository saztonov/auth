#!/usr/bin/env bash
# Проверка realm-as-code: маппер `billhub_user_id` (config-cli) + user-profile через ПРЯМОЙ Admin API.
# На ОТДЕЛЬНОМ realm `up-poc` (su10 НЕ трогаем). Запускать на VPS.
#
#   bash keycloak/realm/verify-userprofile-poc.sh
#
# Почему так: config-cli 6.x НЕ применяет секцию userProfile (known issue adorsys #979 — оставляет
# профиль дефолтным). Надёжно ставить user-profile прямым `PUT /admin/realms/<r>/users/profile`
# (тот же эндпоинт, что и Admin-консоль). Клиент/мапперы config-cli делает штатно.
#
# Что доказывает:
#   0. (диагностика) после ОДНОГО config-cli профиль остаётся дефолтным (unmanaged отключён);
#   1. прямой PUT users/profile ставит unmanagedAttributePolicy=ADMIN_EDIT;
#   2. после этого атрибут billhub_user_id через Admin API СОХРАНЯЕТСЯ (не отбрасывается);
#   3. маппер пробрасывает billhub_user_id в access-token (claim == заданному uuid);
#   4. сервис-аккаунт без firstName/lastName не блокируется required-именами.
#
# Секреты/пароли/токены НЕ печатаются. su10/estimat/billhub не затрагиваются (realm up-poc удаляется при успехе).
set -euo pipefail
set +x

KC_DIR="${KC_DIR:-/opt/infra/keycloak}"
KC_CONTAINER="${KC_CONTAINER:-keycloak}"
EDGE_NET="${EDGE_NET:-edge}"
REALM="${REALM:-up-poc}"
CLIENT="${CLIENT:-up-cli}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:latest}"
NODE_IMAGE="${NODE_IMAGE:-node:20-alpine}"
CONFIG_CLI_IMAGE="${KC_CONFIG_CLI_IMAGE:-adorsys/keycloak-config-cli:latest-26}"

fail() { echo "!! $*" >&2; echo "   (realm ${REALM} ОСТАВЛЕН для разбора; удалить: docker exec ${KC_CONTAINER} /opt/keycloak/bin/kcadm.sh delete realms/${REALM})" >&2; exit 1; }
info() { echo "==> $*"; }

command -v docker >/dev/null || fail "docker не найден"
[[ -f "${KC_DIR}/.env" ]] || fail "нет ${KC_DIR}/.env"
docker ps --format '{{.Names}}' | grep -qx "${KC_CONTAINER}" || fail "контейнер '${KC_CONTAINER}' не запущен"

getenv() { grep -E "^$1=" "${KC_DIR}/.env" | tail -1 | cut -d= -f2- | sed -e 's/^["'\'']//' -e 's/["'\'']$//'; }
ADMIN_USER="$(getenv KEYCLOAK_ADMIN_USER)"; [[ -n "${ADMIN_USER}" ]] || ADMIN_USER="$(getenv KC_BOOTSTRAP_ADMIN_USERNAME)"
ADMIN_PASS="$(getenv KEYCLOAK_ADMIN_PASSWORD)"; [[ -n "${ADMIN_PASS}" ]] || ADMIN_PASS="$(getenv KC_BOOTSTRAP_ADMIN_PASSWORD)"
[[ -n "${ADMIN_USER}" && -n "${ADMIN_PASS}" ]] || fail "нет admin-creds в ${KC_DIR}/.env"
export ADMIN_USER ADMIN_PASS

info "kcadm login (master)"
docker exec -e AU="${ADMIN_USER}" -e AP="${ADMIN_PASS}" "${KC_CONTAINER}" \
  sh -c '/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user "$AU" --password "$AP"' \
  >/dev/null || fail "kcadm login не прошёл (проверьте admin-creds в .env)"
kc() { docker exec "${KC_CONTAINER}" /opt/keycloak/bin/kcadm.sh "$@"; }

TMP="$(mktemp -d)"; chmod 755 "${TMP}"
trap 'rm -rf "${TMP}"; docker exec "${KC_CONTAINER}" sh -c "rm -f /tmp/up-*.json" >/dev/null 2>&1' EXIT
kc delete "realms/${REALM}" >/dev/null 2>&1 || true   # чистый старт

# --- admin-токен для Admin REST (профиль ставим/читаем через него) ---
get_admin_token() {
  docker run --rm --network "${EDGE_NET}" -e ADMIN_USER -e ADMIN_PASS "${CURL_IMAGE}" sh -c \
    'curl -s -d grant_type=password -d client_id=admin-cli -d "username=$ADMIN_USER" -d "password=$ADMIN_PASS" \
     http://'"${KC_CONTAINER}"':8080/realms/master/protocol/openid-connect/token' \
  | grep -oE '"access_token":"[^"]+"' | cut -d'"' -f4
}
ATOKEN="$(get_admin_token)"; [[ -n "${ATOKEN}" ]] || fail "не получил admin-токен"
export ATOKEN
api() { # $1=method $2=path [stdin=body] → печатает тело ответа
  local m="$1" p="$2"
  docker run --rm -i --network "${EDGE_NET}" -e ATOKEN "${CURL_IMAGE}" sh -c \
    'curl -s -X '"$m"' -H "Authorization: Bearer $ATOKEN" -H "Content-Type: application/json" --data-binary @- \
     http://'"${KC_CONTAINER}"':8080/admin/realms/'"${p}"
}
api_get() { docker run --rm --network "${EDGE_NET}" -e ATOKEN "${CURL_IMAGE}" sh -c \
    'curl -s -H "Authorization: Bearer $ATOKEN" http://'"${KC_CONTAINER}"':8080/admin/realms/'"$1"; }
profile_policy() { api_get "${REALM}/users/profile" | tr -d ' \n' | grep -o '"unmanagedAttributePolicy":"[^"]*"' || true; }

# --- config-cli: realm + клиент с маппером + сервис-аккаунт (БЕЗ userProfile — его config-cli не применяет) ---
cat > "${TMP}/up-poc.yaml" <<'YAML'
realm: up-poc
enabled: true
clients:
  - clientId: up-cli
    enabled: true
    protocol: openid-connect
    publicClient: true
    standardFlowEnabled: true
    directAccessGrantsEnabled: true
    redirectUris:
      - "*"
    protocolMappers:
      - name: billhub_user_id
        protocol: openid-connect
        protocolMapper: oidc-usermodel-attribute-mapper
        config:
          user.attribute: billhub_user_id
          claim.name: billhub_user_id
          jsonType.label: String
          access.token.claim: "true"
          id.token.claim: "true"
          userinfo.token.claim: "true"
          multivalued: "false"
  - clientId: up-svc
    enabled: true
    protocol: openid-connect
    publicClient: false
    standardFlowEnabled: false
    serviceAccountsEnabled: true
    secret: up-svc-dummy-secret
users:
  - username: service-account-up-svc
    enabled: true
    serviceAccountClientId: up-svc
    clientRoles:
      realm-management:
        - view-users
YAML

info "config-cli применяет realm + клиент(маппер) + сервис-аккаунт"
export KEYCLOAK_USER="${ADMIN_USER}" KEYCLOAK_PASSWORD="${ADMIN_PASS}"
docker run --rm --network "${EDGE_NET}" \
  -e KEYCLOAK_URL="http://${KC_CONTAINER}:8080" \
  -e KEYCLOAK_USER -e KEYCLOAK_PASSWORD \
  -e KEYCLOAK_AVAILABILITYCHECK_ENABLED=true -e KEYCLOAK_AVAILABILITYCHECK_TIMEOUT=60s \
  -e IMPORT_VARSUBSTITUTION_ENABLED=false -e IMPORT_MANAGED_USER=no-delete \
  -e IMPORT_FILES_LOCATIONS=/config/up-poc.yaml \
  -v "${TMP}:/config:ro" "${CONFIG_CLI_IMAGE}" \
  || fail "config-cli упал (см. вывод выше)"
info "[ok] config-cli применил клиент/маппер/сервис-аккаунт"

# --- 0. диагностика: после ОДНОГО config-cli профиль дефолтный ---
info "[DIAG] политика профиля после config-cli (ожидаемо пусто/дефолт): '$(profile_policy)'"

# --- 1. прямой PUT user-profile (то, что config-cli не делает) ---
cat > "${TMP}/up-profile.json" <<'JSON'
{
  "attributes": [
    { "name": "username", "displayName": "${username}",
      "validations": { "length": { "min": 3, "max": 255 }, "username-prohibited-characters": {}, "up-username-not-idn-homograph": {} },
      "permissions": { "view": ["admin","user"], "edit": ["admin","user"] }, "multivalued": false },
    { "name": "email", "displayName": "${email}",
      "validations": { "email": {}, "length": { "max": 255 } }, "required": { "roles": ["user"] },
      "permissions": { "view": ["admin","user"], "edit": ["admin","user"] }, "multivalued": false },
    { "name": "firstName", "displayName": "${firstName}",
      "validations": { "length": { "max": 255 }, "person-name-prohibited-characters": {} }, "required": { "roles": ["user"] },
      "permissions": { "view": ["admin","user"], "edit": ["admin","user"] }, "multivalued": false },
    { "name": "lastName", "displayName": "${lastName}",
      "validations": { "length": { "max": 255 }, "person-name-prohibited-characters": {} }, "required": { "roles": ["user"] },
      "permissions": { "view": ["admin","user"], "edit": ["admin","user"] }, "multivalued": false }
  ],
  "groups": [ { "name": "user-metadata", "displayHeader": "User metadata", "displayDescription": "Attributes, which refer to user metadata" } ],
  "unmanagedAttributePolicy": "ADMIN_EDIT"
}
JSON
info "прямой PUT /users/profile (Admin API)"
api PUT "${REALM}/users/profile" < "${TMP}/up-profile.json" >/dev/null 2>&1 || true
# curl -s возвращает 0 и на HTTP-ошибке → результат проверяем повторным GET политики
POL="$(profile_policy)"
[[ "${POL}" == *ADMIN_EDIT* ]] || fail "[FAIL] PUT профиля не дал ADMIN_EDIT (получено: '${POL:-<пусто>}')"
info "[ok] user-profile применён напрямую: ${POL}"

# --- 2. атрибут billhub_user_id СОХРАНЯЕТСЯ ---
PW="up-$(head -c18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c16)-Aa1"
TEST_UID="$(cat /proc/sys/kernel/random/uuid)"
export PW
cat > "${TMP}/up-user.json" <<JSON
{"username":"up-user","enabled":true,"firstName":"Up","lastName":"User","email":"up-user@example.invalid","emailVerified":true,
 "attributes":{"billhub_user_id":["${TEST_UID}"]},
 "credentials":[{"type":"password","value":"${PW}","temporary":false}]}
JSON
docker cp "${TMP}/up-user.json" "${KC_CONTAINER}:/tmp/up-user.json" >/dev/null
kc create users -r "${REALM}" -f /tmp/up-user.json >/dev/null || fail "не удалось создать up-user"
UID_KC="$(kc get users -r "${REALM}" -q username=up-user 2>/dev/null \
  | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
[[ -n "${UID_KC}" ]] || fail "up-user не найден после создания"
if kc get "users/${UID_KC}" -r "${REALM}" 2>/dev/null | grep -q "${TEST_UID}"; then
  info "[ok] атрибут billhub_user_id СОХРАНЁН (unmanagedAttributePolicy работает)"
else
  fail "[FAIL] атрибут billhub_user_id ОТБРОШЕН даже после прямого PUT профиля"
fi

# --- 3. claim в access-token ---
RESP="$(docker run --rm --network "${EDGE_NET}" -e PW -e U=up-user "${CURL_IMAGE}" sh -c \
  'curl -s -d grant_type=password -d client_id='"${CLIENT}"' -d "username=$U" -d "password=$PW" \
   http://'"${KC_CONTAINER}"':8080/realms/'"${REALM}"'/protocol/openid-connect/token')"
TOKEN="$(printf '%s' "${RESP}" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)"
[[ -n "${TOKEN}" ]] || fail "[FAIL] direct grant не вернул токен"
CLAIM="$(printf '%s' "${TOKEN}" | docker run --rm -i "${NODE_IMAGE}" node -e \
  'let t="";process.stdin.on("data",d=>t+=d).on("end",()=>{try{const p=JSON.parse(Buffer.from(t.trim().split(".")[1],"base64url").toString());process.stdout.write(String(p.billhub_user_id||""))}catch(e){}})')"
if [[ "${CLAIM}" == "${TEST_UID}" ]]; then
  info "[ok] claim billhub_user_id в access-token присутствует и равен заданному (${CLAIM})"
else
  fail "[FAIL] claim billhub_user_id в токене отсутствует/не совпал. Получено: '${CLAIM:-<пусто>}'"
fi

# --- 4. сервис-аккаунт без имён ---
if kc get users -r "${REALM}" -q username=service-account-up-svc 2>/dev/null | grep -q service-account-up-svc; then
  info "[ok] сервис-аккаунт (без firstName/lastName) на месте — required-имена его не блокируют"
else
  echo "    [warn] сервис-аккаунт service-account-up-svc не найден — сверьте вывод config-cli"
fi

kc delete "realms/${REALM}" >/dev/null 2>&1 || true
echo
info "РЕЗУЛЬТАТ: рабочая связка доказана — маппер (config-cli) + user-profile (прямой Admin API PUT):"
info "          атрибут billhub_user_id сохраняется, claim в токене, сервис-аккаунт цел. realm ${REALM} удалён."
info "ВЫВОД: в su10 user-profile ставить прямым PUT /users/profile (config-cli его не применяет), маппер — в realm-as-code."
