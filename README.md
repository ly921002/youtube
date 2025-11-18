version: '3'

services:
  ffmpegstream:
    image: ly920907/ffmpeg-autostream:latest
    container_name: ffmpeg-streamer
    restart: always
    environment:
      RTMP_URL: "rtmp://a.rtmp.youtube.com/live2/直播码"
      VIDEO_DIR: "/videos"
      WATERMARK: "no"
      SLEEP_MIN: "1"
      SLEEP_MAX: "3"
    volumes:
      - /home/ubuntu/videos:/videos
