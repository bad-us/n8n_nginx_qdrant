# Стек n8n + nginx + Qdrant на Debian

Готовый production-стек: **n8n** (автоматизация), **Qdrant** (векторная БД), **nginx** (единая точка входа, TLS).
Все параметры — в одном файле `.env`. Сервисы связаны внутренними Docker-сетями и общаются друг с другом по именам.

---

## 1. Архитектура

```
                    Internet
                       │
              ┌────────▼────────┐
              │  nginx  :80/443 │  TLS-терминация, реверс-прокси
              └───┬─────────┬───┘
                  │         │
   https://n8n... │         │ https://qdrant...
                  │         │
        ┌─────────▼──┐   ┌──▼─────────┐
        │    n8n     │   │   Qdrant   │
        │  :5678     │──▶│  :6333     │   n8n → Qdrant по внутренней сети
        └────────────┘   └────────────┘
             │  сеть edge (интернет) + сеть data (внутренняя)
             │
        ┌────▼─────┐
        │ certbot  │  выпуск и автопродление Let's Encrypt (profile: tls)
        └──────────┘
```

**Сети:**

| Сеть | Тип | Участники | Назначение |
|---|---|---|---|
| `edge` | bridge, есть выход в интернет | nginx, n8n, certbot | внешний трафик, ACME, вызовы внешних API из n8n |
| `data` | bridge, `internal: true` | n8n, nginx, qdrant | обмен n8n ↔ Qdrant, проксирование nginx → Qdrant. Наружу выхода нет |

**Тома:** `n8n_data`, `qdrant_data`, `letsencrypt_certs`, `certbot_www`, `nginx_cache`
**Bind-mount:** `./data/n8n/files` (файлы n8n), `./data/qdrant/snapshots` (снапшоты Qdrant)

Порты `5678` (n8n) и `6333/6334` (Qdrant) **наружу не публикуются** — доступ только через nginx.
Раскомментируйте блоки `ports:` в `docker-compose.yml`, если нужен доступ с localhost для отладки.

---

## 2. Структура проекта

```
n8n-stack/
├── docker-compose.yml                     # описание стека
├── .env.example                           # ВСЕ переменные (копируется в .env)
├── install-docker.sh                      # установка Docker Engine + Compose на Debian
├── README.md
├── scripts/
│   ├── gen-secrets.sh                     # генерация N8N_ENCRYPTION_KEY, QDRANT_API_KEY
│   ├── init-letsencrypt.sh                # выпуск сертификата + подъём стека в HTTPS
│   └── test-stack.sh                      # проверка связности всех компонентов
├── nginx/
│   ├── templates/                         # шаблоны конфигов (подстановка переменных из .env)
│   │   ├── 10-http-only.conf.template     # HTTP-режим (пока нет сертификата)
│   │   ├── 10-http-redirect.conf.template # :80 → :443 + ACME
│   │   └── 20-tls.conf.template           # HTTPS-виртхосты n8n и Qdrant
│   ├── snippets/proxy-params.conf         # общие параметры проксирования (WebSocket и т.д.)
│   ├── conf.d/00-upgrade-map.conf         # map для WebSocket-апгрейда
│   ├── docker-entrypoint.d/25-render-confs.sh   # рендер конфигов при старте nginx
│   └── htpasswd/                          # опциональный basic-auth на Qdrant
└── data/
    ├── n8n/files/                         # файлы n8n (bind-mount /files)
    └── qdrant/snapshots/                  # снапшоты Qdrant
```

---

## 3. Требования

- Debian 11/12/13, root или sudo
- Открытые порты **80** и **443** (для ACME-челленджа и HTTPS)
- Два DNS-имени (A-записи) на IP сервера: например `n8n.example.com` и `qdrant.example.com`
- Минимум 2 GB RAM, 2 vCPU, 20 GB диска

Проверка DNS до запуска (обе команды должны вернуть IP сервера):

```bash
dig +short n8n.example.com
dig +short qdrant.example.com
```

---

## 4. Установка Docker (Debian)

```bash
sudo bash install-docker.sh
```

Скрипт делает всё по официальной схеме: удаляет конфликтующие пакеты, добавляет GPG-ключ и репозиторий
`download.docker.com/linux/debian`, ставит `docker-ce`, `docker-ce-cli`, `containerd.io`,
`docker-buildx-plugin`, `docker-compose-plugin`, включает автозапуск и настраивает ротацию логов
в `/etc/docker/daemon.json`.

Проверка:

```bash
docker --version
docker compose version
docker run --rm hello-world
```

> После установки пользователь добавлен в группу `docker` — перелогиньтесь, чтобы работать без `sudo`.

Ручной вариант (если не хотите запускать скрипт):

```bash
sudo apt-get update && sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo tee /etc/apt/keyrings/docker.asc >/dev/null
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
| sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
```

---

## 5. Быстрый старт (пошагово)

```bash
# 1. Распаковать и зайти в каталог
cd n8n-stack

# 2. Создать .env из шаблона
cp .env.example .env
nano .env
```

Заполните как минимум:

| Переменная | Пример | Комментарий |
|---|---|---|
| `N8N_DOMAIN` | `n8n.example.com` | A-запись уже должна указывать на сервер |
| `QDRANT_DOMAIN` | `qdrant.example.com` | то же |
| `TLS_CERT_NAME` | `n8n.example.com` | **должно совпадать с `N8N_DOMAIN`** |
| `LETSENCRYPT_EMAIL` | `admin@example.com` | реальный e-mail |
| `TZ` | `Europe/Berlin` | часовой пояс |

```bash
# 3. Сгенерировать секреты (N8N_ENCRYPTION_KEY, QDRANT_API_KEY, QDRANT_READONLY_API_KEY)
./scripts/gen-secrets.sh

# 4. Права на скрипты и каталоги данных
chmod +x install-docker.sh scripts/*.sh nginx/docker-entrypoint.d/*.sh
sudo chown -R 1000:1000 data/n8n/files

# 5. Поднять стек и выпустить сертификаты (HTTP-режим -> HTTPS)
sudo ./scripts/init-letsencrypt.sh

# 6. Проверить связность
./scripts/test-stack.sh
```

После шага 5:

- n8n — `https://n8n.example.com`
- Qdrant Dashboard — `https://qdrant.example.com/dashboard`

**Первый вход в n8n:** откройте URL, создайте owner-аккаунт (e-mail + пароль) — это единственный администратор инстанса.

### Альтернатива без домена (локальный тест по IP)

```bash
# в .env:
N8N_DOMAIN=localhost
QDRANT_DOMAIN=localhost
N8N_PROTOCOL=http
N8N_SECURE_COOKIE=false
NGINX_HTTP_PORT=80
# затем:
docker compose up -d
```
HTTPS в этом варианте не настраивается (`init-letsencrypt.sh` не запускаем).

---

## 6. Как это работает

### 6.1 Маршрутизация nginx

Конфиги **не редактируются вручную** — они рендерятся из шаблонов `nginx/templates/*.template`
скриптом `nginx/docker-entrypoint.d/25-render-confs.sh` при каждом старте контейнера:

- сертификата нет → рендерится `10-http-only.conf` (оба домена на :80, ACME-челлендж доступен);
- сертификат есть → рендерятся `10-http-redirect.conf` (:80 → :443 + ACME) и `20-tls.conf` (:443 для n8n и Qdrant).

Подстановка значений идёт из переменных окружения контейнера, которые берутся из `.env`.
Ручной повторный рендер после выпуска сертификата:

```bash
docker compose exec nginx /docker-entrypoint.d/25-render-confs.sh
docker compose exec nginx nginx -t
docker compose exec nginx nginx -s reload
```

Резолвинг апстримов — динамический (`resolver 127.0.0.11` + `set $upstream …`), поэтому nginx
не падает при старте, если n8n ещё не поднялся, и подхватывает смену IP контейнера без рестарта.

### 6.2 Связка n8n ↔ Qdrant

n8n видит Qdrant по внутреннему DNS-имени `qdrant:6333`. Переменные уже прокинуты в контейнер n8n:

```
QDRANT_URL     = http://qdrant:6333
QDRANT_API_KEY = <значение из .env>
```

Доступны в выражениях как `{{ $env.QDRANT_URL }}` и `{{ $env.QDRANT_API_KEY }}`.

**Настройка в n8n (UI):**

1. *Credentials → Add credential → Qdrant API*
   - **URL**: `http://qdrant:6333`
   - **API Key**: значение `QDRANT_API_KEY` из `.env`
2. Либо используйте ноду **Qdrant Vector Store** (встроена в n8n) с теми же параметрами.

**Проверка изнутри n8n (быстрый тест):**

```bash
docker compose exec n8n wget -qO- --header="api-key: $QDRANT_API_KEY" http://qdrant:6333/collections
```

**Проверка снаружи (через nginx):**

```bash
curl -H "api-key: $QDRANT_API_KEY" https://qdrant.example.com/collections
```

### 6.3 Безопасность

- Qdrant закрыт API-ключом (`QDRANT__SERVICE__API_KEY`), порт наружу не публикуется.
- Внутренняя сеть `data` — `internal: true`, без выхода в интернет.
- nginx: TLS 1.2/1.3, HSTS, `server_tokens off`, ограничение размера тела запроса.
- n8n: `N8N_ENCRYPTION_KEY` (шифрование credentials), secure-cookie, привязка к домену.

**Дополнительно — basic-auth на Qdrant Dashboard** (рекомендуется, если домен публичный):

```bash
sudo apt-get install -y apache2-utils
htpasswd -c nginx/htpasswd/.htpasswd admin
docker compose exec nginx /docker-entrypoint.d/25-render-confs.sh
docker compose exec nginx nginx -s reload
```
Файл `nginx/htpasswd/.htpasswd` подхватывается автоматически, пока он существует и не пуст.

---

## 7. Справочник переменных `.env`

### Общие

| Переменная | По умолчанию | Описание |
|---|---|---|
| `COMPOSE_PROJECT_NAME` | `n8n-stack` | имя проекта Compose |
| `TZ` | `Europe/Berlin` | часовой пояс всех контейнеров |

### Домены и TLS

| Переменная | По умолчанию | Описание |
|---|---|---|
| `N8N_DOMAIN` | `n8n.example.com` | домен n8n |
| `QDRANT_DOMAIN` | `qdrant.example.com` | домен Qdrant |
| `TLS_CERT_NAME` | `n8n.example.com` | имя линии сертификата, **= N8N_DOMAIN** |
| `LETSENCRYPT_EMAIL` | — | e-mail для Let's Encrypt |
| `LETSENCRYPT_STAGING` | `0` | `1` — тестовый контур LE (не доверенный сертификат) |

### Порты

| Переменная | По умолчанию | Описание |
|---|---|---|
| `NGINX_HTTP_PORT` | `80` | публикуемый HTTP |
| `NGINX_HTTPS_PORT` | `443` | публикуемый HTTPS |
| `N8N_PORT` | `5678` | внутренний порт n8n |
| `QDRANT_HTTP_PORT` | `6333` | REST/dashboard Qdrant |
| `QDRANT_GRPC_PORT` | `6334` | gRPC Qdrant |

### Секреты

| Переменная | Описание |
|---|---|
| `N8N_ENCRYPTION_KEY` | ключ шифрования credentials n8n. **Не менять после первого запуска.** |
| `QDRANT_API_KEY` | полный ключ доступа к Qdrant |
| `QDRANT_READONLY_API_KEY` | ключ только для чтения |

### Версии образов

| Переменная | По умолчанию |
|---|---|
| `N8N_VERSION` | `2.41.5` |
| `NGINX_VERSION` | `stable-alpine` |
| `QDRANT_VERSION` | `v1.19.1` |
| `CERTBOT_VERSION` | `latest` |

### Имена контейнеров / сетей / томов

`N8N_CONTAINER_NAME`, `QDRANT_CONTAINER_NAME`, `NGINX_CONTAINER_NAME`, `CERTBOT_CONTAINER_NAME`,
`NET_EDGE`, `NET_DATA`, `VOL_N8N_DATA`, `VOL_QDRANT_DATA`, `VOL_NGINX_CACHE`,
`VOL_LETSENCRYPT`, `VOL_CERTBOT_WWW`

### n8n

| Переменная | По умолчанию | Описание |
|---|---|---|
| `N8N_PROTOCOL` | `https` | схема внешнего URL |
| `N8N_PROXY_HOPS` | `1` | число доверенных прокси (nginx) |
| `N8N_SECURE_COOKIE` | `true` | cookie только по HTTPS |
| `N8N_PAYLOAD_SIZE_MAX` | `64` | макс. размер запроса, MiB |
| `N8N_EXECUTIONS_MAX_AGE` | `336` | удаление выполнений старше N часов |

### nginx / Qdrant / служебные

| Переменная | По умолчанию | Описание |
|---|---|---|
| `NGINX_CLIENT_MAX_BODY_SIZE` | `64m` | лимит тела запроса |
| `NGINX_HSTS_MAX_AGE` | `31536000` | max-age HSTS |
| `NGINX_ACME_WEBROOT` | `/var/www/certbot` | webroot для ACME |
| `NGINX_TLS_PROTOCOLS` | `TLSv1.2 TLSv1.3` | разрешённые версии TLS |
| `NGINX_TLS_CIPHERS` | Mozilla intermediate | набор шифров |
| `NGINX_SERVER_TOKENS` | `off` | скрывать версию nginx |
| `QDRANT_LOG_LEVEL` | `INFO` | уровень логов Qdrant |
| `HEALTHCHECK_INTERVAL/TIMEOUT/RETRIES` | `15s` / `5s` / `5` | параметры healthcheck |
| `LOG_MAX_SIZE` / `LOG_MAX_FILE` | `10m` / `5` | ротация логов Docker |

---

## 8. Эксплуатация

### Логи

```bash
docker compose logs -f nginx
docker compose logs -f n8n
docker compose logs -f qdrant
docker compose logs -f certbot
```

### Статус и перезапуск

```bash
docker compose ps
docker compose restart nginx          # перечитает конфиги и сертификаты
docker compose up -d                  # применить изменения .env
docker compose --profile tls up -d    # вместе с контейнером автопродления сертификатов
```

> После правки `.env` обязательно `docker compose up -d` — иначе переменные не применятся.

### Обновление образов

```bash
docker compose pull
docker compose up -d
docker image prune -f
```

Версии фиксируются в `.env` (`N8N_VERSION`, `QDRANT_VERSION`, `NGINX_VERSION`) — меняйте их осознанно.
Перед обновлением n8n сделайте бэкап (см. ниже) — миграции схемы необратимы.

### Бэкап

```bash
# n8n (включая credentials — ключ шифрования в .env!)
docker run --rm -v n8n_data:/data -v "$PWD/backup":/backup alpine \
  tar czf /backup/n8n-$(date +%F).tar.gz -C /data .

# Qdrant — снапшот через API
curl -X POST -H "api-key: $QDRANT_API_KEY" \
  "https://qdrant.example.com/collections/<collection>/snapshots"

# .env и каталоги проекта
tar czf backup/config-$(date +%F).tar.gz .env docker-compose.yml nginx/ scripts/
```

Восстановление n8n:

```bash
docker compose stop n8n
docker run --rm -v n8n_data:/data -v "$PWD/backup":/backup alpine \
  sh -c "rm -rf /data/* && tar xzf /backup/n8n-2026-01-01.tar.gz -C /data"
docker compose up -d n8n
```

### Сертификаты

- Выпуск: `sudo ./scripts/init-letsencrypt.sh`
- Автопродление: контейнер `certbot` (профиль `tls`) проверяет продление каждые 12 часов.
- nginx подхватывает новые сертификаты при перезапуске/перезагрузке:

```bash
docker compose exec nginx nginx -s reload
```

- Проверить срок действия: `echo | openssl s_client -connect n8n.example.com:443 2>/dev/null | openssl x509 -noout -dates`
- Cron на хосте для гарантированной перезагрузки после продления:

```cron
0 4 * * * cd /opt/n8n-stack && docker compose exec -T nginx nginx -s reload >/dev/null 2>&1
```

---

## 9. Диагностика

| Симптом | Причина / решение |
|---|---|
| `nginx` в рестарте, в логах `cannot load certificate` | Сертификата нет. Запустите `sudo ./scripts/init-letsencrypt.sh` (он поднимет HTTP-режим и выпустит сертификат) |
| certbot: `Timeout during connect` | Порт 80 закрыт файрволом или DNS ещё не указывает на сервер |
| `docker compose exec nginx nginx -t` — `host not found in upstream` | Используется старый конфиг; перезапустите nginx, чтобы перерендерились конфиги |
| n8n открывается, но логин не сохраняется | `N8N_SECURE_COOKIE=true` при `N8N_PROTOCOL=http`. Приведите оба параметра в соответствие |
| n8n: `Bad request` / редирект на localhost | Проверьте `N8N_HOST`, `WEBHOOK_URL`, `N8N_EDITOR_BASE_URL` и `N8N_PROXY_HOPS=1` |
| n8n не видит Qdrant | `docker compose exec n8n wget -qO- http://qdrant:6333/readyz`; убедитесь, что оба контейнера в сети `n8n_data` |
| Qdrant отвечает `403`/`401` | Не передан `api-key`. Проверьте значение `QDRANT_API_KEY` |
| Порт 80/443 занят | `ss -tlnp | grep -E ':(80|443)'` — остановите мешающий сервис (apache2/nginx на хосте) |
| Изменения в `.env` не применились | `docker compose up -d` (пересоздаёт контейнеры с новыми переменными) |

Полезные команды:

```bash
docker compose config                  # итоговый конфиг с подставленными переменными
docker compose exec nginx nginx -T     # полный действующий конфиг nginx
docker network inspect n8n_data        # кто в какой сети
docker compose exec n8n env | sort     # переменные окружения n8n
```

---

## 10. Приложение: Postgres для n8n (опционально)

По умолчанию n8n использует SQLite — этого достаточно для одного инстанса и небольших нагрузок.
Для высокой нагрузки и параллельных выполнений переведите n8n на Postgres.

1. Добавьте в `docker-compose.yml` сервис и том:

```yaml
volumes:
  postgres_data:
    name: ${VOL_POSTGRES_DATA}

services:
  postgres:
    image: postgres:16-alpine
    container_name: n8n-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
      TZ: ${TZ}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks: [data]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 15s
      timeout: 5s
      retries: 5
    logging: *default-logging
```

2. В сервисе `n8n` добавьте `depends_on: postgres: condition: service_healthy` и замените переменные БД:

```yaml
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: ${POSTGRES_DB}
      DB_POSTGRESDB_USER: ${POSTGRES_USER}
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}
```

3. Добавьте в `.env`:

```env
POSTGRES_USER=n8n
POSTGRES_PASSWORD=CHANGE_ME
POSTGRES_DB=n8n
VOL_POSTGRES_DATA=n8n_postgres_data
```

4. `./scripts/gen-secrets.sh` (при необходимости добавьте `POSTGRES_PASSWORD` в список) и `docker compose up -d`.

> Миграция существующих данных SQLite → Postgres автоматически не выполняется: переносите workflow экспортом/импортом.
