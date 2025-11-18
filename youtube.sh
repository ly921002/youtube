#!/usr/bin/env bash
set -e

echo "===== FFmpeg 自动推流脚本（环境变量控制版）====="

# ---------------------------
# 环境变量
# ---------------------------

RTMP_URL="${RTMP_URL:?请设置 RTMP_URL 环境变量，例如 rtmp://xxx/live}"
VIDEO_DIR="${VIDEO_DIR:-/videos}"
WATERMARK="${WATERMARK:-no}"
WATERMARK_IMG="${WATERMARK_IMG:-}"
SLEEP_MIN="${SLEEP_MIN:-5}"
SLEEP_MAX="${SLEEP_MAX:-15}"

# ---------------------------
# 检查环境
# ---------------------------

if [ ! -d "$VIDEO_DIR" ]; then
    echo "❌ ERROR: VIDEO_DIR 目录不存在: $VIDEO_DIR"
    exit 1
fi

if [ "$WATERMARK" = "yes" ]; then
    if [ ! -f "$WATERMARK_IMG" ]; then
        echo "❌ ERROR: WATERMARK=yes 但未找到水印图像: $WATERMARK_IMG"
        exit 1
    fi
    FILTER="-filter_complex overlay=W-w-5:5"
else
    FILTER=""
fi

echo "RTMP_URL     = $RTMP_URL"
echo "VIDEO_DIR    = $VIDEO_DIR"
echo "WATERMARK    = $WATERMARK"
echo "SLEEP_MIN    = $SLEEP_MIN 秒"
echo "SLEEP_MAX    = $SLEEP_MAX 秒"
echo "========================================="

# ---------------------------
# 推流循环
# ---------------------------

while true; do
    # 选随机视频
    VIDEO=$(find "$VIDEO_DIR" -type f -name "*.mp4" | shuf -n 1)

    if [ -z "$VIDEO" ]; then
        echo "❌ 未找到任何 MP4 文件，请检查目录：$VIDEO_DIR"
        sleep 5
        continue
    fi

    echo "▶ 正在推流: $VIDEO"

    ffmpeg \
        -re \
        -i "$VIDEO" \
        $FILTER \
        -c:v libx264 \
        -preset veryfast \
        -c:a aac \
        -b:a 192k \
        -f flv "$RTMP_URL"

    # 每个视频播放完随机休息一下
    SLEEP_TIME=$(shuf -i "$SLEEP_MIN"-"$SLEEP_MAX" -n 1)
    echo "⏳ 等待 $SLEEP_TIME 秒后继续下一段推流..."
    sleep "$SLEEP_TIME"
done
