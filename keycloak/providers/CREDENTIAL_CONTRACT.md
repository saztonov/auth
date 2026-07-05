# Контракт bcrypt-credential для импорта в Keycloak (миграция BillHub)

Источник истины для payload-builder миграции BillHub. Описывает **точный** вид credential, который
проверяет наш `bcrypt` PasswordHashProvider (`keycloak/providers/bcrypt-spi/`). Сверено по исходникам
Keycloak `26.1.5`; доказано на тест-realm `bcrypt-poc` скриптом `verify-bcrypt-poc.sh`.

## Целевой объект credential

На каждого мигрируемого пользователя в массив `credentials` кладётся ОДИН объект:

```json
{
  "type": "password",
  "algorithm": "bcrypt",
  "secretData": "{\"value\":\"$2a$12$Kix...полный bcrypt-хэш из BillHub...\"}",
  "credentialData": "{\"hashIterations\":12,\"algorithm\":\"bcrypt\"}"
}
```

- **`secretData`** и **`credentialData`** — это **JSON-строки внутри JSON** (кавычки экранированы).
- **`secretData.value`** — полный bcrypt-хэш из BillHub (`$2[aby]$NN$<22-симв. соль><digest>`).
  Соль и cost содержатся в самой строке — **отдельного поля `salt` быть НЕ должно**.
- **`credentialData.algorithm`** обязан быть `"bcrypt"` — по нему Keycloak при проверке выбирает наш
  провайдер (`getId() == "bcrypt"`).
- **`credentialData.hashIterations`** — cost из хэша (для BillHub `12`). Поле информативное; `verify`
  берёт cost из самой строки хэша.

## Почему именно так (факты из исходников 26.1.5)

- `org.keycloak.models.credential.dto.PasswordSecretData` (модуль `keycloak-server-spi`):
  ```java
  if (salt == null || "__SALT__".equals(salt)) { this.value = value; this.salt = null; }
  ```
  → `secretData` без поля `salt` десериализуется корректно; `getPasswordSecretData().getValue()`
  возвращает полный bcrypt-хэш, который читает `verify`.
- Наш `verify(rawPassword, credential)`:
  1. `hash = credential.getPasswordSecretData().getValue()`;
  2. sanity-check cost из префикса (диапазон 4..16 — защита от CPU-DoS при кривом импорте);
  3. `at.favre.lib` verifyer (truncate до 72 байт, как bcryptjs) — распознаёт `$2a/$2b/$2y` из хэша.
- Выбор провайдера при проверке: Keycloak берёт `credentialData.algorithm` (`"bcrypt"`) и ищет
  `PasswordHashProvider` c этим `getId()`.

## Путь импорта

Канонический путь (тот, что использует payload-builder) — **realm `partialImport`**:

```
POST /admin/realms/{realm}/partialImport
{
  "ifResourceExists": "FAIL" | "SKIP" | "OVERWRITE",
  "users": [ { "username": "...", "email": "...", "enabled": true,
              "credentials": [ { ...объект выше... } ] }, ... ]
}
```

Admin API `POST /admin/realms/{realm}/users` (create-user) в тестах используется как мягкая
кросс-проверка того же формата.

## Перехэш после первого входа (важно для миграции)

Realm password policy **остаётся дефолтной (argon2)** — `hashAlgorithm` НЕ задаём. Механика
(`services/PasswordCredentialProvider.rehashPasswordIfRequired`, 26.1.5): после успешного `verify`
Keycloak берёт провайдер **policy/дефолтного** алгоритма (argon2), его `policyCheck` видит
`algorithm=bcrypt` → `false` → **перехэширует пароль в argon2** и перезаписывает credential в БД.
После этого bcrypt для данного пользователя больше не участвует. Когда все активные пользователи вошли
хотя бы раз — bcrypt-провайдер можно снять (см. `README.md`).

## Мини-пример генерации хэша (bcryptjs, cost 12)

Так BillHub формирует `secretData.value` (пароль в чат/лог не выводить):

```js
const bcrypt = require('bcryptjs');
const hash = bcrypt.hashSync(plainPassword, bcrypt.genSaltSync(12)); // "$2b$12$..."
// secretData     = JSON.stringify({ value: hash })
// credentialData = JSON.stringify({ hashIterations: 12, algorithm: 'bcrypt' })
```

> Формат доказан для `$2a`/`$2b`/`$2y` при cost 12 (и 10) на realm `bcrypt-poc`: вход старым паролем
> успешен, после входа `GET users/{id}/credentials` показывает `algorithm=argon2`.
