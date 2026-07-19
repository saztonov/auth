#!/usr/bin/env bash
# Деплой auth-контура (Keycloak: тема su10 + bcrypt-провайдер + realm) — ЗАПУСКАТЬ НА VPS.
# Portal-scoped по образцу deploy-estimat/deploy-billhub: трогает ТОЛЬКО сервис `keycloak`,
# соседние порталы (estimat/billhub), их темы и nginx не задевает. Работает из любой папки —
# подключается симлинком в /usr/local/bin (путь к репо резолвится от самого скрипта).
#
#   deploy-auth            — git pull + синк темы su10/провайдеров/realm + рестарт Keycloak
#   deploy-auth --migrate  — то же + накат realm-as-code (config-cli) + user-profile
#
# Установка симлинка (один раз):
#   sudo ln -sf /home/corpsu/auth/deploy/deploy-auth-vps.sh /usr/local/bin/deploy-auth
#
# Замечания:
#  - Витрину (launcher) на VPS НЕ собираем (нет node/npm) — она деплоится с dev-машины
#    (deploy/deploy-auth.sh) или заранее собранным dist. Здесь — только Keycloak-часть.
#  - ingress (nginx keycloak.conf) тоже остаётся dev-стороной/ручной правкой (root-only, редко меняется).
#  - Секреты берутся из /opt/infra/keycloak/.env (640 root:docker) — скрипт его НЕ трогает.
set -euo pipefail

# Репо-корень резолвится от реального пути скрипта (через симлинк), не от $PWD — работает из любой папки.
SCRIPT="$(readlink -f "$0")"
REPO="$(cd "$(dirname "$SCRIPT")/.." && pwd)"   # ~/auth
KC_DIR=/opt/infra/keycloak                      # живая раскладка Keycloak
PROJECT=keycloak                                # docker compose -p

MIGRATE=""
[ "${1:-}" = "--migrate" ] && MIGRATE=1

[ -d "$KC_DIR" ] || { echo "Нет $KC_DIR — скрипт запускать НА VPS (см. шапку)"; exit 1; }
[ -f "$REPO/docker-compose.yml" ] || { echo "Не похоже на auth-репо: нет $REPO/docker-compose.yml"; exit 1; }

echo "==> [1/5] git pull ($REPO)"
if git -C "$REPO" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  git -C "$REPO" pull --ff-only
else
  echo "git upstream не настроен — пропускаю pull"
fi

echo "==> [2/5] синк темы su10 / провайдеров / realm → $KC_DIR"
# Пофайлово: --delete в пределах su10/providers/realm безопасно. НЕ синкаем весь keycloak/ разом —
# иначе --delete снёс бы themes/billhub (её нет в этом репо). Собранный bcrypt-jar сохраняем (--exclude).
rsync -a --delete                    "$REPO/keycloak/themes/su10/"  "$KC_DIR/keycloak/themes/su10/"
rsync -a --delete --exclude '*.jar'  "$REPO/keycloak/providers/"    "$KC_DIR/keycloak/providers/"
rsync -a --delete                    "$REPO/keycloak/realm/"        "$KC_DIR/keycloak/realm/"
# docker-compose.yml принадлежит root — пишем через sudo и только если отличается. .env не трогаем.
if ! cmp -s "$REPO/docker-compose.yml" "$KC_DIR/docker-compose.yml"; then
  echo "    docker-compose.yml изменился — обновляю (sudo)"
  sudo cp "$REPO/docker-compose.yml" "$KC_DIR/docker-compose.yml"
fi

echo "==> [3/5] рестарт Keycloak (подхват темы/провайдеров; в проде кэш темы включён)"
# force-recreate ТОЛЬКО keycloak — estimat/billhub не задеваем.
( cd "$KC_DIR" && docker compose -p "$PROJECT" up -d --force-recreate keycloak )

if [ -n "$MIGRATE" ]; then
  echo "==> [4/5] накат realm-as-code (keycloak-config-cli)"
  ( cd "$KC_DIR" && docker compose -p "$PROJECT" --profile config run --rm config-cli )
  echo "    user-profile realm su10 (Admin API PUT — config-cli его не применяет, adorsys #979)"
  bash "$KC_DIR/keycloak/realm/apply-userprofile.sh"
else
  echo "==> [4/5] realm-as-code пропущен (нужен флаг --migrate)"
fi

echo "==> [5/5] health-проба (изнутри сети edge)"
health_ok=""
for _ in $(seq 1 30); do
  if docker run --rm --network edge curlimages/curl:latest -sf http://keycloak:9000/health/ready >/dev/null 2>&1; then
    health_ok=1; break
  fi
  sleep 2
done
if [ -n "$health_ok" ]; then
  echo "health: ok"
else
  echo "health: НЕ готов за отведённое время — проверьте: docker logs keycloak"
fi

echo "Готово. Discovery: curl -s https://auth.su10.ru/realms/su10/.well-known/openid-configuration | head"
