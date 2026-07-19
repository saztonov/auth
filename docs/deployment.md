# Деплой — auth (Keycloak-контур su10)

Keycloak — отдельный инфраструктурный сервис на `backend-vps-1`, разворачивается один раз и
обновляется независимо от порталов (`deploy-estimat`/`deploy-billhub` его не трогают).

## Раскладка на VPS

```
/opt/infra/keycloak/
  docker-compose.yml
  .env                      # секреты, 640 root:docker, НЕ в git
  keycloak/themes/su10/     # кастомная тема
  keycloak/providers/       # SPI-jar (bcrypt и т.п.)
  keycloak/realm/           # realm-as-code (su10-realm.yaml)
/opt/infra/nginx/conf.d/keycloak.conf # ingress (auth.su10.ru + auth-admin.su10.ru)
/opt/infra/launcher/dist/             # собранная SPA-витрина (статик)
```

Docker-сеть `edge` — общая с `infra-nginx` и порталами. Наружу порты Keycloak не публикуются.

## Предпосылки (один раз)

1. **DNS:** A-записи `auth.su10.ru` и `auth-admin.su10.ru` → публичный IP `backend-vps-1`.
2. **БД:** `keycloak_db` + пользователь `keycloak_runtime` (Yandex Managed PG), TLS, backup, PITR.
3. **Сеть:** `docker network create edge` (если ещё нет).
4. **Секреты** в `/opt/infra/keycloak/.env` (640 root:docker): `KC_DB_PASSWORD`,
   `KC_BOOTSTRAP_ADMIN_*`, позже — `KEYCLOAK_ADMIN_*` (для config-cli), client secrets порталов.
5. **TLS:** один SAN-сертификат на оба домена (webroot ДО добавления 443-блоков):
   ```bash
   certbot certonly --webroot -w /var/www/certbot -d auth.su10.ru -d auth-admin.su10.ru
   ```

## Первый запуск

```bash
cd /opt/infra/keycloak
cp .env.example .env            # заполнить
docker compose -p keycloak up -d keycloak
docker compose -p keycloak logs -f keycloak     # дождаться "Running the server in ... mode"
```

Проверка изнутри сети edge:
```bash
docker run --rm --network edge curlimages/curl -s http://keycloak:9000/health/ready
```

ingress:
```bash
cp /opt/infra/keycloak/deploy/nginx/conf.d/keycloak.conf /opt/infra/nginx/conf.d/keycloak.conf
# ЗАМЕНЯЕТ живой keycloak.conf: сначала backup, затем смержить allowlist/cert-пути с боевым
# заполнить <VPN_OR_OFFICE_CIDR> в server-блоке auth-admin.su10.ru
docker compose -p infra-nginx exec nginx nginx -t && \
docker compose -p infra-nginx exec nginx nginx -s reload
```

Проверка discovery:
```bash
curl -s https://auth.su10.ru/realms/su10/.well-known/openid-configuration | head
```

## Регулярный деплой

Есть два скрипта — под разные ситуации.

### A. Полный деплой с dev-машины (`deploy/deploy-auth.sh`)

Push по `ssh`+`rsync` (запускать с dev-машины; хост/пути задаются переменными вверху скрипта).
Умеет то, что VPS-команда не умеет: **сборку витрины** (нужен npm) и **ingress-nginx**.
1. rsync инфры репозитория → `/opt/infra/keycloak` (compose, themes, providers, realm; **без** `.env`);
2. сборка витрины (`launcher`: `npm ci && npm run build`) → rsync `dist/` → `/opt/infra/launcher/dist`;
3. копия `deploy/nginx/conf.d/keycloak.conf` → `/opt/infra/nginx/conf.d/` (заменяет живой keycloak.conf — backup + merge allowlist/cert вручную), `nginx -t` + reload;
4. `docker compose -p keycloak up -d` (рестарт подхватывает темы и providers);
5. накат realm: `docker compose -p keycloak --profile config run --rm config-cli`.

```bash
./deploy/deploy-auth.sh
```

### B. VPS-команда `deploy-auth [--migrate]` (`deploy/deploy-auth-vps.sh`)

Запускается **на самом VPS из любой папки** (как `deploy-estimat`/`deploy-billhub`) — для быстрых
правок темы su10 / провайдеров / realm без dev-машины. Витрину и nginx **не** трогает (на VPS нет
npm; ingress редко меняется и root-only — это остаётся за сценарием A / ручной правкой).

- `deploy-auth` — `git -C ~/auth pull` → rsync темы su10/провайдеров/realm в `/opt/infra/keycloak`
  → рестарт **только** сервиса `keycloak` (`up -d --force-recreate`, в проде кэш темы включён).
- `deploy-auth --migrate` — то же + накат realm-as-code (`--profile config run --rm config-cli`)
  + `apply-userprofile.sh`. Это и есть «накат миграций» для auth (своей БД-миграции у Keycloak нет).

Синк идёт **пофайлово** (su10 / providers / realm), поэтому `--delete` не сносит `themes/billhub`
(её нет в этом репо), а собранный `keycloak-bcrypt-*.jar` сохраняется (`--exclude '*.jar'`).
`docker-compose.yml` (владелец root) переписывается через `sudo cp` только при отличии; `.env` не трогается.

Установка симлинка (один раз, репо на VPS — `~/auth`):
```bash
cd ~/auth && git pull --ff-only
sudo ln -sf /home/corpsu/auth/deploy/deploy-auth-vps.sh /usr/local/bin/deploy-auth
```

Использование:
```bash
deploy-auth --migrate    # правки темы/провайдеров + накат realm-as-code
deploy-auth              # только тема/провайдеры/рестарт, без realm
```

## Настройка realm вручную (первый раз)

1. Войти в `https://auth-admin.su10.ru` под bootstrap-админом (из доверенной сети). Создать
   **постоянного** админа, удалить bootstrap-учётку, убрать `KC_BOOTSTRAP_*` из `.env`.
2. Дальше realm ведётся как код: правки — в `keycloak/realm/su10-realm.yaml`, накат — config-cli.

## Бэкап / восстановление

- `keycloak_db` — штатными backup Yandex Managed PG (PITR).
- Realm export (`kc.sh export --realm su10 --users realm_file`) — регулярно (cron), как страховка.
- Restore: поднять Keycloak на восстановленной `keycloak_db`; при необходимости `kc.sh import`.

## Обновление версии Keycloak

```bash
# 1. realm export + backup keycloak_db
# 2. поднять KEYCLOAK_IMAGE в .env на новый pin-тег
docker compose -p keycloak pull
docker compose -p keycloak up -d
# 3. проверить discovery, вход, витрину, тему
```

## Мониторинг

- Публичный health: `https://auth.su10.ru/realms/su10/.well-known/openid-configuration`.
- Внутренний: `http://keycloak:9000/health/ready`, `/metrics` (из сети edge / Prometheus).
- Алерты: Keycloak down, (позже) AD/LDAP down, VPN down, TLS expiry, DB near limit.
