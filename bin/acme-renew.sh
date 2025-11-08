#!/usr/bin/env bash
set -euo pipefail

# Запускает acme.sh --cron в одноразовом контейнере (compose service: acme)
# По завершении — нормализует права на ключе и "пинает" Traefik (file provider) через touch.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Выбираем docker compose плагин или старый docker-compose
compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  else
    docker-compose "$@"
  fi
}

echo "[ACME] Run cron renew..."
compose --profile acme run --rm acme sh -lc '
  set -e
  export LE_WORKING_DIR=/acme.sh
  # ежедневная проверка/продление, если пора
  acme.sh --cron --home /acme.sh --debug 2

  # Если сертификаты на месте — правим права и "пинаем" Traefik
  if [ -n "${DOMAIN:-}" ] && [ -f "/out/${DOMAIN}/fullchain.pem" ] && [ -f "/out/${DOMAIN}/privkey.pem" ]; then
    chmod 640 "/out/${DOMAIN}/privkey.pem" || true
    chmod 644 "/out/${DOMAIN}/fullchain.pem" || true
    # Traefik file provider вотчит каталоги: touch заставит перечитать конфиг/серты
    touch /traefik_dynamic/90-tls-certs.yaml || true
  fi
'

echo "[ACME] Done."
