#!/usr/bin/env bash
set -e

echo "===== FFmpeg 自动推流（自动识别全部视频格式）====="

# ---------------------------
# 环境变量
# ---------------------------

RTMP_URL="${RTMP_URL:?必须设置 RTMP_URL，例如 rtmp://xxx/live}"
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
        echo "❌ ERROR: WATERMARK=yes 但未找到图片: $WATERMARK_IMG"
        exit 1
    fi
    FILTER="-filter_complex overlay=W-w-5:5"
else
    FILTER=""
fi

echo "推流地址: $RTMP_URL"
echo "视频目录: $VIDEO_DIR"
echo "水印开关: $WATERMARK"
echo "随机休眠: ${SLEEP_MIN}-${SLEEP_MAX} 秒 中间"
echo "========================================="

# ---------------------------
# 自动识别视频文件
# ---------------------------

function load_video_list() {
    echo "🔍 正在扫描并检测可用视频格式..."

    VIDEO_LIST=()

    # 遍历所有文件，不限制扩展名
    for f in "$VIDEO_DIR"/*; do
        [ -f "$f" ] || continue

        # ffprobe 检测视频可读性（不会输出内容）
        if ffprobe -v error -show_entries stream=codec_type \
            -of default=noprint_wrappers=1:nokey=1 "$f" | grep -q "video"; then
            VIDEO_LIST+=("$f")
        fi
    done

    if [ ${#VIDEO_LIST[@]} -eq 0 ]; then
        echo "❌ ERROR: 未找到任何 FFmpeg 可识别的视频格式"
        exit 1
    fi

    echo "✅ 找到 ${#VIDEO_LIST[@]} 个有效视频文件"
}

load_video_list

# ---------------------------
# 推流循环
# ---------------------------

while true; do
    # 如目录内容更新，可重新加载列表（可选：每 20 次刷新一次）
    if [ $((RANDOM % 20)) -eq 0 ]; then
        load_video_list
    fi

    # 随机选取一个视频
    VIDEO="${VIDEO_LIST[RANDOM % ${#VIDEO_LIST[@]}]}"

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

    # 结束后随机休眠
    SLEEP_TIME=$(shuf -i "$SLEEP_MIN"-"$SLEEP_MAX" -n 1)
    echo "⏳ 等待 $SLEEP_TIME 秒..."
    sleep "$SLEEP_TIME"
done
