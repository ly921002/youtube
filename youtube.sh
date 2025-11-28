#!/usr/bin/env bash
set -euo pipefail   # 严格模式，避免脚本静默失败

echo "=== Ultra FFmpeg Auto Stream v3.1 ==="

# ===== 基础参数 =====
: "${MULTI_RTMP_URLS:?需要设置 MULTI_RTMP_URLS}"   # 多路 RTMP 输出必填
VIDEO_DIR="${VIDEO_DIR:-/videos}"

TARGET_FPS="${TARGET_FPS:-30}"
KEYFRAME_INTERVAL_SECONDS="${KEYFRAME_INTERVAL_SECONDS:-2}"
MAX_UPLOAD="${MAX_UPLOAD:-10000k}"

SHOW_FILENAME="${SHOW_FILENAME:-no}"
WATERMARK="${WATERMARK:-no}"
WATERMARK_IMG="${WATERMARK_IMG:-}"
FONT_FILE="${FONT_FILE:-}"

VIDEO_EXTENSIONS="${VIDEO_EXTENSIONS:-mp4,avi,mkv,mov,flv,wmv,webm}"
SLEEP_SECONDS="${SLEEP_SECONDS:-8}"

# ===== 工具函数 =====
log() { echo "[$(date '+%H:%M:%S')] $*"; }

sort_videos() {   # 按文件名前缀数字排序（001、002...）
    awk '{
        n=999999; if (match($0, /^([0-9]+)/, a)) n=a[1];
        printf "%06d\t%s\n", n, $0;
    }' | sort -n | cut -f2-
}

load_videos() {   # 扫描目录 + 过滤无视频轨道
    IFS=',' read -ra exts <<<"$VIDEO_EXTENSIONS"
    find_args=()
    for e in "${exts[@]}"; do find_args+=(-iname "*.${e,,}" -o); done
    unset 'find_args[${#find_args[@]}-1]'

    mapfile -t raw < <(find "$VIDEO_DIR" -maxdepth 1 -type f \( "${find_args[@]}" \))
    [[ ${#raw[@]} -eq 0 ]] && { log "❌ 未找到视频"; exit 1; }

    mapfile -t VIDEO_LIST < <(
        for f in "${raw[@]}"; do
            ffprobe -v error -select_streams v:0 -show_entries stream=codec_type \
                -of csv=p=0 "$f" | grep -q video && echo "$f"
        done | sort_videos
    )
}

choose_bitrate() {   # 根据分辨率选择最佳码率
    local h="$1" upl="${MAX_UPLOAD%k}"
    case $h in
        2160|2[2-9][0-9][0-9]) v=14000 m=15000 b=20000 ;;
        1440|1[4-9][0-9][0-9]) v=9000  m=10000 b=16000 ;;
        1080|1[0-3][0-9][0-9]) v=5500  m=6000  b=9000 ;;
        *)                    v=3000  m=3500  b=6000 ;;
    esac
    (( v > upl )) && v=$upl
    (( m > upl )) && m=$upl
    VIDEO_BITRATE="${v}k"; MAXRATE="${m}k"; VIDEO_BUFSIZE="${b}k"
}

is_copy_ok() {   # 能否直接视频流 copy
    [[ "$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
        -of csv=p=0 "$1")" == "h264" ]]
}

# ===== 构建 RTMP 多路输出 =====
OUTPUTS=()
for u in $MULTI_RTMP_URLS; do OUTPUTS+=(-f flv "$u"); done

# ===== 主循环 =====
log "📁 扫描视频..."
load_videos
TOTAL=${#VIDEO_LIST[@]}
GOP=$((TARGET_FPS * KEYFRAME_INTERVAL_SECONDS))
idx=0

while true; do
    v="${VIDEO_LIST[$idx]}"
    base=$(basename "$v")
    log "▶️ 播放 ($((idx+1))/$TOTAL) $base"

    # 读取视频分辨率 → 自动选码率
    read WIDTH HEIGHT < <(ffprobe -v error -select_streams v:0 \
        -show_entries stream=width,height -of csv=p=0 "$v")
    choose_bitrate "$HEIGHT"

    # 判断是否有音频
    if ffprobe -v error -select_streams a:0 -show_entries stream=codec_type \
        -of csv=p=0 "$v" >/dev/null 2>&1; then
        AUDIO_ARGS=(-c:a aac -b:a 128k)
    else
        AUDIO_ARGS=(-an)
    fi

    # ===== 构建滤镜（文字 + 水印） =====
    TEXT=""
    if [[ "$SHOW_FILENAME" == "yes" ]]; then
        safe=$(printf "%s" "$base" | sed "s/'/\\\\'/g;s/:/\\\\:/g")
        font_arg=""
        [[ -f "$FONT_FILE" ]] && font_arg="fontfile='$FONT_FILE':"
        TEXT="drawtext=${font_arg}text='$safe':fontcolor=white:fontsize=24:x=10:y=h-th-10:box=1:boxcolor=black@0.5"
    fi

    FILTERS=()
    INPUTS=(-i "$v")

    if [[ "$WATERMARK" == "yes" && -f "$WATERMARK_IMG" ]]; then
        INPUTS+=(-i "$WATERMARK_IMG")
        FILTERS+=("[0:v][1:v]overlay=10:10")
    fi
    [[ -n "$TEXT" ]] && FILTERS+=("$TEXT")

    FILTER_CHAIN=""
    (( ${#FILTERS[@]} > 0 )) && FILTER_CHAIN=$(IFS=','; echo "${FILTERS[*]}")

    # ===== FFmpeg 公共参数 =====
    COMMON=(
        -preset superfast -tune zerolatency
        -b:v "$VIDEO_BITRATE" -maxrate "$MAXRATE" -bufsize "$VIDEO_BUFSIZE"
        -g "$GOP" -keyint_min "$GOP" -r "$TARGET_FPS"
        "${AUDIO_ARGS[@]}"
    )

    # ===== 优先使用 COPY（无滤镜且 H264 才能 copy） =====
    if [[ -z "$FILTER_CHAIN" && "$SHOW_FILENAME" == "no" && "$WATERMARK" == "no" \
        && $(is_copy_ok "$v" && echo yes) == yes ]]; then

        log "🚀 COPY 模式"
        ffmpeg -loglevel warning -re -i "$v" -c:v copy -c:a copy "${OUTPUTS[@]}" \
            || { log "⚠️ COPY 失败 → 转码"; \
                 ffmpeg -loglevel error -re -i "$v" -c:v libx264 "${COMMON[@]}" \
                    "${OUTPUTS[@]}"; }

    else
        # ========= 转码模式 =========
        log "🚀 转码模式"

        if [[ -n "$FILTER_CHAIN" ]]; then
            ffmpeg -loglevel error -re "${INPUTS[@]}" -filter_complex "$FILTER_CHAIN" \
                -c:v libx264 "${COMMON[@]}" "${OUTPUTS[@]}"
        else
            ffmpeg -loglevel error -re "${INPUTS[@]}" -c:v libx264 \
                "${COMMON[@]}" "${OUTPUTS[@]}"
        fi
    fi

    sleep "$SLEEP_SECONDS"

    idx=$(( (idx + 1) % TOTAL ))   # 循环播放
    [[ $idx -eq 0 ]] && load_videos && TOTAL=${#VIDEO_LIST[@]}   # 自动刷新目录
done
