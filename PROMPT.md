# PROMPT — задача для модели, работающей в репозитории `auth`

> Отдать этот файл вайбкодинг-модели в новом проекте `auth` (VS Code открыт на
> `C:\Users\Usr\claudeprojects\auth`; для справки подключить папку `C:\Users\Usr\EstiMat`).
> Правила проекта — в `CLAUDE.md`. Секреты в чат не выводить.

## Контекст

Контур su10 переходит на единый корпоративный Keycloak (realm `su10`). Keycloak **уже развёрнут и
работает** на VPS (`backend-vps-1`, `/opt/infra/keycloak`, образ 26.1) + Yandex Managed PostgreSQL
(БД `keycloak_db`). Публичный домен `auth.su10.ru`, админка `auth-admin.su10.ru` (VPN allowlist).

Этот репозиторий становится **источником правды** по всей аутентификации: инфраструктура Keycloak,
кастомная тема, realm-as-code (клиенты/роли/мапперы) и **SPA-витрина порталов**. Порталы EstiMat
(сметный) и BillHub — отдельные репозитории, подключаются как OIDC-клиенты. Из EstiMat инфра
Keycloak убирается (см. `docs/split-from-estimat.md`).

Скелет уже создан. Твоя работа — довести его до рабочего состояния и развернуть.

## Цель этого этапа

1. **Витрина `launcher/`** — SPA на `auth.su10.ru`, где сотрудник (свой или подрядчика):
   - входит через Keycloak (OIDC Authorization Code + PKCE, клиент `su10-launcher`);
   - видит **плитки доступных ему порталов** со ссылками;
   - может **сменить пароль / настроить MFA** (deep-link в Account Console `/realms/su10/account`);
   - регистрируется — **по приглашению** (invite/registration-token), не открытая регистрация.
2. **Тема `keycloak/themes/su10/`** — брендинг страниц входа и Account Console под su10.
3. **realm-as-code `keycloak/realm/su10-realm.yaml`** — привести клиентов `estimat`, `billhub`,
   `su10-launcher`, роли и мапперы к описанному состоянию через keycloak-config-cli.
4. **Деплой `deploy/deploy-auth.sh`** — выкатить тему, витрину и realm на VPS, обновить ingress.

## Задачи по порядку

1. **Витрина (основной объём кода):**
   - `launcher/src/auth/oidc.ts` — конфиг `react-oidc-context` (issuer `https://auth.su10.ru/realms/su10`,
     client `su10-launcher`, `redirect_uri` = origin, scope `openid profile email`, PKCE).
   - `launcher/src/config/portals.ts` — список порталов (name, url, иконка, опц. `requiredRole`).
   - `launcher/src/pages/Launcher.tsx` — плитки; фильтрация по `requiredRole`, если роль есть в
     токене (иначе показывать все); кнопки «Сменить пароль» и «Выйти».
   - Логаут через end-session Keycloak. Обработка callback на корне.
2. **Клиент `su10-launcher`** в `keycloak/realm/su10-realm.yaml`: public, PKCE S256, redirect
   `https://auth.su10.ru/*`, web origins `https://auth.su10.ru`. Плюс сверить клиентов `estimat`/`billhub`.
3. **Тема:** оформить `login/` (форма входа) и `account/` под su10. Проверить рестартом контейнера.
4. **ingress:** `deploy/nginx/conf.d/auth.conf` — `/realms/`,`/resources/`,`/js/` → Keycloak, `/` → витрина.
5. **Деплой:** `deploy/deploy-auth.sh` — rsync инфры в `/opt/infra/keycloak`, сборка витрины →
   `/opt/infra/launcher/dist`, копия ingress + `nginx -s reload`, `docker compose -p keycloak up -d`,
   накат realm через keycloak-config-cli.
6. **Invite-регистрация** подрядчиков — спроектировать (Keycloak registration flow с обязательной
   верификацией email / invite-link, либо провижининг из портала по token). Описать в
   `docs/architecture.md`, реализовать минимальный вариант.

## Критерии готовности

- [ ] `https://auth.su10.ru` открывает витрину; неавторизованного редиректит на вход Keycloak.
- [ ] После входа видны плитки порталов; клик ведёт на портал (SSO — без повторного пароля).
- [ ] «Сменить пароль» открывает Account Console; смена работает.
- [ ] Тема входа/Account Console — в брендинге su10.
- [ ] `keycloak-config-cli` идемпотентно приводит realm к `su10-realm.yaml` без ручных правок.
- [ ] `deploy-auth.sh` выкатывает всё вышеперечисленное на VPS.

## Ограничения

- Realm `su10` — общий; не пересоздавать, только реконсилить. Пользователей/AD-федерацию в
  realm-as-code не описывать.
- Секреты — только в `.env`/секрет-сторедже VPS, не в git и не в чат.
- Не трогать конфиги и сертификаты соседних сервисов (`estimat.su10.ru`, сами порталы).
