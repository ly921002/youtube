FROM alpine:3.19

# 安装 ffmpeg（Alpine 的 ffmpeg 包含 ffprobe）
RUN apk add --no-cache ffmpeg bash coreutils findutils ttf-dejavu fontconfig
RUN apk add --no-cache font-noto-cjk

WORKDIR /app

# 拷贝推流脚本
COPY youtube.sh /app/youtube.sh
RUN chmod +x /app/youtube.sh

# 默认环境变量（可被外部覆盖）
ENV RTMP_URL=""
ENV VIDEO_DIR="/videos"
ENV WATERMARK="no"
ENV WATERMARK_IMG=""

# 新增：是否显示文件名
ENV SHOW_FILENAME="yes"

# 新增：指定字体路径（可选，默认留空会使用系统字体）
ENV FONT_FILE=""

# 循环间隔
ENV SLEEP_SECONDS="10"

ENTRYPOINT ["/bin/bash", "/app/youtube.sh"]
