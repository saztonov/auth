# keycloak/providers — кастомные SPI

Сюда кладётся `.jar` кастомных провайдеров Keycloak. Каталог монтируется в контейнер как
`/opt/keycloak/providers` (read-only). Команда `start` (без `--optimized`) выполняет `kc.sh build` при
старте и подхватывает провайдеры — после добавления/обновления jar нужен **пересоздать** контейнер:

```bash
docker compose -p keycloak up -d --force-recreate keycloak
```

> `.jar` и артефакты сборки в git не коммитим (см. корневой `.gitignore`:
> `keycloak/providers/**/*.jar`, `**/target/`). Храним исходники SPI, а бинарь собираем при деплое.

## bcrypt PasswordHashProvider (миграция паролей BillHub)

BillHub хранит пароли как **bcrypt** (`$2[aby]$12$…`, bcryptjs). Keycloak 26 по умолчанию хэширует
**argon2** и bcrypt «из коробки» не проверяет. Провайдер `bcrypt` нужен, чтобы *проверить* перенесённые
хэши; при первом успешном входе Keycloak сам перехэширует пароль в argon2 (policy realm — дефолтная).

- **Исходники (собраны свой минимальный SPI):** [`bcrypt-spi/`](bcrypt-spi/) — Maven-проект,
  `PasswordHashProvider` + `PasswordHashProviderFactory` (id `bcrypt`), bcrypt-библиотека
  `at.favre.lib` шейдится в jar. Совместим с Keycloak 26.1.x (сигнатуры сверены по исходникам 26.1.5).
- **Контракт credential:** [`CREDENTIAL_CONTRACT.md`](CREDENTIAL_CONTRACT.md) — точный `secretData`/
  `credentialData` для payload-builder BillHub.

### Сборка jar (на VPS, без java/maven на хосте)

```bash
bash keycloak/providers/bcrypt-spi/build-jar.sh
# → keycloak/providers/bcrypt-spi/target/keycloak-bcrypt-<версия KC>.jar
```
Скрипт определяет фактическую версию рантайма из контейнера `keycloak` и собирает строго под неё
(в compose плавающий тег `26.1`). Юнит-тесты гоняются при сборке и гейтят артефакт.

### Доказательство контракта (тест-realm `bcrypt-poc`, не трогая su10)

```bash
bash keycloak/providers/bcrypt-spi/verify-bcrypt-poc.sh
```
Скрипт: **preflight** (`kc.sh build` c jar в disposable-контейнере — до касания live KC) → выкат jar в
live `providers/` и `force-recreate keycloak` **с rollback** при неудачном старте → на realm `bcrypt-poc`
импортирует bcrypt-кред через `partialImport`, логинится старым паролем (`$2a/$2b/$2y × cost{12,10}`),
проверяет перехэш в argon2 → удаляет realm. Затрагивается только сервис `keycloak`; estimat/billhub не трогаются.

### Деплой на боевой su10 (по явному запросу)

Провайдер инертен, пока ни один credential не использует `algorithm=bcrypt`, поэтому его наличие на
боевом KC безопасно. Выкат:
```bash
bash keycloak/providers/bcrypt-spi/build-jar.sh
cp keycloak/providers/bcrypt-spi/target/keycloak-bcrypt-*.jar /opt/infra/keycloak/keycloak/providers/
cd /opt/infra/keycloak && docker compose -p keycloak up -d --force-recreate keycloak
```
Опционально (по согласованию) — запинить тег образа в `docker-compose.yml` на точный патч (напр.
`26.1.5`) для воспроизводимости сборки/рантайма.

### Удаление после миграции

Когда все активные пользователи вошли хотя бы раз (все bcrypt-креды перехэшированы в argon2 — проверить
по БД/выборочно через `GET users/{id}/credentials`), провайдер можно снять:
```bash
rm /opt/infra/keycloak/keycloak/providers/keycloak-bcrypt-*.jar
cd /opt/infra/keycloak && docker compose -p keycloak up -d --force-recreate keycloak
```

### Как работает (кратко)

1. Провайдер `bcrypt` в этом каталоге, Keycloak пересобирается при старте (`start` → `kc.sh build`).
2. Realm password policy — **дефолтная (argon2)**; bcrypt только *проверяет* перенесённые креды.
3. Импортируемый credential: `algorithm=bcrypt`, `secretData={"value":"<полный $2…>"}`,
   `credentialData={"hashIterations":<cost>,"algorithm":"bcrypt"}` (см. `CREDENTIAL_CONTRACT.md`).
4. При первом успешном входе policy/дефолтный (argon2) провайдер видит несоответствие алгоритма и
   **перехэширует пароль в argon2** (пишет в `keycloak_db`).
5. Когда перехэшированы все активные пользователи — провайдер можно убрать.
