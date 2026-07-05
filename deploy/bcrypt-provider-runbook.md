# Runbook: bcrypt PasswordHashProvider — сборка, тест, выкат на VPS

Полный набор команд для VPS. Провайдер `bcrypt` нужен для проверки перенесённых из BillHub bcrypt-хэшей
при миграции (KC 26 из коробки bcrypt не проверяет). После первого входа Keycloak сам перехэширует пароль
в argon2 (policy realm остаётся дефолтной). Исходники и контракт — в репозитории `auth`:
`keycloak/providers/bcrypt-spi/`, `keycloak/providers/CREDENTIAL_CONTRACT.md`.

## Факты окружения (подтверждено)

| Параметр | Значение |
|---|---|
| VPS (ssh) | `corpsu@compute-vm-2-8-80-ssd-backend` |
| Чекаут репо на VPS | `~/auth` (`/home/corpsu/auth`) |
| Раскладка Keycloak | `/opt/infra/keycloak` (`docker-compose.yml` + `.env`) |
| Live providers (том `:ro`) | `/opt/infra/keycloak/keycloak/providers` |
| compose-проект | `keycloak` (`command: start`, без `--optimized`) |
| Версия Keycloak (рантайм) | `26.1.5` → jar `keycloak-bcrypt-26.1.5.jar` |
| Docker-сеть | `edge` (общая с infra-nginx и порталами) |
| Health (внутри edge) | `http://keycloak:9000/health/ready` |

> Если docker на VPS доступен только под root — запускай скрипты через `sudo bash …`.
> Соседние порталы (estimat/billhub) не трогаем: `force-recreate` применяется ТОЛЬКО к сервису `keycloak`.

## Результаты этого обновления (2026-07-05)

- Собран минимальный SPI `bcrypt` под KC 26.1.x, исходники + unit-тесты + скрипты закоммичены в `auth`.
- Версия рантайма подтверждена на VPS: **26.1.5**.
- Первая сборка упала из-за `--` в XML-комментарии `pom.xml` (недопустимо в XML) → **исправлено**
  (коммит с фиксом). После `git pull` сборка проходит.
- POC на тест-realm `bcrypt-poc` — следующий шаг (раздел 3 ниже).

---

## 1. Обновить исходники на VPS

```bash
ssh corpsu@compute-vm-2-8-80-ssd-backend
cd ~/auth && git pull
```

## 2. Собрать jar (docker-maven; юнит-тесты гейтят сборку)

```bash
cd ~/auth
bash keycloak/providers/bcrypt-spi/build-jar.sh
# ok → ~/auth/keycloak/providers/bcrypt-spi/target/keycloak-bcrypt-26.1.5.jar
```

Проверить, что jar на месте:

```bash
ls -l ~/auth/keycloak/providers/bcrypt-spi/target/keycloak-bcrypt-26.1.5.jar
```

## 3. Доказать контракт на тест-realm `bcrypt-poc`

Скрипт делает всё сам: preflight (`kc.sh build` c jar в disposable-контейнере) → выкат jar на live KC с
откатом при сбое старта → на realm `bcrypt-poc` импортирует bcrypt-креды (`partialImport`), логинится
паролем (`$2a/$2b/$2y × cost{12,10}`), проверяет перехэш в argon2 → удаляет realm.

```bash
cd ~/auth
bash keycloak/providers/bcrypt-spi/verify-bcrypt-poc.sh
```

Успех: в конце `РЕЗУЛЬТАТ: контракт доказан …`, по каждому пользователю `[ok] … перехэш → argon2`.
Провал → ненулевой код возврата; при незапуске KC скрипт сам откатится (снимет jar, пересоздаст keycloak).

## 4. Диагностика / ручные проверки (по желанию)

```bash
# провайдер зарегистрировался без ошибок:
docker logs keycloak 2>&1 | grep -iE 'bcrypt|error' | tail -20

# health живого KC:
docker run --rm --network edge curlimages/curl:latest -sf http://keycloak:9000/health/ready && echo " READY"

# тест-realm удалён (bcrypt-poc не должно быть):
docker exec keycloak /opt/keycloak/bin/kcadm.sh get realms --fields realm 2>/dev/null | grep -i bcrypt-poc || echo "bcrypt-poc отсутствует — ок"

# что лежит в live providers:
ls -l /opt/infra/keycloak/keycloak/providers/
```

## 5. Боевой su10 (по факту jar уже выкачен шагом 3)

После успешного POC jar остаётся в `/opt/infra/keycloak/keycloak/providers/`, провайдер активен (инертен,
пока никакой credential не использует `algorithm=bcrypt`). Отдельный выкат не нужен. Пере-выкат вручную:

```bash
cp ~/auth/keycloak/providers/bcrypt-spi/target/keycloak-bcrypt-26.1.5.jar /opt/infra/keycloak/keycloak/providers/
cd /opt/infra/keycloak && docker compose -p keycloak up -d --force-recreate keycloak
docker run --rm --network edge curlimages/curl:latest -sf http://keycloak:9000/health/ready && echo " READY"
```

## 6. Удалить провайдер после завершения миграции

Когда все активные пользователи вошли хотя бы раз (bcrypt-креды перехэшированы в argon2):

```bash
rm /opt/infra/keycloak/keycloak/providers/keycloak-bcrypt-*.jar
cd /opt/infra/keycloak && docker compose -p keycloak up -d --force-recreate keycloak
docker run --rm --network edge curlimages/curl:latest -sf http://keycloak:9000/health/ready && echo " READY"
```

## 7. Цикл обновления при правке SPI

```bash
# [DEV] закоммитить и запушить правки:
cd ~/claudeprojects/auth && git add -p && git commit -m "…" && git push

# [VPS] подтянуть, пересобрать, перепроверить:
ssh corpsu@compute-vm-2-8-80-ssd-backend
cd ~/auth && git pull
bash keycloak/providers/bcrypt-spi/build-jar.sh
bash keycloak/providers/bcrypt-spi/verify-bcrypt-poc.sh
```

## 8. Траблшутинг

- **`Non-parseable POM … in comment after two dashes (--)`** — в XML-комментарии `pom.xml` нельзя `--`
  (двойной дефис). Использовать em-dash `—` или переформулировать. Исправлено в текущей версии.
- **`cannot find symbol: class PasswordHashProviderFactory`** — фабрика лежит в артефакте
  `keycloak-server-spi-private` (не в `keycloak-server-spi`). Зависимость добавлена в `pom.xml`. Исправлено.
- **Сборка не видит версию KC** — `build-jar.sh` берёт версию из контейнера `keycloak`; можно задать явно:
  `KC_VERSION=26.1.5 bash keycloak/providers/bcrypt-spi/build-jar.sh`.
- **`docker: permission denied`** — запускать через `sudo bash …` или добавить пользователя в группу docker.
- **POC: `нет jar …`** — сначала выполнить шаг 2 (сборку).
- **POC: `kcadm login не прошёл`** — проверить `KEYCLOAK_ADMIN_USER`/`KEYCLOAK_ADMIN_PASSWORD` (или
  `KC_BOOTSTRAP_ADMIN_*`) в `/opt/infra/keycloak/.env`.
- **target/ принадлежит root** (maven-контейнер пишет от root) — очистка при необходимости:
  `sudo rm -rf ~/auth/keycloak/providers/bcrypt-spi/target`.
