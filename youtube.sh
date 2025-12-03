#!/usr/bin/env bash
set -euo pipefail

echo "=== Ultra FFmpeg Mixed Stream v2 ==="

# -------------------------
# 环境变量
# -------------------------
MULTI_RTMP_URLS="${MULTI_RTMP_URLS:?需要设置 MULTI_RTMP_URLS（空格分隔）}"
VIDEO_DIR="${VIDEO_DIR:-/videos}"

TARGET_FPS="${TARGET_FPS:-30}"
KEYFRAME_INTERVAL_SECONDS="${KEYFRAME_INTERVAL_SECONDS:-2}"
MAX_UPLOAD="${MAX_UPLOAD:-10000k}"

SHOW_FILENAME="${SHOW_FILENAME:-no}"
WATERMARK="${WATERMARK:-no}"
WATERMARK_IMG="${WATERMARK_IMG:-}"
FONT_FILE="${FONT_FILE:-}"

VIDEO_EXTENSIONS="${VIDEO_EXTENSIONS:-mp4,avi,mkv,mov,flv,wmv,webm}"
SLEEP_SECONDS="${SLEEP_SECONDS:-5}"

# -------------------------
log() { echo "[$(date '+%H:%M:%S')] $*"; }

is_copy_compatible() {
    codec=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_name -of csv=p=0 "$1")
    [[ "$codec" == "h264" ]]
}

sort_items() {
    awk '
        {n=999999; if (match($0,/^([0-9]+)/,a)) n=a[1]; printf "%06d\t%s\n",n,$0;
    }' | sort -n -k1,1 | cut -f2-
}

# -------------------------
# 扫描本地 + YouTube (.url)
# -------------------------
load_playlist() {
    mapfile -t FILES_LOCAL < <(
        find "$VIDEO_DIR" -maxdepth 1 -type f \
        \( $(printf -- "-iname '*.%s' -o " ${VIDEO_EXTENSIONS//,/ }) -false \)
    )

    mapfile -t FILES_URL < <(
        find "$VIDEO_DIR" -maxdepth 1 -type f -iname "*.url"
    )

    # 必须至少 1 个视频源
    if [[ ${#FILES_LOCAL[@]} -eq 0 && ${#FILES_URL[@]} -eq 0 ]]; then
        log "❌ 未找到视频或 URL 列表"
        exit 1
    fi

    # 拼接
    PLAYLIST=("${FILES_LOCAL[@]}" "${FILES_URL[@]}")

    mapfile -t PLAYLIST < <(printf "%s\n" "${PLAYLIST[@]}" | sort_items)

    log "已加载 ${#PLAYLIST[@]} 个播放项（本地 + URL）"
}

# -------------------------
# 获取 URL 真实播放地址
# -------------------------
resolve_url() {
    url_file="$1"
    URL=$(sed -n '1p' "$url_file")

    if [[ "$URL" =~ ^https?:// ]]; then
        log "🌐 解析 URL：$URL"
        REAL_URL=$(yt-dlp -f "best" -g "$URL")
        echo "$REAL_URL"
    else
        log "⚠️ URL 文件内容不合法：$URL"
        return 1
    fi
}

# -------------------------
# 选择码率
# -------------------------
choose_bitrate() {
    local h="$1"
    local upl="${MAX_UPLOAD%k}"
    VIDEO_BITRATE="3000k"
    MAXRATE="3500k"
    VIDEO_BUFSIZE="6000k"

    (( h >= 2160 )) && VIDEO_BITRATE="15000k" && MAXRATE="18000k"
    (( h >= 1440 && h < 2160 )) && VIDEO_BITRATE="9000k" && MAXRATE="12000k"
    (( h >= 1080 && h < 1440 )) && VIDEO_BITRATE="6000k" && MAXRATE="8000k"

    [[ ${VIDEO_BITRATE%k} -gt $upl ]] && VIDEO_BITRATE="${upl}k"
    [[ ${MAXRATE%k} -gt $upl ]] && MAXRATE="${upl}k"
}

# -------------------------
# 多路推流构造
# -------------------------
OUTPUTS=()
for u in $MULTI_RTMP_URLS; do
    OUTPUTS+=(-f flv "$u")
done

# -------------------------
# 主流程
# -------------------------
load_playlist
TOTAL=${#PLAYLIST[@]}
idx=0
GOP=$((TARGET_FPS * KEYFRAME_INTERVAL_SECONDS))

while true; do
    item="${PLAYLIST[$idx]}"

    if [[ "$item" =~ \.url$ ]]; then
        log "▶️ 播放 URL 源：$(basename "$item")"

        REAL=$(resolve_url "$item")

        INPUTS=(-i "$REAL")
        FILTER=""
        COPY_MODE="no"

        # URL 永远转码（稳定）
        HAS_AUDIO="yes"

        WIDTH=1920
        HEIGHT=1080
        choose_bitrate "$HEIGHT"

    else
        log "▶️ 播放本地文件：$(basename "$item")"

        INPUTS=(-i "$item")

        read WIDTH HEIGHT < <(ffprobe -v error -select_streams v:0 \
            -show_entries stream=width,height -of csv=p=0 "$item")

        choose_bitrate "$HEIGHT"

        HAS_AUDIO=$(ffprobe -v error -select_streams a:0 \
            -show_entries stream=codec_type -of csv=p=0 "$item" || true)

        if is_copy_compatible "$item"; then
            COPY_MODE="yes"
        else
            COPY_MODE="no"
        fi

        FILTER=""
    fi

    # 字幕/水印
    if [[ "$SHOW_FILENAME" == "yes" ]]; then
        safe=$(basename "$item")
        FILTER="drawtext=text='$safe':fontcolor=white:fontsize=24:x=10:y=h-th-10"
    fi

    if [[ "$WATERMARK" == "yes" && -f "$WATERMARK_IMG" ]]; then
        if [[ -n "$FILTER" ]]; then
            FILTER="[0:v][1:v]overlay=10:10,$FILTER"
            INPUTS+=(-i "$WATERMARK_IMG")
        else
            FILTER="overlay=10:10"
            INPUTS+=(-i "$WATERMARK_IMG")
        fi
    fi

    AUDIO_ARGS=()
    [[ -n "$HAS_AUDIO" ]] && AUDIO_ARGS=(-c:a aac -b:a 128k) || AUDIO_ARGS=(-an)

    COMMON=(
        -preset superfast -tune zerolatency
        -b:v "$VIDEO_BITRATE" -maxrate "$MAXRATE" -bufsize "$VIDEO_BUFSIZE"
        -g "$GOP" -keyint_min "$GOP" -r "$TARGET_FPS"
        "${AUDIO_ARGS[@]}"
    )

    # -------------------------
    # COPY 优先（仅限本地文件）
    # -------------------------
    if [[ "$COPY_MODE" == "yes" && -z "$FILTER" && "$item" != *.url ]]; then
        log "🚀 COPY 模式"
        ffmpeg -loglevel warning -re "${INPUTS[@]}" -c:v copy -c:a copy \
            "${OUTPUTS[@]}" \
            || log "COPY 失败 → 转码"
    fi

    if [[ "$COPY_MODE" == "no" || "$item" == *.url ]]; then
        log "🚀 转码模式"
        if [[ -n "$FILTER" ]]; then
            ffmpeg -loglevel error -re "${INPUTS[@]}" -filter_complex "$FILTER" \
                -c:v libx264 "${COMMON[@]}" "${OUTPUTS[@]}"
        else
            ffmpeg -loglevel error -re "${INPUTS[@]}" -c:v libx264 \
                "${COMMON[@]}" "${OUTPUTS[@]}"
        fi
    fi

    sleep "$SLEEP_SECONDS"

    idx=$(( (idx + 1) % TOTAL ))
    [[ $idx -eq 0 ]] && load_playlist && TOTAL=${#PLAYLIST[@]}
done
