#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
log(){ printf "[%(%Y-%m-%d %H:%M:%S)T] %s\n" -1 "$*"; }

# 1) .env: создать из шаблона, если отсутствует
if [ ! -f ".env" ] && [ -f ".env.example" ]; then
  cp -n .env.example .env
  log "Created .env from .env.example — проверь DOMAIN/LE_EMAIL/TZ"
fi

# 2) splash: создать дефолтную страницу, если кастома нет
SPLASH_DIR="config/nginx-splash/html"
if [ -d "$SPLASH_DIR" ] && [ ! -f "$SPLASH_DIR/index.html" ] && [ -f "$SPLASH_DIR/index.html.example" ]; then
  cp -n "$SPLASH_DIR/index.html.example" "$SPLASH_DIR/index.html"
  log "Created splash index.html from example"
fi

# 3) basic auth: сгенерировать htpasswd, если нет
if [ ! -f "secrets/basic_auth.htpasswd" ]; then
  mkdir -p secrets
  docker run --rm httpd:2.4 htpasswd -nbB admin 'ChangeMe!' > secrets/basic_auth.htpasswd
  chmod 600 secrets/basic_auth.htpasswd || true
  log "Created secrets/basic_auth.htpasswd (login: admin, pass: ChangeMe!) — замени пароль"
fi

log "ensure-local done."