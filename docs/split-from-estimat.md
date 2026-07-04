# Вынос Keycloak из репозитория EstiMat

Инфраструктура Keycloak переезжает в этот репозиторий (`auth`). В EstiMat остаётся **только сметный
портал**. Ниже — что перенесено и что убрать из EstiMat.

## Перенесено в `auth`

| Было в EstiMat | Стало в `auth` |
|---|---|
| `deploy/infra-keycloak/docker-compose.yml` | `docker-compose.yml` (+ mount тем/providers, config-cli) |
| `deploy/infra-keycloak/.env.example` | `.env.example` (+ переменные config-cli) |
| `deploy/infra-keycloak/README.md` | `docs/deployment.md` + `README.md` |
| `deploy/infra-nginx/conf.d/keycloak.conf` | `deploy/nginx/conf.d/auth.conf` (+ маршрут витрины) |
| `deploy/keycloak-ad-integration-guide.md` | `docs/ad-integration-guide.md` (обобщён на EstiMat + BillHub) |

Новое, чего в EstiMat не было: кастомная тема (`keycloak/themes/su10`), realm-as-code
(`keycloak/realm`), SPA-витрина (`launcher`), провайдеры (`keycloak/providers`).

## Что удалить из EstiMat

После того как `auth` развёрнут и проверен, из `C:\Users\Usr\EstiMat` удалить:

```
deploy/infra-keycloak/                       # весь каталог
deploy/infra-nginx/conf.d/keycloak.conf
deploy/keycloak-ad-integration-guide.md
```

И вычистить упоминания Keycloak-инфры из EstiMat-доков (`deploy/README.md`, при наличии — секции про
`infra-keycloak`), оставив лишь ссылку: «Keycloak-контур вынесен в репозиторий `auth`».

> Важно: **на VPS ничего не переносится физически** — Keycloak уже работает в `/opt/infra/keycloak`.
> Меняется только источник правды: теперь этот каталог деплоится из репозитория `auth`
> (`deploy-auth.sh`), а не из EstiMat. `deploy-estimat` Keycloak и так не трогал.

## Что в EstiMat остаётся (и появится на этапе OIDC)

EstiMat как OIDC-клиент `estimat` реализует у себя (Этап 2 EstiMat, отдельно):
- OIDC redirect-поток (login/callback/logout), проверку токена по JWKS `auth.su10.ru`;
- `OIDC_CLIENT_SECRET` в своём `estimat.env`.

Конфигурация клиента `estimat` (redirect URIs, мапперы, audience) ведётся **здесь**, в
`keycloak/realm/su10-realm.yaml`, а не в EstiMat.

## Порядок

1. Развернуть и проверить `auth` (тема, витрина, realm, деплой).
2. Убедиться, что вход/discovery работают через `auth.su10.ru`.
3. Удалить перечисленные файлы из EstiMat, обновить его доки, отдельный коммит в EstiMat
   («chore: вынос Keycloak-инфры в репозиторий auth»).
