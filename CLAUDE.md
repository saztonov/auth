# auth — правила проекта

## Общение
- Язык общения: русский. Промежуточные размышления — тоже на русском.
- Не запускать сервисы «на потест» самостоятельно, если не просят: Keycloak развёрнут на VPS,
  локальный запуск — по явному запросу.

## Назначение репозитория
Единственная зона ответственности — **аутентификация контура su10**: Keycloak (realm `su10`),
кастомная тема, SPA-витрина порталов, realm-as-code, интеграция с AD, деплой. Код самих порталов
(EstiMat, BillHub) сюда не добавлять — они подключаются как OIDC-клиенты.

## Безопасность
- Секреты (пароль `keycloak_db`, bootstrap-админ, client secrets, PSK/bind-пароль AD) **не выводить
  в чат** и не коммитить. Только `.env.example`/YAML с плейсхолдерами (`<...>`, `***`).
- Не печатать команды, раскрывающие секреты (`cat .env`, `echo $KC_DB_PASSWORD` и т.п.). Проверять
  наличие/длину/последние символы, не значение.
- Приватные ключи сертификатов DC и bind-пароль AD — не хранить в репозитории вообще.

## Git
- Изолированные коммиты: включать только правки текущей сессии; чужие незакоммиченные изменения не
  стейджить.
- Коммиты без трейлеров-автоподписей (`Co-Authored-By` и подобных).

## Инфраструктура (факт)
- Keycloak `quay.io/keycloak/keycloak:26.1`, команда `start` (без `--optimized`).
- БД: отдельная `keycloak_db` в Yandex Managed PostgreSQL, пользователь `keycloak_runtime`, TLS,
  `KC_DB_POOL_MAX_SIZE=20`.
- Docker-сеть `edge` (общая с infra-nginx и порталами). Наружу порты не публикуются — TLS терминирует
  `infra-nginx`, проксируя на `keycloak:8080`. Management-порт `9000` (health/metrics) — только внутри.
- Раскладка на VPS: `/opt/infra/keycloak/` (compose + `.env` + `themes/` + `providers/`),
  `/opt/infra/nginx/conf.d/keycloak.conf`, `/opt/infra/launcher/dist/` (собранная витрина).
- Домены: `auth.su10.ru` (публичный), `auth-admin.su10.ru` (админка, VPN allowlist).

## Keycloak-конвенции
- Realm — **`su10`**, единый на весь контур. Порталы — клиенты в нём (`estimat`, `billhub`,
  `su10-launcher`).
- Клиент портала: confidential, Standard flow On, **PKCE S256**, redirect на API-домен портала
  (`/api/auth/oidc/callback`), exact allowlist redirect/web-origins (без `*`), **audience mapper**
  `aud=<client-id>`, мапперы `email`/`preferred_username`. Роли авторизации портала держит сам портал
  (в токен client-роли для авторизации не тянем без необходимости).
- Клиент витрины `su10-launcher`: public, PKCE S256, redirect на `https://auth.su10.ru/*`.
- Настройки realm — как код в `keycloak/realm/` (keycloak-config-cli), а не только руками в консоли.
  Пользователи/AD-федерация в realm-as-code не описываются (управляются отдельно).

## Тема
- Кастомная тема в `keycloak/themes/su10/` (FreeMarker + CSS). Меняем внешний вид страниц входа и
  Account Console, не ломая штатную логику. Изменения темы применяются после рестарта контейнера
  (в проде кэш темы включён).

## Миграция паролей (bcrypt)
- Для бесшовного переезда BillHub (пароли bcrypt `$2[aby]$12$…`) нужен bcrypt PasswordHashProvider в
  `keycloak/providers/`. Realm password policy — по умолчанию (argon2, non-FIPS): после первого входа
  Keycloak сам перехэширует пароль в native-алгоритм. Формат импортируемого credential доказывать на
  тестовом realm до массовой заливки.

## Стек
- Keycloak 26 (Quarkus) + PostgreSQL 17 (Yandex Managed).
- Витрина: Vite + React 19 + TypeScript + `react-oidc-context` (OIDC PKCE).
- realm-as-code: keycloak-config-cli.
- Деплой: docker compose (`-p keycloak`) + rsync/ssh на VPS, ingress через общий `infra-nginx`.

## Референсы
- EstiMat (`C:\Users\Usr\EstiMat`) — откуда переносится инфра Keycloak; в EstiMat остаётся только
  сметный портал (см. `docs/split-from-estimat.md`).
- BillHub (`C:\Users\Usr\billhub`) — второй портал-клиент, миграция его авторизации на Keycloak.
