#!/usr/bin/env bash
# WorkBuddy Remote —— 一键安装（macOS / Linux）
#
# ┌─ 两种角色，别装反了 ───────────────────────────────────────────┐
# │                                                                │
# │  被控端 (server)  装在你的开发机上。它把本机 WorkBuddy 变成    │
# │                   可被远程访问的服务。默认模式。                │
# │                                                                │
# │  控制端 (client)  装在你用来远程的那台电脑上。它只是给你一个    │
# │                   能点开的图标/命令，本质还是浏览器。           │
# │                   用法：--client <被控端地址>                   │
# │                                                                │
# └────────────────────────────────────────────────────────────────┘
#
# 被控端：
#   curl -fsSL https://raw.githubusercontent.com/hacksmo/workbuddy-remote/main/install.sh | bash
#
# 控制端：
#   curl -fsSL .../install.sh | bash -s -- --client 'https://your-host/?token=xxx'
#
# 可选环境变量：
#   WB_REF       分支/标签，默认 main
#   WB_DIR       安装目录，默认 ~/.local/share/workbuddy-remote
#   WB_BIN_DIR   命令安装目录，默认 ~/.local/bin
#   WB_REPO      仓库地址（测试/自建镜像用）

set -euo pipefail

REPO="${WB_REPO:-https://github.com/hacksmo/workbuddy-remote.git}"
REF="${WB_REF:-main}"
DEST="${WB_DIR:-$HOME/.local/share/workbuddy-remote}"
BIN_DIR="${WB_BIN_DIR:-$HOME/.local/bin}"

if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_OK=''; C_ERR=''; C_DIM=''; C_B=''; C_0=''
fi
info() { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s ✓%s %s\n' "$C_OK" "$C_0" "$*"; }
warn() { printf '%s !%s %s\n' "$C_ERR" "$C_0" "$*"; }
dim()  { printf '%s   %s%s\n' "$C_DIM" "$*" "$C_0"; }
die()  { warn "$*"; exit 1; }

# ── 参数 ────────────────────────────────────────────────────────────────
MODE=server
CLIENT_URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --client)
      MODE=client
      if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then CLIENT_URL="$2"; shift; fi
      shift ;;
    --client=*) MODE=client; CLIENT_URL="${1#--client=}"; shift ;;
    -h|--help)
      sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "未知参数: $1（--help 查看用法）" ;;
  esac
done

case "$(uname -s)" in
  Darwin) PLATFORM=macos ;;
  Linux)  PLATFORM=linux ;;
  *) die "仅支持 macOS / Linux，当前是 $(uname -s)" ;;
esac

# ══════════════════════════════════════════════════════════════════════
#  控制端：只是给你一个能点开的入口，不需要 node / git / 任何运行时
# ══════════════════════════════════════════════════════════════════════
if [ "$MODE" = client ]; then
  [ -n "$CLIENT_URL" ] || die "缺少被控端地址。用法：--client 'https://host/?token=xxx'"

  case "$CLIENT_URL" in
    http://*|https://*) ;;
    *) die "地址要以 http:// 或 https:// 开头" ;;
  esac

  mkdir -p "$BIN_DIR"

  # 找可用的 Chromium 系浏览器（app 模式需要它，能开出无地址栏的独立窗口）
  CHROME=""
  if [ "$PLATFORM" = macos ]; then
    for c in \
      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
      "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
      "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
      "/Applications/Chromium.app/Contents/MacOS/Chromium"; do
      [ -x "$c" ] && { CHROME="$c"; break; }
    done
  else
    for n in google-chrome google-chrome-stable microsoft-edge brave-browser chromium chromium-browser; do
      command -v "$n" >/dev/null 2>&1 && { CHROME="$(command -v "$n")"; break; }
    done
  fi
  [ -n "$CHROME" ] || warn "没找到 Chrome / Edge，将用系统默认浏览器打开（没有独立窗口）"

  PROFILE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/workbuddy-remote/client-profile"
  mkdir -p "$PROFILE_DIR"

  cat >"$BIN_DIR/workbuddy" <<EOF
#!/usr/bin/env bash
# WorkBuddy 控制端 —— 打开远程开发机
# 由 install.sh --client 生成，重新安装会覆盖
URL='${CLIENT_URL}'
PROFILE='${PROFILE_DIR}'
CHROME='${CHROME}'

if [ -n "\$CHROME" ] && [ -x "\$CHROME" ]; then
  exec "\$CHROME" --app="\$URL" --user-data-dir="\$PROFILE" \\
    --window-size=1440,900 --no-first-run --no-default-browser-check "\$@"
fi

case "\$(uname -s)" in
  Darwin) exec open "\$URL" ;;
  *)      exec xdg-open "\$URL" 2>/dev/null || echo "请手动打开：\$URL" ;;
esac
EOF
  chmod +x "$BIN_DIR/workbuddy"
  ok "命令已安装：$BIN_DIR/workbuddy"

  # macOS 额外做一个 .app，能从应用程序/程序坞直接点
  if [ "$PLATFORM" = macos ]; then
    APP="$HOME/Applications/WorkBuddy Remote.app"
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>WorkBuddy Remote</string>
    <key>CFBundleDisplayName</key><string>WorkBuddy Remote</string>
    <key>CFBundleIdentifier</key><string>com.workbuddy.remote.client</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>launch</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
</dict>
</plist>
PLIST
    cat >"$APP/Contents/MacOS/launch" <<EOF
#!/bin/bash
exec "${BIN_DIR}/workbuddy"
EOF
    chmod +x "$APP/Contents/MacOS/launch"
    ok "应用已创建：$APP"
    dim "在「访达 → 应用程序」里能找到，可拖到程序坞"
  fi

  echo
  printf '%s控制端安装完成%s\n\n' "$C_B$C_OK" "$C_0"
  printf '  打开：%sworkbuddy%s\n' "$C_B" "$C_0"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR 不在 PATH 中："
       printf '  export PATH="%s:$PATH"\n' "$BIN_DIR" ;;
  esac
  echo
  dim "目标：$CLIENT_URL"
  dim "控制端不执行任何本机操作，只是打开一个浏览器窗口。"
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════
#  被控端：装桥，把本机 WorkBuddy 变成可远程访问的服务
# ══════════════════════════════════════════════════════════════════════
if ! command -v node >/dev/null 2>&1; then
  warn "未找到 node（需要 Node.js 18+）"
  case "$PLATFORM" in
    macos) dim "  brew install node" ;;
    linux) dim "  sudo apt install nodejs   或   https://nodejs.org" ;;
  esac
  printf '  装好后再跑一次本脚本。\n'
  exit 1
fi
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[ "$NODE_MAJOR" -ge 18 ] || die "Node.js 版本过低（$(node -v)），需要 18+"
ok "node $(node -v)"

command -v git >/dev/null 2>&1 || die "未找到 git，请先安装"

if [ -d "$DEST/.git" ]; then
  info "更新已有安装：$DEST"
  git -C "$DEST" fetch --depth 1 origin "$REF" >/dev/null 2>&1 || true
  git -C "$DEST" checkout -q "$REF" 2>/dev/null || true
  git -C "$DEST" reset --hard "origin/$REF" >/dev/null 2>&1 || true
  ok "已更新到 origin/$REF"
else
  info "安装到 $DEST"
  mkdir -p "$(dirname "$DEST")"
  rm -rf "$DEST.tmp"
  if git clone --depth 1 --branch "$REF" "$REPO" "$DEST.tmp" >/dev/null 2>&1; then
    rm -rf "$DEST"
    mv "$DEST.tmp" "$DEST"
    ok "克隆完成"
  else
    rm -rf "$DEST.tmp"
    die "克隆失败。检查网络，或确认仓库地址：$REPO"
  fi
fi

chmod +x "$DEST/scripts/"*.sh 2>/dev/null || true

mkdir -p "$BIN_DIR"
cat >"$BIN_DIR/workbuddy-remote" <<EOF
#!/usr/bin/env bash
exec "$DEST/scripts/start.sh" "\$@"
EOF
chmod +x "$BIN_DIR/workbuddy-remote"
ok "命令已安装：$BIN_DIR/workbuddy-remote"

STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/workbuddy-remote"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true
if [ ! -s "$STATE_DIR/token" ]; then
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16 >"$STATE_DIR/token"
  else
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-32 >"$STATE_DIR/token"
  fi
  chmod 600 "$STATE_DIR/token"
  ok "已生成访问令牌"
fi

echo
printf '%s被控端安装完成%s\n\n' "$C_B$C_OK" "$C_0"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR 不在 PATH 中："
     printf '  export PATH="%s:$PATH"\n\n' "$BIN_DIR" ;;
esac
printf '  启动：%sworkbuddy-remote%s\n' "$C_B" "$C_0"
printf '  状态：%sworkbuddy-remote --status%s\n' "$C_B" "$C_0"
printf '  停止：%sworkbuddy-remote --stop%s\n\n' "$C_B" "$C_0"
printf '  令牌：%s%s/token%s\n\n' "$C_DIM" "$STATE_DIR" "$C_0"
printf '%s注意：启动会重启 WorkBuddy 以开启调试端口，正在跑的任务会中断。%s\n\n' "$C_DIM" "$C_0"
printf '想从别的电脑远程连进来？\n'
printf '  1. 在%s这台%s机器上启动：%sworkbuddy-remote%s\n' "$C_B" "$C_0" "$C_B" "$C_0"
printf '  2. 在%s另一台%s电脑上装控制端：\n' "$C_B" "$C_0"
printf '     %scurl .../install.sh | bash -s -- --client "<上面打印的地址>"%s\n' "$C_DIM" "$C_0"