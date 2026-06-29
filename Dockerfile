FROM alpine:3.19

# 安装 ffmpeg（Alpine 的 ffmpeg 包含 ffprobe）
RUN apk add --no-cache ffmpeg bash coreutils findutils ttf-dejavu fontconfig python3
RUN apk add --no-cache font-noto-cjk

WORKDIR /app

# 拷贝推流脚本与网页界面
COPY youtube.sh /app/youtube.sh
COPY entrypoint.sh /app/entrypoint.sh
COPY status_writer.sh /app/status_writer.sh
COPY web /app/web
RUN chmod +x /app/youtube.sh /app/entrypoint.sh /app/status_writer.sh

# 默认环境变量（可被外部覆盖）
ENV MULTI_RTMP_URLS=""
ENV VIDEO_DIR="/videos"
ENV WATERMARK="no"
ENV WATERMARK_IMG=""

# 新增：是否显示文件名
ENV SHOW_FILENAME="yes"

# 新增：指定字体路径（可选，默认留空会使用系统字体）
ENV FONT_FILE=""

# 循环间隔
ENV SLEEP_SECONDS="10"

EXPOSE 8080

ENTRYPOINT ["/bin/bash", "/app/entrypoint.sh"]
