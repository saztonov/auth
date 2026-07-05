#!/usr/bin/env bash
# Экспорт конфига realm su10 (users:skip — realm-as-code уже в git, это доп. страховка на состояние
# ЖИВОГО realm перед миграцией/рискованной операцией). Кладёт экспорт в ${KC_DIR}/backups/.
#
#   bash keycloak/realm/export-realm-backup.sh
set -euo pipefail
set +x

KC_DIR="${KC_DIR:-/opt/infra/keycloak}"
KC_CONTAINER="${KC_CONTAINER:-keycloak}"
REALM="${REALM:-su10}"
BACKUP_DIR="${BACKUP_DIR:-${KC_DIR}/backups}"

fail() { echo "!! $*" >&2; exit 1; }
info() { echo "==> $*"; }

command -v docker >/dev/null || fail "docker не найден"
docker ps --format '{{.Names}}' | grep -qx "${KC_CONTAINER}" || fail "контейнер '${KC_CONTAINER}' не запущен"

STAMP="$(docker exec "${KC_CONTAINER}" date +%Y%m%d-%H%M%S)"
TMP_DIR="/tmp/su10-export-${STAMP}"
DEST="${BACKUP_DIR}/su10-realm-export-${STAMP}"

info "экспорт realm ${REALM} (--users skip) внутри контейнера"
docker exec "${KC_CONTAINER}" /opt/keycloak/bin/kc.sh export --dir "${TMP_DIR}" --realm "${REALM}" --users skip

mkdir -p "${BACKUP_DIR}"
docker cp "${KC_CONTAINER}:${TMP_DIR}" "${DEST}"
docker exec "${KC_CONTAINER}" rm -rf "${TMP_DIR}"

[[ -d "${DEST}" ]] || fail "экспорт не найден по ${DEST}"
info "[ok] realm-export: ${DEST}"
ls -la "${DEST}"
