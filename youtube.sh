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
    echo "🔍 尝试 android_embedded 客户端解析..."

    # ① android_embedded（支持 cookie）
    REAL_URL=$(yt-dlp -g --cookies "$COOKIE_FILE" \
        --extractor-args "youtube:player_client=android_embedded;js_engine=node" \
        -f "bv*+ba/best" "$YOUTUBE_URL" 2>/dev/null || true)

    if [[ -z "$REAL_URL" ]]; then
        echo "⚠️ 切换到 iOS 客户端..."
        REAL_URL=$(yt-dlp -g --cookies "$COOKIE_FILE" \
            --extractor-args "youtube:player_client=ios;js_engine=node" \
            -f "bv*+ba/best" "$YOUTUBE_URL" 2>/dev/null || true)
    fi

    if [[ -z "$REAL_URL" ]]; then
        echo "⚠️ 切换到 web_creator 客户端..."
        REAL_URL=$(yt-dlp -g --cookies "$COOKIE_FILE" \
            --extractor-args "youtube:player_client=web_creator;js_engine=node" \
            -f "bv*+ba/best" "$YOUTUBE_URL" 2>/dev/null || true)
    fi

    if [[ -z "$REAL_URL" ]]; then
        echo "⚠️ 切换到 web 模式（最后尝试）..."
        REAL_URL=$(yt-dlp -g --cookies "$COOKIE_FILE" \
            --extractor-args "youtube:force_persistent_connection=True;player_client=web;js_engine=node" \
            -f "bv*+ba/best" "$YOUTUBE_URL" 2>/dev/null || true)
    fi

    if [[ -z "$REAL_URL" ]]; then
        echo "❌ 所有客户端都解析失败 —— 10 秒后重试"
        sleep 10
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
