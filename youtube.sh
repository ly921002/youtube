#!/usr/bin/env bash
set -euo pipefail

echo "===== FFmpeg 自动推流（顺序循环播放）====="

# ---------------------------
# 环境变量
# ---------------------------

RTMP_URL="${RTMP_URL:?必须设置 RTMP_URL，例如 rtmp://xxx/live}"
VIDEO_DIR="${VIDEO_DIR:-/videos}"

WATERMARK="${WATERMARK:-no}"
WATERMARK_IMG="${WATERMARK_IMG:-}"

VIDEO_BITRATE="${VIDEO_BITRATE:-1000k}"
AUDIO_BITRATE="${AUDIO_BITRATE:-128k}"
VIDEO_BUFSIZE="${VIDEO_BUFSIZE:-2000k}"
MAXRATE="${MAXRATE:-1200k}"
KEYFRAME_INTERVAL_SECONDS="${KEYFRAME_INTERVAL_SECONDS:-4}"
TARGET_FPS="${TARGET_FPS:-30}"

VIDEO_EXTENSIONS="${VIDEO_EXTENSIONS:-mp4,avi,mkv,mov,flv,wmv,webm}"
SLEEP_SECONDS="${SLEEP_SECONDS:-10}"   # 固定休眠，不要随机

# ---------------------------
# 基础检查
# ---------------------------

if [[ ! -d "$VIDEO_DIR" ]]; then
    echo "❌ VIDEO_DIR 不存在: $VIDEO_DIR"
    exit 1
fi

if [[ "$WATERMARK" = "yes" ]]; then
    if [[ ! -f "$WATERMARK_IMG" ]]; then
        echo "❌ 水印启用，但 WATERMARK_IMG 不存在: $WATERMARK_IMG"
        exit 1
    fi
    USE_WATERMARK=true
else
    USE_WATERMARK=false
fi

echo "推流地址: $RTMP_URL"
echo "视频目录: $VIDEO_DIR"
echo "水印开关: $WATERMARK"
echo "========================================="


# ---------------------------
# 通用排序函数（按数字前缀排序）
# ---------------------------
sort_videos() {
    local files=("$@")
    local out=()

    while IFS= read -r line; do
        out+=("$line")
    done < <(
        for f in "${files[@]}"; do
            local base prefix
            base=$(basename "$f")

            if [[ "$base" =~ ^([0-9]+)[-_\.] ]]; then
                prefix="${BASH_REMATCH[1]}"
            elif [[ "$base" =~ ^([0-9]+) ]]; then
                prefix="${BASH_REMATCH[1]}"
            else
                prefix=999999
            fi

            printf "%06d\t%s\n" "$prefix" "$f"
        done | sort -n -k1,1 | cut -f2-
    )

    printf '%s\n' "${out[@]}"
}


# ---------------------------
# 加载视频列表
# ---------------------------
load_video_list() {
    local exts ext

    IFS=',' read -ra exts <<< "$VIDEO_EXTENSIONS"
    local args=()

    for ext in "${exts[@]}"; do
        args+=(-name "*.${ext,,}")
        args+=(-o)
        args+=(-name "*.${ext^^}")
        args+=(-o)
    done
    unset 'args[${#args[@]}-1]'  # 去掉最后一个 -o

    local raw_files=()

    while IFS= read -r -d '' f; do
        raw_files+=("$f")
    done < <(find "$VIDEO_DIR" -maxdepth 1 -type f \( "${args[@]}" \) -print0)

    if [[ ${#raw_files[@]} -eq 0 ]]; then
        echo "❌ 未找到任何视频文件"
        exit 1
    fi

    # 过滤有效视频（只跑一次 ffprobe）
    local valid=()
    for f in "${raw_files[@]}"; do
        if ffprobe -v error -select_streams v:0 -show_entries stream=codec_type \
            -of default=nw=1:nk=1 "$f" 2>/dev/null | grep -q video; then
            valid+=("$f")
        fi
    done

    if [[ ${#valid[@]} -eq 0 ]]; then
        echo "❌ 找到文件，但均不是有效视频"
        exit 1
    fi

    mapfile -t VIDEO_LIST < <(sort_videos "${valid[@]}")
}


# ---------------------------
# 显示视频信息
# ---------------------------
show_video_info() {
    local f="$1"
    local base=$(basename "$f")

    local info=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=width,height \
        -of csv=s=x:p=0 "$f" 2>/dev/null || echo "unknown")

    echo "文件：$base ($info)"
}


# ---------------------------
# 构造 FFmpeg 参数
# ---------------------------
build_ffmpeg_args() {
    local video="$1"
    local gop=$((KEYFRAME_INTERVAL_SECONDS * TARGET_FPS))

    local args=(
        -re
        -i "$video"
    )

    if $USE_WATERMARK; then
        args+=(
            -i "$WATERMARK_IMG"
            -filter_complex "[1:v]scale=iw/6:-1[wm];[0:v][wm]overlay=W-w-10:10"
        )
    fi

    args+=(
        -c:v libx264
        -preset veryfast
        -b:v "$VIDEO_BITRATE"
        -maxrate "$MAXRATE"
        -bufsize "$VIDEO_BUFSIZE"
        -g "$gop"
        -keyint_min "$gop"
        -r "$TARGET_FPS"
        -c:a aac
        -b:a "$AUDIO_BITRATE"
        -f flv "$RTMP_URL"
    )

    printf '%s\n' "${args[@]}"
}


# ---------------------------
# 主流程
# ---------------------------

echo "🔍 加载视频列表..."
load_video_list
TOTAL=${#VIDEO_LIST[@]}
echo "📁 共找到 $TOTAL 个视频"

index=0

while true; do
    video="${VIDEO_LIST[$index]}"
    echo ""
    echo "🎬 播放第 $((index+1))/$TOTAL 个视频"
    show_video_info "$video"

    # 构建参数
    mapfile -t FF_ARGS < <(build_ffmpeg_args "$video")

    echo "▶️ FFmpeg 开始推流（已开启详细日志）..."
    if ! ffmpeg -loglevel verbose "${FF_ARGS[@]}"; then
        echo "❌ FFmpeg 推流失败！以下是错误原因 ↑"
    fi

    echo "⏳ 等待 ${SLEEP_SECONDS} 秒..."
    sleep "$SLEEP_SECONDS"

    index=$(( (index + 1) % TOTAL ))

    # 每完成一轮，重新扫描视频（用于新增文件）
    if [[ $index -eq 0 ]]; then
        echo "🔄 重新扫描目录..."
        load_video_list
        TOTAL=${#VIDEO_LIST[@]}
    fi
done
