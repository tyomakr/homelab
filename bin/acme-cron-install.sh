#!/usr/bin/env bash
set -euo pipefail

# Устанавливает (или обновляет) cron-задачу для автопродления wildcard через acme-renew.sh
# По умолчанию: 02:15 ежедневно. Можно передать расписание первым аргументом.
# Пример: bin/acme-cron-install.sh "5 3 * * *"

CRON_SPEC="${1:-15 2 * * *}"   # по умолчанию 02:15

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RENEW_SCRIPT="$ROOT/bin/acme-renew.sh"
LOCK_FILE="/var/lock/homelab-acme.lock"
LOG_FILE="/var/log/homelab-acme.log"
LOGROTATE_FILE="/etc/logrotate.d/homelab-acme"

need_root() {
  if [ "$EUID" -ne 0 ]; then
    exec sudo -E bash "$0" "$CRON_SPEC"
  fi
}
need_root

if [ ! -x "$RENEW_SCRIPT" ]; then
  echo "Make $RENEW_SCRIPT executable..."
  chmod +x "$RENEW_SCRIPT"
fi

echo "Ensuring log file..."
touch "$LOG_FILE"
chown root:adm "$LOG_FILE" || true
chmod 0640 "$LOG_FILE" || true

echo "Writing logrotate config..."
cat > "$LOGROTATE_FILE" <<EOF
$LOG_FILE {
  weekly
  rotate 8
  missingok
  notifempty
  compress
  delaycompress
  create 0640 root adm
}
EOF

# Собираем новую crontab root, вычищая старые записи с нашим маркером
TMP_CRON="$(mktemp)"
crontab -l 2>/dev/null | sed '/# homelab:acme/d' > "$TMP_CRON" || true

# Добавляем нашу строку (идемпотентно)
# Важное: используем абсолютные пути и flock, чтобы не запускалось параллельно
echo "$CRON_SPEC /usr/bin/flock -n $LOCK_FILE $RENEW_SCRIPT >> $LOG_FILE 2>&1 # homelab:acme" >> "$TMP_CRON"

echo "Installing root crontab..."
crontab "$TMP_CRON"
rm -f "$TMP_CRON"

echo "Cron installed:"
crontab -l | sed -n '1,200p'
