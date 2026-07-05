#!/usr/bin/env bash
# Сборка bcrypt PasswordHashProvider (jar) БЕЗ установки java/maven на хост — временным docker-maven.
# Запускать на VPS из чекаута репозитория (там есть docker; на dev-машине java/maven/docker нет).
#
#   bash keycloak/providers/bcrypt-spi/build-jar.sh
#
# Версия Keycloak определяется из ЖИВОГО контейнера keycloak (в compose плавающий тег 26.1) — jar
# собирается строго под неё. Тесты гоняются при сборке и гейтят артефакт.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
KC_CONTAINER="${KC_CONTAINER:-keycloak}"
MAVEN_IMAGE="${MAVEN_IMAGE:-maven:3.9-eclipse-temurin-21}"

# --- 1. Детект версии рантайма Keycloak ---
KC_VERSION="${KC_VERSION:-}"
if [[ -z "${KC_VERSION}" ]]; then
  if docker ps --format '{{.Names}}' | grep -qx "${KC_CONTAINER}"; then
    KC_VERSION="$(docker exec "${KC_CONTAINER}" /opt/keycloak/bin/kc.sh --version 2>/dev/null \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  fi
fi
if [[ -z "${KC_VERSION}" ]]; then
  KC_VERSION="26.1.5"
  echo "!! Не удалось определить версию из контейнера '${KC_CONTAINER}'. Fallback KC_VERSION=${KC_VERSION}."
  echo "   (можно задать явно: KC_VERSION=26.1.x bash $0)"
fi
echo "==> Собираем провайдер под Keycloak ${KC_VERSION}"

# --- 2. Сборка временным docker-maven (кэш ~/.m2 монтируем для скорости, если есть) ---
M2_MOUNT=()
if [[ -d "${HOME}/.m2" ]]; then
  M2_MOUNT=(-v "${HOME}/.m2:/root/.m2")
fi

docker run --rm \
  -v "${REPO_ROOT}:/w" \
  "${M2_MOUNT[@]}" \
  -w /w/keycloak/providers/bcrypt-spi \
  "${MAVEN_IMAGE}" \
  mvn -q -Dkeycloak.version="${KC_VERSION}" package

JAR="${SCRIPT_DIR}/target/keycloak-bcrypt-${KC_VERSION}.jar"
if [[ -f "${JAR}" ]]; then
  echo "==> Готово: ${JAR}"
  echo "    Дальше — доказательство контракта: bash ${SCRIPT_DIR}/verify-bcrypt-poc.sh"
else
  echo "!! jar не найден по ожидаемому пути: ${JAR}" >&2
  ls -1 "${SCRIPT_DIR}/target/" 2>/dev/null | sed 's/^/    target\//' >&2 || true
  exit 1
fi
