# auth — корпоративный Identity Provider контура su10 (Keycloak)

Отдельный репозиторий, отвечающий за **всю аутентификацию** контура su10: Keycloak (realm `su10`),
кастомная тема входа/пароля, SPA-витрина порталов, интеграция с AD и деплой на VPS.

Порталы (EstiMat — сметный, BillHub и будущие) сюда **не** входят: они живут в своих
репозиториях и подключаются к этому Keycloak как OIDC-клиенты. Настройки клиентов/ролей/мапперов —
здесь, в `keycloak/realm/`.

## Что в репозитории

| Каталог | Назначение |
|---|---|
| `docker-compose.yml`, `.env.example` | Keycloak (образ 26.1, БД `keycloak_db` в Yandex Managed PG, сеть `edge`) |
| `keycloak/themes/su10/` | Кастомная тема: страницы входа и Account Console (брендинг su10) |
| `keycloak/providers/` | Кастомные SPI (в т.ч. bcrypt-провайдер для миграции паролей BillHub) |
| `keycloak/realm/` | realm-as-code: клиенты `estimat`/`billhub`/`su10-launcher`, роли, мапперы (keycloak-config-cli) |
| `launcher/` | SPA-витрина порталов (Vite + React, OIDC-клиент `su10-launcher`): плитки порталов, вход, «сменить пароль» |
| `deploy/` | `deploy-auth.sh` + ingress-конфиг nginx (`auth.su10.ru`, `auth-admin.su10.ru`) |
| `docs/` | Архитектура, деплой, гайд по AD, что убрать из EstiMat |

## Домены

- **`auth.su10.ru`** — публичный. `/` → SPA-витрина; `/realms/`, `/resources/`, `/js/` → Keycloak
  (форма входа, Account Console, OIDC discovery, JWKS).
- **`auth-admin.su10.ru`** — админ-консоль Keycloak, только из доверенной сети (VPN/allowlist).

## Быстрый старт (локально)

```bash
cp .env.example .env            # заполнить секреты (в git не попадает)
docker compose up -d keycloak   # поднять Keycloak
docker compose --profile config run --rm config-cli   # накатить realm из keycloak/realm/
cd launcher && npm ci && npm run dev                   # витрина на http://localhost:5173
```

Полная схема окружения и деплой — в [docs/architecture.md](docs/architecture.md) и
[docs/deployment.md](docs/deployment.md). Что и как убрать из репозитория EstiMat —
[docs/split-from-estimat.md](docs/split-from-estimat.md).

> Секреты (пароль БД, bootstrap-админ, client secrets) в git не хранятся и в чат не выводятся.
> Только `.env.example` с плейсхолдерами.
