#!/usr/bin/env bash
# 反向 SSH 隧道 —— 让外网能访问本机的桥（穿透 CGNAT / 对称 NAT）
#
# 适用场景：工作机在公司网络（常是 CGNAT），家里电脑要连进来。
# 原理：连接方向反过来 —— 本机主动连出到有公网 IP 的中转服务器，
#      由它在 127.0.0.1 上开一个端口回指本机。CGNAT 只拦外部主动连入，
#      不拦内部主动连出，所以对 NAT 类型完全不敏感。
#
#   ./scripts/tunnel.sh            按 ~/.config/workbuddy-remote/tunnel.env 连接
#   ./scripts/tunnel.sh --once     只连一次，不断线重试（调试用）
#
# 需要的配置（首次运行会生成模板）：
#   ~/.config/workbuddy-remote/tunnel.env
#     TUNNEL_HOST=1.2.3.4        中转服务器地址
#     TUNNEL_USER=ubuntu         登录用户
#     TUNNEL_KEY=~/.ssh/id_ed25519
#     TUNNEL_REMOTE_PORT=18797    在服务器上监听的端口
#     TUNNEL_LOCAL_PORT=8797      本机桥端口
#     TUNNEL_BIND_IFACE=en0       可选：绑定的本机网卡名（有 TUN 代理时必须）
#
# 服务器侧需配合 nginx 反代（见 deploy/nginx.conf.example）。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/workbuddy-remote"
ENV_FILE="$STATE_DIR/tunnel.env"
LOG_DIR="$STATE_DIR/logs"
LOG="$LOG_DIR/tunnel.log"
mkdir -p "$LOG_DIR"

if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_OK=''; C_ERR=''; C_B=''; C_0=''
fi
info() { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s ✓%s %s\n' "$C_OK" "$C_0" "$*"; }
warn() { printf '%s !%s %s\n' "$C_ERR" "$C_0" "$*"; }
die()  { warn "$*"; exit 1; }

# ── 首次生成模板 ────────────────────────────────────────────────────────
if [ ! -f "$ENV_FILE" ]; then
  cat >"$ENV_FILE" <<'EOF'
# WorkBuddy Remote —— 隧道配置
# 填好下面几项，然后运行：workbuddy-remote-tunnel

TUNNEL_HOST=
TUNNEL_USER=root
TUNNEL_KEY=~/.ssh/id_ed25519
TUNNEL_REMOTE_PORT=18797
TUNNEL_LOCAL_PORT=8797

# 本机开着全局代理（Clash/Surge/Shadowrocket 等 TUN 模式）时必须设，
# 否则 SSH 会绕经代理出口，延迟翻好几倍。macOS 一般是 en0。
# 留空则自动探测。
TUNNEL_BIND_IFACE=

# SSH 端口，一般不用改
TUNNEL_SSH_PORT=22
EOF
  chmod 600 "$ENV_FILE"
  ok "已生成配置模板：$ENV_FILE"
  echo
  info "把 TUNNEL_HOST / TUNNEL_USER / TUNNEL_KEY 填好后再运行一次"
  exit 0
fi

# shellcheck disable=SC1090
. "$ENV_FILE"

[ -n "${TUNNEL_HOST:-}" ] || die "请先在 $ENV_FILE 里填 TUNNEL_HOST"
KEY="${TUNNEL_KEY/#\~/$HOME}"
[ -f "$KEY" ] || die "找不到私钥：$KEY"

REMOTE_PORT="${TUNNEL_REMOTE_PORT:-18797}"
LOCAL_PORT="${TUNNEL_LOCAL_PORT:-8797}"
SSH_PORT="${TUNNEL_SSH_PORT:-22}"

# 自动探测物理网卡地址（绕开 TUN 代理）
detect_src() {
  if [ -n "${TUNNEL_BIND_IFACE:-}" ]; then
    local a; a="$(ipconfig getifaddr "$TUNNEL_BIND_IFACE" 2>/dev/null \
                  || ip -4 addr show "$TUNNEL_BIND_IFACE" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)"
    [ -n "$a" ] && { echo "$a"; return; }
  fi
  case "$(uname -s)" in
    Darwin)
      for i in en0 en1 en2; do
        local a; a="$(ipconfig getifaddr "$i" 2>/dev/null)" && [ -n "$a" ] && { echo "$a"; return; }
      done ;;
    Linux)
      local a; a="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)"
      [ -n "$a" ] && { echo "$a"; return; } ;;
  esac
}

ONCE=0
[ "${1:-}" = "--once" ] && ONCE=1

BACKOFF=3
while :; do
  SRC="$(detect_src)"
  BIND=""
  [ -n "$SRC" ] && BIND="-b $SRC"

  info "连接 ${TUNNEL_USER}@${TUNNEL_HOST}  本机:${LOCAL_PORT} → 远端:${REMOTE_PORT}${SRC:+  源 $SRC}"

  # -N: 不执行远程命令  -R: 反向端口转发
  # ExitOnForwardFailure: 远端端口被占用时立刻失败，避免"连上了但没隧道"的假在线
  # ServerAliveInterval: NAT 表项老化前主动保活
  # shellcheck disable=SC2086
  ssh -N -T $BIND \
      -p "$SSH_PORT" \
      -i "$KEY" \
      -o StrictHostKeyChecking=accept-new \
      -o ExitOnForwardFailure=yes \
      -o ServerAliveInterval=20 \
      -o ServerAliveCountMax=3 \
      -o TCPKeepAlive=yes \
      -o ConnectTimeout=15 \
      -o LogLevel=ERROR \
      -R "127.0.0.1:${REMOTE_PORT}:127.0.0.1:${LOCAL_PORT}" \
      "${TUNNEL_USER}@${TUNNEL_HOST}" 2>>"$LOG"

  rc=$?
  [ "$ONCE" = "1" ] && { warn "退出 (rc=$rc)"; exit $rc; }

  warn "隧道断开 (rc=$rc)，${BACKOFF}s 后重连"
  sleep "$BACKOFF"
  if [ "$rc" -eq 0 ]; then BACKOFF=3; else BACKOFF=$(( BACKOFF < 30 ? BACKOFF * 2 : 30 )); fi
done