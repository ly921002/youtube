# 📺 FFmpeg Auto Stream

高性能、多平台、多路 RTMP 自动推流工具

## ✨ 功能特性

- ⚡ **自动循环推流** - 自动扫描视频文件，按顺序循环播放
- ⚡ **多路同时输出** - 支持向多个平台同时推流
- ⚡ **COPY 优先策略** - 自动使用 copy 模式，提高稳定性
- ⚡ **自动码率调节** - 根据视频分辨率智能选择码率
- ⚡ **动态水印/文件名叠加** - 可选显示文件名或水印
- ⚡ **音频自动检测** - 无音轨时自动静音推流
- ⚡ **断流自动恢复** - 失败自动重试，24小时稳定运行

## 🚀 快速开始

### Docker Compose 部署

创建 `docker-compose.yml` 文件

启动服务：

bash
docker compose up -d

## 📂 文件结构

/home/ubuntu/videos/ # 主机视频目录
├── 01.mp4
├── 02.mp4
└── 03.mp4

容器内映射路径：`/videos`

## ⚙️ 环境变量配置

| 变量名 | 默认值 | 说明 |
|-------|--------|------|
| `MULTI_RTMP_URLS` | **(必填)** | 多个 RTMP 地址，用空格分隔 |
| `VIDEO_DIR` | `/videos` | 视频目录路径 |
| `TARGET_FPS` | `30` | 输出视频帧率 |
| `KEYFRAME_INTERVAL_SECONDS` | `2` | GOP 间隔秒数 |
| `MAX_UPLOAD` | `10000k` | 最大视频码率上限 |
| `SHOW_FILENAME` | `no` | 显示文件名（强制转码） |
| `WATERMARK` | `no` | 添加水印（强制转码） |
| `WATERMARK_IMG` | 空 | 水印图片路径 |
| `FONT_FILE` | 空 | 字体文件路径 |
| `VIDEO_EXTENSIONS` | `mp4,avi,mkv,...` | 支持的视频格式 |
| `SLEEP_SECONDS` | `8` | 视频间隔秒数 |

## 🛡 稳定性特性

- Bash `set -euo pipefail` 错误处理
- COPY 失败自动转码回退
- `ffprobe` 视频轨道检测
- 音轨自动处理
- 轮播不间断
- 低延迟 zerolatency 推流
- Docker 自动重启机制

## 🤝 贡献

欢迎提交 Issue 和 PR！如有需求（随机播放、远程管理、HLS 输出等），可在 Issue 中提出。

## 📜 许可证

MIT License
