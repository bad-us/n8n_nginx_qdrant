#!/usr/bin/env bash
# ============================================================
#  Первичный выпуск сертификатов Let's Encrypt и включение HTTPS.
#
#  Что делает:
#    1. поднимает nginx в HTTP-режиме;
#    2. выпускает один сертификат на N8N_DOMAIN + QDRANT_DOMAIN;
#    3. перерендеривает конфиги nginx в HTTPS-режим и перезагружает его;
#    4. поднимает весь стек + контейнер автопродления (profile tls).
#
#  Запуск (из корня проекта):   sudo ./scripts/init-letsencrypt.sh
#  Тест на staging (не тратит лимиты LE): LETSENCRYPT_STAGING=1 sudo -E ./scripts/init-letsencrypt.sh
# ============================================================
set -Eeuo pipefail

cd "$(dirname "$(readlink -f "$0")")/.."

# --- определение docker compose -------------------------------------------
if docker compose version >/dev/null 2>&1; then
    DC=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
    DC=(docker-compose)
else
    echo "ОШИБКА: не найден 'docker compose' (плагин) или 'docker-compose'." >&2
    exit 1
fi

# --- .env ------------------------------------------------------------------
[ -f .env ] || { echo "ОШИБКА: нет файла .env. Сделайте: cp .env.example .env && nano .env" >&2; exit 1; }
set -a
# shellcheck disable=SC1091
. ./.env
set +a

: "${N8N_DOMAIN:?N8N_DOMAIN не задан в .env}"
: "${QDRANT_DOMAIN:?QDRANT_DOMAIN не задан в .env}"
: "${TLS_CERT_NAME:?TLS_CERT_NAME не задан в .env}"
: "${LETSENCRYPT_EMAIL:?LETSENCRYPT_EMAIL не задан в .env}"
: "${NGINX_ACME_WEBROOT:=/var/www/certbot}"

echo "=================================================================="
echo " Домены      : ${N8N_DOMAIN}, ${QDRANT_DOMAIN}"
echo " Cert-name   : ${TLS_CERT_NAME}"
echo " E-mail      : ${LETSENCRYPT_EMAIL}"
echo " Staging     : ${LETSENCRYPT_STAGING:-0}"
echo "=================================================================="

# --- 1. nginx в HTTP-режиме -------------------------------------------------
echo ">> [1/5] Поднимаю nginx (HTTP-режим)…"
"${DC[@]}" up -d nginx

echo ">> Жду, пока nginx начнёт отвечать на :80 …"
READY=0
for i in $(seq 1 30); do
    if "${DC[@]}" exec -T nginx wget -q --spider "http://127.0.0.1/" >/dev/null 2>&1; then
        echo "   nginx готов (попытка ${i})"
        READY=1
        break
    fi
    sleep 2
done
if [ "$READY" != "1" ]; then
    echo "ОШИБКА: nginx не поднялся. Логи: ${DC[*]} logs nginx" >&2
    exit 1
fi

# --- 2. выпуск сертификата --------------------------------------------------
echo ">> [2/5] Запрашиваю сертификат Let's Encrypt…"
CERTBOT_ARGS=(
    certonly
    --webroot -w "${NGINX_ACME_WEBROOT}"
    --email "${LETSENCRYPT_EMAIL}"
    --agree-tos
    --no-eff-email
    --non-interactive
    --keep-until-expiring
    --cert-name "${TLS_CERT_NAME}"
    -d "${N8N_DOMAIN}"
    -d "${QDRANT_DOMAIN}"
)
if [ "${LETSENCRYPT_STAGING:-0}" = "1" ]; then
    CERTBOT_ARGS+=(--staging)
fi

"${DC[@]}" --profile tls run --rm --entrypoint certbot certbot "${CERTBOT_ARGS[@]}"

# --- 3. переключение nginx в HTTPS -----------------------------------------
echo ">> [3/5] Рендерю HTTPS-конфиги nginx…"
"${DC[@]}" exec -T nginx /docker-entrypoint.d/25-render-confs.sh
"${DC[@]}" exec -T nginx nginx -t
"${DC[@]}" exec -T nginx nginx -s reload

# --- 4. поднимаем весь стек -------------------------------------------------
echo ">> [4/5] Поднимаю весь стек…"
"${DC[@]}" --profile tls up -d

# --- 5. проверка ------------------------------------------------------------
echo ">> [5/5] Проверка…"
sleep 5
"${DC[@]}" ps

echo
echo "=================================================================="
echo " Готово."
echo "   n8n    : https://${N8N_DOMAIN}"
echo "   Qdrant : https://${QDRANT_DOMAIN}/dashboard"
echo " Проверка стека: ./scripts/test-stack.sh"
echo "=================================================================="
