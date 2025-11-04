# homelab (Traefik v3 + wildcard via acme.sh) — Bootstrap Guide

Модульный каркас для хоумлаба с **Traefik v3**, wildcard‑TLS (**Let’s Encrypt** через **DNS‑01 REG.RU** и `acme.sh`), единым `docker-compose.yml`, профилями сервисов и безопасными мидлварами (по умолчанию — доступ только из allowlist).

> ✅ **Тестировалось** на Ubuntu 25.10.  
> 🧩 **Подходит для любого современного Linux** (Debian/Ubuntu/Alpine/RHEL и др.), где доступны **Docker Engine 24+** и **Docker Compose V2 2.24+**.  
> 🔒 **Совместимость привязана к версиям образов в `docker-compose.yml`**, поэтому используйте их как базовую точку. При смене версий сверяйте изменения в документации соответствующих проектов.

---

## Сервисы и версии (пин в compose)

- **Traefik**: `traefik:v3.5` — reverse proxy / TLS‑терминация  
- **Nginx splash**: `nginx:1.28-alpine` — статичная заглушка для корня домена  
- **Gitea**: `gitea/gitea:1.25` — Git‑сервис
- **acme.sh агент**: `neilpang/acme.sh:latest` — выпуск/обновление wildcard по DNS‑01 REG.RU

> Дополнительно (опционально, позже): **Portainer**, **AdGuard Home**, внутренние сервисы (QNAP/HA и др.) через Traefik file‑provider.

---

## Предварительно (вне проекта)

1. **DNS‑записи**:  
   - `A @` → публичный IP сервера  
   - `A *` → публичный IP сервера  

2. **Порты**: пробросите 80/443 с роутера на этот хост.

3. **REG.RU API**: получите логин/пароль API (для DNS‑01). Если ваш DNS не REG.RU — используйте соответствующий плагин `acme.sh` и адаптируйте шаг 4‑5.

---

## 1) Клонирование

```bash
sudo mkdir -p /opt/homelab
sudo chown -R $USER:$USER /opt/homelab
cd /opt/homelab
git clone https://github.com/<your-account>/homelab .
```

> Замените `<your-account>` на свой. Репозиторий не должен содержать секретов — они лежат локально.

---

## 2) Конфигурация `.env` и allowlist

1) Создайте `.env` из примера:
```bash
cp .env.example .env
# отредактируйте DOMAIN, LE_EMAIL; при необходимости TZ и COMPOSE_PROFILES
```

2) Создайте allowlist из примера и внесите IP/подсети, которым разрешён доступ **по умолчанию** ко всем поддоменам:
```bash
cp docs/allowlist.example.yaml config/traefik/dynamic/01-allowlist.yaml
# откройте и заполните sourceRange
```

---

## 3) Секреты

1) **Basic auth** для Traefik Dashboard (будем включать позже):
```bash
mkdir -p secrets
docker run --rm httpd:2.4 htpasswd -nbB admin 'YourStrongPass' > secrets/basic_auth.htpasswd
chmod 600 secrets/basic_auth.htpasswd
```

2) **REG.RU API** (для `acme.sh`):
```bash
printf 'REGRU_API_Username="login@reg.ru"\nREGRU_API_Password="password"\n' > secrets/regru.env
chmod 600 secrets/regru.env
```

> Каталоги `secrets/`, `data/` и файлы реального allowlist добавлены в `.gitignore` и **не** попадают в git.

---

## 4) Выпуск wildcard‑сертификата (Let’s Encrypt, DNS‑01 REG.RU)

Запустите скрипт (однократно при первом развёртывании и далее по необходимости):
```bash
chmod +x bin/acme-issue.sh
COMPOSE_PROFILES=acme ./bin/acme-issue.sh
```
> Если у REG.RU TXT‑запись распространяется долго, увеличьте задержку `--dnssleep` в `bin/acme-issue.sh` (например, до `600–1800`).

Ожидаемые файлы:
```
config/traefik/acme-certs/<DOMAIN>/fullchain.pem
config/traefik/acme-certs/<DOMAIN>/privkey.pem
```

---

## 5) Запуск базового стека (Traefik + Splash + Gitea)

```bash
# .env уже может содержать COMPOSE_PROFILES=proxy,gitea
docker compose up -d
```

Проверка локально (без внешнего DNS, подставьте IP сервера):
```bash
curl -I --resolve <DOMAIN>:443:<srv_ip> https://<DOMAIN>
curl -I --resolve git.<DOMAIN>:443:<srv_ip> https://git.<DOMAIN>
```

Если видите `TRAEFIK DEFAULT CERT`:
- проверьте корректность `config/traefik/dynamic/90-tls-certs.yaml` (пути к wildcard‑файлам),
- и ошибки в динамических файлах (любая ошибка валит **весь** file‑provider):
  ```bash
  docker logs homelab-traefik-1 --since=2m
  ```

---

## 6) (Опционально, при переносе данных) Восстановление Gitea из бэкапа каталога `/data`

```bash
docker compose stop gitea
# распакуйте ваш бэкап в /opt/homelab/data/gitea так, чтобы внутри были каталоги gitea/, git/, lfs/, ...
sudo chown -R 1000:1000 /opt/homelab/data/gitea   # ВАЖНО!
docker compose up -d gitea
docker logs -f homelab-gitea-1
```

> Если ранее использовалась внешняя БД, проверьте `conf/app.ini` и восстановите БД отдельно.

---

## 7) Пример: Home Assistant (Ingress‑friendly заголовки)

Файл в репо: `config/traefik/dynamic/21-ha.yaml`.  
Внутри него:
- роутер `hass` на `https://hass.<DOMAIN>`,
- мягкая цепочка заголовков (без `X-Frame-Options: DENY`) — нужно для Ingress аддонов,
- проксирование внутрь по HTTP на `http://<HA_IP>:8123`.

Для корректной работы за прокси добавьте в **`configuration.yaml`** HA:
```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - <подсеть docker-сети proxy, например 10.0.3.0/24>
```

Подсеть найти так:
```bash
docker network inspect homelab_proxy | grep -i Subnet
```

Проверка:
```bash
curl -I --resolve hass.<DOMAIN>:443:<srv_ip> https://hass.<DOMAIN>
```

---

## 8) FAQ / Три частые ошибки и решения

**A. “TRAEFIK DEFAULT CERT”**  
— Traefik не подхватил `90-tls-certs.yaml` (или весь file‑provider не загрузился).  
*Проверьте:* валидность YAML во всех `config/traefik/dynamic/*.yaml`, наличие `fullchain.pem`/`privkey.pem`, логи `docker logs homelab-traefik-1 --since=2m`.

**B. “routers cannot be a standalone element”**  
— В пустом файле динамики заданы разделы `routers:`/`services:`.  
*Решение:* оставьте `http: {}` или удалите файл/переименуйте в `.off`.

**C. “tls: first record does not look like a TLS handshake”**  
— Проксируете `https://` на бэкенд, который слушает `http://`.  
*Решение:* укажите правильный протокол в `services.*.loadBalancer.servers[].url` и (при HTTPS с самоподписанным) используйте `serversTransports.insecureSkipVerify: true`.

---

## 9) Обновление/деплой

Локально (VSCode) → коммит → GitHub → на сервере:
```bash
cd /opt/homelab
git pull --ff-only
docker compose pull
docker compose up -d
```

---

## Примечания

- Любая ошибка YAML в одном файле валит весь file‑provider Traefik. Для черновиков временно переименовывайте файл в `.off`.
- Если ваш DNS **не REG.RU**, используйте соответствующий плагин `acme.sh` (например, `dns_cf` для Cloudflare) и измените команду выпуска wildcard в `bin/acme-issue.sh`.
- **Права Gitea после восстановления обязательно:**  
  ```bash
  sudo chown -R 1000:1000 /opt/homelab/data/gitea
  ```
- Вся конфигурация выполнена «TLS‑терминацией» в Traefik (wildcard). Внутренние сервисы можно держать на HTTP; либо на HTTPS (с `serversTransports.insecureSkipVerify: true` для самоподписанных).

---

## Полезные команды

Проверка сертификата:
```bash
openssl s_client -connect <ip>:443 -servername <host> </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates
```

Тест без внешнего DNS:
```bash
curl -I --resolve host.example.tld:443:<srv_ip> https://host.example.tld
```

Логи Traefik:
```bash
docker logs homelab-traefik-1 --since=2m
```
