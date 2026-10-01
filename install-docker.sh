#!/usr/bin/env bash
# ============================================================
#  Установка Docker Engine + Compose plugin на Debian
#  (официальный репозиторий Docker, актуальный способ 2026)
#
#  Запуск:  sudo bash install-docker.sh
#  Поддерживается: Debian 11 (bullseye), 12 (bookworm), 13 (trixie)
# ============================================================
set -Eeuo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ОШИБКА: запускать от root (sudo bash install-docker.sh)" >&2
    exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release

if [ "${ID:-}" != "debian" ] && [ "${ID_LIKE:-}" != "debian" ]; then
    echo "ВНИМАНИЕ: дистрибутив '${ID:-unknown}' не Debian — скрипт рассчитан на Debian." >&2
fi

echo ">> [1/7] Удаляю старые/конфликтующие пакеты (если есть)…"
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
    apt-get remove -y "$pkg" >/dev/null 2>&1 || true
done

echo ">> [2/7] Ставлю зависимости…"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg

echo ">> [3/7] Добавляю GPG-ключ Docker…"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo ">> [4/7] Добавляю репозиторий Docker (${VERSION_CODENAME})…"
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

echo ">> [5/7] Устанавливаю Docker Engine и Compose plugin…"
apt-get update -qq
apt-get install -y -qq \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

echo ">> [6/7] Настраиваю автозапуск и лимиты логов…"
mkdir -p /etc/docker
if [ ! -f /etc/docker/daemon.json ]; then
    cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "5"
  },
  "live-restore": true
}
JSON
    echo "   создан /etc/docker/daemon.json"
else
    echo "   /etc/docker/daemon.json уже существует — не трогаю"
fi

systemctl enable --now docker
systemctl restart docker

echo ">> [7/7] Добавляю пользователя ${SUDO_USER:-root} в группу docker…"
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    usermod -aG docker "${SUDO_USER}"
    echo "   ${SUDO_USER} добавлен в группу docker (нужен повторный вход в сессию)"
fi

echo
echo "=================================================================="
echo " Версии:"
docker --version
docker compose version
echo "=================================================================="
echo " Проверка:  docker run --rm hello-world"
echo " Если работаете под ${SUDO_USER:-root} — перелогиньтесь, чтобы применилась группа docker."
echo "=================================================================="
