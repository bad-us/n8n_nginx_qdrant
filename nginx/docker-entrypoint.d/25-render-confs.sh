#!/bin/sh
# ============================================================
#  Рендер конфигов nginx из шаблонов с подстановкой .env-переменных.
#  Запускается автоматически при старте контейнера nginx
#  (официальный entrypoint выполняет /docker-entrypoint.d/*.sh по порядку,
#  этот файл — после штатного envsubst, поэтому он и есть источник истины).
#
#  Логика:
#    - есть сертификат -> рендерим HTTP-редирект + HTTPS
#    - нет сертификата -> рендерим только HTTP (чтобы стек поднялся и
#      certbot смог пройти ACME-челлендж)
#  Повторный запуск вручную (после выпуска сертификата):
#    docker compose exec nginx /docker-entrypoint.d/25-render-confs.sh
#    docker compose exec nginx nginx -t && docker compose exec nginx nginx -s reload
# ============================================================
set -eu

TPL_DIR=/etc/nginx/templates-app
OUT_DIR=/etc/nginx/conf.d
OPT_DIR=/etc/nginx/conf.d-optional
CERT_DIR="/etc/letsencrypt/live/${TLS_CERT_NAME}"

# Список переменных, которые разрешено подставлять.
# Всё остальное (например $host, $remote_addr) nginx оставляет себе.
ENVSUBST_VARS='${N8N_DOMAIN} ${QDRANT_DOMAIN} ${TLS_CERT_NAME} ${N8N_PORT} ${QDRANT_HTTP_PORT} ${NGINX_CLIENT_MAX_BODY_SIZE} ${NGINX_HSTS_MAX_AGE} ${NGINX_ACME_WEBROOT} ${NGINX_TLS_PROTOCOLS} ${NGINX_TLS_CIPHERS} ${NGINX_SERVER_TOKENS}'

mkdir -p "$OPT_DIR" "$OUT_DIR"

# Убираем конфиг по умолчанию из образа и свои предыдущие рендеры
rm -f "$OUT_DIR/default.conf" "$OUT_DIR/10-http.conf" "$OUT_DIR/20-tls.conf"

if [ -f "${CERT_DIR}/fullchain.pem" ] && [ -f "${CERT_DIR}/privkey.pem" ]; then
    TLS_ENABLED=1
else
    TLS_ENABLED=0
fi

if [ "$TLS_ENABLED" = "1" ]; then
    envsubst "$ENVSUBST_VARS" < "$TPL_DIR/10-http-redirect.conf.template" > "$OUT_DIR/10-http.conf"
    envsubst "$ENVSUBST_VARS" < "$TPL_DIR/20-tls.conf.template"          > "$OUT_DIR/20-tls.conf"
else
    envsubst "$ENVSUBST_VARS" < "$TPL_DIR/10-http-only.conf.template"    > "$OUT_DIR/10-http.conf"
fi

# Опциональный basic-auth на Qdrant (только если файл создан)
if [ -s /etc/nginx/htpasswd/.htpasswd ]; then
    printf 'auth_basic "Qdrant";\nauth_basic_user_file /etc/nginx/htpasswd/.htpasswd;\n' > "$OPT_DIR/10-qdrant-auth.conf"
    AUTH=on
else
    rm -f "$OPT_DIR/10-qdrant-auth.conf"
    AUTH=off
fi

echo "[render-confs] TLS=${TLS_ENABLED} cert_name=${TLS_CERT_NAME} basic_auth=${AUTH}"
