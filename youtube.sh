#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== FFmpeg Auto Stream v1 ==="

MULTI_RTMP_URLS="${MULTI_RTMP_URLS:?MULTI_RTMP_URLS is required, separated by spaces}"
VIDEO_DIR="${VIDEO_DIR:-/videos}"
FOLDER="${FOLDER:-2}"
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
FFMPEG_LOGLEVEL="${FFMPEG_LOGLEVEL:-warning}"
AUDIO_BITRATE="${AUDIO_BITRATE:-128k}"
AUDIO_SAMPLE_RATE="${AUDIO_SAMPLE_RATE:-44100}"

# ===== 稳定性相关配置 =====
STALL_TIMEOUT="${STALL_TIMEOUT:-30}"              # 连续多少秒无数据输出判定为卡死（0=关闭检测）
FFMPEG_START_GRACE="${FFMPEG_START_GRACE:-30}"    # 启动宽限期，期间不做卡死判定
PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-5}"       # 存活检测轮询间隔（秒）
RUNTIME_GRACE="${RUNTIME_GRACE:-120}"             # 单个视频在自身时长之外额外允许的秒数
MAX_RUNTIME="${MAX_RUNTIME:-0}"                   # 单个视频最长推流秒数，0=按时长自动推算
RETRY_MAX="${RETRY_MAX:-3}"                       # 单个视频失败后的重试次数（不含首次）
RETRY_BACKOFF="${RETRY_BACKOFF:-5}"               # 重试退避基数（秒），指数递增
RETRY_BACKOFF_MAX="${RETRY_BACKOFF_MAX:-300}"     # 退避上限（秒）
FFMPEG_STOP_TIMEOUT="${FFMPEG_STOP_TIMEOUT:-10}"  # 优雅停止等待秒数，超时后升级为 SIGTERM

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

die() {
    log "ERROR: $*"
    exit 1
}

is_yes() {
    case "${1,,}" in
        yes|true|1|on) return 0 ;;
        *) return 1 ;;
    esac
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

escape_filter_text() {
    printf '%s' "$1" | sed "s/\\\\/\\\\\\\\/g;s/'/\\\\'/g;s/:/\\\\:/g;s/%/\\\\%/g"
}

escape_filter_path() {
    printf '%s' "$1" | sed "s/\\\\/\\\\\\\\/g;s/'/\\\\'/g;s/:/\\\\:/g"
}

# 当前 ffmpeg 子进程 pid，供信号处理使用
FF_PID=""

graceful_stop() {
    log "收到停止信号，正在结束当前推流..."
    if [[ -n "$FF_PID" ]] && kill -0 "$FF_PID" 2>/dev/null; then
        terminate_ffmpeg "$FF_PID"
    fi
    exit 0
}

trap graceful_stop TERM INT

sort_videos() {
    awk '
        {
            file=$0
            name=file
            sub(/^.*\//, "", name)
            number=999999
            if (match(name, /^[0-9]+/)) {
                number=substr(name, RSTART, RLENGTH) + 0
            }
            printf "%06d\t%s\n", number, file
        }
    ' | sort -n -k1,1 -k2,2 | cut -f2-
}

declare -a VIDEO_LIST
declare -a OUTPUT_ARGS
declare -A SUBTITLE_MAP

build_find_args() {
    local -n out_ref="$1"
    local csv="$2"
    local ext

    out_ref=()
    IFS=',' read -ra exts <<<"$csv"
    for ext in "${exts[@]}"; do
        ext="$(trim "$ext")"
        [[ -z "$ext" ]] && continue
        ext="${ext#.}"
        out_ref+=(-iname "*.${ext,,}" -o)
    done

    [[ ${#out_ref[@]} -gt 0 ]] || die "No file extensions configured"
    unset 'out_ref[${#out_ref[@]}-1]'
}

has_video_stream() {
    ffprobe -v error -select_streams v:0 -show_entries stream=codec_type \
        -of csv=p=0 "$1" 2>/dev/null | grep -q '^video$'
}

has_audio_stream() {
    ffprobe -v error -select_streams a:0 -show_entries stream=codec_type \
        -of csv=p=0 "$1" 2>/dev/null | grep -q '^audio$'
}

video_codec() {
    ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
        -of csv=p=0 "$1" 2>/dev/null | head -n 1
}

video_size() {
    ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
        -of csv=p=0:s=x "$1" 2>/dev/null | head -n 1
}

video_duration() {
    ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n 1
}

# 从 ffmpeg -progress 输出中提取进度指纹：只要它在变，就说明还在往外发数据
progress_marker() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    awk -F= '/^(out_time_ms|total_size|frame)=/ { printf "%s=%s;", $1, $2 }' "$file" 2>/dev/null
}

# 先 SIGINT 让 ffmpeg 收尾写 trailer，超时再 SIGTERM
terminate_ffmpeg() {
    local pid="$1"
    local waited=0
    kill -INT "$pid" 2>/dev/null || true
    while (( waited < FFMPEG_STOP_TIMEOUT )); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 1
        waited=$((waited + 1))
    done
    kill -TERM "$pid" 2>/dev/null || true
}

# 计算单个视频的最大推流时长，防止 ffmpeg 假死后无限挂起
compute_runtime_limit() {
    local duration int_duration
    if (( MAX_RUNTIME > 0 )); then
        printf '%s' "$MAX_RUNTIME"
        return 0
    fi
    duration="$(video_duration "$1")"
    if [[ "$duration" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        int_duration="${duration%%.*}"
        printf '%s' "$((int_duration + RUNTIME_GRACE))"
    else
        printf '0'
    fi
}

find_subtitle_for_video() {
    local video="$1"
    local video_base="${video%.*}"
    local ext subtitle

    IFS=',' read -ra sub_exts <<<"$SUBTITLE_EXTENSIONS"
    for ext in "${sub_exts[@]}"; do
        ext="$(trim "$ext")"
        [[ -z "$ext" ]] && continue
        ext="${ext#.}"
        subtitle="${video_base}.${ext,,}"
        [[ -f "$subtitle" ]] && {
            printf '%s' "$subtitle"
            return 0
        }
    done

    return 1
}

load_videos() {
    log "Scanning videos in $VIDEO_DIR"
    [[ -d "$VIDEO_DIR" ]] || die "VIDEO_DIR does not exist: $VIDEO_DIR"

    local -a video_find_args raw_videos valid
    local file subtitle

    build_find_args video_find_args "$VIDEO_EXTENSIONS"
    mapfile -t raw_videos < <(find -L "$VIDEO_DIR" -maxdepth "$FOLDER" -type f \( "${video_find_args[@]}" \) 2>/dev/null)

    valid=()
    SUBTITLE_MAP=()
    for file in "${raw_videos[@]}"; do
        if has_video_stream "$file"; then
            valid+=("$file")

            if is_yes "$ENABLE_SUBTITLES" && subtitle="$(find_subtitle_for_video "$file")"; then
                SUBTITLE_MAP["$file"]="$subtitle"
                log "Subtitle matched: $(basename "$file") -> $(basename "$subtitle")"
            fi
        else
            log "Skipping non-video file: $file"
        fi
    done

    [[ ${#valid[@]} -gt 0 ]] || die "No playable videos found in $VIDEO_DIR"
    mapfile -t VIDEO_LIST < <(printf "%s\n" "${valid[@]}" | sort_videos)
}

choose_bitrate() {
    local height="$1"
    local v="3000k" m="3500k" b="6000k"
    local upload

    if (( height >= 2160 )); then
        v="14000k"; m="15000k"; b="20000k"
    elif (( height >= 1440 )); then
        v="9000k"; m="10000k"; b="16000k"
    elif (( height >= 1080 )); then
        v="6000k"; m="7500k"; b="12000k"
    fi

    upload="${MAX_UPLOAD%k}"
    [[ "$upload" =~ ^[0-9]+$ ]] || die "MAX_UPLOAD must look like 10000k"

    (( ${v%k} > upload )) && v="${upload}k"
    (( ${m%k} > upload )) && m="${upload}k"
    (( ${b%k} > upload * 2 )) && b="$((upload * 2))k"

    VIDEO_BITRATE="$v"
    MAXRATE="$m"
    VIDEO_BUFSIZE="$b"
}

is_copy_compatible() {
    [[ "$(video_codec "$1")" == "h264" ]]
}

build_outputs() {
    OUTPUT_ARGS=()
    local url count=0 tee_output="" last_url=""

    # 空格分隔多个推流地址，此处需要刻意分词
    # shellcheck disable=SC2086
    for url in $MULTI_RTMP_URLS; do
        [[ -z "$url" ]] && continue
        if [[ $count -eq 0 ]]; then
            tee_output="[f=flv:onfail=ignore]$url"
        else
            tee_output="$tee_output|[f=flv:onfail=ignore]$url"
        fi
        last_url="$url"
        count=$((count + 1))
    done

    (( count > 0 )) || die "MULTI_RTMP_URLS does not contain any RTMP URL"
    if (( count == 1 )); then
        OUTPUT_ARGS=(-f flv "$last_url")
    else
        OUTPUT_ARGS=(-f tee "$tee_output")
    fi
    log "Configured $count RTMP output(s)"
}

build_video_filters() {
    local video="$1"
    local base="$2"
    local -a filters=()
    local subtitle="${SUBTITLE_MAP[$video]:-}"
    local safe_text font_arg

    if is_yes "$ENABLE_SUBTITLES" && [[ -n "$subtitle" ]]; then
        filters+=("subtitles='$(escape_filter_path "$subtitle")'")
    fi

    if is_yes "$SHOW_FILENAME"; then
        safe_text="$(escape_filter_text "$base")"
        font_arg=""
        [[ -n "$FONT_FILE" && -f "$FONT_FILE" ]] && font_arg="fontfile='$(escape_filter_path "$FONT_FILE")':"
        filters+=("drawtext=${font_arg}text='$safe_text':fontcolor=white:fontsize=24:x=10:y=h-th-10:box=1:boxcolor=black@0.5")
    fi

    local IFS=,
    printf '%s' "${filters[*]}"
}

# 返回值：0=正常结束；124=判定卡死被终止；125=达到时长上限被终止；其他=ffmpeg 自身退出码
# 用法：run_ffmpeg <本次最长允许秒数,0 表示不限> <ffmpeg 参数...>
run_ffmpeg() {
    local limit="$1"
    shift
    local progress_file pid rc=0 ffmpeg_rc=0 elapsed=0 stalled=0
    local marker="" last_marker=""

    progress_file="$(mktemp "${TMPDIR:-/tmp}/ffmpeg-progress.XXXXXX")"
    rm -f "$progress_file"

    ffmpeg -nostdin -progress "$progress_file" "$@" &
    pid=$!
    FF_PID="$pid"

    while kill -0 "$pid" 2>/dev/null; do
        sleep "$PROGRESS_INTERVAL"
        kill -0 "$pid" 2>/dev/null && elapsed=$((elapsed + PROGRESS_INTERVAL))

        marker="$(progress_marker "$progress_file")"
        if [[ -z "$marker" ]]; then
            stalled=0
        elif [[ "$marker" == "$last_marker" ]]; then
            stalled=$((stalled + PROGRESS_INTERVAL))
        else
            stalled=0
            last_marker="$marker"
        fi

        if (( STALL_TIMEOUT > 0 && elapsed > FFMPEG_START_GRACE && stalled >= STALL_TIMEOUT )); then
            log "推流已 ${stalled}s 没有数据输出，判定为卡死，准备重启本次推流"
            rc=124
            break
        fi

        if (( limit > 0 && elapsed >= limit )); then
            log "已达到本视频最大推流时长 ${limit}s，主动结束"
            rc=125
            break
        fi
    done

    if (( rc != 0 )); then
        terminate_ffmpeg "$pid"
    fi
    wait "$pid" 2>/dev/null || ffmpeg_rc=$?
    FF_PID=""
    rm -f "$progress_file"

    if (( rc == 0 )); then
        rc="$ffmpeg_rc"
    fi
    return "$rc"
}

stream_with_copy() {
    local video="$1"
    local has_audio="$2"
    local limit="$3"
    local -a args

    args=(-loglevel "$FFMPEG_LOGLEVEL" -re -i "$video")
    if [[ "$has_audio" == "yes" ]]; then
        args+=(-map 0:v:0 -map 0:a:0 -c:v copy -c:a aac -b:a "$AUDIO_BITRATE")
    else
        args+=(-f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=$AUDIO_SAMPLE_RATE")
        args+=(-map 0:v:0 -map 1:a:0 -c:v copy -c:a aac -b:a "$AUDIO_BITRATE" -shortest)
    fi

    run_ffmpeg "$limit" "${args[@]}" "${OUTPUT_ARGS[@]}"
}

stream_with_transcode() {
    local video="$1"
    local has_audio="$2"
    local video_filters="$3"
    local use_watermark="$4"
    local limit="$5"
    local -a inputs common map_args filter_args

    inputs=(-re -i "$video")
    if [[ "$use_watermark" == "yes" ]]; then
        inputs+=(-i "$WATERMARK_IMG")
    fi
    if [[ "$has_audio" != "yes" ]]; then
        inputs+=(-f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=$AUDIO_SAMPLE_RATE")
    fi

    common=(
        -c:v libx264 -preset superfast -tune zerolatency
        -b:v "$VIDEO_BITRATE" -maxrate "$MAXRATE" -bufsize "$VIDEO_BUFSIZE"
        -g "$GOP" -keyint_min "$GOP" -r "$TARGET_FPS"
        -c:a aac -b:a "$AUDIO_BITRATE" -ar "$AUDIO_SAMPLE_RATE"
    )

    map_args=(-map "[vout]")
    if [[ "$has_audio" == "yes" ]]; then
        map_args+=(-map 0:a:0)
    elif [[ "$use_watermark" == "yes" ]]; then
        map_args+=(-map 2:a:0 -shortest)
    else
        map_args+=(-map 1:a:0 -shortest)
    fi

    if [[ "$use_watermark" == "yes" ]]; then
        if [[ -n "$video_filters" ]]; then
            filter_args=(-filter_complex "[0:v]${video_filters}[base];[base][1:v]overlay=10:10[vout]")
        else
            filter_args=(-filter_complex "[0:v][1:v]overlay=10:10[vout]")
        fi
    elif [[ -n "$video_filters" ]]; then
        filter_args=(-filter_complex "[0:v]${video_filters}[vout]")
    else
        filter_args=(-filter_complex "[0:v]null[vout]")
    fi

    run_ffmpeg "$limit" -loglevel "$FFMPEG_LOGLEVEL" "${inputs[@]}" "${filter_args[@]}" \
        "${map_args[@]}" "${common[@]}" "${OUTPUT_ARGS[@]}"
}

build_outputs
load_videos
TOTAL=${#VIDEO_LIST[@]}
[[ "$TARGET_FPS" =~ ^[0-9]+$ && "$KEYFRAME_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || die "TARGET_FPS and KEYFRAME_INTERVAL_SECONDS must be integers"

for stability_var in STALL_TIMEOUT FFMPEG_START_GRACE PROGRESS_INTERVAL RUNTIME_GRACE \
    MAX_RUNTIME RETRY_MAX RETRY_BACKOFF RETRY_BACKOFF_MAX FFMPEG_STOP_TIMEOUT; do
    [[ "${!stability_var}" =~ ^[0-9]+$ ]] || die "$stability_var must be a non-negative integer (got '${!stability_var}')"
done

GOP=$((TARGET_FPS * KEYFRAME_INTERVAL_SECONDS))
(( GOP > 0 )) || die "GOP must be greater than 0"

idx=0
while true; do
    video="${VIDEO_LIST[$idx]}"
    base="$(basename "$video")"
    log "Playing ($((idx + 1))/$TOTAL): $base"

    size="$(video_size "$video")"
    if [[ "$size" =~ ^([0-9]+)x([0-9]+)$ ]]; then
        HEIGHT="${BASH_REMATCH[2]}"
    else
        log "Could not read video size, using 720p bitrate profile"
        HEIGHT=720
    fi
    choose_bitrate "$HEIGHT"

    audio="no"
    has_audio_stream "$video" && audio="yes"

    video_filters="$(build_video_filters "$video" "$base")"
    watermark_enabled="no"
    if is_yes "$WATERMARK"; then
        if [[ -f "$WATERMARK_IMG" ]]; then
            watermark_enabled="yes"
        else
            log "Watermark enabled but file not found: $WATERMARK_IMG"
        fi
    fi

    limit="$(compute_runtime_limit "$video")"
    if (( limit > 0 )); then
        log "Runtime limit for this video: ${limit}s"
    fi

    attempt=0
    force_transcode=0
    while true; do
        use_copy=0
        if (( force_transcode == 0 )) && [[ -z "$video_filters" && "$watermark_enabled" == "no" ]] \
            && is_copy_compatible "$video"; then
            use_copy=1
        fi

        rc=0
        if (( use_copy == 1 )); then
            log "Using copy mode: video=$VIDEO_BITRATE audio=$audio (第 $((attempt + 1)) 次尝试)"
            stream_with_copy "$video" "$audio" "$limit" || rc=$?
            if (( rc == 0 )); then
                break
            fi
            if (( rc == 125 )); then
                log "已在时长上限处结束本视频，继续下一个"
                break
            fi
            log "Copy mode failed (rc=$rc), retrying with transcode mode"
            force_transcode=1
            continue
        else
            log "Using transcode mode: video=$VIDEO_BITRATE maxrate=$MAXRATE bufsize=$VIDEO_BUFSIZE audio=$audio (第 $((attempt + 1)) 次尝试)"
            stream_with_transcode "$video" "$audio" "$video_filters" "$watermark_enabled" "$limit" || rc=$?
        fi

        if (( rc == 0 )); then
            break
        fi
        if (( rc == 125 )); then
            log "已在时长上限处结束本视频，继续下一个"
            break
        fi

        attempt=$((attempt + 1))
        if (( attempt > RETRY_MAX )); then
            log "Stream failed after $RETRY_MAX retry(s), giving up: $base"
            break
        fi

        delay=$((RETRY_BACKOFF * (2 ** (attempt - 1))))
        if (( delay > RETRY_BACKOFF_MAX )); then
            delay="$RETRY_BACKOFF_MAX"
        fi
        log "推流中断 (rc=$rc)，${delay}s 后进行第 $attempt 次重试：$base"
        sleep "$delay"
    done

    sleep "$SLEEP_SECONDS"

    idx=$(((idx + 1) % TOTAL))
    if [[ $idx -eq 0 ]]; then
        load_videos
        TOTAL=${#VIDEO_LIST[@]}
    fi
done
