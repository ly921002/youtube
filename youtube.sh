#!/usr/bin/env bash
set -euo pipefail

echo "=== Ultra FFmpeg Auto Stream v1 (Subtitles Support) ==="

# -------------------------
# 环境变量
# -------------------------
MULTI_RTMP_URLS="${MULTI_RTMP_URLS:?需要设置 MULTI_RTMP_URLS（空格分隔）}"
VIDEO_DIR="${VIDEO_DIR:-/videos}"

TARGET_FPS="${TARGET_FPS:-30}"
KEYFRAME_INTERVAL_SECONDS="${KEYFRAME_INTERVAL_SECONDS:-2}"
MAX_UPLOAD="${MAX_UPLOAD:-20000k}"

SHOW_FILENAME="${SHOW_FILENAME:-no}"
WATERMARK="${WATERMARK:-no}"
WATERMARK_IMG="${WATERMARK_IMG:-}"
FONT_FILE="${FONT_FILE:-}"

VIDEO_EXTENSIONS="${VIDEO_EXTENSIONS:-mp4,avi,mkv,mov,flv,wmv,webm}"
SUBTITLE_EXTENSIONS="${SUBTITLE_EXTENSIONS:-ass,srt,vtt,lrc}" 
ENABLE_SUBTITLES="${ENABLE_SUBTITLES:-no}" 
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

# 存储视频到字幕文件的映射
declare -A SUBTITLE_MAP

load_videos() {
    log "🔎 查找视频和字幕文件..."
    IFS=',' read -ra video_exts <<<"$VIDEO_EXTENSIONS"
    video_find_args=()
    for e in "${video_exts[@]}"; do
        video_find_args+=(-iname "*.${e,,}" -o)
    done
    unset 'video_find_args[${#video_find_args[@]}-1]'

    mapfile -t raw_videos < <(find "$VIDEO_DIR" -maxdepth 1 -type f \( "${video_find_args[@]}" \))

    [[ ${#raw_videos[@]} -eq 0 ]] && { log "❌ 未找到视频"; exit 1; }

    # 只保留有视频轨道的文件
    valid=()
    for f in "${raw_videos[@]}"; do
        if ffprobe -v error -select_streams v:0 -show_entries stream=codec_type \
            -of csv=p=0 "$f" 2>/dev/null | grep -q video; then
            valid+=("$f")

            # 查找匹配的字幕文件
            if [[ "$ENABLE_SUBTITLES" == "yes" ]]; then
                local video_base="${f%.*}"
                IFS=',' read -ra sub_exts <<<"$SUBTITLE_EXTENSIONS"
                local found_sub=""
                for e in "${sub_exts[@]}"; do
                    local sub_file="${video_base}.${e,,}"
                    if [[ -f "$sub_file" ]]; then
                        found_sub="$sub_file"
                        break
                    fi
                done

                if [[ -n "$found_sub" ]]; then
                    SUBTITLE_MAP["$f"]="$found_sub"
                    log "🔗 视频 '$f' 关联字幕 '$found_sub'"
                fi
            fi
        fi
    done

    mapfile -t VIDEO_LIST < <(printf "%s\n" "${valid[@]}" | sort_videos)
}

choose_bitrate() {
    local h="$1"
    local v="3000k" m="3500k" b="6000k"
    (( h >= 2160 )) && v="14000k" m="15000k" b="20000k"
    (( h >= 1440 && h < 2160 )) && v="9000k" m="10000k" b="16000k"
    (( h >= 1080 && h < 1440 )) && v="6000k" m="7500k" b="12000k"

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
log "📁 扫描视频..."
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

    # 文字滤镜
    TEXT=""
    if [[ "$SHOW_FILENAME" == "yes" ]]; then
        safe=$(echo "$base" | sed "s/'/\\\\'/g;s/:/\\\\:/g")
        font_arg=""
        [[ -f "$FONT_FILE" ]] && font_arg="fontfile='$FONT_FILE':"
        TEXT="drawtext=${font_arg}text='$safe':fontcolor=white:fontsize=24:x=10:y=h-th-10:box=1:boxcolor=black@0.5"
    fi

    # 获取当前视频的字幕文件
    current_subtitle="${SUBTITLE_MAP[$v]:-}" 
    SUBTITLE_FILTER=""
    if [[ "$ENABLE_SUBTITLES" == "yes" && -n "$current_subtitle" ]]; then
        # 注意：这里需要确保 $current_subtitle 是可读的，并且路径是 FFmpeg 容器内可访问的
        # 使用 subtitles 滤镜
        SUBTITLE_FILTER="subtitles='$(echo "$current_subtitle" | sed "s/'/\\\\'/g")'"
    fi

    # 构建 filter 链和 INPUTS
    FILTER_CHAIN=""
    INPUTS=(-i "$v")

    # 1. 字幕滤镜
    if [[ -n "$SUBTITLE_FILTER" ]]; then
        FILTER_CHAIN="$SUBTITLE_FILTER"
    fi

    # 2. 水印滤镜 (overlay)
    if [[ "$WATERMARK" == "yes" && -f "$WATERMARK_IMG" ]]; then
        # 如果有水印，需要多一个输入 (-i "$WATERMARK_IMG")
        # 并将水印放在字幕之后（如果字幕存在）
        if [[ -n "$FILTER_CHAIN" ]]; then
            FILTER_CHAIN="$FILTER_CHAIN,[1:v]overlay=10:10"
        else
            FILTER_CHAIN="overlay=10:10"
        fi
        INPUTS+=(-i "$WATERMARK_IMG")
    fi

    # 3. 文件名显示 (drawtext)
    if [[ -n "$TEXT" ]]; then
        if [[ -n "$FILTER_CHAIN" ]]; then
            FILTER_CHAIN="$FILTER_CHAIN,$TEXT"
        else
            FILTER_CHAIN="$TEXT"
        fi
    fi

    COMMON=(
        -preset superfast -tune zerolatency
        -b:v "$VIDEO_BITRATE" -maxrate "$MAXRATE" -bufsize "$VIDEO_BUFSIZE"
        -g "$GOP" -keyint_min "$GOP" -r "$TARGET_FPS"
        "${AUDIO_ARGS[@]}"
    )

    # COPY 优先 (如果启用了任何滤镜，则不能使用 COPY 模式)
    if [[ -z "$FILTER_CHAIN" && $(is_copy_compatible "$v" && echo "yes") == "yes" ]]; then
        log "🚀 COPY 模式"
        ffmpeg -loglevel warning -re -i "$v" -c:v copy -c:a copy "${OUTPUTS[@]}" || {
            log "⚠️ COPY 失败 → 转码"
            # 此时 $FILTER_CHAIN 应该为空，但为了容错，保留它
            ffmpeg -loglevel error -re "${INPUTS[@]}" -c:v libx264 -vf "$FILTER_CHAIN" "${COMMON[@]}" \
                "${OUTPUTS[@]}" || log "❌ 推流失败"
        }
    else
        log "🚀 转码模式"
        if [[ -n "$FILTER_CHAIN" ]]; then
            # 使用 -filter_complex 或 -vf
            # 只有当有多个输入流合并（例如水印）时才使用 -filter_complex
            if [[ "$WATERMARK" == "yes" && -f "$WATERMARK_IMG" ]]; then
                log "⚙️ 使用 -filter_complex: $FILTER_CHAIN"
                # 注意：此时 [0:v] 是视频输入，[1:v] 是水印输入
                ffmpeg -loglevel error -re "${INPUTS[@]}" -filter_complex "$FILTER_CHAIN" \
                    -c:v libx264 "${COMMON[@]}" "${OUTPUTS[@]}" || log "❌ 推流失败"
            else
                log "⚙️ 使用 -vf: $FILTER_CHAIN"
                # 此时只有视频输入，使用 -vf
                ffmpeg -loglevel error -re "${INPUTS[@]}" -c:v libx264 -vf "$FILTER_CHAIN" \
                    "${COMMON[@]}" "${OUTPUTS[@]}" || log "❌ 推流失败"
            fi
        else
            log "⚙️ 无滤镜转码"
            ffmpeg -loglevel error -re "${INPUTS[@]}" -c:v libx264 \
                "${COMMON[@]}" "${OUTPUTS[@]}" || log "❌ 推流失败"
        fi
    fi

    sleep "$SLEEP_SECONDS"

    idx=$(( (idx + 1) % TOTAL ))
    [[ $idx -eq 0 ]] && load_videos && TOTAL=${#VIDEO_LIST[@]}
done
