# homelab — модульный каркас (Traefik v3, wildcard TLS, сервисы по профилям)

Готовая структура для хоумлаба на базе **Traefik v3**, с wildcard‑сертификатом (**Let’s Encrypt DNS‑01 через REG.RU и `acme.sh`**), единым `docker-compose.yml`, профилями сервисов и безопасными мидлварами (по умолчанию доступ к субдоменам только из allowlist).

> Тестировано на Ubuntu 25.10, Docker Engine 24+, Docker Compose V2 2.24+.  
> Совместимость привязана к версиям образов в `docker-compose.yml` (Traefik v3.5, nginx:1.28‑alpine, Gitea 1.25, Portainer EE, AdGuardHome latest).

---

## 0) Предварительно (DNS/порты)

1. DNS записи у регистратора:
   - `A @` → публичный IP сервера;
   - `A *` → публичный IP сервера.
2. На роутере проброс:
   - `80/tcp`, `443/tcp` → на Ubuntu‑хост.

---

## 1) Клонирование и базовая структура

```bash
sudo mkdir -p /opt/homelab
sudo chown -R $USER:$USER /opt/homelab
cd /opt/homelab
git clone https://github.com/<your-account>/homelab .
```

> Секреты/локальные файлы не коммитятся (см. `.gitignore`).

---

## 2) Настройка `.env` и allowlist

1) Создать `.env` из примера и заполнить переменные:
```bash
cp .env.example .env
# проверьте DOMAIN, LE_EMAIL; при желании TZ
```

2) Allowlist (пример — заменить на свои адреса/подсети):
```bash
cp docs/allowlist.example.yaml config/traefik/dynamic/01-allowlist.yaml
# отредактируйте http.middlewares.allowlist-default.ipAllowList.sourceRange
```

---

## 3) Секреты

1) BasicAuth для Dashboard (Traefik):
```bash
mkdir -p secrets
docker run --rm httpd:2.4 htpasswd -nbB admin 'ChangeMe!' > secrets/basic_auth.htpasswd
chmod 600 secrets/basic_auth.htpasswd
```

2) Регистратор REG.RU (для `acme.sh`):
```bash
printf 'REGRU_API_Username="login@reg.ru"\nREGRU_API_Password="password"\n' > secrets/regru.env
chmod 600 secrets/regru.env
```

---

## 4) Выпуск wildcard‑серта (Let’s Encrypt, DNS‑01 REG.RU)

Однократно при первом развёртывании (при необходимости повторить). Если TXT у провайдера расходится медленно — увеличьте `--dnssleep` в `bin/acme-issue.sh` до `600–1800`.

```bash
chmod +x bin/acme-issue.sh
COMPOSE_PROFILES=acme ./bin/acme-issue.sh
```

Путь к сертификатам:
```
config/traefik/acme-certs/<DOMAIN>/fullchain.pem
config/traefik/acme-certs/<DOMAIN>/privkey.pem
```

---

## 5) Базовый запуск (Traefik + splash + Gitea)

Traefik и splash — **базовые** (без профиля), стартуют всегда.

```bash
docker compose up -d          # traefik + splash
```

Gitea — по профилю:
```bash
COMPOSE_PROFILES=gitea docker compose up -d gitea
```

Проверка (локально, подставьте IP сервера):
```bash
curl -I --resolve ${DOMAIN}:443:<server_ip> https://${DOMAIN}
curl -I --resolve git.${DOMAIN}:443:<server_ip> https://git.${DOMAIN}
```

Если видите `TRAEFIK DEFAULT CERT` — проверьте логи и валидность **всех** `config/traefik/dynamic/*.yaml` (ошибка в одном валит весь file‑provider), а также `config/traefik/dynamic/90-tls-certs.yaml`.

```bash
docker logs homelab-traefik-1 --since=2m
```

### (Опционально) Восстановление Gitea из бэкапа `/data`
```bash
docker compose stop gitea
# распаковать бэкап в /opt/homelab/data/gitea (внутри: gitea/, git/, lfs/ ...)
sudo chown -R 1000:1000 /opt/homelab/data/gitea
docker compose up -d gitea
```

---

## 6) Примеры сервисов за Traefik

### Home Assistant (ingress‑friendly заголовки)
`config/traefik/dynamic/21-ha.yaml`:
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

### QNAP (фикс `ERR_BLOCKED_BY_RESPONSE` — минимум заголовков)
`config/traefik/dynamic/22-qnap.yaml`:
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

---

## 7) Traefik Dashboard на субдомене

Dashboard включён в `config/traefik/static/traefik.yaml` (`api.dashboard: true`).  
Роутер настроен через **labels** Traefik‑сервиса: `Host(\`traefik.${DOMAIN}\`)`, middlewares: `allowlist + basicAuth`.

Проверка:
```bash
curl -I --resolve traefik.${DOMAIN}:443:<server_ip> https://traefik.${DOMAIN}
```

---

## 8) Portainer на `p.${DOMAIN}` (профиль `portainer`)

Данные Portainer в `./data/portainer`. Если есть бэкап volume EE — распакуйте сюда (внутри ожидается `files.db` и пр.).

Старт:
```bash
COMPOSE_PROFILES=portainer docker compose up -d portainer
curl -I --resolve p.${DOMAIN}:443:<server_ip> https://p.${DOMAIN}
```
- Первый запуск — мастер‑инициализация (пароль admin).
- Если восстановили бэкап EE — увидите прежние данные (возможно, потребуется перелогин).  
- Для корректной работы за прокси задайте в Portainer `Settings → Authentication → Public domain = p.${DOMAIN}`.

---

## 9) AdGuard Home на `agh.${DOMAIN}` (профиль `adguard`)

DNS‑порты 53/tcp,53/udp отданы контейнеру; веб‑морда идёт через Traefik на 3000.

```bash
COMPOSE_PROFILES=adguard docker compose up -d adguard
curl -I --resolve agh.${DOMAIN}:443:<server_ip> https://agh.${DOMAIN}
```

Мастер‑настройка открывается по `https://agh.${DOMAIN}` (порт 3000 внутри контейнера).  
Папки данных: `./data/adguard/work`, `./data/adguard/conf` (попадают в бэкап).

> При желании в DHCP выдавайте DNS = IP сервера. Упрямых клиентов, шлющих в 8.8.8.8, можно перехватить dst‑NAT’ом на роутере (напр. MikroTik) на 53/tcp+udp → 192.168.222.5:53.

---

## 10) Бэкап (на NAS)

Скрипт: `/opt/homelab/bin/backup_homelab.sh`

- Снапшот в `/mnt/nas/docker_data/homelab/YYYY-mm-dd_HH-MM-SS/`
- Сохраняет верхний уровень директорий (`config/`, `data/`, `secrets/`, `bin/`, `docs/` и т.д.)
- Симлинк `latest`
- Хранит N последних (по умолчанию 7)
- Для чтения приватных ключей самоэскалация до root через `sudo` (требуется sudo без пароля **только** на чтение файлов; либо запускайте от root)

Ручной запуск:
```bash
DEST_ROOT=/mnt/nas/docker_data KEEP=7 /opt/homelab/bin/backup_homelab.sh
```

Крон (root):
```
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
MAILTO=""

30 3 * * * flock -n /var/lock/homelab-backup.lock bash -lc 'nice -n 10 ionice -c2 -n7 KEEP=14 DEST_ROOT=/mnt/nas/docker_data /opt/homelab/bin/backup_homelab.sh >> /var/log/homelab-backup.log 2>&1'
```

Logrotate `/etc/logrotate.d/homelab-backup`:
```
/var/log/homelab-backup.log {
  weekly
  rotate 8
  missingok
  notifempty
  compress
  delaycompress
  create 0640 root adm
}
```

---

## 11) GitHub по SSH (на сервере)

Работайте из‑под обычного пользователя (не root):

```bash
sudo -iu <user>
cd /opt/homelab

ssh-keygen -t ed25519 -C "homelab@host" -f ~/.ssh/id_ed25519
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
# Добавить ключ на GitHub → Settings → SSH and GPG keys → New SSH key

git remote set-url origin git@github.com:<your-account>/homelab.git
ssh -T git@github.com
git pull --ff-only
git push
```

Не терять `+x` и LF у *.sh:
```
# .gitattributes
*.sh text eol=lf
bin/*.sh text eol=lf
```
И один раз в индексе:
```bash
git update-index --chmod=+x bin/backup_homelab.sh bin/*.sh
git commit -m "fix: mark scripts executable & enforce LF via .gitattributes"
git push
```

---

## 12) Локальные «ensure» задачи (не меняют отслеживаемые файлы)

Запустить после `git clone/pull`, чтобы создать локальные заготовки при первом запуске:
```bash
bin/ensure-local.sh
```
Что делает:
- создаёт `.env` из `.env.example`, если `.env` отсутствует;
- создаёт `config/nginx-splash/html/index.html` из `index.html.example`, если кастома ещё нет;
- генерит `secrets/basic_auth.htpasswd`, если отсутствует (логин: `admin`, пароль: `ChangeMe!`).

---

## 13) Частые ошибки

- **TRAEFIK DEFAULT CERT** — не подхватился `90-tls-certs.yaml` или валится весь file‑provider из‑за ошибки в любом `*.yaml`. Смотрите логи: `docker logs homelab-traefik-1 --since=2m`.
- **routers cannot be a standalone element** — в пустом файле лишние `routers:`/`services:`. Удалите файл или переименуйте в `.off`.
- **tls: first record does not look like a TLS handshake** — у бэкенда HTTP, а в `services[].url` указан `https://` (или наоборот). Исправьте протокол/добавьте `serversTransports.insecureSkipVerify`.
- **ERR_BLOCKED_BY_RESPONSE** (QNAP) — лишние security‑заголовки. Используйте минимальный профиль из примера выше.