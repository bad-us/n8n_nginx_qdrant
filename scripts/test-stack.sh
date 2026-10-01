#!/usr/bin/env bash
# ============================================================
#  Проверка работоспособности и связности стека n8n + nginx + Qdrant.
#  Запуск: ./scripts/test-stack.sh
# ============================================================
set -uo pipefail

cd "$(dirname "$(readlink -f "$0")")/.."

if docker compose version >/dev/null 2>&1; then DC=(docker compose); else DC=(docker-compose); fi

[ -f .env ] && { set -a; . ./.env; set +a; }

ok=0; fail=0
check() { # check "<описание>" <команда...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '  [ OK ] %s\n' "$desc"; ok=$((ok+1))
    else
        printf '  [FAIL] %s\n' "$desc"; fail=$((fail+1))
    fi
}

echo "== Контейнеры =="
"${DC[@]}" ps

echo
echo "== Внутренняя связность =="
check "n8n -> Qdrant (REST /readyz)" \
    "${DC[@]}" exec -T n8n wget -q -O- --header="api-key: ${QDRANT_API_KEY:-}" "http://qdrant:${QDRANT_HTTP_PORT:-6333}/readyz"
check "Qdrant принимает API-ключ" \
    "${DC[@]}" exec -T n8n wget -q -O- --header="api-key: ${QDRANT_API_KEY:-}" "http://qdrant:${QDRANT_HTTP_PORT:-6333}/collections"
check "nginx видит n8n" \
    "${DC[@]}" exec -T nginx wget -q -O- "http://n8n:${N8N_PORT:-5678}/healthz/readiness"
check "nginx видит Qdrant" \
    "${DC[@]}" exec -T nginx wget -q -O- "http://qdrant:${QDRANT_HTTP_PORT:-6333}/readyz"

echo
echo "== Внешние точки входа =="
check "HTTP :${NGINX_HTTP_PORT:-80} отвечает" \
    curl -s -o /dev/null "http://127.0.0.1:${NGINX_HTTP_PORT:-80}/"
check "HTTPS https://${N8N_DOMAIN:-n8n.local}/healthz/readiness" \
    curl -sk -o /dev/null "https://${N8N_DOMAIN:-n8n.local}/healthz/readiness"
check "HTTPS https://${QDRANT_DOMAIN:-qdrant.local}/readyz" \
    curl -sk -o /dev/null "https://${QDRANT_DOMAIN:-qdrant.local}/readyz"

echo
echo "Итого: OK=${ok}, FAIL=${fail}"
[ "$fail" -eq 0 ]
