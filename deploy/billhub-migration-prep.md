# Миграция BillHub → Keycloak: готовность со стороны auth (su10)

Handoff-документ: что подготовлено в контуре su10 для массового импорта аккаунтов BillHub и включения
входа через Keycloak. **Код импорта (CLI `migrate-to-keycloak.ts`, фазы Ф1–Ф4) пишется в репо billhub**
(отдельно) — этот документ описывает только auth-сторону и порядок cutover.

## Готовность su10 (на 2026-07-05)

| Компонент | Состояние | Где |
|---|---|---|
| bcrypt PasswordHashProvider | ✅ на su10 (инертен), доказан | `keycloak/providers/bcrypt-spi/`, `CREDENTIAL_CONTRACT.md` |
| Маппер `billhub_user_id` | ✅ на клиенте billhub | `su10-realm.yaml` |
| User-profile (`billhub_user_id` managed + `ADMIN_EDIT`, firstName/lastName required) | ✅ применён прямым PUT | `su10-userprofile.json` + `apply-userprofile.sh` |
| Группы `billhub-pending`/`billhub-active` | ✅ | `su10-realm.yaml` |
| Сервис-аккаунт billhub (view/manage-users) | ✅ | `su10-realm.yaml` |
| **Импорт-клиент `billhub-import` (manage-realm)** | ✅ на su10, **доказан** `verify-import-creds.sh` (partialImport=200); сейчас `enabled:false` — включить на окно миграции | `su10-realm.yaml`, `verify-import-creds.sh` |

## Импорт-креды (для CLI импорта Ф3)

`partialImport` требует роль **manage-realm**, которой нет у сервис-аккаунта billhub. Заведён отдельный
машинный клиент **`billhub-import`** (client_credentials, serviceAccountsEnabled, роли `manage-realm` +
`manage-users` + `view-users`). Держится **`enabled: false`** — включать только на окно миграции, после
выключить/удалить.

**Как CLI аутентифицируется** (client_credentials):
```
POST https://auth.su10.ru/realms/su10/protocol/openid-connect/token
  grant_type=client_credentials
  client_id=billhub-import
  client_secret=<BILLHUB_IMPORT_CLIENT_SECRET из .env su10>
→ access_token (с manage-realm) → Admin API:
POST https://auth.su10.ru/admin/realms/su10/partialImport
```
Значения для env CLI в BillHub (свои имена переменных на стороне billhub): base `https://auth.su10.ru`,
realm `su10`, client_id `billhub-import`, secret — из su10 `.env`. **Секрет не коммитить.**

## Порядок деплоя импорт-креда на su10 (перед импортом)

1. Придумать секрет и положить в `/opt/infra/keycloak/.env`:
   `BILLHUB_IMPORT_CLIENT_SECRET=<openssl rand -hex 32>`
2. Доставить обновлённый realm-yaml и накатить config-cli:
   ```bash
   cd ~/auth && git pull
   cp keycloak/realm/su10-realm.yaml /opt/infra/keycloak/keycloak/realm/
   cd /opt/infra/keycloak && docker compose -p keycloak --profile config run --rm config-cli
   ```
3. **Включить** клиент на окно миграции: admin console → Clients → `billhub-import` → Enabled **On**
   (или временно `enabled: true` в yaml + config-cli).
4. Проверить креды (client_credentials отдаёт токен):
   ```bash
   cd /opt/infra/keycloak
   g(){ grep -E "^$1=" .env | tail -1 | cut -d= -f2- | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//'; }
   CS="$(g BILLHUB_IMPORT_CLIENT_SECRET)"; export CS
   docker run --rm --network edge -e CS curlimages/curl:latest sh -c \
     'curl -s -o /dev/null -w "%{http_code}\n" -d grant_type=client_credentials -d client_id=billhub-import -d "client_secret=$CS" \
      http://keycloak:8080/realms/su10/protocol/openid-connect/token'
   # 200 = креды рабочие
   ```
5. После завершения миграции — **выключить** `billhub-import` (Enabled Off / enabled:false + config-cli) или удалить роль.

## Cutover — общий порядок (auth ⇄ billhub ⇄ ops)

0. **Предпосылки:** su10 готов (таблица выше) + `billhub-import` включён; **CLI импорта реализован и
   протестирован** (billhub, Ф3); бэкапы.
1. **Бэкап:** дамп БД BillHub (Yandex Managed PG snapshot) + realm-export su10 (ниже). Зафиксировать метку cutover.
2. **Репетиция (НЕ su10):** CLI `preflight`/`--dry-run` → дубли `lower(email)`, null/битые bcrypt,
   будущие `sub`-mismatch. По желанию — реальный `partialImport` на throwaway-realm (клонировать группы/
   клиент/профиль). На su10 не идём, пока не чисто.
3. **Импорт в su10:** CLI `import` батчами (`ifResourceExists=SKIP`, `id=users.id`), payload по контракту
   (`firstName/lastName`, `attributes.billhub_user_id`, bcrypt-креды — `CREDENTIAL_CONTRACT.md`); перечитать
   реальный `sub`; `user_identity_links`; активных → `billhub-active`; отчёт imported/skipped/mismatch.
4. **Канарейка:** `AUTH_MODE=keycloak` на ОДНОМ инстансе — вход старым bcrypt-паролем → перехэш в argon2;
   гейт по группе; резолв по `billhub_user_id`; роль из БД; SSO; logout. Остальные — на standalone.
5. **Флип в прод:** `AUTH_MODE=keycloak` везде. **Откат готов:** `password_hash`/standalone-код/refresh-
   таблицы не удалять до конца окна отката; откат = `AUTH_MODE=standalone`.

## Бэкап realm su10 (перед импортом)

Экспорт realm su10 в файл (на VPS; users экспортируются отдельным дампом БД KC при необходимости):
```bash
docker exec keycloak /opt/keycloak/bin/kc.sh export --dir /tmp/su10-export --realm su10 --users skip
docker cp keycloak:/tmp/su10-export /opt/infra/keycloak/backup-su10-$(date +%F)   # если date недоступен в exec — подставить дату
```
(realm-as-code и так в git; экспорт — доп. страховка на состояние живого realm.)

## Что остаётся закрыть (не auth-код)
- ✅ Реализовать и протестировать CLI импорта + Ф1/Ф2/Ф4 (billhub) — сделано, закоммичено (2026-07-06).
- ✅ Сгенерировать `BILLHUB_IMPORT_CLIENT_SECRET`, положить в su10 `.env`, накатить — сделано и доказано
  `verify-import-creds.sh` (2026-07-05). Клиент сейчас `enabled:false` — **включить** перед реальным импортом
  (шаг 3 выше), выключить сразу после.
- ⬜ Сверить `OIDC_CLIENT_SECRET` billhub с `BILLHUB_CLIENT_SECRET` в su10 `.env`.
- ⬜ Бэкапы + метка cutover.
- ⬜ Сам cutover: preflight → dry-run → backup → import → канарейка → флип (см. траблшутинг ниже).

## Траблшутинг (специфично для этого раздела)
- **`.env` на VPS `640 root:docker`** — писать секрет только `sudo tee -a .env` (не `>>`).
- **config-cli «Cannot resolve variable env:...» даже после добавления секрета в `.env`** — на VPS мог
  остаться устаревший `docker-compose.yml` (секрет пробрасывается в config-cli именно через него). Смотри
  общее правило в `CLAUDE.md` («Инфраструктура»): при ручном патче копировать `docker-compose.yml` +
  `keycloak/realm/*` вместе, не по одному файлу.
- **`config-cli` не применяет user-profile** — см. `bcrypt-provider-runbook.md`/скиллы (adorsys #979);
  профиль правится ТОЛЬКО `apply-userprofile.sh`, не через `su10-realm.yaml`.
