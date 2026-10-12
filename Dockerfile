FROM alpine:3.19

# 安装 ffmpeg（Alpine 的 ffmpeg 包含 ffprobe）
RUN apk add --no-cache ffmpeg bash coreutils findutils ttf-dejavu fontconfig
RUN apk add --no-cache font-noto-cjk
# 控制面板：Python 3 标准库，无需任何第三方依赖
RUN apk add --no-cache python3

WORKDIR /app

# 拷贝推流脚本与控制面板
COPY youtube.sh /app/youtube.sh
COPY entrypoint.sh /app/entrypoint.sh
COPY web/ /app/web/
RUN chmod +x /app/youtube.sh /app/entrypoint.sh

# 默认环境变量（可被外部覆盖）
ENV MULTI_RTMP_URLS=""
ENV VIDEO_DIR="/videos"
ENV WATERMARK="no"
ENV WATERMARK_IMG=""
ENV SHOW_FILENAME="yes"
ENV FONT_FILE=""
ENV SLEEP_SECONDS="10"

# 控制面板
ENV STATUS_ENABLED="yes"
ENV STATUS_DIR="/app/status"
ENV COMMAND_DIR="/app/status/commands"
ENV PORT="8080"
# 只监听本机；需要局域网/公网访问时改 0.0.0.0，并务必设置 WEB_USER / WEB_PASSWORD
ENV WEB_HOST="127.0.0.1"
ENV WEB_USER=""
ENV WEB_PASSWORD=""

EXPOSE 8080

ENTRYPOINT ["/bin/bash", "/app/entrypoint.sh"]
