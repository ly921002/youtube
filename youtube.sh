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

# ===== 无视频时的等待策略 =====
WAIT_FOR_VIDEOS="${WAIT_FOR_VIDEOS:-yes}"         # 目录里暂时没有可播放视频时是否等待（no=直接退出，保持旧行为）
VIDEO_SCAN_INTERVAL="${VIDEO_SCAN_INTERVAL:-30}"  # 等待/暂停期间重新扫描视频目录的间隔（秒）

# ===== Web 控制面板相关配置 =====
STATUS_ENABLED="${STATUS_ENABLED:-yes}"
STATUS_DIR="${STATUS_DIR:-/app/status}"
STATUS_FILE="${STATUS_FILE:-$STATUS_DIR/status.json}"
COMMAND_DIR="${COMMAND_DIR:-$STATUS_DIR/commands}"

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
APP_START_TIME="$(date +%s)"
VIDEO_LIST=()
# 断点续播：本轮推流的起始位置（秒），>0 时给 ffmpeg 加 -ss
SEEK_OFFSET=0
# 暂停时记录下来的播放位置（秒），resume 时作为 -ss 的起点
RESUME_POSITION=0

# 供 Web 面板读取的运行时状态
STATUS_STATE="starting"
STATUS_CURRENT=""
STATUS_INDEX=0
STATUS_TOTAL=0
STATUS_MODE="unknown"
STATUS_LIMIT=0
STATUS_ELAPSED=0
STATUS_STARTED_AT=""
STATUS_LAST_ERROR=""
RTMP_TARGETS_MASKED=()
PENDING_COMMAND=""
PENDING_COMMAND_FILE=""

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

# ---------------------------------------------------------------- 状态与指令

json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\r'/}"
    value="${value//$'\t'/\\t}"
    value="${value//$'\n'/\\n}"
    printf '%s' "$value"
}

# 推流地址含推流码，不能原样暴露给前端
mask_rtmp() {
    printf '%s/****' "${1%/*}"
}

# 原子写入状态文件：先写临时文件再 mv，避免前端读到半个 JSON
write_status() {
    is_yes "$STATUS_ENABLED" || return 0
    local now tmp targets="" item
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$STATUS_DIR" 2>/dev/null || return 0

    for item in ${RTMP_TARGETS_MASKED[@]+"${RTMP_TARGETS_MASKED[@]}"}; do
        [[ -n "$item" ]] || continue
        if [[ -z "$targets" ]]; then
            targets="\"$(json_escape "$item")\""
        else
            targets="$targets,\"$(json_escape "$item")\""
        fi
    done

    tmp="$(mktemp "${STATUS_DIR}/.status.XXXXXX" 2>/dev/null)" || return 0
    {
        printf '{\n'
        printf '  "state": "%s",\n' "$(json_escape "$STATUS_STATE")"
        printf '  "current_file": "%s",\n' "$(json_escape "$STATUS_CURRENT")"
        printf '  "current_index": %s,\n' "$STATUS_INDEX"
        printf '  "total_videos": %s,\n' "$STATUS_TOTAL"
        printf '  "mode": "%s",\n' "$(json_escape "$STATUS_MODE")"
        printf '  "video_bitrate": "%s",\n' "$(json_escape "${VIDEO_BITRATE:-}")"
        printf '  "elapsed_seconds": %s,\n' "$STATUS_ELAPSED"
        printf '  "resume_offset": %s,\n' "$SEEK_OFFSET"
        printf '  "limit_seconds": %s,\n' "$STATUS_LIMIT"
        printf '  "started_at": "%s",\n' "$(json_escape "$STATUS_STARTED_AT")"
        printf '  "updated_at": "%s",\n' "$now"
        printf '  "uptime_seconds": %s,\n' "$(( $(date +%s) - APP_START_TIME ))"
        printf '  "ffmpeg_pid": %s,\n' "${FF_PID:-0}"
        printf '  "rtmp_count": %s,\n' "${#RTMP_TARGETS_MASKED[@]}"
        printf '  "rtmp_targets": [%s],\n' "$targets"
        printf '  "last_error": "%s"\n' "$(json_escape "$STATUS_LAST_ERROR")"
        printf '}\n'
    } >"$tmp"
    mv -f "$tmp" "$STATUS_FILE" 2>/dev/null || rm -f "$tmp"
}

# 安全移动播放下标：TOTAL 为 0（还没扫到视频）时不做取模，避免除零
step_index() {
    local delta="$1"
    (( TOTAL > 0 )) || return 0
    idx=$(((idx + delta + TOTAL) % TOTAL))
}

# 窥视指令目录里最早的一条指令，**不删除文件**。
# 调用方只有真正处理了这条指令，才可以调用 consume_command 把它删掉；
# 否则指令会保留下来留给能处理它的地方（比如播放中收到的 rescan 留给主循环）。
peek_command() {
    PENDING_COMMAND=""
    PENDING_COMMAND_FILE=""
    is_yes "$STATUS_ENABLED" || return 0
    [[ -d "$COMMAND_DIR" ]] || return 0
    local file cmd
    for file in "$COMMAND_DIR"/*; do
        [[ -f "$file" ]] || continue
        cmd="$(tr -d '[:space:]' <"$file" 2>/dev/null)"
        if [[ -z "$cmd" ]]; then
            rm -f "$file" 2>/dev/null || true
            continue
        fi
        PENDING_COMMAND="$cmd"
        PENDING_COMMAND_FILE="$file"
        return 0
    done
}

# 确认消费当前指令（删除指令文件）
consume_command() {
    [[ -n "$PENDING_COMMAND_FILE" ]] || return 0
    rm -f "$PENDING_COMMAND_FILE" 2>/dev/null || true
    PENDING_COMMAND=""
    PENDING_COMMAND_FILE=""
}

# 视频间隔期间处理控制指令，可能修改 idx / TOTAL，也可能暂停或退出
process_commands() {
    is_yes "$STATUS_ENABLED" || return 0
    local cmd
    while true; do
        peek_command
        cmd="$PENDING_COMMAND"
        case "$cmd" in
            "")
                return 0
                ;;
            next | skip)
                consume_command
                log "收到控制指令：跳到下一个"
                SEEK_OFFSET=0
                RESUME_POSITION=0
                step_index 1
                ;;
            prev)
                consume_command
                log "收到控制指令：回到上一个"
                SEEK_OFFSET=0
                RESUME_POSITION=0
                step_index -1
                ;;
            rescan)
                consume_command
                rescan_videos
                ;;
            pause)
                consume_command
                # 还没开始播就暂停，恢复时从头开始
                RESUME_POSITION=0
                pause_until_resume
                ;;
            stop)
                consume_command
                graceful_stop
                ;;
            *)
                # 未知指令直接丢弃，避免死循环
                log "忽略未知控制指令：$cmd"
                consume_command
                ;;
        esac
    done
}

# 重新扫描视频目录。扫描不到可播放视频时**不会**终止脚本，而是保留原列表。
rescan_videos() {
    log "收到控制指令：重新扫描视频目录"
    local -a old_list=()
    if [[ ${#VIDEO_LIST[@]} -gt 0 ]]; then
        old_list=("${VIDEO_LIST[@]}")
    fi

    if load_videos; then
        TOTAL=${#VIDEO_LIST[@]}
        (( idx < TOTAL )) || idx=0
        log "重新扫描完成，共 $TOTAL 个视频"
    else
        VIDEO_LIST=()
        if [[ ${#old_list[@]} -gt 0 ]]; then
            VIDEO_LIST=("${old_list[@]}")
        fi
        TOTAL=${#VIDEO_LIST[@]}
        (( idx < TOTAL )) || idx=0
        log "重新扫描未找到可播放视频，保持原有列表（$TOTAL 个）"
    fi
    STATUS_TOTAL="$TOTAL"
    write_status
}

# 暂停推流，直到收到 resume（期间仍响应 next / prev / rescan / stop）
pause_until_resume() {
    log "收到控制指令：暂停（等待 resume）"
    STATUS_STATE="paused"
    write_status
    while true; do
        sleep 2
        peek_command
        case "$PENDING_COMMAND" in
            resume)
                consume_command
                if (( RESUME_POSITION > 0 )); then
                    log "收到控制指令：恢复推流，从断点 ${RESUME_POSITION}s 继续播放"
                else
                    log "收到控制指令：恢复推流，从头播放当前视频"
                fi
                SEEK_OFFSET="$RESUME_POSITION"
                RESUME_POSITION=0
                STATUS_STATE="idle"
                write_status
                return 0
                ;;
            next | skip)
                consume_command
                log "收到控制指令：跳到下一个"
                SEEK_OFFSET=0
                RESUME_POSITION=0
                step_index 1
                STATUS_STATE="idle"
                write_status
                return 0
                ;;
            prev)
                consume_command
                log "收到控制指令：回到上一个"
                SEEK_OFFSET=0
                RESUME_POSITION=0
                step_index -1
                STATUS_STATE="idle"
                write_status
                return 0
                ;;
            rescan)
                consume_command
                rescan_videos
                ;;
            stop)
                consume_command
                graceful_stop
                ;;
        esac
    done
}

# 目录里还没有可播放视频时，进入等待状态并周期性重扫；面板保持可用
wait_for_videos() {
    log "VIDEO_DIR 中暂无可播放视频，进入等待状态（每 ${VIDEO_SCAN_INTERVAL}s 重新扫描）"
    STATUS_STATE="waiting"
    STATUS_CURRENT=""
    STATUS_INDEX=0
    STATUS_TOTAL=0
    write_status

    while true; do
        if load_videos; then
            TOTAL=${#VIDEO_LIST[@]}
            STATUS_TOTAL="$TOTAL"
            log "扫描到 $TOTAL 个可播放视频，开始推流"
            return 0
        fi
        STATUS_STATE="waiting"
        write_status
        # 等待期间也要能响应指令（rescan 立即重扫 / stop 退出）
        process_commands
        sleep "$VIDEO_SCAN_INTERVAL"
    done
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

# 扫描视频目录并填充 VIDEO_LIST。
# 返回值：0=至少有一个可播放视频；1=目录不存在或没有可播放视频（不再直接终止脚本）
load_videos() {
    log "Scanning videos in $VIDEO_DIR"
    if [[ ! -d "$VIDEO_DIR" ]]; then
        log "VIDEO_DIR does not exist: $VIDEO_DIR"
        return 1
    fi

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

    if [[ ${#valid[@]} -eq 0 ]]; then
        log "No playable videos found in $VIDEO_DIR"
        return 1
    fi
    mapfile -t VIDEO_LIST < <(printf "%s\n" "${valid[@]}" | sort_videos)
    return 0
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
    RTMP_TARGETS_MASKED=()
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
        RTMP_TARGETS_MASKED+=("$(mask_rtmp "$url")")
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

# 返回值：0=正常结束；124=判定卡死被终止；125=达到时长上限被终止；
#         126=被控制指令跳过；127=被控制指令停止；128=被控制指令暂停；129=被控制指令切到上一个
#         其他=ffmpeg 自身退出码
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
    STATUS_STATE="streaming"
    STATUS_ELAPSED=0
    write_status

    while kill -0 "$pid" 2>/dev/null; do
        sleep "$PROGRESS_INTERVAL"
        kill -0 "$pid" 2>/dev/null && elapsed=$((elapsed + PROGRESS_INTERVAL))

        # 播放中也能响应「下一个 / 上一个 / 暂停 / 停止」
        # 注意：这里只消费自己能处理的指令，rescan 等留给主循环，不会被吞掉
        peek_command
        case "$PENDING_COMMAND" in
            next | skip)
                consume_command
                log "收到控制指令：立即跳到下一个"
                rc=126
                break
                ;;
            prev)
                consume_command
                log "收到控制指令：立即回到上一个"
                rc=129
                break
                ;;
            pause)
                consume_command
                # 记下断点：本轮已播秒数 + 本轮的起始偏移，resume 时从这里继续
                RESUME_POSITION=$((SEEK_OFFSET + elapsed))
                log "收到控制指令：立即暂停当前推流（断点 ${RESUME_POSITION}s）"
                rc=128
                break
                ;;
            stop)
                consume_command
                log "收到控制指令：停止推流"
                rc=127
                break
                ;;
            rescan)
                # 播放中也可以立即重扫：只刷新列表，不打断当前推流
                consume_command
                rescan_videos
                ;;
            *)
                # 播放中处理不了的指令直接丢弃，避免一直堵住指令队列
                consume_command
                ;;
        esac

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

        STATUS_ELAPSED="$elapsed"
        write_status
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

# 断点续播：SEEK_OFFSET>0 时在输入文件前插入 -ss（输入侧定位，走关键帧）
stream_with_copy() {
    local video="$1"
    local has_audio="$2"
    local limit="$3"
    local -a args

    args=(-loglevel "$FFMPEG_LOGLEVEL" -re)
    # 断点续播：-ss 必须放在 -i 之前（输入侧定位，走关键帧）
    if (( SEEK_OFFSET > 0 )); then
        args+=(-ss "$SEEK_OFFSET")
    fi
    args+=(-i "$video")
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

    inputs=(-re)
    # 断点续播：-ss 必须放在 -i 之前（输入侧定位，走关键帧）
    if (( SEEK_OFFSET > 0 )); then
        inputs+=(-ss "$SEEK_OFFSET")
    fi
    inputs+=(-i "$video")
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
if ! load_videos; then
    is_yes "$WAIT_FOR_VIDEOS" || die "No playable videos found in $VIDEO_DIR"
fi
TOTAL=${#VIDEO_LIST[@]}

if is_yes "$STATUS_ENABLED"; then
    mkdir -p "$STATUS_DIR" "$COMMAND_DIR"
    STATUS_TOTAL="$TOTAL"
    write_status
fi
[[ "$TARGET_FPS" =~ ^[0-9]+$ && "$KEYFRAME_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || die "TARGET_FPS and KEYFRAME_INTERVAL_SECONDS must be integers"

for stability_var in STALL_TIMEOUT FFMPEG_START_GRACE PROGRESS_INTERVAL RUNTIME_GRACE \
    MAX_RUNTIME RETRY_MAX RETRY_BACKOFF RETRY_BACKOFF_MAX FFMPEG_STOP_TIMEOUT; do
    [[ "${!stability_var}" =~ ^[0-9]+$ ]] || die "$stability_var must be a non-negative integer (got '${!stability_var}')"
done
[[ "$VIDEO_SCAN_INTERVAL" =~ ^[0-9]+$ && "$VIDEO_SCAN_INTERVAL" -gt 0 ]] || die "VIDEO_SCAN_INTERVAL must be a positive integer (got '$VIDEO_SCAN_INTERVAL')"

GOP=$((TARGET_FPS * KEYFRAME_INTERVAL_SECONDS))
(( GOP > 0 )) || die "GOP must be greater than 0"

idx=0
while true; do
    # 目录里还没有视频时先等待，期间面板保持可用
    if [[ ${#VIDEO_LIST[@]} -eq 0 ]]; then
        wait_for_videos
    fi

    process_commands
    video="${VIDEO_LIST[$idx]}"
    base="$(basename "$video")"
    log "Playing ($((idx + 1))/$TOTAL): $base"

    STATUS_CURRENT="$base"
    STATUS_INDEX=$((idx + 1))
    STATUS_TOTAL="$TOTAL"
    STATUS_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    STATUS_ELAPSED=0

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
    if (( SEEK_OFFSET > 0 )); then
        # 断点续播：剩余可推时长要扣掉已经播过的部分
        limit=$((limit - SEEK_OFFSET))
        (( limit >= 10 )) || limit=10
        log "从断点 ${SEEK_OFFSET}s 继续，本轮剩余时长上限 ${limit}s"
    fi
    STATUS_LIMIT="$limit"
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
            STATUS_MODE="copy"
            write_status
            stream_with_copy "$video" "$audio" "$limit" || rc=$?
            if (( rc == 0 )); then
                break
            fi
            if (( rc == 125 )); then
                log "已在时长上限处结束本视频，继续下一个"
                break
            fi
            if (( rc == 126 )); then
                log "已跳过当前视频"
                break
            fi
            if (( rc == 128 || rc == 129 )); then
                # 暂停 / 切上一个：都不是失败，不要降级成转码重试
                break
            fi
            if (( rc == 127 )); then
                graceful_stop
            fi
            STATUS_LAST_ERROR="copy mode rc=$rc"
            log "Copy mode failed (rc=$rc), retrying with transcode mode"
            force_transcode=1
            continue
        else
            log "Using transcode mode: video=$VIDEO_BITRATE maxrate=$MAXRATE bufsize=$VIDEO_BUFSIZE audio=$audio (第 $((attempt + 1)) 次尝试)"
            STATUS_MODE="transcode"
            write_status
            stream_with_transcode "$video" "$audio" "$video_filters" "$watermark_enabled" "$limit" || rc=$?
        fi

        if (( rc == 0 )); then
            STATUS_LAST_ERROR=""
            break
        fi
        if (( rc == 125 )); then
            log "已在时长上限处结束本视频，继续下一个"
            break
        fi
        if (( rc == 126 )); then
            log "已跳过当前视频"
            break
        fi
        if (( rc == 128 || rc == 129 )); then
            # 暂停 / 切上一个：都不是失败，不计入重试次数
            break
        fi
        if (( rc == 127 )); then
            graceful_stop
        fi

        attempt=$((attempt + 1))
        STATUS_LAST_ERROR="rc=$rc, 第 $((attempt - 1)) 次重试"
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

    # rc=128 表示播放中被暂停：先停流等待 resume，
    # pause_until_resume 会在 resume 时把断点写进 SEEK_OFFSET，下一轮从断点继续
    if (( rc == 128 )); then
        pause_until_resume
    fi

    STATUS_STATE="idle"
    STATUS_ELAPSED=0
    write_status
    sleep "$SLEEP_SECONDS"

    case "$rc" in
        128) ;;                 # 暂停恢复后从断点重播当前视频，下标不动、断点保留
        129) step_index -1 ;;   # 切上一个
        *)   step_index 1 ;;
    esac
    if [[ $rc -ne 128 ]]; then
        SEEK_OFFSET=0
        RESUME_POSITION=0
    fi
    if [[ $idx -eq 0 ]]; then
        if ! load_videos; then
            log "重新扫描未找到可播放视频，沿用上一次的列表"
        fi
        TOTAL=${#VIDEO_LIST[@]}
    fi
done
