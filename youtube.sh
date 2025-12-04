#!/usr/bin/env bash
set -euo pipefail

echo "=== YouTube Online Stream → RTMP Restream ==="

# 必选：要推流的目标（可多路）
MULTI_RTMP_URLS="${MULTI_RTMP_URLS:?MULTI_RTMP_URLS 未设置}"

# YouTube 视频 / 直播 / 播放列表
YOUTUBE_URL="${YOUTUBE_URL:?必须提供 YOUTUBE_URL}"

# 是否循环播放
LOOP="${LOOP:-yes}"

# Cookie
COOKIE_FILE="${COOKIE_FILE:-/cookies/cookie.txt}"

# FPS、画质设定
TARGET_FPS="${TARGET_FPS:-30}"

# 自动获取来源 stream URL
get_stream_url() {
    echo "🔍 正在解析 YouTube 流地址..."

    if [[ -f "$COOKIE_FILE" ]]; then
        REAL_URL=$(yt-dlp -g --cookies "$COOKIE_FILE" --extractor-args "youtube:player_client=web;js_engine=node" "$YOUTUBE_URL")
    else
        REAL_URL=$(yt-dlp -g --extractor-args "youtube:player_client=web;js_engine=node" "$YOUTUBE_URL")
    fi

    if [[ -z "$REAL_URL" ]]; then
        echo "❌ 无法解析直播流，5 秒后重试"
        sleep 5
        get_stream_url
    fi

    echo "🎯 解析成功"
    echo "$REAL_URL"
}

push_stream() {
    local INPUT_URL="$1"

    # 多路输出
    OUTPUTS=()
    for u in $MULTI_RTMP_URLS; do
        OUTPUTS+=(-f flv "$u")
    done

    echo "🚀 开始转推流..."

    ffmpeg -loglevel error -re -i "$INPUT_URL" \
        -c:v libx264 -preset veryfast -tune zerolatency \
        -c:a aac -b:a 128k \
        -r "$TARGET_FPS" \
        "${OUTPUTS[@]}"
}

while true; do
    STREAM_URL=$(get_stream_url)
    push_stream "$STREAM_URL"

    [[ "$LOOP" == "yes" ]] || break

    echo "🔁 ffmpeg 退出，10 秒后重新解析并继续推流..."
    sleep 10
done
