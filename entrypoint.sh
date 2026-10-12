#!/bin/bash
# 容器入口：先启动控制面板（后台），再以前台方式运行推流脚本
set -e

is_yes() {
    case "${1,,}" in
        yes|true|1|on) return 0 ;;
        *) return 1 ;;
    esac
}

if is_yes "${STATUS_ENABLED:-yes}"; then
    mkdir -p "${STATUS_DIR:-/app/status}" "${COMMAND_DIR:-${STATUS_DIR:-/app/status}/commands}"
    echo "=== Starting web panel on ${WEB_HOST:-127.0.0.1}:${PORT:-8080} ==="
    python3 /app/web/server.py &
else
    echo "=== Web panel disabled (STATUS_ENABLED=${STATUS_ENABLED}) ==="
fi

echo "=== Starting ffmpeg auto stream ==="
exec /bin/bash /app/youtube.sh
