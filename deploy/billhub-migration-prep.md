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
3. **Включить** клиент на окно миграции (только на время реального `import`, между dry-run и импортом):
   ```bash
   bash keycloak/realm/set-import-client.sh enable
   ```
4. Проверить креды (client_credentials отдаёт токен) — тот же smoke, что делает billhub со своей стороны:
   ```bash
   cd /opt/infra/keycloak
   g(){ grep -E "^$1=" .env | tail -1 | cut -d= -f2- | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//'; }
   CS="$(g BILLHUB_IMPORT_CLIENT_SECRET)"; export CS
   docker run --rm --network edge -e CS curlimages/curl:latest sh -c \
     'curl -s -o /dev/null -w "%{http_code}\n" -d grant_type=client_credentials -d client_id=billhub-import -d "client_secret=$CS" \
      http://keycloak:8080/realms/su10/protocol/openid-connect/token'
   # 200 = креды рабочие
   ```
5. Сразу после `import` (batch или sample) — **выключить**:
   ```bash
   bash keycloak/realm/set-import-client.sh disable
   ```

## Вспомогательные скрипты auth-стороны (2026-07-06)

- **`keycloak/realm/set-import-client.sh enable|disable`** — вкл/выкл `billhub-import` (см. выше).
- **`keycloak/realm/export-realm-backup.sh`** — экспорт конфига su10 (`users:skip`) перед импортом в
  `${KC_DIR}/backups/su10-realm-export-<timestamp>/` (доп. страховка сверх realm-as-code в git).
- **`keycloak/realm/verify-import-result.sh [sample.txt]`** — пост-импортная read-only сверка: счётчики
  `users/count`, размеры групп `billhub-pending`/`billhub-active`; с файлом-сэмплом (username/email по
  строке) — spot-check, что у каждого проставлен атрибут `billhub_user_id`.
- **`keycloak/realm/rollback-delete-kc-users.sh <список.txt>`** — при откате удаляет из su10 KC
  перечисленных пользователей (username/email построчно). ⚠️ Прочитать комментарий в шапке скрипта:
  удаление нужно ТОЛЬКО если планируется повторная попытка миграции с чистого листа; при постоянном
  откате безопаснее оставить KC-записи как есть. Список строится из отчёта импорта billhub (`kc-import.json`)
  — точный `jq`-фильтр зависит от схемы отчёта, уточнить у billhub-стороны.

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

## Статус на 2026-07-06 (после боевого импорта)
- ✅ CLI импорта + Ф1/Ф2/Ф4 (billhub) — реализовано, закоммичено.
- ✅ Импорт-креды доказаны (`verify-import-creds.sh`: client_credentials=200, partialImport=200). Диагностика
  раннего 401 закрыта — причина была на billhub-стороне (забыт `KC_IMPORT_CLIENT_ID`, `URLSearchParams`
  тихо слал `client_id=undefined`), не секрет (сверен sha256).
- ✅ **Боевой импорт выполнен**: 195 users (182 `billhub-active`, 14 `billhub-pending`), sample-spot-check
  зелёный (`billhub_user_id`/`emailVerified`/членство). Импорт-клиент снова `enabled:false`.
- ✅ Группы `employee`/`contractor` заведены (тип персоны виден в консоли KC) — членство проставит billhub
  отдельным скриптом позже (не блокер флипа).
- ✅ Витрина `su10-launcher` фильтрует плитки по правам (fail-closed): мапперы `resource_access`/`groups`
  накатаны config-cli; `launcher/dist` собран и закоммичен.
- ✅ Login-тема `billhub` активна (`attributes.login_theme` на клиенте, том смонтирован, форма
  брендированная). Остаётся косметика CSS (лейбл «Пароль» наезжает) — правит billhub.

### Гейты до флипа (осталось)
- ⬜ **Деплой витрины** в `/opt/infra/launcher/dist/` (мапперы уже накатаны → безопасно, окна «0 плиток» нет).
- ⬜ **CSS-фикс темы** (billhub) + рестарт KC (кэш темы в проде).
- ⬜ **Канарейка** (критический гейт): реальный импортированный юзер входит старым bcrypt-паролем при
  `AUTH_MODE=keycloak` на ОДНОМ инстансе → проверить: вход (bcrypt verify), перехэш в argon2, гейт по
  `billhub-active`, резолв `billhub_user_id`, роль из БД, SSO, logout. Остальные инстансы — standalone.
- ⬜ **Полный флип** `AUTH_MODE=keycloak` — только после зелёной канарейки. Откат = `AUTH_MODE=standalone`
  (не удалять `password_hash`/standalone-код/refresh-таблицы до конца окна отката).

## Траблшутинг (специфично для этого раздела)
- **`.env` на VPS `640 root:docker`** — писать секрет только `sudo tee -a .env` (не `>>`).
- **config-cli «Cannot resolve variable env:...» даже после добавления секрета в `.env`** — на VPS мог
  остаться устаревший `docker-compose.yml` (секрет пробрасывается в config-cli именно через него). Смотри
  общее правило в `CLAUDE.md` («Инфраструктура»): при ручном патче копировать `docker-compose.yml` +
  `keycloak/realm/*` вместе, не по одному файлу.
- **`config-cli` не применяет user-profile** — см. `bcrypt-provider-runbook.md`/скиллы (adorsys #979);
  профиль правится ТОЛЬКО `apply-userprofile.sh`, не через `su10-realm.yaml`.
- **`kc.sh export`: `ERROR ... Unable to start the management interface on 0.0.0.0:9000 / Address already
  in use`** — `kc.sh export` сам поднимает полноценный Quarkus-рантайм (порты 8080/9000). Запуск через
  `docker exec` в УЖЕ работающий `keycloak`-контейнер конфликтует с live-процессом (общий network
  namespace) — данные при этом экспортируются успешно, но следующий за этим краш обрывает скрипт до
  `docker cp`. Исправлено: `export-realm-backup.sh` гоняет экспорт в ОТДЕЛЬНОМ одноразовом контейнере
  (`docker create/start/cp/rm`, та же БД через `--env-file`), не трогая live keycloak.
