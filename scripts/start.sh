#!/usr/bin/env bash
# WorkBuddy Remote —— 跨平台启动器（macOS / Linux）
#
# 职责：
#   1. 定位 WorkBuddy 桌面端（不同平台安装路径不同）
#   2. 以 --remote-debugging-port 重启它，开出一个 CDP 端口
#   3. 起 CDP 桥（bridge/cdp.mjs），把渲染进程能力暴露成 HTTP
#
# 用法：
#   ./scripts/start.sh              启动（会自动重启 WorkBuddy）
#   ./scripts/start.sh --no-restart 不重启 WorkBuddy，只起桥（它已在调试模式时用）
#   ./scripts/start.sh --stop       停止桥
#   ./scripts/start.sh --status     查看状态
#
# 环境变量：
#   WB_CDP_PORT     CDP 端口，默认 9333
#   WB_PORT         桥端口，默认 8797
#   WB_HOST         桥监听地址，默认 auto（回环 + 所有局域网 IP）
#                   也可显式写 127.0.0.1,192.168.1.5（要公网/隧道访问见 deploy/）
#   WB_LAN          设 0 关掉局域网监听，只留回环
#   WB_TOKEN        访问令牌，不设则自动生成并保存到 ~/.config/workbuddy-remote/token
#   WB_APP          手工指定 WorkBuddy 可执行文件路径

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/workbuddy-remote"
TOKEN_FILE="$STATE_DIR/token"
LOG_DIR="$STATE_DIR/logs"
PID_FILE="$STATE_DIR/bridge.pid"
BRIDGE_LOG="$LOG_DIR/bridge.log"
ENDPOINT_FILE="$STATE_DIR/endpoints"

CDP_PORT="${WB_CDP_PORT:-9333}"
WB_PORT="${WB_PORT:-8797}"
WB_HOST="${WB_HOST:-auto}"
# WB_LAN=0 可关掉局域网监听（只留回环），海康/公司网段不想暴露时用
WB_LAN="${WB_LAN:-1}"

mkdir -p "$STATE_DIR" "$LOG_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

# ── 输出 ────────────────────────────────────────────────────────────────
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

# ── 平台探测 ────────────────────────────────────────────────────────────
OS="$(uname -s)"
case "$OS" in
  Darwin) PLATFORM=macos ;;
  Linux)  PLATFORM=linux ;;
  *) die "不支持的平台: $OS（仅支持 macOS / Linux）" ;;
esac

# 找 WorkBuddy 可执行文件。返回 0 表示找到，路径写入全局 APP_BIN。
#
# macOS：一定是 .app bundle，必须经 `open -a` 启动（直接跑 bundle 内二进制会因
#        Mach port rendezvous 找不到父进程而自杀），所以这里只用来校验存在。
# Linux：Electron 应用常见三种形态 —— AppImage / 解包目录 / 系统级安装。
#        解包目录需要直接执行二进制，且 root 下要加 --no-sandbox。
APP_BIN=""
APP_KIND=""   # macos-bundle | linux-bin

detect_app() {
  if [ -n "${WB_APP:-}" ]; then
    [ -x "${WB_APP}" ] || [ -f "${WB_APP}" ] || die "WB_APP 指定的路径不存在: ${WB_APP}"
    APP_BIN="${WB_APP}"
    APP_KIND=$([ "$PLATFORM" = macos ] && echo macos-bundle || echo linux-bin)
    return 0
  fi

  if [ "$PLATFORM" = macos ]; then
    local cands=(
      "/Applications/WorkBuddy.app/Contents/MacOS/Electron"
      "$HOME/Applications/WorkBuddy.app/Contents/MacOS/Electron"
    )
    for c in "${cands[@]}"; do
      if [ -x "$c" ]; then APP_BIN="$c"; APP_KIND=macos-bundle; return 0; fi
    done
    return 1
  fi

  # Linux：先看 PATH 里的名字，再看常见安装目录
  local name
  for name in workbuddy WorkBuddy workbuddy-desktop; do
    if command -v "$name" >/dev/null 2>&1; then
      APP_BIN="$(command -v "$name")"; APP_KIND=linux-bin; return 0
    fi
  done

  local cands=(
    /opt/WorkBuddy/workbuddy
    /opt/workbuddy/workbuddy
    /opt/WorkBuddy.AppImage
    "$HOME/Applications/WorkBuddy.AppImage"
    "$HOME/.local/share/applications/workbuddy.AppImage"
    /usr/lib/workbuddy/workbuddy
    /snap/bin/workbuddy
  )
  for c in "${cands[@]}"; do
    if [ -x "$c" ]; then APP_BIN="$c"; APP_KIND=linux-bin; return 0; fi
  done

  # 兜底：在常见目录里搜一次（限深度，避免扫全盘）
  local found
  found="$(find /opt "$HOME/Applications" "$HOME/.local" -maxdepth 4 \
             -iname 'workbuddy*' -type f -perm -u+x 2>/dev/null | head -1)"
  if [ -n "$found" ]; then APP_BIN="$found"; APP_KIND=linux-bin; return 0; fi

  return 1
}

# ── 局域网地址探测 ──────────────────────────────────────────────────────
# 只认 RFC1918 私网段：192.168/16、10/8、172.16~172.31。
# 排除 100.x（Tailscale）与 198.18/15（Shadowrocket 等 TUN 假地址），
# 它们都在私网段之外或属于虚拟网卡，监听上去毫无意义。
detect_lan_ips() {
  command -v node >/dev/null 2>&1 || return 0
  node -e '
    const os = require("os");
    const ok = /^(192\.168\.|10\.|172\.(1[6-9]|2\d|3[01])\.)/;
    const out = [];
    for (const list of Object.values(os.networkInterfaces())) {
      for (const n of list || []) {
        if (n.family !== "IPv4" || n.internal) continue;
        if (ok.test(n.address)) out.push(n.address);
      }
    }
    process.stdout.write([...new Set(out)].join(" "));
  ' 2>/dev/null
}

# WB_HOST 的三种取值：
#   缺省 auto  → 127.0.0.1 加上所有探测到的局域网 IP（同网段内直连，不绕公网）
#   显式列表   → 原样使用（WB_HOST=127.0.0.1,192.168.0.52）
#   WB_LAN=0   → 强制只监听回环，回到「只能经公网隧道访问」
resolve_hosts() {
  [ "$WB_HOST" = "auto" ] || return 0

  if [ "$WB_LAN" = "0" ]; then
    WB_HOST="127.0.0.1"
    LAN_IPS=""
    return 0
  fi

  LAN_IPS="$(detect_lan_ips)"
  WB_HOST="127.0.0.1"
  for ip in $LAN_IPS; do WB_HOST="$WB_HOST,$ip"; done
}

# 把本次可用端点落盘，供控制端/其它脚本读取，也方便用户排查
write_endpoints() {
  local token; token="$(load_token)"
  {
    printf '# WorkBuddy Remote endpoints —— 由 start.sh 自动生成，不要手改\n'
    printf 'updated=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')"
    printf 'hostname=%s\n' "$(hostname 2>/dev/null || echo unknown)"
    printf 'port=%s\n' "$WB_PORT"
    printf 'token=%s\n' "$token"
    # .local 名字给同网段的 Mac 用（Bonjour 自动解析），IP 变了也不怕
    if [ "$PLATFORM" = macos ]; then
      local lh; lh="$(scutil --get LocalHostName 2>/dev/null || true)"
      [ -n "$lh" ] && printf 'mdns=%s.local\n' "$lh"
    fi
    for ip in ${LAN_IPS:-}; do
      printf 'lan=http://%s:%s\n' "$ip" "$WB_PORT"
    done
  } >"$ENDPOINT_FILE" 2>/dev/null || true
  chmod 600 "$ENDPOINT_FILE" 2>/dev/null || true
}

# ── 令牌 ────────────────────────────────────────────────────────────────
load_token() {
  if [ -n "${WB_TOKEN:-}" ]; then printf '%s' "$WB_TOKEN"; return; fi
  if [ -s "$TOKEN_FILE" ]; then cat "$TOKEN_FILE"; return; fi
  local t
  if command -v openssl >/dev/null 2>&1; then
    t="$(openssl rand -hex 16)"
  else
    t="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-32)"
  fi
  printf '%s' "$t" >"$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  printf '%s' "$t"
}

# ── 依赖检查 ────────────────────────────────────────────────────────────
need_node() {
  command -v node >/dev/null 2>&1 || die "未找到 node，请先安装 Node.js 18+：https://nodejs.org"
  local major
  major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  [ "$major" -ge 18 ] || die "Node.js 版本过低（当前 $(node -v)），需要 18 及以上"
}

# ── CDP 就绪探测 ────────────────────────────────────────────────────────
cdp_ready() {
  curl -s -m 1 "http://127.0.0.1:${CDP_PORT}/json/version" >/dev/null 2>&1
}

# 已有的 WorkBuddy 是否带调试端口。已带就跳过重启，避免打断用户正在跑的任务。
already_debugging() {
  cdp_ready && return 0
  return 1
}

# ── 启动 WorkBuddy（带调试端口）─────────────────────────────────────────
start_app() {
  info "重启 WorkBuddy 以开启调试端口 :${CDP_PORT}"
  dim "当前正在执行的任务会中断"

  if [ "$PLATFORM" = macos ]; then
    osascript -e 'quit app "WorkBuddy"' >/dev/null 2>&1 || true
    sleep 3
    pkill -f "WorkBuddy.app/Contents/MacOS/Electron" >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
      pgrep -f "^/Applications/WorkBuddy.app/Contents/MacOS/Electron$" >/dev/null 2>&1 || break
      sleep 1
    done
    # 必须用 open：直接执行 bundle 内二进制会自杀
    open -a "$(dirname "$(dirname "$(dirname "$APP_BIN")")")" \
         --args --remote-debugging-port="${CDP_PORT}" 2>"$LOG_DIR/app.log" || true
  else
    pkill -f "$(basename "$APP_BIN")" >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
      pgrep -f "$(basename "$APP_BIN")" >/dev/null 2>&1 || break
      sleep 1
    done
    local sandbox_flag=""
    # root 下 Chromium 沙箱不可用，必须显式关闭
    [ "$(id -u)" = "0" ] && sandbox_flag="--no-sandbox"
    nohup "$APP_BIN" --remote-debugging-port="${CDP_PORT}" $sandbox_flag \
      >"$LOG_DIR/app.log" 2>&1 &
  fi

  info "等待 CDP 就绪（最多 45 秒）"
  for _ in $(seq 1 45); do
    if cdp_ready; then ok "CDP 已就绪"; return 0; fi
    sleep 1
  done
  warn "CDP 未就绪，最近日志："
  tail -15 "$LOG_DIR/app.log" 2>/dev/null || true
  return 1
}

# ── 桥进程管理 ──────────────────────────────────────────────────────────
bridge_alive() {
  [ -f "$PID_FILE" ] || return 1
  local pid; pid="$(cat "$PID_FILE" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

stop_bridge() {
  if bridge_alive; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    for _ in $(seq 1 10); do bridge_alive || break; sleep 0.3; done
    bridge_alive && kill -9 "$(cat "$PID_FILE")" 2>/dev/null || true
    ok "桥已停止"
  else
    dim "桥未在运行"
  fi
  rm -f "$PID_FILE"
}

start_bridge() {
  local token; token="$(load_token)"

  # 端口占用检查：只认我们自己的 pidfile，别人的占用直接报错
  if command -v lsof >/dev/null 2>&1; then
    if lsof -nP -iTCP:"$WB_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
      if bridge_alive; then
        ok "桥已在运行（pid $(cat "$PID_FILE")）"
        return 0
      fi
      die "端口 ${WB_PORT} 已被其他进程占用，换个端口：WB_PORT=8800 $0"
    fi
  fi

  info "启动 CDP 桥 → ${WB_HOST}:${WB_PORT}"
  : >"$BRIDGE_LOG"

  if [ "${FOREGROUND:-0}" = "1" ]; then
    # 前台模式：给 systemd / launchd 用。进程不 detach，退出即服务结束，
    # 上层（Restart=on-failure / KeepAlive）才能正确判断存活。
    exec node "$ROOT/bridge/cdp.mjs" \
      --host "$WB_HOST" --port "$WB_PORT" --cdp "$CDP_PORT" --token "$token" \
      >>"$BRIDGE_LOG" 2>&1
  fi

  nohup node "$ROOT/bridge/cdp.mjs" \
    --host "$WB_HOST" --port "$WB_PORT" --cdp "$CDP_PORT" --token "$token" \
    >>"$BRIDGE_LOG" 2>&1 &
  echo $! >"$PID_FILE"

  for _ in $(seq 1 25); do
    if curl -s -m 1 "http://127.0.0.1:${WB_PORT}/health" >/dev/null 2>&1; then
      ok "桥已就绪"
      return 0
    fi
    bridge_alive || break
    sleep 0.4
  done

  warn "桥启动失败，日志："
  tail -25 "$BRIDGE_LOG" 2>/dev/null || true
  return 1
}

print_access() {
  local token; token="$(load_token)"
  echo
  printf '%s访问地址%s\n' "$C_B" "$C_0"
  for h in $(echo "$WB_HOST" | tr ',' ' '); do
    case "$h" in
      127.0.0.1|localhost|::1) printf '  %s（仅本机）%s\n  http://%s:%s/?token=%s\n' "$C_DIM" "$C_0" "$h" "$WB_PORT" "$token" ;;
      *)                       printf '  %s（同网段直连，免公网）%s\n  http://%s:%s/?token=%s\n' "$C_DIM" "$C_0" "$h" "$WB_PORT" "$token" ;;
    esac
  done
  if [ -z "${LAN_IPS:-}" ] && [ "$WB_LAN" != "0" ]; then
    dim "没探测到局域网地址，只能经隧道/公网访问"
  fi
  echo
  dim "令牌保存在 ${TOKEN_FILE}（权限 600）"
  dim "端点清单：${ENDPOINT_FILE}"
  dim "日志：${BRIDGE_LOG}"
}

# ── 状态 ────────────────────────────────────────────────────────────────
do_status() {
  printf '%s平台%s      %s (%s)\n' "$C_B" "$C_0" "$PLATFORM" "$OS"
  if detect_app; then
    printf '%sWorkBuddy%s %s\n' "$C_B" "$C_0" "$APP_BIN"
  else
    printf '%sWorkBuddy%s %s未找到%s\n' "$C_B" "$C_0" "$C_ERR" "$C_0"
  fi
  if cdp_ready; then
    printf '%sCDP%s       %s:%-5s 已就绪%s\n' "$C_B" "$C_0" "$C_OK" "$CDP_PORT" "$C_0"
  else
    printf '%sCDP%s       :%s 未开启\n' "$C_B" "$C_0" "$CDP_PORT"
  fi
  if bridge_alive; then
    printf '%s桥%s        %s:%-5s 运行中（pid %s）%s\n' "$C_B" "$C_0" "$C_OK" "$WB_PORT" "$(cat "$PID_FILE")" "$C_0"
    # 实际在监听哪些地址（含局域网），用 lsof 看真实绑定
    local binds=""
    if command -v lsof >/dev/null 2>&1; then
      binds="$(lsof -nP -iTCP:"$WB_PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}' | sed 's/.*://;s/.*\*//' | sort -u | tr '\n' ' ')"
    fi
    if [ -n "$binds" ]; then
      printf '%s监听%s      %s\n' "$C_B" "$C_0" "$binds"
      case " $binds " in
        *" 127.0.0.1 "*)
          local has_lan=0
          for b in $binds; do
            case "$b" in 127.0.0.1|::1|localhost) ;; *) has_lan=1 ;; esac
          done
          [ "$has_lan" = 1 ] && printf '%s局域网%s      %s已开放（同网段可直连）%s\n' "$C_B" "$C_0" "$C_OK" "$C_0" \
                             || printf '%s局域网%s      %s未开放（仅回环，需经隧道）%s\n' "$C_B" "$C_0" "$C_ERR" "$C_0"
          ;;
      esac
    fi
  else
    printf '%s桥%s        :%s 未运行\n' "$C_B" "$C_0" "$WB_PORT"
  fi
}

# ── 主流程 ──────────────────────────────────────────────────────────────
MODE=start
NO_RESTART=0
QUIET=0
for a in "$@"; do
  case "$a" in
    --stop) stop_bridge; exit 0 ;;
    --status) do_status; exit 0 ;;
    --no-restart) NO_RESTART=1 ;;
    --quiet) QUIET=1 ;;
    --foreground) FOREGROUND=1 ;;
    --restart) : ;;
    -h|--help)
      sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "未知参数: $a（--help 查看用法）" ;;
  esac
done

# --quiet 供开机自启使用：不打印成功信息（避免日志噪音），
# 但失败时仍要输出原因，并返回非 0 让上层知道。
if [ "$QUIET" = "1" ]; then
  info() { :; }; ok() { :; }; dim() { :; }
fi

need_node

# 先算好监听地址，后面 start_bridge / print_access / endpoints 都依赖
resolve_hosts

printf '%sWorkBuddy Remote%s  platform=%s\n\n' "$C_B" "$C_0" "$PLATFORM"

detect_app || die "未找到 WorkBuddy 桌面端。请先安装，或用 WB_APP=/path/to/workbuddy 指定路径"
ok "WorkBuddy: $APP_BIN"

if cdp_ready; then
  ok "CDP :${CDP_PORT} 已就绪，跳过重启"
elif [ "$NO_RESTART" = "1" ]; then
  die "CDP :${CDP_PORT} 未开启，但指定了 --no-restart。请手动让 WorkBuddy 带 --remote-debugging-port=${CDP_PORT} 启动"
else
  start_app || die "WorkBuddy 启动失败"
fi

start_bridge || die "桥启动失败"

write_endpoints

if [ "$QUIET" != "1" ]; then print_access; fi