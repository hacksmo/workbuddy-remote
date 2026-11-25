#!/usr/bin/env bash
# WorkBuddy Remote —— 一键安装（macOS / Linux）
#
#   curl -fsSL https://raw.githubusercontent.com/<user>/workbuddy-remote/main/install.sh | bash
#
# 做的事：
#   1. 检查 node（缺则提示安装方式，不擅自装系统包）
#   2. 把项目拉到 ~/.local/share/workbuddy-remote
#   3. 装一个 `workbuddy-remote` 命令到 PATH
#   4. 生成访问令牌
#
# 可选环境变量：
#   WB_REF       分支/标签，默认 main
#   WB_DIR       安装目录，默认 ~/.local/share/workbuddy-remote
#   WB_BIN_DIR   命令安装目录，默认 ~/.local/bin
#   WB_REPO      仓库地址（测试/自建镜像用）

set -euo pipefail

REPO="${WB_REPO:-https://github.com/__OWNER__/workbuddy-remote.git}"
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
die()  { warn "$*"; exit 1; }

case "$(uname -s)" in
  Darwin|Linux) ;;
  *) die "仅支持 macOS / Linux，当前是 $(uname -s)" ;;
esac

# ── 依赖 ────────────────────────────────────────────────────────────────
if ! command -v node >/dev/null 2>&1; then
  warn "未找到 node（需要 Node.js 18+）"
  case "$(uname -s)" in
    Darwin) dim_hint="  brew install node" ;;
    Linux)  dim_hint="  sudo apt install nodejs   # 或见 https://nodejs.org" ;;
  esac
  printf '  安装后再跑一次本脚本，或先执行：\n%s\n' "$dim_hint"
  exit 1
fi
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[ "$NODE_MAJOR" -ge 18 ] || die "Node.js 版本过低（$(node -v)），需要 18+"
ok "node $(node -v)"

command -v git >/dev/null 2>&1 || die "未找到 git，请先安装"

# ── 取代码 ──────────────────────────────────────────────────────────────
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

chmod +x "$DEST/scripts/start.sh" 2>/dev/null || true

# ── 装命令 ──────────────────────────────────────────────────────────────
mkdir -p "$BIN_DIR"
cat >"$BIN_DIR/workbuddy-remote" <<EOF
#!/usr/bin/env bash
exec "$DEST/scripts/start.sh" "\$@"
EOF
chmod +x "$BIN_DIR/workbuddy-remote"
ok "命令已安装：$BIN_DIR/workbuddy-remote"

# ── 令牌 ────────────────────────────────────────────────────────────────
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

# ── 收尾提示 ────────────────────────────────────────────────────────────
echo
printf '%s安装完成%s\n\n' "$C_B$C_OK" "$C_0"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    warn "$BIN_DIR 不在 PATH 中，把下面这行加到 shell 配置里："
    printf '  export PATH="%s:$PATH"\n\n' "$BIN_DIR"
    ;;
esac
printf '  启动：%sworkbuddy-remote%s\n' "$C_B" "$C_0"
printf '  状态：%sworkbuddy-remote --status%s\n' "$C_B" "$C_0"
printf '  停止：%sworkbuddy-remote --stop%s\n\n' "$C_B" "$C_0"
printf '  令牌：%s%s/token%s\n' "$C_DIM" "$STATE_DIR" "$C_0"
printf '%s注意：启动会重启 WorkBuddy 以开启调试端口，正在跑的任务会中断。%s\n' "$C_DIM" "$C_0"