#!/usr/bin/env bash
set -euo pipefail

echo "===== FFmpeg 自动推流（顺序循环播放 + 智能码率 + 多路输出）====="

# ---------------------------
# 环境变量
# ---------------------------
# MULTI_RTMP_URLS 必须设置，例如 rtmp://server1/live rtmp://server2/live
MULTI_RTMP_URLS="${MULTI_RTMP_URLS:?必须设置 MULTI_RTMP_URLS，多个地址用空格分隔}"
VIDEO_DIR="${VIDEO_DIR:-/videos}"

WATERMARK="${WATERMARK:-no}"
WATERMARK_IMG="${WATERMARK_IMG:-}"

TARGET_FPS="${TARGET_FPS:-30}"
KEYFRAME_INTERVAL_SECONDS="${KEYFRAME_INTERVAL_SECONDS:-2}"

# VPS 最大可用上传带宽限制（例如 VPS 上行 10Mbps）
# 可在 Docker 启动时 -e MAX_UPLOAD="8000k" 覆盖
MAX_UPLOAD="${MAX_UPLOAD:-10000k}"

SLEEP_SECONDS="${SLEEP_SECONDS:-10}"

VIDEO_EXTENSIONS="${VIDEO_EXTENSIONS:-mp4,avi,mkv,mov,flv,wmv,webm}"
# 是否在画面显示文件名 (yes/no)
SHOW_FILENAME="${SHOW_FILENAME:-yes}"
# 字体路径 (如果 VPS 是最小化安装，可能需要安装 ttf-dejavu 或指定字体文件路径)
# 如果留空，FFmpeg 会尝试使用系统默认字体
FONT_FILE="${FONT_FILE:-}"


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

echo "推流地址 (多路): $MULTI_RTMP_URLS"
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

            # 提取文件名前面的数字
            if   [[ "$base" =~ ^([0-9]+)[-_\.] ]]; then prefix="${BASH_REMATCH[1]}"
            elif [[ "$base" =~ ^([0-9]+)       ]]; then prefix="${BASH_REMATCH[1]}"
            fi

            # 【核心修复点】
            # $((10#...)) 语法强制 bash 使用 10 进制解析数字
            # 这样 '08' 就会被解析为数字 8，而不是错误的八进制
            prefix=$((10#$prefix))

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

# 构建多路输出参数 (只需构建一次)
OUTPUTS=()
URL_COUNT=0
for url in $MULTI_RTMP_URLS; do
    OUTPUTS+=("-f" "flv" "$url")
    ((URL_COUNT++))
done

echo "📡 将推流到 $URL_COUNT 个 RTMP 地址"

while true; do
    video="${VIDEO_LIST[$index]}"
    base=$(basename "$video")

    echo ""
    echo "🎬 播放第 $((index+1))/$TOTAL 个视频：$base"

    # 解析视频分辨率
    res=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=width,height \
        -of csv=p=0 "$video")
    
    WIDTH=$(echo "$res" | cut -d',' -f1)
    HEIGHT=$(echo "$res" | cut -d',' -f2)

    echo "分辨率：${WIDTH}x${HEIGHT}"

    # 自动选择码率
    choose_bitrate "$WIDTH" "$HEIGHT"

    echo "自动码率：VIDEO=$VIDEO_BITRATE  MAXRATE=$MAXRATE  BUF=$VIDEO_BUFSIZE"

    GOP=$((TARGET_FPS * KEYFRAME_INTERVAL_SECONDS))

    # ==========================================
    # [新增] 构建文字滤镜 (drawtext)
    # ==========================================
    TEXT_FILTER=""
    if [[ "$SHOW_FILENAME" == "yes" ]]; then
        # 1. 对文件名进行转义，防止 FFmpeg 滤镜解析错误 (处理冒号和单引号)
        safe_name=$(echo "$base" | sed "s/:/\\\\\\\\:/g" | sed "s/'/\\\\\\\\'/g")
        
        # 2. 构建滤镜字符串
        # x=10:y=h-th-10 (左下角), fontsize=24, fontcolor=white, 黑色半透明背景框
        TEXT_FILTER="drawtext=text='$safe_name':fontcolor=white:fontsize=24:x=10:y=h-th-10:box=1:boxcolor=black@0.5:boxborderw=5"
        
        # 如果指定了字体文件，加入 fontfile 参数
        if [[ -n "$FONT_FILE" && -f "$FONT_FILE" ]]; then
             TEXT_FILTER="drawtext=fontfile='$FONT_FILE':text='$safe_name':fontcolor=white:fontsize=24:x=10:y=h-th-10:box=1:boxcolor=black@0.5:boxborderw=5"
        fi
    fi

    echo "▶️ 开始推流（日志已打开）..."

    if $USE_WATERMARK; then
        # 场景 A: 有水印
        FILTER_COMPLEX=""
        if [[ -n "$TEXT_FILTER" ]]; then
            # 水印 + 文字：先 overlay 得到 [bg]，再在 [bg] 上 drawtext
            FILTER_COMPLEX="[0:v][1:v]overlay=10:10[bg];[bg]${TEXT_FILTER}"
        else
            # 仅水印
            FILTER_COMPLEX="overlay=10:10"
        fi

        ffmpeg -loglevel verbose \
            -re -i "$video" \
            -i "$WATERMARK_IMG" \
            -filter_complex "$FILTER_COMPLEX" \
            -c:v libx264 -preset superfast -tune zerolatency \
            -b:v "$VIDEO_BITRATE" -maxrate "$MAXRATE" -bufsize "$VIDEO_BUFSIZE" \
            -g "$GOP" -keyint_min "$GOP" -r "$TARGET_FPS" \
            -c:a aac -b:a 160k \
            "${OUTPUTS[@]}" # <-- 已修改为多路输出

    else
        # 场景 B: 无水印
        if [[ -n "$TEXT_FILTER" ]]; then
            # 无水印 + 有文字 (使用 -vf)
            ffmpeg -loglevel verbose \
                -re -i "$video" \
                -vf "$TEXT_FILTER" \
                -c:v libx264 -preset superfast -tune zerolatency \
                -b:v "$VIDEO_BITRATE" -maxrate "$MAXRATE" -bufsize "$VIDEO_BUFSIZE" \
                -g "$GOP" -keyint_min "$GOP" -r "$TARGET_FPS" \
                -c:a aac -b:a 160k \
                "${OUTPUTS[@]}" # <-- 已修改为多路输出
        else
            # 场景 C: 无水印 + 无文字 (原样推流，效率最高)
            ffmpeg -loglevel verbose \
                -re -i "$video" \
                -c:v libx264 -preset superfast -tune zerolatency \
                -b:v "$VIDEO_BITRATE" -maxrate "$MAXRATE" -bufsize "$VIDEO_BUFSIZE" \
                -g "$GOP" -keyint_min "$GOP" -r "$TARGET_FPS" \
                -c:a aac -b:a 160k \
                "${OUTPUTS[@]}" # <-- 已修改为多路输出
        fi
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
