FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt update && apt install -y \
    wget curl python3 python3-pip ca-certificates git \
    ffmpeg build-essential \
    nodejs npm \
    && rm -rf /var/lib/apt/lists/*

# 安装最新 yt-dlp（nightly 才支持 n-challenge 完整解密）
RUN pip3 install --upgrade --force-reinstall "yt-dlp[default]"

# 安装 EJS challenge-solver
RUN mkdir -p /opt/challenge-solver \
    && git clone https://github.com/yt-dlp/yt-dlp.git /opt/challenge-solver \
    && ln -s /opt/challenge-solver/yt_dlp/extractor/* /usr/local/lib/python3.10/dist-packages/yt_dlp/extractor/ || true


# =====================
# 目录
# =====================
RUN mkdir -p /app /cookies

# 拷贝推流脚本
COPY youtube.sh /app/youtube.sh
RUN chmod +x /app/youtube.sh

WORKDIR /app

ENTRYPOINT ["/bin/bash", "/app/youtube.sh"]
