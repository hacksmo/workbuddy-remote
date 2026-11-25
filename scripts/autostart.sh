#!/usr/bin/env bash
# 安装开机自启：登录后自动起桥（macOS 用 LaunchAgent，Linux 用 systemd --user）
#
#   ./scripts/autostart.sh install    安装并立即启用
#   ./scripts/autostart.sh uninstall  卸载
#   ./scripts/autostart.sh status     查看
#
# 说明：只让「桥」常驻，不代管 WorkBuddy 本身。WorkBuddy 需要以调试端口启动，
# 若它自己不带，桥起来也连不上 —— 所以自启脚本会先探测，连不上就等下一轮。
# 想彻底免手动，把 WorkBuddy 的启动项改成带 --remote-debugging-port=9333。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/workbuddy-remote"
LOG_DIR="$STATE_DIR/logs"
START="$ROOT/scripts/start.sh"
LABEL="com.workbuddy.remote.bridge"
UNIT="workbuddy-remote-bridge"
CDP_PORT="${WB_CDP_PORT:-9333}"
WB_PORT="${WB_PORT:-8797}"

mkdir -p "$STATE_DIR" "$LOG_DIR"

if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_OK=''; C_ERR=''; C_B=''; C_0=''
fi
info() { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s ✓%s %s\n' "$C_OK" "$C_0" "$*"; }
warn() { printf '%s !%s %s\n' "$C_ERR" "$C_0" "$*"; }
die()  { warn "$*"; exit 1; }

case "$(uname -s)" in
  Darwin) PLATFORM=macos ;;
  Linux)  PLATFORM=linux ;;
  *) die "仅支持 macOS / Linux" ;;
esac

# ── macOS：LaunchAgent ──────────────────────────────────────────────────
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

mac_install() {
  mkdir -p "$HOME/Library/LaunchAgents"
  cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${START}</string>
        <string>--no-restart</string>
        <string>--foreground</string>
        <string>--quiet</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key><string>${HOME}</string>
        <key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>WB_CDP_PORT</key><string>${CDP_PORT}</string>
        <key>WB_PORT</key><string>${WB_PORT}</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <!-- 前台常驻模式，进程活着就是服务活着；退出即重启 -->
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>30</integer>
    <key>StandardOutPath</key><string>${LOG_DIR}/autostart.out.log</string>
    <key>StandardErrorPath</key><string>${LOG_DIR}/autostart.err.log</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null \
    || launchctl load "$PLIST" 2>/dev/null || true
  ok "LaunchAgent 已安装：$PLIST"
}

mac_uninstall() {
  launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  ok "LaunchAgent 已移除"
}

mac_status() {
  if launchctl print "gui/$(id -u)/${LABEL}" >/dev/null 2>&1; then
    ok "LaunchAgent 已加载"
    launchctl print "gui/$(id -u)/${LABEL}" 2>/dev/null | grep -E "state|pid" | head -3
  else
    warn "LaunchAgent 未加载"
  fi
}

# ── Linux：systemd --user ───────────────────────────────────────────────
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT_FILE="$UNIT_DIR/${UNIT}.service"

linux_install() {
  command -v systemctl >/dev/null 2>&1 || die "未找到 systemctl，无法安装自启"
  mkdir -p "$UNIT_DIR"
  cat >"$UNIT_FILE" <<EOF
[Unit]
Description=WorkBuddy Remote bridge
After=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash "${START}" --no-restart --foreground --quiet
Restart=on-failure
RestartSec=30
Environment=WB_CDP_PORT=${CDP_PORT}
Environment=WB_PORT=${WB_PORT}
Environment=PATH=/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now "${UNIT}.service" 2>/dev/null || true
  # 未开启 linger 时，注销后用户级服务会停
  if command -v loginctl >/dev/null 2>&1; then
    loginctl enable-linger "$(id -un)" 2>/dev/null || \
      warn "未能开启 linger，注销后自启会失效（需要 sudo）"
  fi
  ok "systemd 用户服务已安装：$UNIT_FILE"
}

linux_uninstall() {
  systemctl --user disable --now "${UNIT}.service" 2>/dev/null || true
  rm -f "$UNIT_FILE"
  systemctl --user daemon-reload 2>/dev/null || true
  ok "systemd 用户服务已移除"
}

linux_status() {
  systemctl --user status "${UNIT}.service" --no-pager 2>/dev/null | head -8 \
    || warn "服务未安装"
}

# ── 主流程 ──────────────────────────────────────────────────────────────
ACTION="${1:-install}"
case "$ACTION" in
  install)
    [ -x "$START" ] || die "找不到启动脚本：$START"
    if [ "$PLATFORM" = macos ]; then mac_install; else linux_install; fi
    echo
    info "提示：自启用 --no-restart 模式，只负责桥。"
    info "WorkBuddy 自身需要带调试端口启动，否则桥连不上。"
    ;;
  uninstall)
    if [ "$PLATFORM" = macos ]; then mac_uninstall; else linux_uninstall; fi
    ;;
  status)
    if [ "$PLATFORM" = macos ]; then mac_status; else linux_status; fi
    ;;
  *) die "未知操作: $ACTION（install / uninstall / status）" ;;
esac