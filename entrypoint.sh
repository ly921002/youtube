#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_DIR="$SCRIPT_DIR/web"
STATUS_DIR="${STATUS_DIR:-$SCRIPT_DIR/web/status}"
mkdir -p "$STATUS_DIR"
export STATUS_DIR

if command -v httpd >/dev/null 2>&1; then
  httpd -f -p 8080 -h "$WEB_DIR" >/tmp/httpd.log 2>&1 &
elif command -v python3 >/dev/null 2>&1; then
  python3 -m http.server 8080 --directory "$WEB_DIR" >/tmp/httpd.log 2>&1 &
else
  echo "WARNING: no simple web server found; continuing without web UI"
fi

if [[ -f "$SCRIPT_DIR/youtube.sh" ]]; then
  exec /bin/bash "$SCRIPT_DIR/youtube.sh" "$@"
else
  exec /bin/bash /app/youtube.sh "$@"
fi
