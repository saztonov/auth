#!/usr/bin/env bash
# Доказательство контракта bcrypt-провайдера на ОТДЕЛЬНОМ realm `bcrypt-poc` (НЕ su10).
# Запускать на VPS ПОСЛЕ build-jar.sh. Требует docker + доступ к /opt/infra/keycloak (.env, providers).
#
#   bash keycloak/providers/bcrypt-spi/verify-bcrypt-poc.sh
#
# Что делает:
#   A. preflight: валидирует jar `kc.sh build` в disposable-контейнере того же образа — ДО касания live KC.
#   B. кладёт jar в live providers, force-recreate ТОЛЬКО сервиса keycloak, с rollback при неудачном старте.
#   C. на realm bcrypt-poc: partialImport bcrypt-кредов (путь BillHub, ЖЁСТКИЙ критерий) + Admin-API
#      create-user (мягкая кросс-проверка), логин throwaway-паролем ($2a/$2b/$2y × cost{12,10}),
#      проверка перехэша в argon2. Затем удаляет realm.
#
# Секреты/пароли/хэши/токены НЕ печатаются. estimat/billhub на VPS не трогаются (только сервис keycloak).
set -euo pipefail
set +x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KC_DIR="${KC_DIR:-/opt/infra/keycloak}"
KC_CONTAINER="${KC_CONTAINER:-keycloak}"
EDGE_NET="${EDGE_NET:-edge}"
REALM="${REALM:-bcrypt-poc}"
CLIENT="${CLIENT:-poc-cli}"
LIVE_PROVIDERS="${KC_DIR}/keycloak/providers"
NODE_IMAGE="${NODE_IMAGE:-node:20-alpine}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:latest}"
HTPASSWD_IMAGE="${HTPASSWD_IMAGE:-httpd:2.4-alpine}"

fail() { echo "!! $*" >&2; exit 1; }
info() { echo "==> $*"; }

command -v docker >/dev/null || fail "docker не найден"
[[ -f "${KC_DIR}/.env" ]] || fail "нет ${KC_DIR}/.env"
docker ps --format '{{.Names}}' | grep -qx "${KC_CONTAINER}" || fail "контейнер '${KC_CONTAINER}' не запущен"
# jar собирается docker-maven от root; каталог /opt/infra может быть root-owned — проверим запись заранее.
[[ -w "${LIVE_PROVIDERS}" ]] || fail "нет прав на запись в ${LIVE_PROVIDERS} — запустите 'sudo bash ${BASH_SOURCE[0]}' (или выдайте права на каталог)"

# --- Версия рантайма и путь к jar ---
KC_VERSION="${KC_VERSION:-$(docker exec "${KC_CONTAINER}" /opt/keycloak/bin/kc.sh --version 2>/dev/null \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)}"
[[ -n "${KC_VERSION}" ]] || fail "не удалось определить версию Keycloak (задайте KC_VERSION=...)"
JAR="${SCRIPT_DIR}/target/keycloak-bcrypt-${KC_VERSION}.jar"
[[ -f "${JAR}" ]] || fail "нет jar ${JAR} — сначала запустите build-jar.sh"
KC_IMAGE="$(docker inspect --format '{{.Config.Image}}' "${KC_CONTAINER}")"
info "Keycloak ${KC_VERSION}, образ ${KC_IMAGE}, jar $(basename "${JAR}")"

# ============================ A. PREFLIGHT (live KC не тронут) ============================
info "[A] preflight: kc.sh build с новым jar в disposable-контейнере ${KC_IMAGE}"
STAGE="$(mktemp -d)"
cp "${JAR}" "${STAGE}/"
if ! docker run --rm -v "${STAGE}:/opt/keycloak/providers:ro" "${KC_IMAGE}" build; then
  rm -rf "${STAGE}"
  fail "preflight build упал — jar несовместим/битый. Live Keycloak НЕ тронут."
fi
rm -rf "${STAGE}"
info "[A] preflight ок — провайдер загружается без ошибок"

# ============================ B. Выкат на live KC с rollback ============================
JAR_BASENAME="$(basename "${JAR}")"

wait_ready() { # ждём health/ready через curl-контейнер в сети edge (порт 9000 наружу не публикуется)
  docker run --rm --network "${EDGE_NET}" "${CURL_IMAGE}" \
    sh -c 'for i in $(seq 1 60); do curl -sf http://'"${KC_CONTAINER}"':9000/health/ready >/dev/null 2>&1 && exit 0; sleep 3; done; exit 1'
}

info "[B] кладём jar в ${LIVE_PROVIDERS} и force-recreate сервиса keycloak"
cp "${JAR}" "${LIVE_PROVIDERS}/"
( cd "${KC_DIR}" && docker compose -p keycloak up -d --force-recreate keycloak )

if ! wait_ready; then
  echo "!! Keycloak не поднялся за таймаут — ОТКАТ (снимаем jar, пересоздаём)" >&2
  rm -f "${LIVE_PROVIDERS}/${JAR_BASENAME}"
  ( cd "${KC_DIR}" && docker compose -p keycloak up -d --force-recreate keycloak )
  if wait_ready; then echo "   откат ок: сервис восстановлен без jar" >&2; else echo "   !! КРИТИЧНО: KC не ready даже после отката — проверьте вручную" >&2; fi
  exit 1
fi
info "[B] keycloak ready с провайдером"

# --- cleanup: удалить realm bcrypt-poc и временные файлы (jar на live оставляем — см. README) ---
TMP="$(mktemp -d)"
cleanup() {
  set +e
  docker exec "${KC_CONTAINER}" /opt/keycloak/bin/kcadm.sh delete "realms/${REALM}" >/dev/null 2>&1
  docker exec "${KC_CONTAINER}" sh -c 'rm -f /tmp/poc-*.json' >/dev/null 2>&1
  rm -rf "${TMP}"
}
trap cleanup EXIT

# ============================ C. Доказательство на realm bcrypt-poc ============================
# admin-creds из .env (без эха): предпочтительно KEYCLOAK_ADMIN_*, иначе bootstrap-admin.
getenv() { grep -E "^$1=" "${KC_DIR}/.env" | tail -1 | cut -d= -f2- | sed -e 's/^["'\'']//' -e 's/["'\'']$//'; }
ADMIN_USER="$(getenv KEYCLOAK_ADMIN_USER)"; [[ -n "${ADMIN_USER}" ]] || ADMIN_USER="$(getenv KC_BOOTSTRAP_ADMIN_USERNAME)"
ADMIN_PASS="$(getenv KEYCLOAK_ADMIN_PASSWORD)"; [[ -n "${ADMIN_PASS}" ]] || ADMIN_PASS="$(getenv KC_BOOTSTRAP_ADMIN_PASSWORD)"
[[ -n "${ADMIN_USER}" && -n "${ADMIN_PASS}" ]] || fail "нет admin-creds в ${KC_DIR}/.env"
export ADMIN_USER ADMIN_PASS

info "[C] kcadm login (master)"
docker exec -e AU="${ADMIN_USER}" -e AP="${ADMIN_PASS}" "${KC_CONTAINER}" \
  sh -c '/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user "$AU" --password "$AP"' \
  >/dev/null || fail "kcadm login не прошёл (проверьте admin-creds в .env)"
kc() { docker exec "${KC_CONTAINER}" /opt/keycloak/bin/kcadm.sh "$@"; }

info "[C] пересоздаём realm ${REALM} (policy без hashAlgorithm → дефолт argon2, как в su10)"
kc delete "realms/${REALM}" >/dev/null 2>&1 || true
kc create realms -s "realm=${REALM}" -s enabled=true >/dev/null
kc create clients -r "${REALM}" -s "clientId=${CLIENT}" -s publicClient=true \
  -s directAccessGrantsEnabled=true -s 'redirectUris=["*"]' >/dev/null

# throwaway-пароль (в терминал/логи не выводим).
PW="poc-$(head -c18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c16)-Aa1"
export PW
info "[C] генерим bcrypt-хэши (cost 12 и 10) через htpasswd (оффлайн) + import-JSON (node, без сети)"
# htpasswd (образ httpd) даёт стандартный bcrypt $2y — сеть в рантайме НЕ нужна (в отличие от npm i bcryptjs).
# Варианты $2a/$2b деривим ниже; для проверки verify источник хэша роли не играет (bcrypt = bcrypt).
gen_bcrypt() { # $1=cost → печатает bcrypt-хэш throwaway-пароля (пароль через stdin, не в argv)
  printf '%s' "${PW}" | docker run --rm -i "${HTPASSWD_IMAGE}" \
    /usr/local/apache2/bin/htpasswd -niB -C "$1" u | sed 's/^[^:]*://'
}
H12="$(gen_bcrypt 12)"; H10="$(gen_bcrypt 10)"
export H12 H10
[[ "${H12}" == \$2* && "${H10}" == \$2* ]] || fail "htpasswd не выдал bcrypt-хэши (H12='${H12:0:4}…', H10='${H10:0:4}…')"
# node — только сборка import-JSON (оффлайн, без npm): JSON.stringify корректно экранирует secretData/credentialData.
docker run --rm -e H12 -e H10 -v "${TMP}:/out" "${NODE_IMAGE}" node -e '
  const fs=require("fs");
  const bases={12:process.env.H12,10:process.env.H10}, users=[];
  for (const cost of [12,10]) {
    const body=bases[cost].slice(3); // "$NN$<salt+digest>" — одинаков для $2a/$2b/$2y
    for (const v of ["a","b","y"]) {
      const h="$2"+v+body;
      users.push({username:"poc-2"+v+"-c"+cost, enabled:true,
        email:"poc-2"+v+"-c"+cost+"@example.invalid", emailVerified:true,
        credentials:[{type:"password", algorithm:"bcrypt",
          secretData:JSON.stringify({value:h}),
          credentialData:JSON.stringify({hashIterations:cost, algorithm:"bcrypt"})}]});
    }
  }
  fs.writeFileSync("/out/poc-partial.json", JSON.stringify({ifResourceExists:"OVERWRITE", users}));
  // кросс-проверка второго пути импорта: тот же credential для Admin API create-user ($2b, cost 12)
  const cu=JSON.parse(JSON.stringify(users.find(u=>u.username==="poc-2b-c12")));
  cu.username="poc-createuser"; cu.email="poc-createuser@example.invalid";
  fs.writeFileSync("/out/poc-createuser.json", JSON.stringify(cu));
' || fail "не удалось собрать import-JSON (node)"

# --- ЖЁСТКИЙ путь: realm partialImport (то, что использует payload-builder BillHub) ---
info "[C] partialImport (путь BillHub) — через Admin REST с bearer-токеном"
get_admin_token() {
  docker run --rm --network "${EDGE_NET}" -e ADMIN_USER -e ADMIN_PASS "${CURL_IMAGE}" sh -c \
    'curl -s -d grant_type=password -d client_id=admin-cli -d "username=$ADMIN_USER" -d "password=$ADMIN_PASS" \
     http://'"${KC_CONTAINER}"':8080/realms/master/protocol/openid-connect/token' \
  | grep -oE '"access_token":"[^"]+"' | cut -d'"' -f4
}
ATOKEN="$(get_admin_token)"; [[ -n "${ATOKEN}" ]] || fail "не получил admin-токен для partialImport"
export ATOKEN
# JSON шлём в stdin (--data-binary @-): curl-контейнер бежит под uid 100 и не может зайти в TMP (mode 700),
# поэтому монтировать каталог нельзя — файл читает хост-shell (у corpsu права есть) и пайпит в stdin.
PI_CODE="$(docker run --rm -i --network "${EDGE_NET}" -e ATOKEN "${CURL_IMAGE}" sh -c \
  'curl -s -o /dev/null -w "%{http_code}" -X POST \
   -H "Authorization: Bearer $ATOKEN" -H "Content-Type: application/json" \
   --data-binary @- \
   http://'"${KC_CONTAINER}"':8080/admin/realms/'"${REALM}"'/partialImport' \
  < "${TMP}/poc-partial.json")"
[[ "${PI_CODE}" == "200" ]] || fail "partialImport вернул HTTP ${PI_CODE} (ожидался 200)"
info "[C] partialImport ок (HTTP 200)"

# --- МЯГКИЙ путь: Admin API create-user (может отличаться в обработке hashed-cred; не жёсткий критерий) ---
CREATEUSER_OK=1
info "[C] create-user (Admin API) — кросс-проверка, мягкая"
docker cp "${TMP}/poc-createuser.json" "${KC_CONTAINER}:/tmp/poc-createuser.json" >/dev/null 2>&1
if ! kc create users -r "${REALM}" -f /tmp/poc-createuser.json >/dev/null 2>&1; then
  echo "    [warn] create-user не принял payload (это ок: канонический путь — partialImport)"; CREATEUSER_OK=0
fi

# --- Логин throwaway-паролем + проверка перехэша ---
uid_of() { kc get users -r "${REALM}" -q "username=$1" 2>/dev/null \
  | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1; }

login_ok() { # $1=username → 0, если вернулся access_token (verify сработал). Токен не печатаем.
  local u="$1" resp
  resp="$(docker run --rm --network "${EDGE_NET}" -e PW -e U="${u}" "${CURL_IMAGE}" sh -c \
    'curl -s -d grant_type=password -d client_id='"${CLIENT}"' -d "username=$U" -d "password=$PW" \
     http://'"${KC_CONTAINER}"':8080/realms/'"${REALM}"'/protocol/openid-connect/token')"
  printf '%s' "${resp}" | grep -q '"access_token"'
}

rehashed_algo() { # $1=username → печатает алгоритм credential после входа (argon2/pbkdf2*/bcrypt), пусто если не найден
  local u="$1" id creds
  id="$(uid_of "${u}")"; [[ -n "${id}" ]] || return 2
  creds="$(kc get "users/${id}/credentials" -r "${REALM}" 2>/dev/null)"
  # credentialData приходит JSON-строкой (…\"algorithm\":\"argon2\"…) — берём первый известный токен алгоритма.
  printf '%s' "${creds}" | grep -oE '(argon2|pbkdf2[a-z0-9-]*|bcrypt)' | head -1
}

PARTIAL_USERS="poc-2a-c12 poc-2b-c12 poc-2y-c12 poc-2a-c10 poc-2b-c10 poc-2y-c10"
info "[C] логин каждым вариантом ($2a/$2b/$2y × cost{12,10}) и проверка перехэша"
LOGIN_FAILS=0; REHASH_FAILS=0
for u in ${PARTIAL_USERS}; do
  if login_ok "${u}"; then
    algo="$(rehashed_algo "${u}")"
    if [[ -n "${algo}" && "${algo}" != "bcrypt" ]]; then
      echo "    [ok]   ${u}: вход успешен, перехэш → ${algo}"
    else
      echo "    [FAIL] ${u}: вход успешен, но перехэш не подтверждён (алгоритм='${algo:-?}')"; REHASH_FAILS=$((REHASH_FAILS+1))
    fi
  else
    echo "    [FAIL] ${u}: вход НЕ прошёл (verify не сработал)"; LOGIN_FAILS=$((LOGIN_FAILS+1))
  fi
done

# create-user — только информационно
if [[ ${CREATEUSER_OK} -eq 1 ]]; then
  if login_ok poc-createuser; then
    cu_algo="$(rehashed_algo poc-createuser)"
    if [[ -n "${cu_algo}" && "${cu_algo}" != "bcrypt" ]]; then
      echo "    [ok]   poc-createuser (Admin API create-user): вход + перехэш → ${cu_algo}"
    else
      echo "    [warn] poc-createuser: вход ок, но перехэш не подтверждён (алгоритм='${cu_algo:-?}')"
    fi
  else
    echo "    [warn] poc-createuser: create-user путь не подтвердил вход (не критично — путь BillHub = partialImport)"
  fi
fi

echo
if [[ ${LOGIN_FAILS} -eq 0 && ${REHASH_FAILS} -eq 0 ]]; then
  info "РЕЗУЛЬТАТ: контракт доказан — partialImport + bcrypt verify работают для всех вариантов, перехэш в argon2 подтверждён."
  info "realm ${REALM} будет удалён (cleanup). jar остаётся в ${LIVE_PROVIDERS} (инертен; удаление — см. README)."
  exit 0
else
  fail "РЕЗУЛЬТАТ: провалов входа=${LOGIN_FAILS}, провалов перехэша=${REHASH_FAILS}. Контракт НЕ доказан."
fi
