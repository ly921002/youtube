📺 youtube

高性能、多平台、多路 RTMP 自动推流工具（FFmpeg Auto Stream）

本项目提供：

🧩 高稳定性的 Bash 推流脚本 youtube.sh

🐳 可直接部署的 Docker 镜像

⚙️ 完整的 docker-compose 示例（适用于 YouTube / Twitch / Bilibili / 任何 RTMP）

支持视频自动轮播、自动排序、自动码率、可选文本/水印、失败自动恢复等功能，是一个可长期 24 小时运行的自动推流解决方案。

✨ 功能特性
⚡ 自动循环推流

自动扫描 /videos 中的所有视频文件（支持 mp4/avi/mkv 等），自动按数字顺序排序后循环播放。

⚡ 多路同时输出

设置 MULTI_RTMP_URLS 后即可向多个平台同时推流。

⚡ COPY 优先策略

如果视频本身为 H.264 且未启用水印/文字 → 自动使用 copy 模式，避免不必要的 CPU 编码，提高稳定性。

⚡ 自动码率调节

根据视频分辨率（720p / 1080p / 2K / 4K）自动选择合理的码率，并限制在 MAX_UPLOAD 以内。

⚡ 动态水印 / 文件名叠字

可选：

🎬 显示当前播放的视频文件名

🖼 指定 PNG/JPG 水印

⚡ 音频自动检测

视频无音轨时不会报错，会自动静音推流。

⚡ 断流自动恢复

失败自动重试，循环不中断，适合长时间运行。

🚀 使用方法（Docker Compose）

以下是推荐的 docker-compose 示例，可直接复制使用。

version: '3'

services:
  ffmpegstream:
    image: ly920907/ffmpeg-autostream:latest
    container_name: ffmpeg-streamer
    restart: always
    
    # 低延迟 RTMP：推荐 host network（Linux Only）
    network_mode: host
    
    environment:
      MULTI_RTMP_URLS: "rtmp://a.rtmp.youtube.com/live2/直播码"
      FONT_FILE: "/usr/share/fonts/noto/NotoSansCJK-Regular.ttc"
      SLEEP_SECONDS: "5"
      SHOW_FILENAME: "no"      # yes = 转码 + 显示文件名
      WATERMARK: "no"          # yes = 转码 + 显示水印
      WATERMARK_IMG: ""        # 水印图片路径

    volumes:
      - /home/ubuntu/videos:/videos

    # 限制 docker logs（否则 FFmpeg 会疯狂输出）
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"


📂 视频文件存放

将你要推流的视频放入：

/home/ubuntu/videos


容器内会映射为：

/videos

⚙ 环境变量说明
变量名	默认值	说明
MULTI_RTMP_URLS	(必填)	多个 RTMP 地址，用空格分隔
VIDEO_DIR	/videos	视频目录
TARGET_FPS	30	输出视频帧率
KEYFRAME_INTERVAL_SECONDS	2	GOP = FPS × 秒
MAX_UPLOAD	10000k	最⼤视频码率上限
SHOW_FILENAME	no	显示文件名（强制转码）
WATERMARK	no	添加水印（强制转码）
WATERMARK_IMG	空	水印文件路径
FONT_FILE	空	字体路径，没有则用系统字体
VIDEO_EXTENSIONS	mp4,avi,mkv,...	扫描的文件类型
SLEEP_SECONDS	8	每个视频间的间隔秒数
🔍 视频自动排序规则

脚本会自动按文件名开头的数字进行升序排序：

01.mp4
02.mp4
10.mp4

无数字的按名称排序。

新增视频无需重启容器，会在下一个循环自动加载。


🛡 稳定性保证

Bash set -euo pipefail 防止脚本崩溃

COPY 失败自动转码

ffprobe 检测视频轨道

音轨自动处理

视频轮播不中断

超低延迟 zerolatency 推流

Docker 自动重启


📜 License

MIT License
