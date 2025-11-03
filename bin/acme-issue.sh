#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

source ./.env

if [[ -z "${DOMAIN:-}" || -z "${LE_EMAIL:-}" ]]; then
  echo "Set DOMAIN and LE_EMAIL in .env"; exit 1
fi

docker compose run --rm acme sh -c "
  set -e
  acme.sh --register-account -m ${LE_EMAIL} --server letsencrypt || true
  acme.sh --issue --dns dns_regru \
    -d ${DOMAIN} -d \"*.${DOMAIN}\" \
    --keylength 4096 \
    --server letsencrypt \
    --dnssleep 300 \
    --debug 2

  mkdir -p /out/${DOMAIN}
  acme.sh --install-cert -d ${DOMAIN} \
    --key-file /out/${DOMAIN}/privkey.pem \
    --fullchain-file /out/${DOMAIN}/fullchain.pem \
    --reloadcmd \"sh -c 'chmod 640 /out/${DOMAIN}/privkey.pem && chmod 644 /out/${DOMAIN}/fullchain.pem && touch /traefik_dynamic/90-tls-certs.yaml'\"
"