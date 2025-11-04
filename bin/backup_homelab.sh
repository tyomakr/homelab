#!/usr/bin/env bash
# homelab backup helper
# Backs up the homelab project (compose, config, data, secrets) to /mnt/nas/docker_data
# Creates timestamped snapshot and updates a "latest" symlink. Keeps N most recent backups.
# If not run as root, re-exec with sudo to ensure we can read root-owned files (e.g., TLS keys).
set -euo pipefail

# ---------- Auto-escalate to root (to read privkey/account keys safely) ----------
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

# ---------- Settings ----------
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_ROOT="${DEST_ROOT:-/mnt/nas/docker_data}"
SNAP_DIR="${DEST_ROOT}/homelab"
KEEP="${KEEP:-7}"                    # how many snapshots to keep
RSYNC_OPTS="${RSYNC_OPTS:--aH --delete --numeric-ids --info=progress2}"
EXCLUDES_FILE="${EXCLUDES_FILE:-}"   # optional path to rsync exclude file

# ---------- Helpers ----------
log() { printf "[%(%Y-%m-%d %H:%M:%S)T] %s\n" -1 "$*"; }
die() { log "ERROR: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

require_cmd() {
  for c in "$@"; do have "$c" || die "Required command not found: $c"; done
}

# ---------- Pre-flight ----------
require_cmd rsync find sort awk date df du mkdir printf mountpoint || true
[[ -d "$PROJECT_ROOT" ]] || die "PROJECT_ROOT not found: $PROJECT_ROOT"

# Check mount & writability
if command -v mountpoint >/dev/null 2>&1; then
  mountpoint -q -- "$DEST_ROOT" || {
    # fallback check via /proc/mounts
    grep -qs " $(printf '%s' "$DEST_ROOT" | sed 's/[[:space:]]/\\&/g') " /proc/mounts \
      || die "Destination root is not a mountpoint: $DEST_ROOT"
  }
else
  grep -qs " $(printf '%s' "$DEST_ROOT" | sed 's/[[:space:]]/\\&/g') " /proc/mounts \
    || die "Destination root is not a mountpoint: $DEST_ROOT"
fi
[[ -w "$DEST_ROOT" ]] || die "Destination root is not writable: $DEST_ROOT"

# Prepare destination
DATE="$(date +%Y-%m-%d_%H-%M-%S)"
DEST="${SNAP_DIR}/${DATE}"
mkdir -p "$DEST" || die "Cannot create destination $DEST"

# ---------- What to back up ----------
INCLUDE=(
  "docker-compose.yml"
  ".env"
  "bin/"
  "config/"
  "data/"
  "secrets/"
  "docs/"
  ".gitignore"
)

# Sanity: show what we plan to copy
log "Project root: $PROJECT_ROOT"
log "Destination : $DEST"
log "Will back up paths:"
for p in "${INCLUDE[@]}"; do log "  - $p"; done

# Optional disk space check (best-effort)
if have du && have df; then
  SRC_BYTES=$( (cd "$PROJECT_ROOT" && du -sb "${INCLUDE[@]}" 2>/dev/null | awk '{s+=$1} END{print s+0}') || echo 0 )
  AVAIL_BYTES=$(df -P "$DEST_ROOT" | awk 'NR==2{print $4*1024}')
  if [[ "$SRC_BYTES" -gt "$AVAIL_BYTES" ]]; then
    log "WARNING: Estimated source size ($SRC_BYTES bytes) > available on target ($AVAIL_BYTES bytes). Proceeding anyway."
  fi
fi

# ---------- Run rsync ----------
RSYNC=(rsync $RSYNC_OPTS)
if [[ -n "$EXCLUDES_FILE" && -f "$EXCLUDES_FILE" ]]; then
  RSYNC+=(--exclude-from="$EXCLUDES_FILE")
fi

# Ensure destination exists
mkdir -p "$DEST"

# ---------- Copy preserving top-level folder names ----------
for p in "${INCLUDE[@]}"; do
  src="$PROJECT_ROOT/$p"
  if [[ -d "$src" ]]; then
    # preserve directory name (e.g., data/ -> <DEST>/data/)
    dest="$DEST/${p%/}"
    mkdir -p "$dest"
    log "Sync dir $p -> ${dest}/ ..."
    "${RSYNC[@]}" "$src" "$dest/"
  elif [[ -f "$src" ]]; then
    log "Sync file $p -> $DEST/ ..."
    "${RSYNC[@]}" "$src" "$DEST/"
  else
    log "Skip (not found): $p"
  fi
done

# ---------- Write snapshot metadata ----------
META="${DEST}/.backup_meta.txt"
{
  echo "timestamp=$(date -Is)"
  echo "host=$(hostname -f 2>/dev/null || hostname)"
  echo "project_root=$PROJECT_ROOT"
  echo "compose_version=$(docker compose version 2>/dev/null | tr -d '\r' || echo 'n/a')"
  if [[ -d "$PROJECT_ROOT/.git" ]] && have git; then
    (cd "$PROJECT_ROOT"
      echo "git_commit=$(git rev-parse --short HEAD 2>/dev/null || echo 'n/a')"
      echo "git_status=$(git status --porcelain 2>/dev/null | wc -l | awk '{print $1}')"
    )
  fi
} >"$META" || log "WARN: cannot write metadata"

# ---------- Update 'latest' symlink ----------
ln -sfn "$DEST" "${SNAP_DIR}/latest"

# ---------- Rotate old snapshots ----------
if [[ "$KEEP" =~ ^[0-9]+$ ]]; then
  log "Keeping last $KEEP snapshots"
  mapfile -t ALL < <(find "$SNAP_DIR" -mindepth 1 -maxdepth 1 -type d -printf "%P\n" | grep -E '^[0-9]{4}-' | sort)
  COUNT=${#ALL[@]}
  if (( COUNT > KEEP )); then
    TO_DELETE=$(( COUNT - KEEP ))
    log "Pruning $TO_DELETE old snapshot(s)"
    for d in "${ALL[@]:0:$TO_DELETE}"; do
      log "  delete: $d"
      rm -rf -- "$SNAP_DIR/$d"
    done
  fi
fi

log "Backup completed: $DEST"