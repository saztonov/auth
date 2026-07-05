# keycloak/realm — realm-as-code (keycloak-config-cli)

`su10-realm.yaml` — декларативное описание realm `su10`: клиенты (`estimat`, `billhub`,
`su10-launcher`), их redirect/web-origins, PKCE, мапперы (audience/email/username/roles), клиентские
роли, тема. Источник правды по конфигурации realm — этот файл (руками в консоли тоже можно, но git
первичен).

## Что здесь НЕ описывается
- Пользователи и их пароли.
- LDAP/AD user federation.
- Секреты (пароли БД, client secrets) — подставляются из переменных окружения config-cli
  (`IMPORT_VARSUBSTITUTION_ENABLED`, см. `ESTIMAT_CLIENT_SECRET`/`BILLHUB_CLIENT_SECRET` в `su10-realm.yaml`).

config-cli настроен на `no-delete` (см. `docker-compose.yml`), поэтому вручную созданные сущности,
которых нет в YAML, **не удаляются**.

> **Осторожно с комментариями в `su10-realm.yaml`**: подстановка переменных — это сырая текстовая
> замена по всему файлу (до разбора YAML), она проходит и по комментариям. Placeholder-примеры вида
> «доллар + круглая скобка + `env:ИМЯ`» в комментариях **ломают импорт**, если такой переменной нет
> в `.env` — писать этот синтаксис можно только там, где переменная реально задана.

## Накат

```bash
# на VPS, из /opt/infra/keycloak (Keycloak уже запущен)
docker compose -p keycloak --profile config run --rm config-cli
```

Требует в `.env`: `KEYCLOAK_URL` (http://keycloak:8080), `KEYCLOAK_ADMIN_USER`,
`KEYCLOAK_ADMIN_PASSWORD` (постоянный админ realm master), а также секреты клиентов:
`ESTIMAT_CLIENT_SECRET`, `BILLHUB_CLIENT_SECRET`.

## Как менять
1. Правим `su10-realm.yaml` (например, добавляем клиент нового портала).
2. Накатываем config-cli — команда идемпотентна, можно гонять сколько угодно.
3. Коммитим изменения YAML.

## Заметки по клиентам
- **estimat** / **billhub** — confidential, PKCE S256, редиректы на API-домен, audience mapper. Секрет
  клиента кладётся в `.env` соответствующего **портала** (`OIDC_CLIENT_SECRET`), а здесь — только
  для реконсиляции через переменные окружения config-cli.
- **su10-launcher** — public (SPA), PKCE, редирект на `https://auth.su10.ru/*`.
- Роли `access` — гейт входа для порталов, которые проверяют доступ по роли (EstiMat). Порталы с
  авторизацией в своей БД (BillHub) используют `access` как признак допуска, а роли берут из БД.
