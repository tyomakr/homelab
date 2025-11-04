# homelab — Руководство по развертыванию (актуализированное)

Модульный каркас для хоумлаба с **Traefik v3**, wildcard‑TLS (**Let’s Encrypt** через **DNS‑01 REG.RU** и `acme.sh`), единым `docker-compose.yml`, профилями сервисов и безопасными мидлварами (по умолчанию — доступ только из allowlist).

> Тестировалось на Ubuntu 25.10, Docker Engine 24+, Docker Compose V2 2.24+.  
> Совместимость привязана к версиям образов в `docker-compose.yml` (Traefik v3.5, nginx 1.28‑alpine, Gitea 1.25).

---

## 0) Предварительно (DNS и порты)

1. DNS:
   - `A @` → публичный IP сервера;
   - `A *` → публичный IP сервера.
2. Проброс портов на роутере: 80/443 → хост (Ubuntu).

---

## 1) Клонирование репозитория и базовая структура

```bash
sudo mkdir -p /opt/homelab
sudo chown -R $USER:$USER /opt/homelab
cd /opt/homelab
git clone https://github.com/<your-account>/homelab .
```

> В репозиторий не попадают секреты и приватные списки — они локальные (в `.gitignore`).

---

## 2) Конфигурация `.env` и allowlist

1) Создать `.env` из примера и заполнить значения:
```bash
cp .env.example .env
# проверьте DOMAIN, LE_EMAIL; при необходимости TZ и COMPOSE_PROFILES
```

2) Создать allowlist (примеры IP/подсетей заменить на свои):
```bash
cp docs/allowlist.example.yaml config/traefik/dynamic/01-allowlist.yaml
# отредактируйте http.middlewares.allowlist-default.ipAllowList.sourceRange
```

---

## 3) Секреты

1) Basic auth для будущего Dashboard (будет включен позже):
```bash
mkdir -p secrets
docker run --rm httpd:2.4 htpasswd -nbB admin 'YourStrongPass' > secrets/basic_auth.htpasswd
chmod 600 secrets/basic_auth.htpasswd
```

2) REG.RU API (для `acme.sh`):
```bash
printf 'REGRU_API_Username="login@reg.ru"\nREGRU_API_Password="password"\n' > secrets/regru.env
chmod 600 secrets/regru.env
```

---

## 4) Выпуск wildcard‑сертификата (Let’s Encrypt, DNS‑01 REG.RU)

Однократно при первом развёртывании (при необходимости повторять). Если у провайдера TXT‑запись распространяется долго — увеличьте `--dnssleep` до `600–1800` секунд в `bin/acme-issue.sh`.

```bash
chmod +x bin/acme-issue.sh
COMPOSE_PROFILES=acme ./bin/acme-issue.sh
```

Ожидаемые файлы:
```
config/traefik/acme-certs/<DOMAIN>/fullchain.pem
config/traefik/acme-certs/<DOMAIN>/privkey.pem
```

---

## 5) Запуск базового стека (Traefik + Splash + Gitea)

```bash
# в .env может быть COMPOSE_PROFILES=proxy,gitea
docker compose up -d
```

Проверка локально (без внешнего DNS, подставьте IP сервера):
```bash
curl -I --resolve <DOMAIN>:443:<srv_ip> https://<DOMAIN>
curl -I --resolve git.<DOMAIN>:443:<srv_ip> https://git.<DOMAIN>
```

Если видите `TRAEFIK DEFAULT CERT` — проверьте валидность **всех** `config/traefik/dynamic/*.yaml` (ошибка в любом валит file‑provider), пути к сертификатам в `90-tls-certs.yaml`, логи:
```bash
docker logs homelab-traefik-1 --since=2m
```

---

## 6) (Опционально) Восстановление Gitea из бэкапа каталога `/data`

```bash
docker compose stop gitea
# распакуйте бэкап в /opt/homelab/data/gitea (внутри должны быть gitea/, git/, lfs/ ...)
sudo chown -R 1000:1000 /opt/homelab/data/gitea   # ВАЖНО
docker compose up -d gitea
docker logs -f homelab-gitea-1
```

---

## 7) Пример: Home Assistant (Ingress‑friendly заголовки)

Файл: `config/traefik/dynamic/21-ha.yaml`

```yaml
http:
  routers:
    hass:
      rule: 'Host(`hass.{{ env "DOMAIN" }}`)'
      entryPoints: ["websecure"]
      middlewares: ["chain-default"]
      service: hass
      tls: {}

  services:
    hass:
      loadBalancer:
        servers:
          - url: "http://192.168.222.24:8123"
```

В `configuration.yaml` HA:
```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 10.0.3.0/24   # подсеть docker-сети homelab_proxy
```

Подсеть узнать:
```bash
docker network inspect homelab_proxy | grep -i Subnet
```

Если в логах Traefik появится `tls: first record does not look like a TLS handshake`, значит в сервисе указан `https://` при HTTP‑бэкенде — поправьте `servers[].url` на `http://` (или включите `serversTransports.insecureSkipVerify` для самоподписанного HTTPS).

---

## 8) Пример: QNAP (исправление `ERR_BLOCKED_BY_RESPONSE`)

Минимальный конфиг (только allowlist, без X‑Frame‑Options/HSTS). Файл: `config/traefik/dynamic/22-qnap.yaml`:

```yaml
http:
  routers:
    qnap:
      rule: 'Host(`q.{{ env "DOMAIN" }}`)'
      entryPoints: ["websecure"]
      middlewares: ["allowlist-default"]
      service: qnap
      tls: {}

  services:
    qnap:
      loadBalancer:
        servers:
          - url: "https://192.168.222.10:443"
        serversTransport: "insecure-skip"

  serversTransports:
    insecure-skip:
      insecureSkipVerify: true
```

> Если QNAP отдаёт HTTP на 80 — укажите `http://…` и уберите `serversTransport`.

После проверки можно постепенно вернуть безопасные заголовки (без `X-Frame-Options: DENY` и без жёсткого CSP).

---

## 9) Бэкап проекта на NAS

Скрипт: `/opt/homelab/bin/backup_homelab.sh`  
Делает снапшот в `/mnt/nas/docker_data/homelab/YYYY-mm-dd_HH-MM-SS/`, сохраняет верхний уровень директорий (`config/`, `data/`, `secrets/`, `bin/`, `docs/` и т.д.), создаёт симлинк `latest`, хранит N последних (по умолчанию 7). Для чтения приватных ключей запускается с root (самоэскалация через `sudo`).

Ручной запуск:
```bash
DEST_ROOT=/mnt/nas/docker_data KEEP=7 /opt/homelab/bin/backup_homelab.sh
```

### Крон (root crontab)

```bash
sudo crontab -e
```

Добавить (пример: 03:30 ежедневно, с блокировкой и логом):
```
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
MAILTO=""

30 3 * * * flock -n /var/lock/homelab-backup.lock bash -lc 'nice -n 10 ionice -c2 -n7 KEEP=14 DEST_ROOT=/mnt/nas/docker_data /opt/homelab/bin/backup_homelab.sh >> /var/log/homelab-backup.log 2>&1'
```

Ротация лога `/var/log/homelab-backup.log`:
```bash
sudo tee /etc/logrotate.d/homelab-backup >/dev/null <<'EOF'
/var/log/homelab-backup.log {
  weekly
  rotate 8
  missingok
  notifempty
  compress
  delaycompress
  create 0640 root adm
}
EOF
```

---

## 10) GitHub по SSH (на сервере), чтобы не вводить пароль и не терять права

Выполнять под **обычным пользователем**, не root:
```bash
sudo -iu localadmin
cd /opt/homelab

# создать SSH-ключ
ssh-keygen -t ed25519 -C "homelab@macmini-srv" -f ~/.ssh/id_ed25519
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub   # добавить на GitHub: Settings → SSH and GPG keys → New SSH key

# переключить origin на SSH
git remote set-url origin git@github.com:<your-account>/homelab.git
ssh -T git@github.com       # проверка "Hi <username>! You've successfully authenticated..."
git pull --ff-only
git push
```

### Не терять `+x` и LF у скриптов после pull

Добавить в `.gitattributes`:
```
*.sh text eol=lf
bin/*.sh text eol=lf
```
Применить:
```bash
git add --renormalize .gitattributes
git commit -m "chore: enforce LF for *.sh via .gitattributes"
git update-index --chmod=+x bin/backup_homelab.sh
git commit -m "fix: mark backup_homelab.sh executable"
git push
```

### Быстрый post‑pull фикс (если пришлось править на Windows)

```bash
cat >/opt/homelab/bin/post-pull.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
sed -i 's/\r$//' /opt/homelab/bin/*.sh || true
chmod 750 /opt/homelab/bin/*.sh || true
EOF
chmod +x /opt/homelab/bin/post-pull.sh
```

Запуск после `git pull`:
```bash
/opt/homelab/bin/post-pull.sh
```

---

## 11) Частые ошибки и их решение

- **TRAEFIK DEFAULT CERT** — не подхватился `90-tls-certs.yaml` или валится весь provider из‑за ошибки в любом .yaml. Проверьте логи: `docker logs homelab-traefik-1 --since=2m`.
- **routers cannot be a standalone element** — пустой файл динамики содержит `routers:`/`services:`. Удалите файл или оставьте `http: {}`/переименуйте в `.off`.
- **tls: first record does not look like a TLS handshake** — у бэкенда HTTP, а в `services[].url` указан `https://` (или наоборот). Исправьте протокол/добавьте `serversTransports.insecureSkipVerify`.
- **ERR_BLOCKED_BY_RESPONSE** в QNAP — лишние security-заголовки (например, `X-Frame-Options: DENY`). Минимальный конфиг выше решает проблему.

---

На этом этапе базовый стек поднят, wildcard работает, Gitea восстановлена, Home Assistant/QNAP заведены через Traefik, бэкап настроен.  
Дальше: подключение Traefik Dashboard и Portainer — в следующем шаге.
