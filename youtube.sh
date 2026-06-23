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
    mapfile -t raw_videos < <(find "$VIDEO_DIR" -maxdepth $FOLDER -type f \( "${video_find_args[@]}" \) 2>/dev/null)

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

run_ffmpeg() {
    ffmpeg "$@"
}

stream_with_copy() {
    local video="$1"
    local has_audio="$2"
    local -a args

    args=(-loglevel "$FFMPEG_LOGLEVEL" -re -i "$video")
    if [[ "$has_audio" == "yes" ]]; then
        args+=(-map 0:v:0 -map 0:a:0 -c:v copy -c:a aac -b:a "$AUDIO_BITRATE")
    else
        args+=(-f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=$AUDIO_SAMPLE_RATE")
        args+=(-map 0:v:0 -map 1:a:0 -c:v copy -c:a aac -b:a "$AUDIO_BITRATE" -shortest)
    fi

    run_ffmpeg "${args[@]}" "${OUTPUT_ARGS[@]}"
}

stream_with_transcode() {
    local video="$1"
    local has_audio="$2"
    local filters="$3"
    local use_watermark="$4"
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
        if [[ -n "$filters" ]]; then
            filter_args=(-filter_complex "[0:v]${filters}[base];[base][1:v]overlay=10:10[vout]")
        else
            filter_args=(-filter_complex "[0:v][1:v]overlay=10:10[vout]")
        fi
    elif [[ -n "$filters" ]]; then
        filter_args=(-filter_complex "[0:v]${filters}[vout]")
    else
        filter_args=(-filter_complex "[0:v]null[vout]")
    fi

    run_ffmpeg -loglevel "$FFMPEG_LOGLEVEL" "${inputs[@]}" "${filter_args[@]}" \
        "${map_args[@]}" "${common[@]}" "${OUTPUT_ARGS[@]}"
}

build_outputs
load_videos
TOTAL=${#VIDEO_LIST[@]}
[[ "$TARGET_FPS" =~ ^[0-9]+$ && "$KEYFRAME_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || die "TARGET_FPS and KEYFRAME_INTERVAL_SECONDS must be integers"
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

    filters="$(build_video_filters "$video" "$base")"
    watermark_enabled="no"
    if is_yes "$WATERMARK"; then
        if [[ -f "$WATERMARK_IMG" ]]; then
            watermark_enabled="yes"
        else
            log "Watermark enabled but file not found: $WATERMARK_IMG"
        fi
    fi

    if [[ -z "$filters" && "$watermark_enabled" == "no" ]] && is_copy_compatible "$video"; then
        log "Using copy mode: video=$VIDEO_BITRATE audio=$audio"
        if ! stream_with_copy "$video" "$audio"; then
            log "Copy mode failed, retrying with transcode mode"
            stream_with_transcode "$video" "$audio" "" "no" || log "Stream failed: $base"
        fi
    else
        log "Using transcode mode: video=$VIDEO_BITRATE maxrate=$MAXRATE bufsize=$VIDEO_BUFSIZE audio=$audio"
        stream_with_transcode "$video" "$audio" "$filters" "$watermark_enabled" || log "Stream failed: $base"
    fi

    sleep "$SLEEP_SECONDS"

    idx=$(((idx + 1) % TOTAL))
    if [[ $idx -eq 0 ]]; then
        load_videos
        TOTAL=${#VIDEO_LIST[@]}
    fi
done
