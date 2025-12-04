FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt update && apt install -y \
    wget curl python3 python3-pip ca-certificates git \
    fonts-dejavu-core fonts-freefont-ttf \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# =====================
# 安装 FFmpeg（完整版）
# =====================
RUN apt update && apt install -y ffmpeg && rm -rf /var/lib/apt/lists/*

# =====================
# 安装 yt-dlp
# =====================
RUN pip3 install --no-cache-dir yt-dlp

# =====================
# 安装 Node.js（v18）
# =====================
RUN curl -fsSL https://deb.nodesource.com/setup_18.x | bash - \
    && apt install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# =====================
# 目录
# =====================
RUN mkdir -p /app /cookies

# 拷贝推流脚本
COPY youtube.sh /app/youtube.sh
RUN chmod +x /app/youtube.sh

WORKDIR /app

ENTRYPOINT ["/bin/bash", "/app/youtube.sh"]
