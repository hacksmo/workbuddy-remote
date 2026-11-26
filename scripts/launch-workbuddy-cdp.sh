#!/bin/bash
# 登录时带 --remote-debugging-port=9333 启动 WorkBuddy。
#
# 为什么不能直接用 open -a：
#   `open -a WorkBuddy --args --remote-debugging-port=9333` 只在 WorkBuddy
#   完全没运行时才传参。只要有一个实例活着（哪怕是你刚手动点开的），
#   open 就退化成「激活窗口」，--args 被静默丢弃，退出码仍然是 0。
#   这个坑让 CDP 9333 时有时无，表现就是「远程连不上」。
#
# 这里先查端口：已经在监听就说明这次启动没问题，直接退出；
# 没监听就杀掉所有实例，再干净地起一个。

APP=/Applications/WorkBuddy.app
BIN="$APP/Contents/MacOS/Electron"
PORT=9333

cdp_up() { curl -s -m 1 "http://127.0.0.1:${PORT}/json/version" >/dev/null 2>&1; }

# 已经有调试端口，什么也不用做
cdp_up && exit 0

# 有实例但没开调试端口：必须先清空，否则 open 会丢掉 --args
if pgrep -f "$BIN" >/dev/null 2>&1; then
    echo "发现未开调试端口的实例，先结束它们"
    osascript -e 'quit app "WorkBuddy"' 2>/dev/null
    for _ in $(seq 1 8); do
        pgrep -f "$BIN" >/dev/null 2>&1 || break
        sleep 1
    done
    pgrep -f "$BIN" >/dev/null 2>&1 && { pkill -f "$BIN" 2>/dev/null; sleep 3; }
    pgrep -f "$BIN" >/dev/null 2>&1 && { pkill -9 -f "$BIN" 2>/dev/null; sleep 2; }
fi

open -a "$APP" --args --remote-debugging-port=${PORT}

# 等端口起来；失败就重启一次，留个日志
for _ in $(seq 1 45); do
    cdp_up && exit 0
    sleep 1
done

echo "$(date '+%F %T') 启动后 ${PORT} 未就绪，重试一次" >>/tmp/wb-workbuddy.log
pkill -9 -f "$BIN" 2>/dev/null
sleep 3
open -a "$APP" --args --remote-debugging-port=${PORT}
for _ in $(seq 1 45); do
    cdp_up && exit 0
    sleep 1
done
echo "$(date '+%F %T') 重试后仍未就绪" >>/tmp/wb-workbuddy.log
exit 1