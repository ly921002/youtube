#!/usr/bin/env bash
set -euo pipefail

echo "===== FFmpeg 自动推流（顺序循环播放 + 智能码率）====="

# ---------------------------
# 环境变量
# ---------------------------
RTMP_URL="${RTMP_URL:?必须设置 RTMP_URL，例如 rtmp://xxx/live}"
VIDEO_DIR="${VIDEO_DIR:-/videos}"

WATERMARK="${WATERMARK:-no}"
WATERMARK_IMG="${WATERMARK_IMG:-}"

TARGET_FPS="${TARGET_FPS:-30}"
KEYFRAME_INTERVAL_SECONDS="${KEYFRAME_INTERVAL_SECONDS:-4}"

# VPS 最大可用上传带宽限制（例如 VPS 上行 10Mbps）
# 可在 Docker 启动时 -e MAX_UPLOAD="8000k" 覆盖
MAX_UPLOAD="${MAX_UPLOAD:-10000k}"

SLEEP_SECONDS="${SLEEP_SECONDS:-10}"

VIDEO_EXTENSIONS="${VIDEO_EXTENSIONS:-mp4,avi,mkv,mov,flv,wmv,webm}"

# ---------------------------
# 基础检查
# ---------------------------
if [[ ! -d "$VIDEO_DIR" ]]; then
    echo "❌ 视频目录不存在：$VIDEO_DIR"
    exit 1
fi

if [[ "$WATERMARK" = "yes" ]]; then
    if [[ ! -f "$WATERMARK_IMG" ]]; then
        echo "❌ 水印启用，但未找到图片：$WATERMARK_IMG"
        exit 1
    fi
    USE_WATERMARK=true
else
    USE_WATERMARK=false
fi

echo "推流地址: $RTMP_URL"
echo "视频目录: $VIDEO_DIR"
echo "水印: $WATERMARK"
echo "VPS 最大上传带宽: $MAX_UPLOAD"
echo "========================================="

# ---------------------------
# 按数字前缀排序
# ---------------------------
sort_videos() {
    local files=("$@")
    local out=()

    while IFS= read -r line; do
        out+=("$line")
    done < <(
        for f in "${files[@]}"; do
            local base=$(basename "$f")
            local prefix=999999

            if   [[ "$base" =~ ^([0-9]+)[-_\.] ]]; then prefix="${BASH_REMATCH[1]}"
            elif [[ "$base" =~ ^([0-9]+)       ]]; then prefix="${BASH_REMATCH[1]}"
            fi

            printf "%06d\t%s\n" "$prefix" "$f"
        done | sort -n -k1,1 | cut -f2-
    )

    printf '%s\n' "${out[@]}"
}

# ---------------------------
# 扫描视频
# ---------------------------
load_video_list() {
    local exts
    IFS=',' read -ra exts <<< "$VIDEO_EXTENSIONS"

    local args=()
    for ext in "${exts[@]}"; do
        args+=(-iname "*.${ext,,}")
        args+=(-o)
    done
    unset 'args[${#args[@]}-1]'

    local raw=()
    while IFS= read -r -d '' f; do raw+=("$f"); done < <(find "$VIDEO_DIR" -maxdepth 1 -type f \( "${args[@]}" \) -print0)

    if [[ ${#raw[@]} -eq 0 ]]; then
        echo "❌ 未找到视频"
        exit 1
    fi

    local valid=()
    for f in "${raw[@]}"; do
        if ffprobe -v error -select_streams v:0 -show_entries stream=codec_type \
            -of default=nw=1:nk=1 "$f" 2>/dev/null | grep -q video; then
            valid+=("$f")
        fi
    done

    mapfile -t VIDEO_LIST < <(sort_videos "${valid[@]}")
}

# ---------------------------
# 自动码率策略（含 VPS 限速）
# ---------------------------
choose_bitrate() {
    local width="$1" height="$2"

    # 默认 720p
    local v_b="3000k"   # 视频码率
    local maxr="3500k"  # 最大码率
    local buf="6000k"

    if   (( height >= 2160 )); then  # 4K
        v_b="14000k"; maxr="15000k"; buf="20000k"
    elif (( height >= 1440 )); then  # 2K
        v_b="9000k"; maxr="10000k"; buf="16000k"
    elif (( height >= 1080 )); then  # 1080p
        v_b="5500k"; maxr="6000k"; buf="9000k"
    elif (( height >= 720 )); then   # 720p
        v_b="3000k"; maxr="3500k"; buf="6000k"
    fi

    # VPS 限速（取最小值）
    local v_bps=${v_b%k}
    local maxr_bps=${maxr%k}
    local upl_bps=${MAX_UPLOAD%k}

    if (( v_bps > upl_bps )); then v_b="${upl_bps}k"; fi
    if (( maxr_bps > upl_bps )); then maxr="${upl_bps}k"; fi

    VIDEO_BITRATE="$v_b"
    MAXRATE="$maxr"
    VIDEO_BUFSIZE="$buf"
}

# ---------------------------
# 主流程
# ---------------------------
echo "🔍 扫描视频..."
load_video_list
TOTAL=${#VIDEO_LIST[@]}
echo "📁 找到 $TOTAL 个视频"

index=0

while true; do
    video="${VIDEO_LIST[$index]}"
    base=$(basename "$video")

    echo ""
    echo "🎬 播放第 $((index+1))/$TOTAL 个视频：$base"

    # 解析视频分辨率
    read WIDTH HEIGHT <<< $(ffprobe -v error -select_streams v:0 \
        -show_entries stream=width,height -of csv=p=0 "$video")

    echo "分辨率：${WIDTH}x${HEIGHT}"

    # 自动选择码率
    choose_bitrate "$WIDTH" "$HEIGHT"

    echo "自动码率：VIDEO=$VIDEO_BITRATE  MAXRATE=$MAXRATE  BUF=$VIDEO_BUFSIZE"

    GOP=$((TARGET_FPS * KEYFRAME_INTERVAL_SECONDS))

    echo "▶️ 开始推流（日志已打开）..."
    if $USE_WATERMARK; then
        ffmpeg -loglevel verbose \
            -re -i "$video" \
            -i "$WATERMARK_IMG" \
            -filter_complex "overlay=10:10" \
            -c:v libx264 -preset veryfast \
            -b:v "$VIDEO_BITRATE" -maxrate "$MAXRATE" -bufsize "$VIDEO_BUFSIZE" \
            -g "$GOP" -keyint_min "$GOP" -r "$TARGET_FPS" \
            -c:a aac -b:a 160k \
            -f flv "$RTMP_URL"
    else
        ffmpeg -loglevel verbose \
            -re -i "$video" \
            -c:v libx264 -preset veryfast \
            -b:v "$VIDEO_BITRATE" -maxrate "$MAXRATE" -bufsize "$VIDEO_BUFSIZE" \
            -g "$GOP" -keyint_min "$GOP" -r "$TARGET_FPS" \
            -c:a aac -b:a 160k \
            -f flv "$RTMP_URL"
    fi

    echo "⏳ 等待 $SLEEP_SECONDS 秒..."
    sleep "$SLEEP_SECONDS"

    # 下一条
    index=$(( (index + 1) % TOTAL ))

    if [[ $index -eq 0 ]]; then
        echo "🔄 再次扫描目录（检查新视频）..."
        load_video_list
        TOTAL=${#VIDEO_LIST[@]}
    fi
done
