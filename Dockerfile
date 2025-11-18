FROM alpine:3.19

# 安装 ffmpeg（Alpine 的 ffmpeg 包含 ffprobe）
RUN apk add --no-cache ffmpeg bash coreutils findutils

WORKDIR /app

# 拷贝推流脚本
COPY youtube.sh /app/youtube.sh
RUN chmod +x /app/youtube.sh

# 默认环境变量（可被外部覆盖）
ENV RTMP_URL=""
ENV VIDEO_DIR="/videos"
ENV WATERMARK="no"
ENV WATERMARK_IMG=""
ENV SLEEP_MIN="5"
ENV SLEEP_MAX="15"

ENTRYPOINT ["/bin/bash", "/app/youtube.sh"]
