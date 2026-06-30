#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_DIR="${STATUS_DIR:-$SCRIPT_DIR/web/status}"
STATUS_FILE="$STATUS_DIR/current_status.json"
STATUS_LOG_FILE="$STATUS_DIR/status.log"
STATUS_LOG_LINES="${STATUS_LOG_LINES:-80}"
mkdir -p "$STATUS_DIR"

append_status_log() {
    local message="$*"
    local max_lines="$STATUS_LOG_LINES"
    [[ "$max_lines" =~ ^[0-9]+$ ]] || max_lines=80

    mkdir -p "$STATUS_DIR"
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$message" >> "$STATUS_LOG_FILE"
    if command -v tail >/dev/null 2>&1; then
        tail -n "$max_lines" "$STATUS_LOG_FILE" > "$STATUS_LOG_FILE.tmp"
        mv "$STATUS_LOG_FILE.tmp" "$STATUS_LOG_FILE"
    fi
}

write_status() {
    local status="$1"
    local current_video="$2"
    local playlist_index="$3"
    local playlist_total="$4"
    local mode="$5"
    local audio="$6"
    local video_bitrate="$7"
    local maxrate="$8"
    local bufsize="$9"
    local last_error="${10:-}"

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$STATUS_FILE" "$STATUS_LOG_FILE" "$status" "$current_video" "$playlist_index" "$playlist_total" "$mode" "$audio" "$video_bitrate" "$maxrate" "$bufsize" "$last_error" <<'PY'
import json
import os
import sys
from datetime import datetime

status_file, log_file, status, current_video, playlist_index, playlist_total, mode, audio, video_bitrate, maxrate, bufsize, last_error = sys.argv[1:]

logs = []
if os.path.exists(log_file):
    with open(log_file, "r", encoding="utf-8", errors="replace") as fh:
        logs = [line.rstrip("\n") for line in fh.readlines()[-80:]]

payload = {
    "status": status,
    "current_video": current_video,
    "playlist_index": int(playlist_index),
    "playlist_total": int(playlist_total),
    "mode": mode,
    "audio": audio,
    "video_bitrate": video_bitrate,
    "maxrate": maxrate,
    "bufsize": bufsize,
    "last_error": last_error,
    "logs": logs,
    "updated_at": datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
}

os.makedirs(os.path.dirname(status_file), exist_ok=True)
with open(status_file, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
    else
        cat > "$STATUS_FILE" <<EOF
{
  "status": "$status",
  "current_video": "$current_video",
  "playlist_index": $playlist_index,
  "playlist_total": $playlist_total,
  "mode": "$mode",
  "audio": "$audio",
  "video_bitrate": "$video_bitrate",
  "maxrate": "$maxrate",
  "bufsize": "$bufsize",
  "last_error": "$last_error",
  "logs": [],
  "updated_at": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF
    fi
}

write_status "waiting" "-" 0 0 "-" "-" "-" "-" "-" "-"
