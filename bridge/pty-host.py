#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
PTY 宿主 —— 给 bridge/terminal.mjs 当子进程用。

为什么是 python 而不是 node：
  项目没有 package.json，也没打算引入 node-pty（要编译原生模块，
  安装时会挑 node ABI 版本，用户机器上装不上就整个功能废掉）。
  系统自带 python3 的 pty / termios / fcntl 就够开一个真终端，
  macOS 和 Linux 出厂都有，零安装。

协议（故意做得极简，避免又一层解析）：
  node → 本进程 stdin：
      \\x00R<cols>x<rows>\\n   改窗口大小
      \\x00K                    结束会话（SIGTERM 给子进程后退出）
      其余字节                 原样写进 PTY
  本进程 → node stdout：
      PTY 的原始输出字节，不做任何包装。

stdin 用\x00 前缀而不是 JSON 帧，是因为终端输入里原本就可能有任意字节，
前缀字节在真实键盘输入里不会出现；而输出侧完全不包装，
前端 xterm.js 拿到的就是终端自己吐的字节流，中间没有任何改写机会。
"""
import os
import sys
import pty
import fcntl
import termios
import struct
import signal
import select
import errno

CTL = b'\x00'

def set_winsize(fd, cols, rows):
    # TIOCSWINSZ 期望 struct winsize: rows, cols, xpixel, ypixel，都是 unsigned short
    cols = max(2, min(1000, int(cols)))
    rows = max(2, min(400, int(rows)))
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
    except OSError:
        pass


def main():
    shell = os.environ.get('WB_TERM_SHELL') or os.environ.get('SHELL') or '/bin/sh'
    cwd = os.environ.get('WB_TERM_CWD') or os.path.expanduser('~')
    try:
        cols = int(os.environ.get('WB_TERM_COLS') or 80)
        rows = int(os.environ.get('WB_TERM_ROWS') or 24)
    except ValueError:
        cols, rows = 80, 24

    # 子进程要一个像样的环境。TERM 必须是 xterm-256color，
    # 否则 vim / htop / 各种 TUI 会退化成单色或干脆不画边框。
    env = dict(os.environ)
    env.update({
        'TERM': 'xterm-256color',
        'COLORTERM': 'truecolor',
        'LANG': env.get('LANG') or 'en_US.UTF-8',
        # 让 shell 知道自己在一个「远端」会话里，conda/nvm 之类的提示能正常显示
        'WB_TERM': '1',
    })
    # 不要把桥自己的环境变量漏给用户 shell
    for k in ('WB_BRIDGE_TOKEN', 'WB_CDP_PORT', 'WB_PORT'):
        env.pop(k, None)

    pid, fd = pty.fork()
    if pid == 0:
        # ---- 子进程 ----
        try:
            set_winsize(0, cols, rows)
            os.chdir(cwd)
            argv = [shell]
            # 登录 shell 才有完整的 PATH（macOS 上尤其重要，brew 装在
            # /opt/homebrew/bin，非登录 shell 读不到 /etc/zprofile）
            base = os.path.basename(shell)
            if base in ('zsh', 'bash', 'sh', 'fish', 'dash', 'ksh'):
                argv = ['-' + base]
            os.execvpe(shell, argv, env)
        except Exception as e:
            sys.stderr.write('pty exec failed: %s\n' % e)
            os._exit(127)

    # ---- 父进程 ----
    set_winsize(fd, cols, rows)

    # 子进程退出时别把它变僵尸
    def reap(*_):
        try:
            os.waitpid(pid, os.WNOHANG)
        except OSError:
            pass
    signal.signal(signal.SIGCHLD, reap)

    stdin = sys.stdin.fileno()
    stdout = sys.stdout.fileno()
    os.set_blocking(stdin, False)

    pending = b''      # 半截控制帧的残留
    running = True

    while running:
        try:
            r, _, _ = select.select([fd, stdin], [], [], 1.0)
        except (OSError, select.error) as e:
            if getattr(e, 'errno', None) == errno.EINTR:
                continue
            break

        if fd in r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                data = b''
            if not data:
                break           # shell 退出了
            try:
                os.write(stdout, data)
            except OSError:
                break           # node 那边断了，没人收就退出

        if stdin in r:
            try:
                chunk = os.read(stdin, 65536)
            except OSError:
                chunk = b''
            if not chunk:
                break           # node 关了管道
            buf = pending + chunk
            pending = b''
            i = 0
            n = len(buf)
            while i < n:
                if buf[i:i + 1] == CTL:
                    # 控制帧：\x00R<cols>x<rows>\n 或 \x00K
                    nl = buf.find(b'\n', i)
                    if nl < 0:
                        pending = buf[i:]      # 还没收完，等下一批
                        i = n
                        break
                    cmd = buf[i + 1:nl]
                    i = nl + 1
                    if cmd[:1] == b'R':
                        try:
                            c, rr = cmd[1:].decode('ascii', 'replace').split('x')
                            set_winsize(fd, int(c), int(rr))
                        except Exception:
                            pass
                    elif cmd[:1] == b'K':
                        running = False
                        break
                    else:
                        pass
                else:
                    # 普通输入：一次性写到下一个控制字节之前
                    nxt = buf.find(CTL, i)
                    if nxt < 0:
                        nxt = n
                    try:
                        os.write(fd, buf[i:nxt])
                    except OSError:
                        running = False
                        break
                    i = nxt
            if not running:
                break

    # 收尾：先礼后兵
    try:
        os.kill(pid, signal.SIGHUP)
    except OSError:
        pass
    for _ in range(20):
        try:
            w, _ = os.waitpid(pid, os.WNOHANG)
            if w:
                break
        except OSError:
            break
        import time
        time.sleep(0.02)
    else:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
    try:
        os.close(fd)
    except OSError:
        pass


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        pass