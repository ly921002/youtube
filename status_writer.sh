#!/usr/bin/env bash
set -Eeuo pipefail

STATUS_DIR="${STATUS_DIR:-/app/web/status}"
STATUS_FILE="$STATUS_DIR/current_status.json"
mkdir -p "$STATUS_DIR"

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
        python3 - "$STATUS_FILE" "$status" "$current_video" "$playlist_index" "$playlist_total" "$mode" "$audio" "$video_bitrate" "$maxrate" "$bufsize" "$last_error" <<'PY'
import json
import os
import sys
from datetime import datetime

status_file, status, current_video, playlist_index, playlist_total, mode, audio, video_bitrate, maxrate, bufsize, last_error = sys.argv[1:]

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
  "updated_at": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF
    fi
}

write_status "waiting" "-" 0 0 "-" "-" "-" "-" "-" "-"
