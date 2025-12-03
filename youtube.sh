#!/usr/bin/env bash
set -euo pipefail

echo "=== Ultra FFmpeg Auto Stream v1 (字幕增强版) ==="

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
SUBTITLE_ENABLE="${SUBTITLE_ENABLE:-no}"
SUBTITLE_EXTENSIONS="${SUBTITLE_EXTENSIONS:-srt,ass,vtt,ssa}"
SLEEP_SECONDS="${SLEEP_SECONDS:-8}"

# -------------------------
# 工具函数
# -------------------------

log() { echo "[$(date '+%H:%M:%S')] $*"; }

sort_videos() {
    awk '
        {
            file=$0;
            n=999999;
            if (match(file, /^([0-9]+)/, a)) n=a[1];
            printf "%06d\t%s\n", n, file;
        }
    ' | sort -n -k1,1 | cut -f2-
}

load_videos() {
    IFS=',' read -ra exts <<<"$VIDEO_EXTENSIONS"
    find_args=()
    for e in "${exts[@]}"; do
        find_args+=(-iname "*.${e,,}" -o)
    done
    unset 'find_args[${#find_args[@]}-1]'

    mapfile -t raw < <(find "$VIDEO_DIR" -maxdepth 1 -type f \( "${find_args[@]}" \))

    [[ ${#raw[@]} -eq 0 ]] && { log "❌❌ 未找到视频"; exit 1; }

    # 只保留有视频轨道的文件
    valid=()
    for f in "${raw[@]}"; do
        if ffprobe -v error -select_streams v:0 -show_entries stream=codec_type \
            -of csv=p=0 "$v" 2>/dev/null | grep -q video; then
            valid+=("$f")
        fi
    done

    mapfile -t VIDEO_LIST < <(printf "%s\n" "${valid[@]}" | sort_videos)
}

# 查找字幕文件
find_subtitle() {
    local video_path="$1"
    local base_name="${video_path%.*}"
    
    IFS=',' read -ra exts <<<"$SUBTITLE_EXTENSIONS"
    for ext in "${exts[@]}"; do
        local subtitle_file="${base_name}.${ext}"
        if [[ -f "$subtitle_file" ]]; then
            echo "$subtitle_file"
            log "📝 找到字幕文件: $(basename "$subtitle_file")"
            return 0
        fi
    done
    
    # 尝试其他常见字幕文件名模式
    local dir=$(dirname "$video_path")
    local name=$(basename "$video_path" | sed 's/\.[^.]*$//')
    
    # 查找匹配的字幕文件
    for sub_ext in "${exts[@]}"; do
        local potential_subs=("${dir}/${name}.${sub_ext}" "${dir}/${name}.zh.${sub_ext}" "${dir}/${name}.chs.${sub_ext}")
        for sub_file in "${potential_subs[@]}"; do
            if [[ -f "$sub_file" && "$sub_file" != "$video_path" ]]; then
                echo "$sub_file"
                log "📝 找到字幕文件: $(basename "$sub_file")"
                return 0
            fi
        done
    done
    
    echo ""
    return 1
}

choose_bitrate() {
    local h="$1"
    local v="3000k" m="3500k" b="6000k"
    (( h >= 2160 )) && v="14000k" m="15000k" b="20000k"
    (( h >= 1440 && h < 2160 )) && v="9000k" m="10000k" b="16000k"
    (( h >= 1080 && h < 1440 )) && v="5500k" m="6000k" b="9000k"

    upl="${MAX_UPLOAD%k}"
    [[ ${v%k} -gt $upl ]] && v="${upl}k"
    [[ ${m%k} -gt $upl ]] && m="${upl}k"

    VIDEO_BITRATE="$v"
    MAXRATE="$m"
    VIDEO_BUFSIZE="$b"
}

# 提前判断是否可 COPY
is_copy_compatible() {
    codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
        -of csv=p=0 "$1")
    [[ "$codec" == "h264" ]]
}

# -------------------------
# 多路 RTMP 输出构建
# -------------------------
OUTPUTS=()
for u in $MULTI_RTMP_URLS; do
    OUTPUTS+=(-f flv "$u")
done

# -------------------------
# 主流程
# -------------------------
log "📁📁 扫描视频..."
load_videos
TOTAL=${#VIDEO_LIST[@]}
log "找到 $TOTAL 个视频"

idx=0
GOP=$((TARGET_FPS * KEYFRAME_INTERVAL_SECONDS))

while true; do
    v="${VIDEO_LIST[$idx]}"
    base=$(basename "$v")
    log "▶️ 播放 ($((idx+1))/$TOTAL) $base"

    # 分辨率
    read WIDTH HEIGHT < <(ffprobe -v error -select_streams v:0 \
        -show_entries stream=width,height -of csv=p=0 "$v")
    choose_bitrate "$HEIGHT"

    # 音频检测
    has_audio=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_type \
        -of csv=p=0 "$v" || true)
    AUDIO_ARGS=()
    [[ -n "$has_audio" ]] && AUDIO_ARGS=(-c:a aac -b:a 128k) || AUDIO_ARGS=(-an)

    # 字幕检测和处理
    SUBTITLE_FILTER=""
    SUBTITLE_INPUTS=()
    if [[ "$SUBTITLE_ENABLE" == "yes" ]]; then
        subtitle_file=$(find_subtitle "$v")
        if [[ -n "$subtitle_file" ]]; then
            case "${subtitle_file##*.}" in
                ass|ssa)
                    SUBTITLE_FILTER="ass='$subtitle_file'"
                    ;;
                srt|vtt)
                    SUBTITLE_FILTER="subtitles='$subtitle_file':force_style='FontName=Arial,FontSize=20,PrimaryColour=&H00FFFFFF,OutlineColour=&H00000000,BorderStyle=1,Outline=1,Shadow=0'"
                    ;;
            esac
        fi
    fi

    # 文字滤镜
    TEXT_FILTER=""
    if [[ "$SHOW_FILENAME" == "yes" ]]; then
        safe=$(echo "$base" | sed "s/'/\\\\'/g;s/:/\\\\:/g")
        font_arg=""
        [[ -f "$FONT_FILE" ]] && font_arg="fontfile='$FONT_FILE':"
        TEXT_FILTER="drawtext=${font_arg}text='$safe':fontcolor=white:fontsize=24:x=10:y=h-th-10:box=1:boxcolor=black@0.5"
    fi

    # 水印滤镜
    WATERMARK_FILTER=""
    WATERMARK_INPUTS=()
    if [[ "$WATERMARK" == "yes" && -f "$WATERMARK_IMG" ]]; then
        WATERMARK_FILTER="[0:v][1:v]overlay=10:10"
        WATERMARK_INPUTS=(-i "$WATERMARK_IMG")
    fi

    # 构建滤镜链
    FILTER_COMPLEX=""
    INPUTS=(-i "$v")
    FILTER_COUNT=0

    # 合并所有滤镜
    FILTER_CHAINS=()

    # 如果有水印，从水印开始
    if [[ -n "$WATERMARK_FILTER" ]]; then
        FILTER_CHAINS+=("$WATERMARK_FILTER")
        INPUTS+=("${WATERMARK_INPUTS[@]}")
        FILTER_COUNT=1
    fi

    # 添加文字滤镜
    if [[ -n "$TEXT_FILTER" ]]; then
        if [[ $FILTER_COUNT -eq 0 ]]; then
            FILTER_CHAINS+=("[0:v]$TEXT_FILTER")
        else
            FILTER_CHAINS+=("$TEXT_FILTER")
        fi
        FILTER_COUNT=$((FILTER_COUNT + 1))
    fi

    # 添加字幕滤镜（最后添加，确保在最上层）
    if [[ -n "$SUBTITLE_FILTER" ]]; then
        if [[ $FILTER_COUNT -eq 0 ]]; then
            FILTER_CHAINS+=("[0:v]$SUBTITLE_FILTER")
        else
            FILTER_CHAINS+=("$SUBTITLE_FILTER")
        fi
        FILTER_COUNT=$((FILTER_COUNT + 1))
    fi

    # 构建完整的filter_complex字符串
    if [[ ${#FILTER_CHAINS[@]} -gt 0 ]]; then
        FILTER_COMPLEX=$(IFS=,; echo "${FILTER_CHAINS[*]}")
    fi

    COMMON=(
        -preset superfast -tune zerolatency
        -b:v "$VIDEO_BITRATE" -maxrate "$MAXRATE" -bufsize "$VIDEO_BUFSIZE"
        -g "$GOP" -keyint_min "$GOP" -r "$TARGET_FPS"
        "${AUDIO_ARGS[@]}"
    )

    # COPY 优先（有滤镜时不能使用COPY）
    if [[ -z "$FILTER_COMPLEX" && "$WATERMARK" == "no" && "$SHOW_FILENAME" == "no" && "$SUBTITLE_ENABLE" == "no" && $(is_copy_compatible "$v" && echo "yes") == "yes" ]]; then
        log "🚀🚀 COPY 模式"
        ffmpeg -loglevel warning -re -i "$v" -c:v copy -c:a copy "${OUTPUTS[@]}" || {
            log "⚠️ COPY 失败 → 转码"
            if [[ -n "$FILTER_COMPLEX" ]]; then
                ffmpeg -loglevel error -re "${INPUTS[@]}" -filter_complex "$FILTER_COMPLEX" \
                    -map "[v]" -c:v libx264 "${COMMON[@]}" "${OUTPUTS[@]}" || log "❌❌ 推流失败"
            else
                ffmpeg -loglevel error -re "${INPUTS[@]}" -c:v libx264 \
                    "${COMMON[@]}" "${OUTPUTS[@]}" || log "❌❌ 推流失败"
            fi
        }
    else
        log "🚀🚀 转码模式"
        if [[ -n "$FILTER_COMPLEX" ]]; then
            # 使用复杂的滤镜链
            ffmpeg -loglevel error -re "${INPUTS[@]}" -filter_complex "$FILTER_COMPLEX" \
                -map "[v]" -c:v libx264 "${COMMON[@]}" "${OUTPUTS[@]}" || log "❌❌ 推流失败"
        else
            # 简单转码
            ffmpeg -loglevel error -re "${INPUTS[@]}" -c:v libx264 \
                "${COMMON[@]}" "${OUTPUTS[@]}" || log "❌❌ 推流失败"
        fi
    fi

    sleep "$SLEEP_SECONDS"

    idx=$(( (idx + 1) % TOTAL ))
    [[ $idx -eq 0 ]] && load_videos && TOTAL=${#VIDEO_LIST[@]}
done
