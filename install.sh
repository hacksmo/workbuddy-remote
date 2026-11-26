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

  # 从公网地址里拆出 token —— 局域网直连时要用同一个 token
  CLIENT_TOKEN="$(printf '%s' "$CLIENT_URL" | sed -n 's/.*[?&]token=\([^&]*\).*/\1/p')"

  # 顺带问被控端要一份「局域网直连候选地址」。装的时候公网路是通的，
  # 此刻拿到的地址质量最好。拿不到不影响安装，运行时还会再探一次。
  CLIENT_LAN_CANDIDATES=""
  if [ -n "$CLIENT_TOKEN" ]; then
    # https://host/?token=x  →  https://host/info?token=x
    _base="${CLIENT_URL%%\?*}"
    _base="${_base%/}"
    _info="$(curl -fsSL --max-time 6 "${_base}/info?token=${CLIENT_TOKEN}" 2>/dev/null || true)"
    if [ -n "$_info" ]; then
      CLIENT_LAN_CANDIDATES="$(printf '%s' "$_info" \
        | grep -o '"url":"http://[0-9.]*:[0-9]*"' \
        | sed 's/.*"url":"//;s/"$//' || true)"
      [ -n "$CLIENT_LAN_CANDIDATES" ] && dim "已知局域网地址：$(printf '%s' "$CLIENT_LAN_CANDIDATES" | tr '\n' ' ')"
    fi
    unset _base _info
  fi

  mkdir -p "$BIN_DIR"

  # 图标：优先从仓库下载高清版，失败则用脚本内嵌的 128px 兜底版
  # 这样脚本本身不臃肿（兜底版约 6KB），同时正常联网时能拿到高清图标
  ICON_FALLBACK_B64='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'

  APP_NAME="WorkBuddy"
  case "$PLATFORM" in
    macos) ICON_DIR="$HOME/.local/share/workbuddy-remote" ;;
    linux) ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/512x512/apps" ;;
  esac
  mkdir -p "$ICON_DIR"
  ICON_PNG="$ICON_DIR/workbuddy-remote.png"

  # 高清图标走多个镜像。国内 Linux 实测 jsDelivr 与 raw.githubusercontent
  # 都可能被重置（curl 35），只有 ghproxy 类镜像通，所以把它们也加进来。
  # raw 的 SHA 地址是为了绕开 CDN 缓存延迟（新推的文件 @main 会 404 一阵）。
  # macOS 要 1024（.icns 里 512@2x 就是从它来的，不能放大凑），Linux 512 够。
  if [ "$PLATFORM" = macos ]; then ICON_ASSET=icon-1024.png; else ICON_ASSET=icon-512.png; fi
  RAW="https://raw.githubusercontent.com/hacksmo/workbuddy-remote"
  ICON_URLS="${WB_ICON_URL:-}
https://cdn.jsdelivr.net/gh/hacksmo/workbuddy-remote@main/assets/${ICON_ASSET}
https://ghproxy.net/${RAW}/main/assets/${ICON_ASSET}
https://gh-proxy.com/${RAW}/main/assets/${ICON_ASSET}
${RAW}/8511958/assets/${ICON_ASSET}
${RAW}/main/assets/${ICON_ASSET}
https://ghfast.top/${RAW}/main/assets/${ICON_ASSET}"

  icon_ok() { [ -f "$1" ] && [ "$(wc -c <"$1" | tr -d ' ')" -gt 20000 ]; }

  if icon_ok "$ICON_PNG"; then
    dim "图标已存在，跳过"
  else
    icon_fetched=0
    for u in $ICON_URLS; do
      [ -n "$u" ] || continue
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 8 "$u" -o "$ICON_PNG.tmp" 2>/dev/null && \
          icon_ok "$ICON_PNG.tmp" && mv -f "$ICON_PNG.tmp" "$ICON_PNG" && icon_fetched=1 && break
      elif command -v wget >/dev/null 2>&1; then
        wget -q -T 12 -O "$ICON_PNG.tmp" "$u" 2>/dev/null && \
          icon_ok "$ICON_PNG.tmp" && mv -f "$ICON_PNG.tmp" "$ICON_PNG" && icon_fetched=1 && break
      else
        break
      fi
    done
    rm -f "$ICON_PNG.tmp" 2>/dev/null || true
    if [ "$icon_fetched" = 0 ]; then
      printf '%s' "$ICON_FALLBACK_B64" | base64 -d >"$ICON_PNG" 2>/dev/null \
        || printf '%s' "$ICON_FALLBACK_B64" | base64 --decode >"$ICON_PNG"
      dim "高清图标下载失败，已用内置版本（外观略有差异，不影响使用）"
    fi
  fi

  # 找 Chromium 系浏览器 —— 只有它能开出「无地址栏」的独立窗口
  CHROME=""
  if [ "$PLATFORM" = macos ]; then
    for c in \
      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
      "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
      "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
      "/Applications/Chromium.app/Contents/MacOS/Chromium" \
      "/Applications/Arc.app/Contents/MacOS/Arc"; do
      [ -x "$c" ] && { CHROME="$c"; break; }
    done
  else
    for n in google-chrome google-chrome-stable microsoft-edge brave-browser chromium chromium-browser; do
      command -v "$n" >/dev/null 2>&1 && { CHROME="$(command -v "$n")"; break; }
    done
  fi
  if [ -z "$CHROME" ]; then
    warn "没找到 Chrome / Edge / Brave 等 Chromium 系浏览器"
    dim "会用系统默认浏览器打开（有地址栏，不是独立窗口）"
    dim "想要独立窗口请先装 Chrome：https://www.google.com/chrome/"
  fi

  PROFILE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/workbuddy-remote/client-profile"
  mkdir -p "$PROFILE_DIR"
  ENDPOINT_CACHE="${XDG_CONFIG_HOME:-$HOME/.config}/workbuddy-remote/lan-endpoint"

  # 统一的启动逻辑，写进 bin/ 里的命令，.app 和 .desktop 都调它。
  #
  # 用单引号 heredoc（内容原样保留）再替换 @@占位符，而不是双引号 heredoc：
  # 双引号里每个 $ 都要转义，嵌套引号一多极易写错，之前就在这上面栽过。
  cat >"$BIN_DIR/workbuddy" <<'LAUNCHER'
#!/usr/bin/env bash
# WorkBuddy 控制端启动器 —— 打开远程开发机
# 由 install.sh --client 生成，重装会覆盖
#
# 同网段时优先走局域网直连：延迟低一个数量级，且流量不出内网。
# 探测失败静默回退公网，不打扰使用者（局域网 IP 会随 DHCP 变化，失败是常态）。

PUB='@@URL@@'
TOKEN='@@TOKEN@@'
PORT='@@PORT@@'
PROFILE='@@PROFILE@@'
CHROME='@@CHROME@@'
CACHE='@@CACHE@@'
# 安装时从被控端问到过的局域网地址，空格分隔
CANDIDATES='@@CANDIDATES@@'

FORCE=auto
EXTRA=()
for a in "$@"; do
  case "$a" in
    --public) FORCE=public ;;
    --lan)    FORCE=lan ;;
    -h|--help)
      printf '用法: %s [--public | --lan]\n\n' "$(basename "$0")"
      printf '  默认   同网段优先直连，探测不到就回退公网\n'
      printf '  --public  强制走公网（排查直连问题时用）\n'
      printf '  --lan     只走局域网，不做回退\n'
      exit 0 ;;
    *) EXTRA+=("$a") ;;
  esac
done

# 一轮健康检查只给 0.4 秒：局域网内正常 5~30ms 返回，
# 超时基本就是不在同一网段，多等纯属浪费启动时间。
healthy() { curl -fsS -m 0.4 "http://$1:$PORT/health" >/dev/null 2>&1; }

host_of() { printf '%s' "$1" | sed 's|^http://||; s|:[0-9]*$||; s|/.*$||'; }

# 只有「一个候选都没有」时才问被控端的公网入口，因为这个请求要绕一圈公网，
# 慢且可能不通。日常换 WiFi / DHCP 换 IP 靠候选里的 .local 名字就能兜住。
refresh_candidates() {
  local base json
  base="${PUB%%\?*}"
  base="${base%/}"
  json="$(curl -fsS -m 3 "${base}/info" 2>/dev/null)" || return 0
  printf '%s' "$json" | grep -o '"url":"http://[0-9.]*:[0-9]*"' | sed 's/.*"url":"//; s/"$//'
  printf '%s' "$json" | grep -o '"mdns":"[^"]*"' | sed 's/.*"mdns":"//; s/"$//' | sed "s|.*|http://&:\$PORT|"
}

pick_lan() {
  local u h tries=0 list=""
  # 缓存里的地址排最前（上次成功的，命中率最高），其次是安装时问到的
  list="$(cat "$CACHE" 2>/dev/null) $CANDIDATES"

  for u in $list; do
    [ -n "$u" ] || continue
    h="$(host_of "$u")"
    [ -n "$h" ] || continue
    tries=$((tries + 1))
    [ "$tries" -gt 4 ] && break
    if healthy "$h"; then printf '%s' "$h"; return 0; fi
  done

  # 候选全空（首次运行且安装时也没问到）→ 才去问公网入口
  if [ -z "$(printf '%s' "$list" | tr -d ' ')" ]; then
    for u in $(refresh_candidates); do
      h="$(host_of "$u")"
      [ -n "$h" ] || continue
      if healthy "$h"; then printf '%s' "$h"; return 0; fi
    done
  fi
  return 1
}

HOST=""
NET=public
case "$FORCE" in
  public) ;;
  lan)
    HOST="$(pick_lan)" || { printf '局域网内没找到可用的 WorkBuddy 服务\n' >&2; exit 1; } ;;
  *)
    HOST="$(pick_lan)" || HOST="" ;;
esac

if [ -n "$HOST" ]; then
  URL="http://${HOST}:${PORT}/?token=${TOKEN}&net=lan"
  NET=lan
  mkdir -p "$(dirname "$CACHE")" 2>/dev/null || true
  printf 'http://%s:%s\n' "$HOST" "$PORT" >"$CACHE" 2>/dev/null || true
else
  URL="${PUB}&net=public"
  NET=public
fi

# 从终端手动跑时给出提示，双击 .app 启动时 stdout 不可见，这里就不打扰
if [ -t 1 ]; then
  [ "$NET" = lan ] && printf '  局域网直连 %s:%s\n' "$HOST" "$PORT" || printf '  经公网访问\n'
fi

if [ -n "$CHROME" ] && [ -x "$CHROME" ]; then
  # 关键：Chrome 的 --app 不接受「唤起已有窗口」——
  # 已经有实例在跑时，它会把这行命令交给那个实例去「新开一个窗口」，
  # 于是每点一次图标就多一个窗口，永远堆着不消失。
  #
  # 所以先问一下有没有已经开着的 WorkBuddy 窗口：
  #   有 → 激活它（相当于 app 的「回到窗口」）
  #   没有 → 才用 --app 新建
  # 这样点图标的行为就跟普通应用程序一致了。

  # 用 SingletonLock 判断这个 profile 的 Chrome 是否还在跑。
  # 锁文件是个符号链接，格式 <hostname>-<pid>，拿末尾的 pid 验活。
  profile_running() {
    local lock lu pid
    lock="$PROFILE/SingletonLock"
    [ -L "$lock" ] || [ -e "$lock" ] || return 1
    lu="$(readlink "$lock" 2>/dev/null)" || return 1
    pid="${lu##*-}"
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$pid" 2>/dev/null
  }

  # 已有窗口 → 激活并退出。AppleScript 只认 Chrome 自己可见的窗口，
  # 用 8797 / 域名匹配，避免误碰用户日常浏览的窗口。
  focus_existing() {
    [ "$(uname -s)" = Darwin ] || return 1
    profile_running || return 1
    osascript >/dev/null 2>&1 <<'APPLESCRIPT'
tell application "Google Chrome"
  set hit to missing value
  repeat with w in windows
    set u to ""
    try
      set u to (URL of active tab of w) as string
    end try
    if u contains ":8797" or u contains "wb.hackmo.net" then
      set hit to w
      exit repeat
    end if
  end repeat
  if hit is missing value then error "no-window"
  set index of hit to 1
  try
    set miniaturized of hit to false
  end try
  activate
end tell
APPLESCRIPT
  }

  focus_existing && exit 0

  # 没有现成窗口 → 新建。--app 开无地址栏窗口；独立 user-data-dir
  # 保证记住登录态且不污染日常浏览器
  exec "$CHROME" --app="$URL" --user-data-dir="$PROFILE" \
    --window-size=1440,900 --no-first-run --no-default-browser-check \
    --disable-features=Translate --class=WorkBuddyRemote ${EXTRA[@]+"${EXTRA[@]}"}
fi

# 没有 Chromium 系浏览器时退化为系统默认浏览器
case "$(uname -s)" in
  Darwin) exec open "$URL" ;;
  *)      exec xdg-open "$URL" 2>/dev/null || echo "请手动打开：$URL" ;;
esac
LAUNCHER

  # 占位符替换。用 | 作分隔符，路径里不会有它。
  CORP_PORT="$(printf '%s' "$CLIENT_URL" | sed -n 's|.*://[^:/]*:\([0-9]*\).*|\1|p')"
  [ -n "$CORP_PORT" ] || CORP_PORT=8797
  _tmp="$(mktemp)"
  sed \
    -e "s|@@URL@@|${CLIENT_URL}|g" \
    -e "s|@@TOKEN@@|${CLIENT_TOKEN}|g" \
    -e "s|@@PORT@@|${CORP_PORT}|g" \
    -e "s|@@PROFILE@@|${PROFILE_DIR}|g" \
    -e "s|@@CHROME@@|${CHROME}|g" \
    -e "s|@@CACHE@@|${ENDPOINT_CACHE}|g" \
    -e "s|@@CANDIDATES@@|$(printf '%s' "$CLIENT_LAN_CANDIDATES" | tr '\n' ' ')|g" \
    "$BIN_DIR/workbuddy" >"$_tmp" && mv -f "$_tmp" "$BIN_DIR/workbuddy"
  unset _tmp
  chmod +x "$BIN_DIR/workbuddy"

  # ── macOS：安装原生壳 ───────────────────────────────────────────────
  #
  # 这里和 Linux 走完全不同的路线，原因不是「顺手」：
  #
  #   bash 脚本不能作为 CFBundleExecutable 出现在 Dock 里 ——
  #   Dock 图标归属「进程」，而脚本进程不连 WindowServer。
  #   早期版本 exec 成 Chrome 后进程身份变成了 Google Chrome，
  #   Dock 里始终只有 Chrome 没有 WorkBuddy Remote。
  #
  #   并且 Chrome 的 --app 没有单实例语义：已有实例时它会新开一个
  #   窗口，于是点一次图标多一个窗口，永远堆着不消失。
  #
  # 所以 macOS 装的是一个真正的原生壳（AppKit + WKWebView，
  # 约 300KB 的通用二进制）。单实例、Dock 图标、Cmd+Tab 全由
  # AppKit 提供，行为跟普通 Mac 应用完全一致。
  #
  # 壳的源码在 macos/shell.swift，由 macos/build-dmg.sh 编译。
  if [ "$PLATFORM" = macos ]; then
    APP="$HOME/Applications/${APP_NAME} Remote.app"
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

    # 取预编译好的通用二进制。优先 GitHub Release 附件（体积小、无速率限制），
    # 其次 raw 的 main 分支最新产物。
    SHELL_URLS="${WB_SHELL_URL:-}
https://github.com/hacksmo/workbuddy-remote/releases/latest/download/WorkBuddyRemote
https://cdn.jsdelivr.net/gh/hacksmo/workbuddy-remote@main/macos/bin/WorkBuddyRemote
${RAW}/main/macos/bin/WorkBuddyRemote
https://ghproxy.net/${RAW}/main/macos/bin/WorkBuddyRemote"

    SHELL_BIN="$APP/Contents/MacOS/WorkBuddyRemote"
    got=0
    for u in $SHELL_URLS; do
      [ -n "$u" ] || continue
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 25 "$u" -o "$SHELL_BIN" 2>/dev/null || continue
      else
        wget -q -T 25 -O "$SHELL_BIN" "$u" 2>/dev/null || continue
      fi
      # 校验：必须是 Mach-O 可执行文件，大小 > 50KB
      sz="$(wc -c <"$SHELL_BIN" 2>/dev/null | tr -d ' ')"
      if [ -n "$sz" ] && [ "$sz" -gt 50000 ] && file "$SHELL_BIN" 2>/dev/null | grep -q "Mach-O"; then
        got=1
        break
      fi
    done

    if [ "$got" = 0 ]; then
      rm -rf "$APP"
      die "原生壳下载失败。请检查网络，或直接下载 DMG：https://github.com/hacksmo/workbuddy-remote/releases/latest"
    fi
    chmod +x "$SHELL_BIN"

    # 图标
    if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
      ICONSET="$(mktemp -d)/icon.iconset"
      mkdir -p "$ICONSET"
      for s in 16 32 128 256 512; do
        sips -z $s $s "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null 2>&1
        d=$((s * 2))
        sips -z $d $d "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null 2>&1
      done
      iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/app.icns" 2>/dev/null || true
      rm -rf "$(dirname "$ICONSET")"
    fi

    cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME} Remote</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME} Remote</string>
    <key>CFBundleIdentifier</key><string>com.workbuddy.remote.client</string>
    <key>CFBundleVersion</key><string>1.3</string>
    <key>CFBundleShortVersionString</key><string>1.3</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>WorkBuddyRemote</string>
    <key>CFBundleIconFile</key><string>app</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

    # ad-hoc 签名。不签的话 Gatekeeper 会直接拒绝启动，
    # 用户得右键「打开」绕过 —— 多一步就多一批人放弃。
    codesign --force --sign - "$APP" 2>/dev/null || true

    # 写入服务器配置，省掉用户第一次打开还要手填
    CFG_DIR="$HOME/Library/Application Support/WorkBuddy Remote"
    mkdir -p "$CFG_DIR"
    LAN_JSON="[]"
    if [ -n "$CLIENT_LAN_CANDIDATES" ]; then
      _lan="$(printf '%s\n' "$CLIENT_LAN_CANDIDATES" | grep -v '^$' \
        | sed 's|.*|"&"|' | paste -sd, -)"
      [ -n "$_lan" ] && LAN_JSON="[$_lan]"
    fi
    cat >"$CFG_DIR/config.json" <<CFG
{"url":"${CLIENT_URL}","token":"${CLIENT_TOKEN}","lanCandidates":${LAN_JSON}}
CFG
    chmod 600 "$CFG_DIR/config.json"

    xattr -cr "$APP" 2>/dev/null || true
    touch "$APP"
    ok "应用已创建：$APP"

    # 加进程序坞
    if command -v defaults >/dev/null 2>&1; then
      if defaults read com.apple.dock persistent-apps 2>/dev/null | grep -qF "${APP}"; then
        dim "程序坞里已有图标，跳过"
      else
        defaults write com.apple.dock persistent-apps -array-add \
          "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>${APP}</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>" \
          2>/dev/null && killall Dock 2>/dev/null && ok "已添加到程序坞" || true
      fi
    fi
  fi

  # ── Linux：生成 .desktop，进应用菜单 ────────────────────────────────
  if [ "$PLATFORM" = linux ]; then
    DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    mkdir -p "$DESKTOP_DIR"
    DESKTOP_FILE="$DESKTOP_DIR/workbuddy-remote.desktop"

    # .desktop 规范：Exec 里路径含空格时用双引号包住整体，
    # 且 %U 必须放在引号外。BIN_DIR 一般没空格，这里按规范处理两种情况。
    case "$BIN_DIR" in
      *" "*) DESKTOP_EXEC="\"${BIN_DIR}/workbuddy\"" ;;
      *)     DESKTOP_EXEC="${BIN_DIR}/workbuddy" ;;
    esac
    cat >"$DESKTOP_FILE" <<DESK
[Desktop Entry]
Type=Application
Version=1.0
Name=${APP_NAME} Remote
Name[zh_CN]=${APP_NAME} 远程
Comment=打开远程开发机上的 ${APP_NAME}
Comment[zh_CN]=打开远程开发机上的 ${APP_NAME}
Exec=$DESKTOP_EXEC %U
Icon=${ICON_PNG}
Terminal=false
Categories=Development;Network;Utility;
Keywords=workbuddy;remote;
StartupWMClass=WorkBuddyRemote
StartupNotify=true
DESK
    chmod +x "$DESKTOP_FILE"
    ok "应用菜单项已创建"

    # 刷新桌面数据库与图标缓存
    command -v update-desktop-database >/dev/null 2>&1 \
      && update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    command -v gtk-update-icon-cache >/dev/null 2>&1 \
      && gtk-update-icon-cache -f -t "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor" 2>/dev/null || true

    # GNOME 需要标记为可信，否则桌面上的图标点了没反应
    if command -v gio >/dev/null 2>&1; then
      gio set "$DESKTOP_FILE" metadata::trusted true 2>/dev/null || true
    fi
  fi

  echo
  printf '%s控制端安装完成%s\n\n' "$C_B$C_OK" "$C_0"
  case "$PLATFORM" in
    macos) printf '  %s打开方式%s\n' "$C_B" "$C_0"
           printf '    · 程序坞里的 %s Remote 图标\n' "$APP_NAME"
           printf '    · 启动台 / 聚焦搜索「%s Remote」\n' "$APP_NAME"
           printf '    · 终端 %sworkbuddy%s\n' "$C_B" "$C_0" ;;
    linux) printf '  %s打开方式%s\n' "$C_B" "$C_0"
           printf '    · 应用菜单里找「%s Remote」\n' "$APP_NAME"
           printf '    · 终端 %sworkbuddy%s\n' "$C_B" "$C_0" ;;
  esac
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo
       warn "$BIN_DIR 不在 PATH 中（只影响终端命令，图标不受影响）："
       printf '  export PATH="%s:$PATH"\n' "$BIN_DIR" ;;
  esac
  echo
  dim "目标：$CLIENT_URL"
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