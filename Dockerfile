FROM debian:stable-slim

# 安装 ffmpeg 和基础工具
RUN apt update && \
    apt install -y ffmpeg bash findutils coreutils && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 拷贝推流脚本
COPY youtube.sh /app/youtube.sh
RUN chmod +x /app/youtube.sh

# 设置默认环境变量（可以被外部覆盖）
ENV RTMP_URL=""
ENV VIDEO_DIR="/videos"
ENV WATERMARK="no"
ENV WATERMARK_IMG=""
ENV SLEEP_MIN="5"
ENV SLEEP_MAX="15"

ENTRYPOINT ["/bin/bash", "/app/youtube.sh"]
