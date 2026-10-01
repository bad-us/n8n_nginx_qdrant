#!/usr/bin/env bash
# ============================================================
#  Генерация секретов и заполнение .env
#  Использование:  ./scripts/gen-secrets.sh [путь_к_env]
#  По умолчанию правит ./.env
#  Уже заполненные (не CHANGE_ME) значения НЕ перезаписывает,
#  если не передан флаг --force
# ============================================================
set -Eeuo pipefail

cd "$(dirname "$(readlink -f "$0")")/.."

ENV_FILE=".env"
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        *)       ENV_FILE="$arg" ;;
    esac
done

if [ ! -f "$ENV_FILE" ]; then
    echo "ОШИБКА: файл $ENV_FILE не найден. Сначала: cp .env.example .env" >&2
    exit 1
fi

# --- генератор случайной строки -------------------------------------------
rand_hex() {
    local bytes="${1:-32}"
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$bytes"
    elif command -v xxd >/dev/null 2>&1; then
        head -c "$bytes" /dev/urandom | xxd -p -c 256
    else
        head -c "$bytes" /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

set_kv() {
    local key="$1" value="$2"
    local current
    current="$(grep -E "^${key}=" "$ENV_FILE" | head -n1 | cut -d= -f2- || true)"

    if [ -n "$current" ] && [ "$current" != "CHANGE_ME" ] && [ "$current" != "CHANGE_ME_TOO" ] && [ "$FORCE" != "1" ]; then
        echo "  = ${key} уже задан — пропускаю"
        return 0
    fi

    if grep -qE "^${key}=" "$ENV_FILE"; then
        # заменяем строку целиком
        sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
    else
        printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
    echo "  + ${key} сгенерирован"
}

echo ">> Генерация секретов в ${ENV_FILE}"
set_kv "N8N_ENCRYPTION_KEY"     "$(rand_hex 32)"
set_kv "QDRANT_API_KEY"         "$(rand_hex 24)"
set_kv "QDRANT_READONLY_API_KEY" "$(rand_hex 24)"

echo ">> Готово."
echo "   N8N_ENCRYPTION_KEY храните в бэкапе: без него не расшифруются credentials n8n."
