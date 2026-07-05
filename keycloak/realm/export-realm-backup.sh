#!/usr/bin/env bash
# Экспорт конфига realm su10 (--users skip — realm-as-code уже в git, это доп. страховка на состояние
# ЖИВОГО realm перед миграцией/рискованной операцией).
#
# ВАЖНО: `kc.sh export` — полноценный запуск Quarkus-рантайма, пытается забиндить порты 8080/9000. Через
# `docker exec` в УЖЕ РАБОТАЮЩИЙ keycloak это конфликтует с live-процессом (тот же network namespace →
# "Address already in use"), хотя сами данные экспортируются успешно ДО этого краха. Поэтому экспорт
# запускается в ОТДЕЛЬНОМ одноразовом контейнере (тот же образ и БД, свой namespace — конфликта нет).
#
#   bash keycloak/realm/export-realm-backup.sh
set -euo pipefail
set +x

KC_DIR="${KC_DIR:-/opt/infra/keycloak}"
KC_CONTAINER="${KC_CONTAINER:-keycloak}"
EDGE_NET="${EDGE_NET:-edge}"
REALM="${REALM:-su10}"
BACKUP_DIR="${BACKUP_DIR:-${KC_DIR}/backups}"

fail() { echo "!! $*" >&2; exit 1; }
info() { echo "==> $*"; }

command -v docker >/dev/null || fail "docker не найден"
[[ -f "${KC_DIR}/.env" ]] || fail "нет ${KC_DIR}/.env"
docker ps --format '{{.Names}}' | grep -qx "${KC_CONTAINER}" || fail "контейнер '${KC_CONTAINER}' не запущен"

# ${KC_DIR} обычно root-owned (как .env) — проверяем запись в BACKUP_DIR ДО дорогого docker create/start
# (сам экспорт занимает ~15-20с), чтобы не гонять его вхолостую при нехватке прав.
if [[ ! -d "${BACKUP_DIR}" ]]; then
  mkdir -p "${BACKUP_DIR}" 2>/dev/null || fail "нет прав создать ${BACKUP_DIR} — разово:
  sudo mkdir -p ${BACKUP_DIR} && sudo chown \$(whoami):docker ${BACKUP_DIR} && sudo chmod 750 ${BACKUP_DIR}"
fi
[[ -w "${BACKUP_DIR}" ]] || fail "нет прав на запись в ${BACKUP_DIR} (см. подсказку chown/chmod выше)"

KC_IMAGE="$(docker inspect --format '{{.Config.Image}}' "${KC_CONTAINER}")"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="${BACKUP_DIR}/su10-realm-export-${STAMP}"

info "экспорт realm ${REALM} (--users skip) во временном контейнере ${KC_IMAGE} — та же БД, live keycloak не трогаем"
# --env-file читает секреты (KC_DB_URL/USERNAME/PASSWORD) напрямую из файла — в команду они не попадают,
# в вывод не печатаются. KC_DB=postgres — литерал из docker-compose.yml (в .env его нет).
CID="$(docker create --network "${EDGE_NET}" --env-file "${KC_DIR}/.env" -e KC_DB=postgres \
  "${KC_IMAGE}" export --dir /tmp/export --realm "${REALM}" --users skip)"
trap 'docker rm -f "${CID}" >/dev/null 2>&1 || true' EXIT

docker start -a "${CID}" || fail "экспорт упал — см. лог выше (временный контейнер будет убран автоматически)"

docker cp "${CID}:/tmp/export" "${DEST}"

[[ -d "${DEST}" ]] || fail "экспорт не найден по ${DEST}"
info "[ok] realm-export: ${DEST}"
ls -la "${DEST}"
info "⚠️ экспорт содержит client secrets в открытом виде (штатное поведение kc.sh export) — держите"
info "   ${BACKUP_DIR} с ограниченными правами доступа, как .env (не публиковать/не коммитить)."
