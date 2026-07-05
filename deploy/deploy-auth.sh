#!/usr/bin/env bash
# Деплой auth-контура (Keycloak + тема + витрина + realm) на backend-vps-1.
# Запускать с dev-машины. Keycloak уже развёрнут; скрипт обновляет инфру, тему, витрину, ingress и realm.
#
# Требуется: ssh-доступ к VPS, rsync. Секреты (.env) на VPS не перезаписываются.
set -euo pipefail

# --- Параметры (задать под своё окружение) ---
VPS_HOST="${VPS_HOST:-backend-vps-1}"          # ssh-хост (алиас из ~/.ssh/config)
KC_DIR="/opt/infra/keycloak"                    # раскладка Keycloak на VPS
NGINX_CONF_DIR="/opt/infra/nginx/conf.d"
LAUNCHER_DIST="/opt/infra/launcher/dist"
COMPOSE_PROJECT="keycloak"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> [1/6] Синхронизация инфры Keycloak → ${VPS_HOST}:${KC_DIR}"
ssh "$VPS_HOST" "mkdir -p ${KC_DIR}/keycloak ${LAUNCHER_DIST}"
rsync -az --delete \
  --exclude '.env' \
  "${REPO_ROOT}/docker-compose.yml" \
  "$VPS_HOST:${KC_DIR}/docker-compose.yml"
rsync -az --delete --exclude 'providers/*.jar' "${REPO_ROOT}/keycloak/" "$VPS_HOST:${KC_DIR}/keycloak/"

echo "==> [2/6] Сборка витрины (launcher) и деплой статики → ${LAUNCHER_DIST}"
( cd "${REPO_ROOT}/launcher" && npm ci && npm run build )
rsync -az --delete "${REPO_ROOT}/launcher/dist/" "$VPS_HOST:${LAUNCHER_DIST}/"

echo "==> [3/6] ingress: keycloak.conf → ${NGINX_CONF_DIR}"
# ВНИМАНИЕ: этот файл ЗАМЕНЯЕТ живой keycloak.conf на VPS — перед деплоем сделать backup live-конфига
# и смержить allowlist/cert-пути вручную. `nginx -t` ниже идёт ДО reload и блокирует битую конфигурацию.
rsync -az "${REPO_ROOT}/deploy/nginx/conf.d/keycloak.conf" "$VPS_HOST:${NGINX_CONF_DIR}/keycloak.conf"
ssh "$VPS_HOST" "docker compose -p infra-nginx exec -T nginx nginx -t && \
                 docker compose -p infra-nginx exec -T nginx nginx -s reload"

echo "==> [4/6] Перезапуск Keycloak (подхват тем и providers)"
ssh "$VPS_HOST" "cd ${KC_DIR} && docker compose -p ${COMPOSE_PROJECT} up -d keycloak"

echo "==> [5/6] Накат realm-as-code (keycloak-config-cli)"
ssh "$VPS_HOST" "cd ${KC_DIR} && docker compose -p ${COMPOSE_PROJECT} --profile config run --rm config-cli"

echo "==> [6/6] User-profile realm su10 (прямой Admin API PUT — config-cli его не применяет, adorsys #979)"
# Профиль: keycloak/realm/su10-userprofile.json; применяется скриптом (идемпотентно). ПОСЛЕ config-cli.
ssh "$VPS_HOST" "bash ${KC_DIR}/keycloak/realm/apply-userprofile.sh"

echo "==> Готово. Проверка:"
echo "    curl -s https://auth.su10.ru/realms/su10/.well-known/openid-configuration | head"
echo "    открыть https://auth.su10.ru (витрина)"
