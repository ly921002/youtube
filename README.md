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
```
bash

docker compose up -d
```

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
| `SUBTITLE_EXTENSIONS` | `ass,srt,vtt,lrc,...` | 支持的字幕格式 |
| `ENABLE_SUBTITLES` | `no` | 字幕自动加载 |
| `SLEEP_SECONDS` | `8` | 视频间隔秒数 |

## 🛡 稳定性特性

| 变量名 | 默认值 | 说明 |
|-------|--------|------|
| `STALL_TIMEOUT` | `30` | 连续多少秒无数据输出即判定为卡死并重启本次推流，`0` 关闭该检测 |
| `FFMPEG_START_GRACE` | `30` | 启动宽限期，期间不做卡死判定（给建立 RTMP 连接留时间） |
| `PROGRESS_INTERVAL` | `5` | 存活检测轮询间隔（秒） |
| `RUNTIME_GRACE` | `120` | 单个视频在自身时长之外额外允许的秒数 |
| `MAX_RUNTIME` | `0` | 单个视频最长推流秒数，`0` 表示按视频时长 + `RUNTIME_GRACE` 自动推算 |
| `RETRY_MAX` | `3` | 单个视频失败后的重试次数（不含首次） |
| `RETRY_BACKOFF` | `5` | 重试退避基数（秒），按 1×、2×、4× 指数递增 |
| `RETRY_BACKOFF_MAX` | `300` | 退避上限（秒） |
| `FFMPEG_STOP_TIMEOUT` | `10` | 优雅停止等待秒数，超时后升级为 `SIGTERM` |

行为说明：

- **卡死检测**：推流时通过 `ffmpeg -progress` 持续读取 `out_time_ms / total_size / frame`，
  只要这些值不再变化且超过 `STALL_TIMEOUT`，就判定为假死并终止重启，避免整个轮播卡住。
- **时长上限**：按 `ffprobe` 取到的视频时长 + `RUNTIME_GRACE` 作为单次推流上限，
  即使 ffmpeg 既不退出也不报错也会被兜底结束。
- **失败重试**：copy 模式失败自动回退 transcode 模式；仍失败则按指数退避重试，
  超过 `RETRY_MAX` 后放弃当前视频并进入下一个。
- **优雅退出**：收到 `SIGTERM` / `SIGINT`（如 `docker stop`）时先向 ffmpeg 发 `SIGINT`
  让它写完 FLV trailer 再退出，避免平台侧看到异常断流。
- Bash `set -euo pipefail` 错误处理
- COPY 失败自动转码回退
- `ffprobe` 视频轨道检测
- 音轨自动处理
- 轮播不间断
- 低延迟 zerolatency 推流
- Docker 自动重启机制


## 📜 许可证

MIT License
