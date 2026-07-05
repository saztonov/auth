#!/usr/bin/env bash
# Проверка realm-as-code изменения: секция `userProfile` (unmanagedAttributePolicy) + маппер
# `billhub_user_id` — на ОТДЕЛЬНОМ realm `up-poc` (su10 НЕ трогаем). Запускать на VPS.
#
#   bash keycloak/realm/verify-userprofile-poc.sh
#
# Что доказывает:
#   1. config-cli понимает ключ `userProfile` (версионный риск) и применяет realm без ошибок;
#   2. сервис-аккаунт (без firstName/lastName) НЕ ломается required-именами (как service-account-billhub);
#   3. атрибут `billhub_user_id`, выставленный через Admin API, СОХРАНЯЕТСЯ (не отбрасывается как unmanaged);
#   4. маппер пробрасывает `billhub_user_id` в access-token (claim присутствует и равен заданному).
#
# Секреты/пароли/токены НЕ печатаются. su10/estimat/billhub не затрагиваются (отдельный realm up-poc, удаляется).
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

fail() { echo "!! $*" >&2; exit 1; }
info() { echo "==> $*"; }

command -v docker >/dev/null || fail "docker не найден"
[[ -f "${KC_DIR}/.env" ]] || fail "нет ${KC_DIR}/.env"
docker ps --format '{{.Names}}' | grep -qx "${KC_CONTAINER}" || fail "контейнер '${KC_CONTAINER}' не запущен"

# admin-creds из .env (без эха): предпочтительно KEYCLOAK_ADMIN_*, иначе bootstrap-admin.
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

TMP="$(mktemp -d)"; chmod 755 "${TMP}"   # config-cli-контейнер (иной uid) читает /config; секретов в файле нет
cleanup() {
  set +e
  kc delete "realms/${REALM}" >/dev/null 2>&1
  docker exec "${KC_CONTAINER}" sh -c 'rm -f /tmp/up-*.json' >/dev/null 2>&1
  rm -rf "${TMP}"
}
trap cleanup EXIT
kc delete "realms/${REALM}" >/dev/null 2>&1 || true   # чистый старт

# --- realm-файл для config-cli: userProfile идентичен su10-realm.yaml + клиент с маппером + сервис-аккаунт ---
cat > "${TMP}/up-poc.yaml" <<'YAML'
realm: up-poc
enabled: true
userProfile:
  attributes:
    - name: username
      displayName: "${username}"
      validations:
        length: { min: 3, max: 255 }
        username-prohibited-characters: {}
        up-username-not-idn-homograph: {}
      permissions:
        view: ["admin", "user"]
        edit: ["admin", "user"]
      multivalued: false
    - name: email
      displayName: "${email}"
      validations:
        email: {}
        length: { max: 255 }
      required:
        roles: ["user"]
      permissions:
        view: ["admin", "user"]
        edit: ["admin", "user"]
      multivalued: false
    - name: firstName
      displayName: "${firstName}"
      validations:
        length: { max: 255 }
        person-name-prohibited-characters: {}
      required:
        roles: ["user"]
      permissions:
        view: ["admin", "user"]
        edit: ["admin", "user"]
      multivalued: false
    - name: lastName
      displayName: "${lastName}"
      validations:
        length: { max: 255 }
        person-name-prohibited-characters: {}
      required:
        roles: ["user"]
      permissions:
        view: ["admin", "user"]
        edit: ["admin", "user"]
      multivalued: false
  groups:
    - name: user-metadata
      displayHeader: "User metadata"
      displayDescription: "Attributes, which refer to user metadata"
  unmanagedAttributePolicy: ADMIN_EDIT
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
  # confidential-клиент с сервис-аккаунтом БЕЗ firstName/lastName — контроль, что required-имена его не блокируют
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

info "config-cli применяет realm ${REALM} (проверка: понимает ли userProfile + не блокирует ли сервис-аккаунт)"
export KEYCLOAK_USER="${ADMIN_USER}" KEYCLOAK_PASSWORD="${ADMIN_PASS}"
docker run --rm --network "${EDGE_NET}" \
  -e KEYCLOAK_URL="http://${KC_CONTAINER}:8080" \
  -e KEYCLOAK_USER -e KEYCLOAK_PASSWORD \
  -e KEYCLOAK_AVAILABILITYCHECK_ENABLED=true \
  -e KEYCLOAK_AVAILABILITYCHECK_TIMEOUT=60s \
  -e IMPORT_VARSUBSTITUTION_ENABLED=false \
  -e IMPORT_MANAGED_USER=no-delete \
  -e IMPORT_FILES_LOCATIONS=/config/up-poc.yaml \
  -v "${TMP}:/config:ro" \
  "${CONFIG_CLI_IMAGE}" \
  || fail "config-cli упал — вероятно версия не понимает ключ userProfile, ЛИБО сервис-аккаунт заблокирован required-именами (см. вывод выше)"
info "[ok] config-cli применил userProfile и создал сервис-аккаунт без ошибок"

# --- проверка политики (информационно) ---
info "userProfile realm ${REALM}:"
kc get "users/profile" -r "${REALM}" 2>/dev/null | tr -d ' \n' | grep -o '"unmanagedAttributePolicy":"[^"]*"' || echo "  (не удалось прочитать профиль)"

# --- проверка: атрибут billhub_user_id СОХРАНЯЕТСЯ (не отбрасывается) ---
PW="up-$(head -c18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c16)-Aa1"
TEST_UID="$(cat /proc/sys/kernel/random/uuid)"
export PW
cat > "${TMP}/up-user.json" <<JSON
{"username":"up-user","enabled":true,"firstName":"Up","lastName":"User","email":"up-user@example.invalid","emailVerified":true,
 "attributes":{"billhub_user_id":["${TEST_UID}"]},
 "credentials":[{"type":"password","value":"${PW}","temporary":false}]}
JSON
docker cp "${TMP}/up-user.json" "${KC_CONTAINER}:/tmp/up-user.json" >/dev/null
kc create users -r "${REALM}" -f /tmp/up-user.json >/dev/null || fail "не удалось создать up-user (профиль/валидация?)"
UID_KC="$(kc get users -r "${REALM}" -q username=up-user 2>/dev/null \
  | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
[[ -n "${UID_KC}" ]] || fail "up-user не найден после создания"
USER_JSON="$(kc get "users/${UID_KC}" -r "${REALM}" 2>/dev/null)"
if printf '%s' "${USER_JSON}" | grep -q "${TEST_UID}"; then
  info "[ok] атрибут billhub_user_id СОХРАНЁН в учётке (unmanagedAttributePolicy работает)"
else
  fail "[FAIL] атрибут billhub_user_id ОТБРОШЕН — unmanagedAttributePolicy не сработала (без неё резолв-по-claim невозможен)"
fi

# --- проверка: claim billhub_user_id в access-token (маппер работает) ---
RESP="$(docker run --rm --network "${EDGE_NET}" -e PW -e U=up-user "${CURL_IMAGE}" sh -c \
  'curl -s -d grant_type=password -d client_id='"${CLIENT}"' -d "username=$U" -d "password=$PW" \
   http://'"${KC_CONTAINER}"':8080/realms/'"${REALM}"'/protocol/openid-connect/token')"
TOKEN="$(printf '%s' "${RESP}" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)"
[[ -n "${TOKEN}" ]] || fail "[FAIL] direct grant не вернул токен (вход не прошёл — см. up-cli/профиль)"
# декод payload в node-контейнере (Buffer base64url надёжнее bash); токен идёт в stdin, печатаем только claim
CLAIM="$(printf '%s' "${TOKEN}" | docker run --rm -i "${NODE_IMAGE}" node -e \
  'let t="";process.stdin.on("data",d=>t+=d).on("end",()=>{try{const p=JSON.parse(Buffer.from(t.trim().split(".")[1],"base64url").toString());process.stdout.write(String(p.billhub_user_id||""))}catch(e){}})')"
if [[ "${CLAIM}" == "${TEST_UID}" ]]; then
  info "[ok] claim billhub_user_id в access-token присутствует и равен заданному (${CLAIM})"
else
  fail "[FAIL] claim billhub_user_id в токене отсутствует/не совпал (маппер не сработал). Получено: '${CLAIM:-<пусто>}'"
fi

# --- проверка: сервис-аккаунт (без имён) существует ---
if kc get users -r "${REALM}" -q username=service-account-up-svc 2>/dev/null | grep -q service-account-up-svc; then
  info "[ok] сервис-аккаунт (без firstName/lastName) на месте — required-имена его не блокируют"
else
  echo "    [warn] сервис-аккаунт service-account-up-svc не найден — сверьте вывод config-cli"
fi

echo
info "РЕЗУЛЬТАТ: realm-изменение доказано — config-cli применил userProfile, атрибут billhub_user_id сохраняется,"
info "          claim в access-token присутствует, сервис-аккаунт цел. realm ${REALM} удаляется (cleanup)."
