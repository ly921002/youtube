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
| `WAIT_FOR_VIDEOS` | `yes` | 目录里暂时没有可播放视频时进入等待状态而不是直接退出，`no` 恢复旧行为 |
| `VIDEO_SCAN_INTERVAL` | `30` | 等待状态下重新扫描视频目录的间隔（秒），必须为正整数 |

行为说明：

- **卡死检测**：推流时通过 `ffmpeg -progress` 持续读取 `out_time_ms / total_size / frame`，
  只要这些值不再变化且超过 `STALL_TIMEOUT`，就判定为假死并终止重启，避免整个轮播卡住。
- **时长上限**：按 `ffprobe` 取到的视频时长 + `RUNTIME_GRACE` 作为单次推流上限，
  即使 ffmpeg 既不退出也不报错也会被兜底结束。
- **失败重试**：copy 模式失败自动回退 transcode 模式；仍失败则按指数退避重试，
  超过 `RETRY_MAX` 后放弃当前视频并进入下一个。
- **优雅退出**：收到 `SIGTERM` / `SIGINT`（如 `docker stop`）时先向 ffmpeg 发 `SIGINT`
  让它写完 FLV trailer 再退出，避免平台侧看到异常断流。
- **无视频等待**：启动时或轮播过程中若目录里没有可播放视频，默认**不会退出**，
  而是进入 `waiting` 状态、每 `VIDEO_SCAN_INTERVAL` 秒重扫一次，面板保持可访问；
  把视频放进目录后会自动开始推流。设 `WAIT_FOR_VIDEOS=no` 可恢复"直接报错退出"的旧行为。
- **重新扫描安全**：面板「重新扫描」或轮播一轮后的自动重扫，扫不到视频时只会
  打印警告并沿用上一次的列表，不会再终止脚本。
- Bash `set -euo pipefail` 错误处理
- COPY 失败自动转码回退
- `ffprobe` 视频轨道检测
- 音轨自动处理
- 轮播不间断
- 低延迟 zerolatency 推流
- Docker 自动重启机制


## 🖥 Web 控制面板

推流脚本会把运行状态原子写入 `/app/status/status.json`，面板读取该文件展示；
控制指令则是面板往 `/app/status/commands/` 写一个 `<时间戳>.<动作>` 文件，由脚本消费后删除。
两者完全解耦，脚本不依赖面板也能正常运行。

### 功能

- 实时状态：当前播放文件、序号、推流模式（COPY / TRANSCODE）、已播时长 / 上限、码率、推流路数、ffmpeg PID、运行时长
- 远程控制：下一个 / 上一个 / 暂停 / 恢复 / 重新扫描视频目录 / 停止推流
- 推流地址自动打码，只显示到 `rtmp://host/path/****`，不会泄露推流码
- 登录鉴权：HMAC-SHA256 签名 Cookie（`HttpOnly` + `SameSite=Strict`）、同 IP 失败限流、进程重启后旧会话失效

### 访问方式

默认只监听容器 `127.0.0.1`，compose 里也只映射到宿主机 `127.0.0.1:8080`，因此需通过 SSH 隧道访问：

```bash
ssh -L 8080:127.0.0.1:8080 user@your-vps
# 浏览器打开 http://127.0.0.1:8080
```

需要局域网或公网直接访问时：把 `WEB_HOST` 改成 `0.0.0.0`、端口映射去掉 `127.0.0.1` 前缀，
**并且必须设置 `WEB_USER` / `WEB_PASSWORD`**（未设置密码时服务会拒绝绑定到非本机地址）。

### 新增环境变量

| 变量名 | 默认值 | 说明 |
|-------|--------|------|
| `STATUS_ENABLED` | `yes` | 是否启用状态输出与面板，`no` 则完全关闭 |
| `STATUS_DIR` | `/app/status` | 状态与指令目录 |
| `PORT` | `8080` | 面板监听端口 |
| `WEB_HOST` | `127.0.0.1` | 面板监听地址 |
| `WEB_USER` | 空 | 登录用户名（与密码同时设置才启用鉴权） |
| `WEB_PASSWORD` | 空 | 登录密码 |

### HTTP 接口

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/` | 面板页面（未登录跳转 `/login.html`） |
| GET | `/api/status` | 当前推流状态 JSON |
| POST | `/api/login` | 登录，body `{"username":"","password":""}` |
| POST | `/api/logout` | 登出 |
| POST | `/api/control` | 下发指令，body `{"action":"next"}` |
| GET | `/api/ping` | 探活，返回是否启用鉴权 |

`action` 可选：`next`、`prev`、`pause`、`resume`、`rescan`、`stop`。
其中 `stop` 会结束脚本进程，需要容器配置 `restart: always` 才会自动拉起。

### 控制语义

| 动作 | 播放中触发 | 说明 |
|------|-----------|------|
| `next` | 立即停止当前推流，切到下一个 | 不计入失败重试 |
| `prev` | 立即停止当前推流，切到上一个 | 不计入失败重试 |
| `pause` | **立即停止当前推流**并进入 `paused` | 等 `resume`；期间仍响应 `next` / `prev` / `rescan` / `stop` |
| `resume` | 仅在 `paused` 时生效 | **从暂停的时间点继续播放**（给 ffmpeg 加 `-ss <断点>`，输入侧定位到最近关键帧） |
| `rescan` | 立即重扫目录，不打断当前推流 | 扫不到视频时沿用旧列表，不会终止脚本 |
| `stop` | 立即停止并结束脚本 | 依赖容器 `restart: always` 自动拉起 |

> 断点续播说明：
> - 断点取自推流已播秒数，精度为 `PROGRESS_INTERVAL`（默认 5 秒），`-ss` 走输入侧定位，
>   实际会从**最近的关键帧**开始，可能与断点相差一个 GOP（`KEYFRAME_INTERVAL_SECONDS`，默认 2 秒）。
> - 恢复后本轮时长上限会扣掉已播部分，进度条按「断点 + 已播」显示。
> - 只有在推流过程中暂停才有断点；如果是在视频间隔期暂停，恢复后仍从头播放当前视频。
> - 恢复后若当前视频在断点处已播放失败（例如断点接近文件末尾），会自动按失败重试逻辑处理并进入下一个。

> 暂停期间按钮会按状态互斥置灰（暂停时只能点「恢复」），避免误点。

面板上的状态取值：`streaming`（直播中）、`idle`（间隔等待）、`paused`（已暂停）、
`waiting`（等待视频）、`starting`（启动中）、`offline`（脚本未运行）。

## 📜 许可证

MIT License
