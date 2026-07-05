---
name: skill_keycloak_universal
description: >-
  Универсальный плейбук подключения любого портала контура su10 к корпоративному Keycloak
  (realm su10, auth.su10.ru) как OIDC-клиента: от описания клиента в realm-as-code до backend
  OIDC/BFF-потока, гейта доступа, провижининга/регистрации аккаунтов и (опционально) миграции
  существующей базы пользователей. Использовать при: «добавить вход через Keycloak в <портал>»,
  «подключить портал к auth.su10.ru», «сделать OIDC-клиента в su10», «SSO для нового портала»,
  «мигрировать пользователей портала в Keycloak». Не для правок самого контура su10 (это репо auth).
---

# Подключение портала к Keycloak su10 (универсальный плейбук)

Пошаговый плейбук: как добавить корпоративную аутентификацию Keycloak в портал контура su10.
Проверенный эталон — BillHub (grant-only, BFF). Подставляй `<portal>` (client-id, напр. `estimat`,
`billhub`, `su10-launcher`) и `<portal-domain>` (напр. `rp.su10.ru`).

## Куда что писать (два репозитория)
- **Конфигурация Keycloak** (клиент, мапперы, группы/роли, сервис-аккаунт, тема) — в репозитории
  **`auth`** (`keycloak/realm/su10-realm.yaml`, `keycloak/themes/`). Портал сам realm НЕ настраивает.
- **Код входа** (OIDC-поток, гейт, провижининг) — в репозитории **портала**.

## Факты контура su10 (цель интеграции, не менять)
- issuer `https://auth.su10.ru/realms/su10` (KC 26.1); discovery `…/.well-known/openid-configuration`.
- Публичный домен `auth.su10.ru`; админка `auth-admin.su10.ru`. Сеть docker `edge`. TLS терминирует infra-nginx.
- ⚠️ **Admin REST API (`/admin/*`) НЕ проксируется на `auth.su10.ru`** — там из Keycloak доступны только
  префиксы `realms|resources|js` (см. `deploy/nginx/conf.d/keycloak.conf`); всё остальное падает на
  SPA-fallback витрины `su10-launcher` (`try_files … /index.html`) — получите **200 с HTML**, а не 4xx,
  что легко принять за баг роутинга, а не за ожидаемое поведение. Admin-вызовы (create-user,
  partialImport, group-membership) — через `auth-admin.su10.ru` (пока открыт всем IP, план — закрыть
  SSH-туннелями) ИЛИ, надёжнее, напрямую по docker-сети `edge`: `http://keycloak:8080` — не зависит от
  будущего запирания `auth-admin.su10.ru`, работает если backend портала подключён к той же сети.
- Регистрация на IdP **закрыта** (`registrationAllowed=false`, Вариант B — провижининг через Admin API портала). `verifyEmail`/`resetPasswordAllowed=false`, **SMTP пока нет**.
- realm-as-code накатывается keycloak-config-cli; секреты клиентов — через переменные окружения config-cli (`<PORTAL>_CLIENT_SECRET`), не в git.
- У каждого портала может быть **своя login-тема** (per-client `loginTheme`), лежит в репо портала.

## Шаг 0. Решения до старта (зафиксировать)
1. **Тип клиента:** backend-портал с сервером → **confidential + паттерн BFF** (токены только в httpOnly-cookie, рекомендуется); чистый SPA без backend → **public + PKCE** (как `su10-launcher`).
2. **Модель доступа (гейт):**
   - **по client-роли** (`<portal>:access`) — если у портала нет своей БД пользователей (эталон: EstiMat);
   - **по группе** (`<portal>-active`/`<portal>-pending`) — если портал держит профили/активацию у себя и хочет провижининг/двойную активацию (эталон: BillHub).
3. **Своя БД пользователей?** Если да — нужна таблица связи `user_identity_links(provider, subject, user_id, …)` и стабильный correlation-key `<portal>_user_id` (атрибут в KC + claim), чтобы `внутренний id` не менялся и переживал переезд local→AD.
4. **Нужен ли self-service провижининг** (регистрация по приглашению) — если да, см. Шаг 4 (Вариант B).
5. **Есть ли существующая база аккаунтов с паролями** для миграции — если да, см. Шаг 5.

## Шаг 1. realm-as-code (репозиторий `auth`)
В `keycloak/realm/su10-realm.yaml` добавить клиента `<portal>`:
- **confidential:** `publicClient:false`, `standardFlowEnabled:true`, `directAccessGrantsEnabled:false`, `secret: $(env:<PORTAL>_CLIENT_SECRET)`; **PKCE S256** (`pkce.code.challenge.method: S256`).
- **Точные** (без `*`) `redirectUris` = API-домен callback (`https://<portal-domain>/api/auth/oidc/callback`), `webOrigins` = origin(ы) портала, `post.logout.redirect.uris`.
- **Мапперы:** `audience` (`aud=<portal>`), `email`, `preferred_username`. Для гейта-по-группе — **Group Membership** (`claim.name: groups`, в access token). При своей БД — user-attribute mapper `<portal>_user_id` (`oidc-usermodel-attribute-mapper`) в access+id token. ⚠️ **KC 26 по умолчанию отбрасывает неописанные атрибуты**, а **keycloak-config-cli 6.x секцию `userProfile` НЕ применяет** (adorsys #979) — поэтому маппер идёт в realm-as-code (config-cli), а user-profile ставится **отдельно прямым Admin API `PUT /users/profile`**: объявить `<portal>_user_id` управляемым атрибутом (admin-only view/edit) + `firstName/lastName` required для роли user. Образец в su10: `keycloak/realm/su10-userprofile.json` + `apply-userprofile.sh` (доказано `verify-userprofile-poc.sh`). Без этого маппер пробросит пустоту. **Client-роли для авторизации в токен НЕ тянуть** (роли держит портал у себя), кроме случая гейта-по-роли (тогда `usermodel-client-role-mapper` с `resource_access.<portal>.roles`).
- **Гейт-по-роли:** клиентские роли `access` (+ прикладные) в секции `roles.client.<portal>`.
- **Гейт-по-группе:** группы `<portal>-pending`/`<portal>-active` (top-level `groups:`) + `serviceAccountsEnabled:true` и сервис-аккаунт с realm-management ролями `view-users`+`manage-users` (для провижининга/активации).
- Per-client `loginTheme:<portal>` — только когда тема задеплоена в KC, иначе KC откатится на дефолт su10 (держать закомментированным хуком).
- Добавить `<PORTAL>_CLIENT_SECRET` в `.env.example`, в env сервиса `config-cli` (`docker-compose.yml`) и на VPS в `.env`.
- Накат: `docker compose -p keycloak --profile config run --rm config-cli` (идемпотентно; `IMPORT_VARSUBSTITUTION_ENABLED=true`; `no-delete` для чужих сущностей).
- ⚠️ В комментариях yaml **не писать** литерал `$(env:...)` как пример — var-substitution проходит по всему файлу и падает на несуществующей переменной.

## Шаг 2. Backend портала — OIDC/BFF-поток
Эталон — `billhub/server/src/routes/auth-keycloak.ts` + `services/auth/keycloak/*`. Библиотека `openid-client` (v6).
- **Env:** `OIDC_ISSUER`, `OIDC_CLIENT_ID=<portal>`, `OIDC_CLIENT_SECRET` (тот же, что в su10 `.env`), `OIDC_REDIRECT_URI`, `OIDC_POST_LOGOUT_REDIRECT_URI`, `OIDC_SCOPES=openid email profile`; для гейта-по-группе — `KC_ADMIN_*`, `KC_PORTAL_GROUP_*`.
  ⚠️ **`KC_ADMIN_BASE_URL` НЕ выводить из `OIDC_ISSUER`** (тот указывает на `auth.su10.ru`, где `/admin/*`
  не проксируется — см. «Факты контура» выше). Задать явно: `http://keycloak:8080` (если backend портала
  на сети `edge`) или временно `https://auth-admin.su10.ru`.
- **Login:** PKCE-challenge (S256) + state/nonce в короткоживущей httpOnly-cookie → redirect на Keycloak.
- **Callback:** обмен code, верификация id_token (iss/aud/nonce/state), достать `{sub,email,emailVerified,preferredUsername, <portal>_user_id?}`. Токены — в httpOnly-cookie (BFF), браузер их не видит.
- **Гейт per-request:** `jwtVerify` по JWKS Keycloak (`iss=issuer`, `aud=<portal>`, проверить `azp=<portal>`).
  - Гейт-по-роли: пускать при наличии `resource_access.<portal>.roles ∋ access`.
  - Гейт-по-группе: пускать при `groups ∋ <portal>-active`; `<portal>-pending` → 403 «ожидает активации».
- **Профиль/роли — из БД портала** (при своей БД: резолв `<portal>_user_id`-claim → внутренний id → роль/данные). Client-роли из токена для бизнес-авторизации не использовать.
- **Logout:** end-session Keycloak + гашение cookie.
- **CSRF** активен и в keycloak-режиме; redaction секретов (`id_token`/`client_secret`/`code_verifier`) в логах.
- Держать AUTH-режим фиче-флагом (`AUTH_MODE`), чтобы можно было откатиться на прежний вход.

## Шаг 3. Своя БД пользователей — модель связи (если применимо)
- Таблица `user_identity_links(provider, subject text, user_id, email_at_link, …)`, UNIQUE `(provider, subject)`; `subject` — `text` (переживает смену provider/subject при переезде на AD). Внутренний `user_id` **неизменен** (на нём FK/история).
- **Порядок резолва идентичности:** (1) claim `<portal>_user_id` из verified JWT → внутренний профиль; (2) link по `(provider, subject)` среди `['keycloak-ad','keycloak-local']`; (3) email-fallback ТОЛЬКО для verified email и как аварийный/диагностический путь (логировать).
- Провайдер `keycloak-local` сейчас; при подключении AD появится `keycloak-ad` c новым `subject` для того же `user_id` — перелинковывать **по `<portal>_user_id`**, не по email; переносить членство `<portal>-active` на новый sub.

## Шаг 4. Провижининг/регистрация (Вариант B — регистрация на IdP закрыта)
Т.к. `registrationAllowed=false`, self-registration в Keycloak недоступна. Провижининг — на стороне портала через Admin API (сервис-аккаунт `manage-users`):
- **Отдельный pre-login endpoint** (напр. `POST /api/auth/register-*`), собирающий форму портала (email, ФИО, компания-из-БД-портала, пароль). Он создаёт KC-юзера (`enabled`, `emailVerified=true`, attribute `<portal>_user_id`, credentials), кладёт в `<portal>-pending`, заводит локальную неактивную запись + link, затем отправляет пользователя на обычный KC-login. **Провижининг ДО OIDC-login, не в callback** (в callback юзер попадает только после успешного входа — а его ещё нет).
- Admin-created пользователи в keycloak-режиме тоже провижинятся в KC сразу (create + attribute + группа + link), а не ждут первого входа.
- Активация: перевод `<portal>-pending → <portal>-active` (админ Keycloak в консоли ИЛИ админ портала через Admin API). Инвалидировать кеш профиля при смене активности.
- Анти-абьюз на стороне портала (обязательный выбор из справочника, rate-limit/CAPTCHA).

## Шаг 5. Миграция существующей базы аккаунтов (если есть свои пароли)
- Пароли bcrypt: Keycloak 26 из коробки проверяет только argon2. bcrypt `PasswordHashProvider` (id `bcrypt`) **собран и доказан** (репо auth, `keycloak/providers/bcrypt-spi/`, KC 26.1.5, 2026-07-05) — точный формат credential в `keycloak/providers/CREDENTIAL_CONTRACT.md`. При первом входе KC перехэширует в argon2 (policy realm — дефолт argon2, **не** задавать `hashAlgorithm`).
- Массовый импорт — `POST /admin/realms/su10/partialImport` (требует **manage-realm** → отдельный `client_credentials`-клиент `<portal>-import`, `enabled` только на окно миграции; **НЕ** сервис-аккаунт портала, у него лишь manage-users), `ifResourceExists=SKIP`, `id=<внутренний id>`, `emailVerified=true`, **`firstName`/`lastName` обязательны** (в KC 26 без них срабатывает VERIFY_PROFILE и вход падает `Account is not fully set up`), attribute `<portal>_user_id`, credentials из bcrypt по контракту (`secretData={"value":"<полный $2…>"}`, `credentialData={"hashIterations":<cost>,"algorithm":"bcrypt"}`), null-хэш → без credentials.
- После импорта: перечитать **реальный** KC sub (по email exact / атрибуту), при `sub != внутренний id` — стоп/approved-mapping; записать `user_identity_links`; активных → `<portal>-active`.
- CLI: режимы `preflight|import|verify|reconcile|report`; dry-run, **checkpoint/resume — курсор в файле состояния** (не в БД: одноразовый прогон, импорт идемпотентен через SKIP+onConflictDoNothing), рейт-лимит, без логирования секретов/хэшей. Backup БД + realm-export до старта; сохранить старый механизм входа на окно отката.
- **Образец (su10, доказан 2026-07-05):** import-клиент `billhub-import` (manage-realm) в `keycloak/realm/su10-realm.yaml`; профиль (объявленный атрибут + `firstName/lastName` required) — прямым PUT `keycloak/realm/apply-userprofile.sh`; проверки `verify-bcrypt-poc.sh` / `verify-userprofile-poc.sh` / `verify-import-creds.sh`; хендофф-порядок cutover — `deploy/billhub-migration-prep.md`.

## Шаг 6. Деплой и проверка
- realm: `config-cli` (2-й прогон — no-op, acceptance идемпотентности).
- тема (если своя): рестарт контейнера KC через `docker compose -p keycloak up -d --force-recreate keycloak` (не `restart` — из-за дискового gzip-кэша ресурсов темы).
- ingress: маршрут портала — отдельным `<portal>.conf`, `nginx -t` до reload; не трогать соседние порталы.
- E2E: вход → гейт (роль/группа) → профиль из БД → SSO с соседними порталами → logout; провижининг/активация; (если была) миграция — вход старым паролем.

## Конвенции и безопасность (чек-лист)
- PKCE S256; точные redirect/web-origins без `*`; audience-mapper `aud=<portal>` + проверка `azp` на бэкенде.
- Секреты клиента — только в env/секрет-сторедже, не в git/лог/чат; сервис-аккаунт портала — минимально (`view-users`+`manage-users`), `manage-realm` — только у отдельных import-кред.
- Роли/бизнес-авторизацию держит портал; client-роли в токен для авторизации не тянуть без нужды.
- Стабильный correlation-key `<portal>_user_id` (атрибут + claim) — для устойчивости к смене sub и переезду local→AD.
- Учитывать пробел SMTP: verify/reset недоступны; пользователи без пароля/сброса — только через админ-процедуру.
