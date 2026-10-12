(function () {
  "use strict";

  var REFRESH_MS = 3000;
  var dom = {
    badge: document.getElementById("badge"),
    badgeText: document.getElementById("badgeText"),
    currentFile: document.getElementById("currentFile"),
    position: document.getElementById("position"),
    mode: document.getElementById("mode"),
    timing: document.getElementById("timing"),
    bitrate: document.getElementById("bitrate"),
    rtmpCount: document.getElementById("rtmpCount"),
    pid: document.getElementById("pid"),
    targets: document.getElementById("targets"),
    progressBar: document.getElementById("progressBar"),
    uptime: document.getElementById("uptime"),
    updatedAt: document.getElementById("updatedAt"),
    errorCard: document.getElementById("errorCard"),
    lastError: document.getElementById("lastError"),
    toast: document.getElementById("toast"),
    logoutBtn: document.getElementById("logoutBtn"),
    btnPause: document.querySelector('button[data-action="pause"]'),
    btnResume: document.querySelector('button[data-action="resume"]')
  };

  var STATE_TEXT = {
    streaming: "直播中",
    idle: "等待中",
    paused: "已暂停",
    starting: "启动中",
    waiting: "等待视频",
    offline: "未运行",
    unknown: "状态未知"
  };

  function formatDuration(seconds) {
    seconds = Math.max(0, parseInt(seconds, 10) || 0);
    var h = Math.floor(seconds / 3600);
    var m = Math.floor((seconds % 3600) / 60);
    var s = seconds % 60;
    if (h > 0) { return h + " 小时 " + m + " 分"; }
    if (m > 0) { return m + " 分 " + s + " 秒"; }
    return s + " 秒";
  }

  var toastTimer = null;
  function toast(message) {
    dom.toast.textContent = message;
    dom.toast.className = "toast show";
    if (toastTimer) { clearTimeout(toastTimer); }
    toastTimer = setTimeout(function () { dom.toast.className = "toast"; }, 2600);
  }

  function api(path, options) {
    return fetch(path, options || {}).then(function (res) {
      if (res.status === 401) {
        window.location.href = "/login.html";
        throw new Error("unauthorized");
      }
      return res.json().catch(function () { return {}; }).then(function (data) {
        if (!res.ok) {
          throw new Error(data.error || ("HTTP " + res.status));
        }
        return data;
      });
    });
  }

  function render(data) {
    var state = data.state || "unknown";
    var live = state === "streaming";

    dom.badge.className = "badge" + (live ? " live" : "");
    dom.badgeText.textContent = STATE_TEXT[state] || state;

    // 暂停 / 恢复按当前状态互斥，避免误点与"点了没反应"的错觉
    if (dom.btnPause) { dom.btnPause.disabled = (state === "paused"); }
    if (dom.btnResume) { dom.btnResume.disabled = (state !== "paused"); }

    dom.currentFile.textContent = data.current_file || "—";
    dom.position.textContent = data.total_videos
      ? (data.current_index || 0) + " / " + data.total_videos
      : "—";

    var mode = data.mode || "unknown";
    if (mode === "copy") {
      dom.mode.innerHTML = '<span class="tag copy">COPY 直推</span>';
    } else if (mode === "transcode") {
      dom.mode.innerHTML = '<span class="tag transcode">TRANSCODE 转码</span>';
    } else {
      dom.mode.textContent = mode;
    }

    var elapsed = parseInt(data.elapsed_seconds, 10) || 0;
    var limit = parseInt(data.limit_seconds, 10) || 0;
    dom.timing.textContent = limit > 0
      ? formatDuration(elapsed) + " / " + formatDuration(limit)
      : formatDuration(elapsed);
    dom.progressBar.style.width = (limit > 0 ? Math.min(100, (elapsed / limit) * 100) : 0) + "%";

    dom.bitrate.textContent = data.video_bitrate || "—";
    dom.rtmpCount.textContent = (data.rtmp_count || 0) + " 路";
    dom.pid.textContent = data.ffmpeg_pid || "—";
    dom.uptime.textContent = "运行时长 " + formatDuration(data.uptime_seconds);

    var targets = data.rtmp_targets || [];
    dom.targets.innerHTML = "";
    if (!targets.length) {
      var empty = document.createElement("li");
      empty.textContent = "—";
      dom.targets.appendChild(empty);
    } else {
      targets.forEach(function (item) {
        var li = document.createElement("li");
        li.textContent = item;
        dom.targets.appendChild(li);
      });
    }

    if (data.last_error) {
      dom.errorCard.style.display = "";
      dom.lastError.textContent = data.last_error;
    } else {
      dom.errorCard.style.display = "none";
    }

    dom.updatedAt.textContent = "状态更新于 " + (data.updated_at || "—");
  }

  function refresh() {
    return api("/api/status").then(render).catch(function (error) {
      if (error.message !== "unauthorized") {
        dom.updatedAt.textContent = "读取状态失败：" + error.message;
      }
    });
  }

  var busy = false;
  function control(action) {
    if (busy) { return; }
    busy = true;
    api("/api/control", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: action })
    }).then(function () {
      toast("指令已下发：" + action);
      return refresh();
    }).catch(function (error) {
      toast("下发失败：" + error.message);
    }).then(function () {
      busy = false;
    });
  }

  Array.prototype.forEach.call(document.querySelectorAll("button[data-action]"), function (btn) {
    btn.addEventListener("click", function () {
      var action = btn.getAttribute("data-action");
      if (action === "stop" && !window.confirm("确定停止推流？容器需配置 restart 策略才会自动拉起。")) {
        return;
      }
      control(action);
    });
  });

  dom.logoutBtn.addEventListener("click", function () {
    fetch("/api/logout", { method: "POST" }).then(function () {
      window.location.href = "/login.html";
    });
  });

  refresh();
  setInterval(refresh, REFRESH_MS);
})();
