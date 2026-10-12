#!/usr/bin/env python3
"""FFmpeg Auto Stream 控制面板（仅用 Python 标准库）。

状态来源：推流脚本原子写入的 status.json
控制方式：往指令目录写 <时间戳>.<动作> 文件，由推流脚本消费

环境变量：
    PORT              监听端口，默认 8080
    WEB_HOST          监听地址，默认 127.0.0.1（只开放本机）
    WEB_USER          登录用户名（与 WEB_PASSWORD 同时设置才启用鉴权）
    WEB_PASSWORD      登录密码
    STATUS_FILE       状态文件路径
    COMMAND_DIR       指令目录路径
"""

import hashlib
import hmac
import json
import os
import re
import secrets
import sys
import time
from http import HTTPStatus
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

PORT = int(os.environ.get("PORT") or "8080")
WEB_HOST = os.environ.get("WEB_HOST") or "127.0.0.1"
WEB_USER = (os.environ.get("WEB_USER") or "").strip()
WEB_PASSWORD = os.environ.get("WEB_PASSWORD") or ""
STATUS_FILE = os.environ.get("STATUS_FILE") or "/app/status/status.json"
COMMAND_DIR = os.environ.get("COMMAND_DIR") or "/app/status/commands"
STATIC_DIR = Path(__file__).resolve().parent / "static"

SESSION_COOKIE = "fas_session"
SESSION_TTL_SECONDS = 12 * 3600
LOGIN_MAX_FAILS = 5
LOGIN_FAIL_WINDOW_SECONDS = 300

ALLOWED_ACTIONS = ("next", "prev", "pause", "resume", "rescan", "stop")
PUBLIC_PATHS = ("/login.html", "/login.css", "/login.js", "/api/login")
STATIC_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
}

# 每次进程启动随机生成，重启后旧 cookie 自动失效
_SECRET_KEY = secrets.token_bytes(32)
_AUTH_ENABLED = bool(WEB_USER and WEB_PASSWORD)
_login_guard = {}


def log(message):
    print("[web] {} {}".format(time.strftime("%Y-%m-%d %H:%M:%S"), message), flush=True)


def sign(payload):
    return hmac.new(_SECRET_KEY, payload.encode("utf-8"), hashlib.sha256).hexdigest()


def issue_token():
    expire_at = str(int(time.time()) + SESSION_TTL_SECONDS)
    return "{}.{}".format(expire_at, sign(expire_at))


def token_valid(token):
    if not token or "." not in token:
        return False
    expire_at, _, signature = token.partition(".")
    if not expire_at.isdigit():
        return False
    if int(expire_at) < time.time():
        return False
    return hmac.compare_digest(sign(expire_at), signature)


def login_blocked(peer):
    now = time.time()
    attempts = [t for t in _login_guard.get(peer, []) if now - t < LOGIN_FAIL_WINDOW_SECONDS]
    if len(attempts) >= LOGIN_MAX_FAILS:
        _login_guard[peer] = attempts
        return True
    return False


def login_failed(peer):
    attempts = _login_guard.setdefault(peer, [])
    attempts.append(time.time())


def login_succeeded(peer):
    _login_guard.pop(peer, None)


def read_status():
    try:
        with open(STATUS_FILE, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        return {
            "state": "offline",
            "message": "尚未生成状态文件，推流可能还没开始",
            "current_file": "",
            "current_index": 0,
            "total_videos": 0,
            "mode": "unknown",
            "rtmp_targets": [],
            "rtmp_count": 0,
            "elapsed_seconds": 0,
            "limit_seconds": 0,
            "ffmpeg_pid": 0,
            "last_error": "",
            "updated_at": None,
            "uptime_seconds": 0,
        }
    except (ValueError, OSError):
        # 正在原子替换的瞬间可能读到半个文件，稍等重试一次
        time.sleep(0.05)
        try:
            with open(STATUS_FILE, "r", encoding="utf-8") as handle:
                return json.load(handle)
        except (ValueError, OSError):
            return {"state": "unknown", "message": "状态文件暂时无法解析"}


def write_command(action):
    os.makedirs(COMMAND_DIR, exist_ok=True)
    path = os.path.join(COMMAND_DIR, "{}.{}".format(int(time.time() * 1000), action))
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(action)
    return path


class PanelHandler(BaseHTTPRequestHandler):
    server_version = "ffmpeg-autostream-panel"
    protocol_version = "HTTP/1.1"

    # ------------------------------------------------------------ 基础工具

    def _peer(self):
        # 只用 TCP 对端地址，不信任 X-Forwarded-For（可伪造）
        return self.client_address[0] if self.client_address else "unknown"

    def _cookies(self):
        jar = SimpleCookie()
        raw = self.headers.get("Cookie")
        if raw:
            try:
                jar.load(raw)
            except Exception:
                return {}
        return {key: value.value for key, value in jar.items()}

    def _send(self, status, body=b"", content_type="application/json; charset=utf-8",
              extra_headers=None, cookie=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "noscript")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
            "connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
        )
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        for key, value in (extra_headers or {}).items():
            self.send_header(key, value)
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _send_json(self, status, payload, cookie=None):
        self._send(status, json.dumps(payload, ensure_ascii=False), cookie=cookie)

    def _authenticated(self):
        if not _AUTH_ENABLED:
            return True
        token = self._cookies().get(SESSION_COOKIE)
        return token_valid(token or "")

    # ------------------------------------------------------------ 路由

    def do_GET(self):
        path = urlparse(self.path).path

        # 登录页及其资源必须匿名可访问，否则未登录时无法登录
        if path in ("/login.html", "/login.css", "/login.js"):
            return self._serve_static(path.lstrip("/"))

        if path == "/api/ping":
            return self._send_json(HTTPStatus.OK, {"ok": True, "auth": _AUTH_ENABLED})

        if path.startswith("/api/"):
            if not self._authenticated():
                return self._send_json(HTTPStatus.UNAUTHORIZED, {"error": "未登录"})
            if path == "/api/status":
                return self._handle_status()
            return self._send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})

        # 其余一律是需要登录的页面或静态资源
        if not self._authenticated():
            return self._redirect_to_login()
        if path in ("/", "/index.html"):
            return self._serve_static("index.html")
        return self._serve_static(path.lstrip("/"))

    def do_POST(self):
        path = urlparse(self.path).path

        if path == "/api/login":
            return self._handle_login()
        if path == "/api/logout":
            cookie = "{}=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict".format(SESSION_COOKIE)
            return self._send_json(HTTPStatus.OK, {"ok": True}, cookie=cookie)

        if not self._authenticated():
            return self._send_json(HTTPStatus.UNAUTHORIZED, {"error": "未登录"})
        if path == "/api/control":
            return self._handle_control()
        return self._send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})

    def do_HEAD(self):
        self._send(HTTPStatus.OK, b"")

    def _redirect_to_login(self):
        self._send(HTTPStatus.FOUND, b"", extra_headers={"Location": "/login.html"})

    def _handle_status(self):
        status = read_status()
        status["auth_enabled"] = _AUTH_ENABLED
        self._send_json(HTTPStatus.OK, status)

    def _handle_control(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return self._send_json(HTTPStatus.BAD_REQUEST, {"error": "请求体为空"})
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return self._send_json(HTTPStatus.BAD_REQUEST, {"error": "请求体不是合法 JSON"})
        action = str(payload.get("action") or "").strip()
        if action not in ALLOWED_ACTIONS:
            return self._send_json(
                HTTPStatus.BAD_REQUEST,
                {"error": "不支持的动作", "allowed": list(ALLOWED_ACTIONS)},
            )
        try:
            write_command(action)
        except OSError as error:
            return self._send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": str(error)})
        log("收到控制指令: {}".format(action))
        self._send_json(HTTPStatus.OK, {"ok": True, "action": action})

    def _handle_login(self):
        if not _AUTH_ENABLED:
            return self._send_json(HTTPStatus.OK, {"ok": True, "auth": False})
        peer = self._peer()
        if login_blocked(peer):
            return self._send_json(
                HTTPStatus.TOO_MANY_REQUESTS,
                {"error": "登录失败次数过多，请 {} 秒后再试".format(LOGIN_FAIL_WINDOW_SECONDS)},
            )
        length = int(self.headers.get("Content-Length") or 0)
        try:
            payload = json.loads(self.rfile.read(length or b"{}").decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            payload = {}
        user = str(payload.get("username") or "")
        password = str(payload.get("password") or "")
        if hmac.compare_digest(user, WEB_USER) and hmac.compare_digest(password, WEB_PASSWORD):
            login_succeeded(peer)
            cookie = "{}={}; Path=/; Max-Age={}; HttpOnly; SameSite=Strict".format(
                SESSION_COOKIE, issue_token(), SESSION_TTL_SECONDS
            )
            log("登录成功: {}".format(peer))
            return self._send_json(HTTPStatus.OK, {"ok": True}, cookie=cookie)
        login_failed(peer)
        log("登录失败: {}".format(peer))
        return self._send_json(HTTPStatus.UNAUTHORIZED, {"error": "用户名或密码错误"})

    def _serve_static(self, relative):
        name = Path(relative).name
        target = (STATIC_DIR / name).resolve()
        if STATIC_DIR not in target.parents and target != STATIC_DIR:
            return self._send_json(HTTPStatus.FORBIDDEN, {"error": "forbidden"})
        if not target.is_file():
            return self._send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
        body = target.read_bytes()
        self._send(HTTPStatus.OK, body, content_type=STATIC_TYPES.get(target.suffix, "application/octet-stream"))

    def log_message(self, fmt, *args):
        log("%s - %s" % (self.address_string(), fmt % args))


def main():
    if not _AUTH_ENABLED:
        if WEB_HOST not in ("127.0.0.1", "localhost", "::1"):
            log("未设置 WEB_USER/WEB_PASSWORD，拒绝绑定到 {}，已强制改为 127.0.0.1".format(WEB_HOST))
            host = "127.0.0.1"
        else:
            host = WEB_HOST
            log("未设置登录凭据，鉴权已关闭；因为只监听 127.0.0.1，需通过 SSH 隧道访问")
    else:
        host = WEB_HOST
        log("鉴权已启用，用户: {}".format(WEB_USER))

    if not STATIC_DIR.is_dir():
        log("静态目录缺失: {}".format(STATIC_DIR))
        return 1

    server = ThreadingHTTPServer((host, PORT), PanelHandler)
    server.daemon_threads = True
    log("控制面板已启动: http://{}:{}".format(host, PORT))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
