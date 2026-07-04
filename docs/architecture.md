# Архитектура — auth (Keycloak-контур su10)

## Общая схема

```
                                  ┌───────────────────────────── backend-vps-1 ─────────────────────────────┐
Пользователь ──HTTPS──> infra-nginx (edge)                                                                   │
   (браузер)               │                                                                                 │
                           ├── auth.su10.ru                                                                   │
                           │     ├── /                → launcher SPA (статик из /opt/infra/launcher/dist)     │
                           │     └── /realms/,/resources/,/js/ → keycloak:8080  (вход, Account Console, OIDC) │
                           ├── auth-admin.su10.ru (VPN allowlist) → keycloak:8080 (админ-консоль)             │
                           ├── estimat.su10.ru → портал EstiMat (свой репозиторий, OIDC-клиент)              │
                           └── rp.su10.ru/ravek.link → портал BillHub (свой репозиторий, OIDC-клиент)        │
                                                     │                                                        │
                                          keycloak (Quarkus 26.1)                                             │
                                                     │  JDBC/TLS                                              │
                                                     ▼                                                        │
                                       Yandex Managed PostgreSQL: keycloak_db                                 │
                                                                                                              │
                                          (позже) LDAPS 636 ──IPsec──> AD компании                            │
                                                                                                              └─┘
```

Realm — единый **`su10`**. Всё, что связано с идентичностью, — здесь; порталы подключаются как
OIDC-клиенты и держат свою авторизацию (роли/доступы) у себя.

## Компоненты

### Keycloak
- Образ `quay.io/keycloak/keycloak:26.1`, команда `start` (образ сам делает build при старте,
  подхватывая `providers/` и темы).
- БД `keycloak_db` (Yandex Managed PG, пользователь `keycloak_runtime`, TLS, пул 20).
- За `infra-nginx`: `KC_PROXY_HEADERS=xforwarded`, `KC_HTTP_ENABLED=true`, порт `8080` внутри сети
  `edge`; management `9000` (health/metrics) — только внутри.
- Hostname: `KC_HOSTNAME=https://auth.su10.ru`, `KC_HOSTNAME_ADMIN=https://auth-admin.su10.ru`
  (админка отделена на свой домен под allowlist).

### Тема `keycloak/themes/su10`
FreeMarker + CSS. Кастомизирует страницы входа (`login/`) и Account Console (`account/`) под su10.
Монтируется в контейнер в `/opt/keycloak/themes/su10`. В проде кэш темы включён — правки применяются
после рестарта контейнера. Тема назначается realm'у/клиентам в realm-as-code (`loginTheme`,
`accountTheme`), либо per-client.

### Провайдеры `keycloak/providers`
Кастомные SPI-jar. Ключевой — **bcrypt PasswordHashProvider** для бесшовной миграции паролей BillHub
(bcrypt `$2[aby]$12$…`). Realm password policy остаётся по умолчанию (argon2, non-FIPS) — после
первого успешного входа Keycloak перехэширует пароль в native-алгоритм. См. `keycloak/providers/README.md`.

### realm-as-code `keycloak/realm/su10-realm.yaml`
Декларативное описание realm (клиенты `estimat`, `billhub`, `su10-launcher`, роли, мапперы). Накат —
keycloak-config-cli (сервис `config-cli` в compose), идемпотентно, на живой Keycloak. Пользователи и
AD-федерация здесь **не** описываются. См. `keycloak/realm/README.md`.

### Витрина `launcher`
SPA (Vite + React + `react-oidc-context`), OIDC-клиент `su10-launcher` (public, PKCE). Отдаётся
`infra-nginx` со статик-каталога на `auth.su10.ru/`. Функции:
- вход через Keycloak (redirect-поток);
- **плитки доступных порталов** (список — `src/config/portals.ts`; при наличии в токене признака
  доступа фильтруется, иначе показываются все);
- «Сменить пароль / MFA» — deep-link в Account Console (`/realms/su10/account`);
- «Выйти» — end-session Keycloak.

## Модель доступа к порталам

Право «этому пользователю доступен портал X» решается **самим порталом** (портал проверяет свою БД —
как BillHub, или client-роль `access` — как EstiMat). Чтобы витрина показывала **точный** список, есть
два варианта:
1. Моделировать в Keycloak признак доступа per-portal (client-роль `access` или группа `*-access`) и
   пробрасывать её в токен `su10-launcher` через маппер — тогда витрина фильтрует плитки по ролям.
2. Витрина показывает все настроенные порталы, а доступ реально проверяет портал при входе.

По умолчанию скелет использует вариант 2 (проще), с заделом под вариант 1 (`requiredRole` в
`portals.ts`).

## Регистрация (invite-based)

Открытая self-registration не используется. Подрядчики заводятся **по приглашению**:
- либо кастомный registration flow Keycloak с обязательной верификацией email / invite-link;
- либо провижининг из портала (BillHub заводит пользователя в Keycloak через Admin API при
  саморегистрации по `registration_token`).

Сотрудники после подключения AD приходят из AD и не регистрируются самостоятельно.

## Интеграция с AD (позже)
LDAPS (636) через site-to-site IPsec к контроллеру домена; Keycloak в READ-ONLY, пароли остаются в
AD. Группы AD `*-Access/*-Admins/…` → роли клиентов. Подробности и инструкция для админов AD —
`docs/ad-integration-guide.md`.
