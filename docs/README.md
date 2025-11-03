# homelab proxy (Traefik v3 + wildcard via acme.sh)

- Single compose + profiles
- TLS wildcard (*.DOMAIN) via acme.sh (DNS-01 REG.RU)
- Default allowlist for all subdomains; public chain available




## Дополнительная информация (заполняется по мере наполнения)
### Восстановление Gitea из бэкапа каталога /data

1) Остановить контейнер:
   ```bash
   docker compose stop gitea
2) Скопировать/распаковать бэкап в /opt/homelab/data/gitea так, чтобы внутри были обычные каталоги (gitea/, git/, lfs/, …).
3) ВАЖНО: права на том:
   ```bash
   sudo chown -R 1000:1000 /opt/homelab/data/gitea
4) Запустить:
   ```bash
   docker compose up -d gitea
   docker logs -f homelab-gitea-1