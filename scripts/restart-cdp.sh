#!/bin/bash
# 手动排查用：检查 CDP 9333 这条链路，能修就修。
#
#   ./scripts/restart-cdp.sh          检查 + 必要时自动修复
#   ./scripts/restart-cdp.sh --check  只检查，不动任何东西
#
# 日常开机自启走的是 LaunchAgent `com.shuimo.wb-workbuddy`，
# 它调 scripts/launch-workbuddy-cdp.sh（逻辑更简单，只负责「保证端口开着」）。
# 这个脚本是给人手动用的，所以多做了逐层诊断和输出。

set -uo pipefail

APP=/Applications/WorkBuddy.app
BIN="$APP/Contents/MacOS/Electron"
PORT=9333
BRIDGE=8797
TOKEN="${WB_TOKEN:-zhengjiannan1218}"
CHECK_ONLY=""
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

_p() { printf "  %-20s %s\n" "$1" "$2"; }
_up() { curl -s -m 2 "http://127.0.0.1:${PORT}/json/version" >/dev/null 2>&1; }

echo "═══ CDP 链路诊断 ═══"

# ── 1. WorkBuddy 实例 ──
n=$(pgrep -f "$BIN" 2>/dev/null | wc -l | tr -d ' ')
_p "WorkBuddy 实例" "${n} 个"

# ── 2. CDP ──
if _up; then
    ver=$(curl -s -m 2 "http://127.0.0.1:${PORT}/json/version" | \
          sed -n 's/.*"Browser": *"\([^"]*\)".*/\1/p')
    _p "CDP ${PORT}" "✅ ${ver:-就绪}"
else
    _p "CDP ${PORT}" "❌ 未监听"
fi

# ── 3. 桥 ──
bh=$(curl -s -m 4 "http://127.0.0.1:${BRIDGE}/health" 2>/dev/null)
case "$bh" in
    *'"ok":true'*) _p "桥 ${BRIDGE}" "✅ 正常" ;;
    *)             _p "桥 ${BRIDGE}" "❌ ${bh:-无响应}" ;;
esac

# ── 4. 隧道 ──
if pgrep -f "ssh.*18797" >/dev/null 2>&1; then
    vh=$(ssh -o ConnectTimeout=8 aws-vps \
           "curl -s -m 6 http://127.0.0.1:18797/health" 2>/dev/null)
    case "$vh" in
        *'"ok":true'*) _p "公网隧道" "✅ VPS 18797 通" ;;
        *)             _p "公网隧道" "⚠️  VPS 侧异常: ${vh:-无响应}" ;;
    esac
else
    _p "公网隧道" "❌ ssh 进程不在"
fi

echo

# ── 修复 ──
if [ -n "$CHECK_ONLY" ]; then
    echo "（--check 模式，不做修改）"
    _up && exit 0 || exit 1
fi

if ! _up; then
    echo "→ 修复：重启 WorkBuddy 并开启 ${PORT}"
    if [ "$n" -gt 0 ]; then
        # 关键：必须先让所有实例退出。有实例活着时 `open --args` 会丢掉参数。
        osascript -e 'quit app "WorkBuddy"' 2>/dev/null
        for _ in $(seq 1 8); do
            pgrep -f "$BIN" >/dev/null 2>&1 || break
            sleep 1
        done
        pgrep -f "$BIN" >/dev/null 2>&1 && { pkill -f "$BIN" 2>/dev/null; sleep 3; }
        pgrep -f "$BIN" >/dev/null 2>&1 && { pkill -9 -f "$BIN" 2>/dev/null; sleep 2; }
    fi
    open -a "$APP" --args --remote-debugging-port=${PORT}

    for i in $(seq 1 45); do
        if _up; then
            echo "  ✅ ${PORT} 就绪（${i}s）"
            break
        fi
        sleep 1
        [ "$i" = "45" ] && { echo "  ❌ 超时"; exit 1; }
    done
else
    echo "CDP 正常，无需修复"
fi

# ── 桥自愈 ──
# 桥是独立进程，每次请求都新连 CDP，所以这里通常不用动它。
for _ in $(seq 1 20); do
    bh=$(curl -s -m 4 "http://127.0.0.1:${BRIDGE}/health" 2>/dev/null)
    case "$bh" in
        *'"ok":true'*) echo "  ✅ 桥已恢复"; exit 0 ;;
    esac
    sleep 1
done

echo "  ⚠️  桥仍未恢复，执行: launchctl kickstart -k gui/$(id -u)/com.shuimo.wb-bridge"
exit 1