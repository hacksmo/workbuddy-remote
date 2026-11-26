/**
 * 远程终端 —— WebSocket + PTY
 *
 * 设计参照 ttyd / gotty / termdock 的通行做法（xterm.js → WebSocket → PTY → shell），
 * 但有两处刻意不同：
 *
 * 1. 不装 node-pty。node-pty 是原生模块，装的时候要按 node ABI 编译，
 *    用户机器上没有编译环境就整个功能不可用。这里改成 python 子进程开 PTY
 *    （见 pty-host.py）——macOS / Linux 出厂自带 python3，零安装。
 * 2. 不依赖 tmux 做会话持久化。tmux 不是默认安装的，要求用户先 brew install
 *    是多余的门槛。这里在桥进程里维护会话表 + 环形缓冲，断线重连时把缓冲
 *    回放给客户端，效果和 tmux attach 等价（区别只在桥进程退出会丢会话）。
 *
 * 协议：
 *   GET /terminal/ws?sid=<会话id>&cols=&rows=
 *     WS 建立后：
 *       后端 → 前端：二进制帧 = PTY 原始输出字节
 *                    文本帧   = JSON 控制消息（exit / ready / pong）
 *       前端 → 后端：二进制帧 = 键盘输入原样字节
 *                    文本帧   = JSON 控制消息 {type:'resize'|'ping'|'kill'}
 */
import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PY_HOST = path.join(HERE, 'pty-host.py');

const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

/** 回放缓冲上限。256KB 大约相当于 3000 行普通输出，
 *  比 xterm 默认的 1000 行 scrollback 还多，重连后视觉上和没断过一样。 */
const RING_MAX = 256 * 1024;
/** 没有任何客户端连着超过这个时间就回收 PTY，避免用户关页面后
 *  shell 在后台挂一整天吃内存。 */
const IDLE_REAP_MS = 10 * 60 * 1000;
/** 同时活着的会话上限。正常用不到这么多 —— 一屏只有几个标签，
 *  设上限纯粹是防「页面反复刷新、每次都在服务端留一个 shell」把机器拖垮。 */
const MAX_SESSIONS = 12;

/* ─────────────────────────── WebSocket 帧编解码 ─────────────────────────── */

function acceptKey(key) {
  return crypto.createHash('sha1').update(key + WS_GUID).digest('base64');
}

/** 服务端 → 客户端：一律不掩码 */
function encodeFrame(opcode, payload) {
  const len = payload.length;
  let head;
  if (len < 126) {
    head = Buffer.alloc(2);
    head[1] = len;
  } else if (len < 65536) {
    head = Buffer.alloc(4);
    head[1] = 126;
    head.writeUInt16BE(len, 2);
  } else {
    head = Buffer.alloc(10);
    head[1] = 127;
    head.writeBigUInt64BE(BigInt(len), 2);
  }
  head[0] = 0x80 | opcode;  // FIN + opcode
  return Buffer.concat([head, payload]);
}

/**
 * 增量解析客户端帧。TCP 会把帧切碎，必须按缓冲区累积，
 * 一次性 parse 整包是实现 WS 服务端最常见的错误来源。
 */
class FrameParser {
  constructor() {
    this.buf = Buffer.alloc(0);
  }
  /** @returns {Array<{opcode:number, payload:Buffer}>} 解出的完整帧 */
  push(chunk) {
    this.buf = this.buf.length ? Buffer.concat([this.buf, chunk]) : chunk;
    const out = [];
    for (;;) {
      const b = this.buf;
      if (b.length < 2) break;
      const fin = (b[0] & 0x80) !== 0;
      const opcode = b[0] & 0x0f;
      const masked = (b[1] & 0x80) !== 0;
      let len = b[1] & 0x7f;
      let off = 2;
      if (len === 126) {
        if (b.length < off + 2) break;
        len = b.readUInt16BE(off);
        off += 2;
      } else if (len === 127) {
        if (b.length < off + 8) break;
        const big = b.readBigUInt64BE(off);
        if (big > 64n * 1024n * 1024n) throw new Error('frame too large');
        len = Number(big);
        off += 8;
      }
      let mask = null;
      if (masked) {
        if (b.length < off + 4) break;
        mask = b.subarray(off, off + 4);
        off += 4;
      }
      if (b.length < off + len) break;

      let payload = Buffer.from(b.subarray(off, off + len));
      if (mask) {
        for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
      }
      this.buf = b.subarray(off + len);

      // 控制帧（close/ping/pong）不能分片，直接出去
      if (opcode >= 0x8) { out.push({ opcode, payload }); continue; }
      // 数据帧：目前客户端只会发不分片的帧，但保留 fin 判断避免误伤
      if (fin) out.push({ opcode, payload });
    }
    return out;
  }
}

/* ─────────────────────────── 终端会话 ─────────────────────────── */

let seq = 0;
/** sid → session */
const sessions = new Map();

class TermSession {
  constructor(opts) {
    this.sid = 't' + (++seq).toString(36) + Math.random().toString(36).slice(2, 6);
    this.cols = opts.cols || 80;
    this.rows = opts.rows || 24;
    this.cwd = opts.cwd || '';
    this.clients = new Set();
    this.ring = [];          // Buffer 片段，按写入顺序
    this.ringLen = 0;
    this.exited = false;
    this.exitCode = null;
    this.lastDetach = 0;
    this.createdAt = Date.now();
    this.title = '';

    const env = { ...process.env };
    // 桥自己的令牌绝不能漏进用户的 shell 环境
    delete env.WB_BRIDGE_TOKEN;
    if (this.cwd) env.WB_TERM_CWD = this.cwd;
    env.WB_TERM_COLS = String(this.cols);
    env.WB_TERM_ROWS = String(this.rows);

    this.proc = spawn(process.env.WB_PYTHON || 'python3', [PY_HOST], {
      env,
      stdio: ['pipe', 'pipe', 'pipe'],
    });

    this.proc.stdout.on('data', (d) => this._onData(d));
    // python 侧的异常走 stderr，转发给客户端能看到原因，比静默好
    this.proc.stderr.on('data', (d) => {
      this._onData(Buffer.from(`\r\n\x1b[31m[pty] ${d.toString().trim()}\x1b[0m\r\n`));
    });
    this.proc.on('exit', (code) => {
      this.exited = true;
      this.exitCode = code;
      this._broadcastText({ type: 'exit', code });
    });
    this.proc.on('error', (e) => {
      this._onData(Buffer.from(`\r\n\x1b[31m[pty] 启动失败：${e.message}\x1b[0m\r\n`));
      this.exited = true;
      this._broadcastText({ type: 'exit', code: -1, error: e.message });
    });

    sessions.set(this.sid, this);
    // 超上限时踢掉最老的、且当前没人连着的那个
    if (sessions.size > MAX_SESSIONS) {
      const idle = [...sessions.values()]
        .filter((s) => s.sid !== this.sid && s.clients.size === 0)
        .sort((a, b) => a.createdAt - b.createdAt);
      for (const s of idle) {
        if (sessions.size <= MAX_SESSIONS) break;
        s.destroy();
      }
    }
  }

  /** 写入回放缓冲，超限就从头丢 —— 丢头比丢尾好，尾是最新的屏幕内容 */
  _onData(buf) {
    this.ring.push(buf);
    this.ringLen += buf.length;
    while (this.ringLen > RING_MAX && this.ring.length > 1) {
      this.ringLen -= this.ring.shift().length;
    }
    for (const c of this.clients) c.sendBinary(buf);
  }

  _broadcastText(obj) {
    const s = JSON.stringify(obj);
    for (const c of this.clients) c.sendText(s);
  }

  /** 拼接回放内容。丢掉第一个换行之前的部分 —— 缓冲被截断时
   *  开头往往是半条转义序列，直接回放会让终端错色。 */
  snapshot() {
    if (!this.ring.length) return Buffer.alloc(0);
    let all = Buffer.concat(this.ring);
    if (this.ringLen >= RING_MAX) {
      const nl = all.indexOf(0x0a);
      if (nl > 0 && nl < 4096) all = all.subarray(nl + 1);
    }
    return all;
  }

  /**
   * 给新客户端的回放。
   *
   * 不能直接 dump snapshot()。zsh 在画提示符前会发一段 PROMPT_SP 序列
   * （`%` + 一串空格 + 右对齐的 EOL mark），它的视觉结果**依赖当时的终端
   * 列数**：重新回放到一个列数不同的终端里，那串空格会把 `%` 推到一个
   * 莫名其妙的位置，看起来就是一个孤立的白方块 + 百分号，像乱码。
   *
   * 所以回放前先发一个软复位（DECSTR）+ 清理行尾，把解析器状态归零；
   * 末尾再补 `\r` 让光标回到行首 —— 否则 shell 的下一个提示符会接在
   * 上一行的残留空格后面。
   */
  replay() {
    const snap = this.snapshot();
    if (!snap.length) return Buffer.alloc(0);
    const RESET = '\x1b[!p';         // DECSTR 软复位：清属性、取消滚动区，不动屏幕内容
    const HEAD = '\r\x1b[0m';        // 回行首 + 重置 SGR
    const TAIL = '\r\x1b[0m\x1b[K';  // 结尾清行尾，压掉残留的半截提示符
    return Buffer.concat([
      Buffer.from(HEAD + RESET, 'utf8'),
      snap,
      Buffer.from(TAIL, 'utf8'),
    ]);
  }

  write(data) {
    if (this.exited || !this.proc.stdin.writable) return;
    try { this.proc.stdin.write(data); } catch {}
  }

  resize(cols, rows) {
    if (this.exited) return;
    this.cols = Math.max(2, Math.min(1000, cols | 0));
    this.rows = Math.max(2, Math.min(400, rows | 0));
    try {
      this.proc.stdin.write(`\x00R${this.cols}x${this.rows}\n`);
    } catch {}
  }

  /**
   * 多客户端时取各端尺寸的最小值。
   *
   * 同一会话被两台设备同时看着（手机 + 电脑是常态），如果谁后连谁说了算，
   * 屏幕就会被反复重排：zsh 的右提示符先掉到第二行、再折成竖排，
   * 看起来就是一片方块乱码。取最小值是 tmux 的做法 —— 保证没有任何
   * 一端的行宽溢出，宽的那端留空白，比两边都错位好。
   */
  resizeFor(client, cols, rows) {
    if (this.exited) return;
    client.cols = Math.max(2, Math.min(1000, cols | 0));
    client.rows = Math.max(2, Math.min(400, rows | 0));
    let c = Infinity, r = Infinity;
    for (const cl of this.clients) {
      if (cl.cols) c = Math.min(c, cl.cols);
      if (cl.rows) r = Math.min(r, cl.rows);
    }
    if (!isFinite(c) || !isFinite(r)) { c = client.cols; r = client.rows; }
    if (c === this.cols && r === this.rows) return;
    this.resize(c, r);
  }

  kill() {
    if (this.exited) return;
    try { this.proc.stdin.write('\x00K'); } catch {}
    // python 侧会 SIGHUP 子进程；再兜一层，2 秒后强杀
    setTimeout(() => {
      if (!this.exited) { try { this.proc.kill('SIGKILL'); } catch {} }
    }, 2000).unref?.();
  }

  destroy() {
    this.kill();
    this.exited = true;
    sessions.delete(this.sid);
  }
}

/** 定时回收：没有客户端且空闲太久的会话 */
setInterval(() => {
  const now = Date.now();
  for (const s of sessions.values()) {
    if (s.clients.size) continue;
    if (!s.lastDetach) { s.lastDetach = now; continue; }
    if (now - s.lastDetach > IDLE_REAP_MS) s.destroy();
  }
}, 60 * 1000).unref?.();

/* ─────────────────────────── 连接处理 ─────────────────────────── */

class Client {
  constructor(socket, session, cols, rows) {
    this.socket = socket;
    this.session = session;
    this.alive = true;
    this.cols = cols || 0;
    this.rows = rows || 0;
    this.parser = new FrameParser();
  }
  sendBinary(buf) { this._send(0x2, buf); }
  sendText(str) { this._send(0x1, Buffer.from(str, 'utf8')); }
  _send(opcode, payload) {
    if (!this.alive) return;
    try { this.socket.write(encodeFrame(opcode, payload)); } catch { this.alive = false; }
  }
  close() {
    if (!this.alive) return;
    this.alive = false;
    try { this.socket.write(encodeFrame(0x8, Buffer.alloc(0))); } catch {}
    try { this.socket.end(); } catch {}
  }
}

/** 把 HTTP upgrade 变成一条终端连接 */
function handleUpgrade(req, socket, head, opts = {}) {
  const url = new URL(req.url, 'http://localhost');
  const key = req.headers['sec-websocket-key'];
  if (!key) {
    socket.write('HTTP/1.1 400 Bad Request\r\n\r\n');
    socket.destroy();
    return;
  }

  const cols = Math.max(2, Number(url.searchParams.get('cols')) || 80);
  const rows = Math.max(2, Number(url.searchParams.get('rows')) || 24);
  let sid = url.searchParams.get('sid') || '';

  // 复用已有会话（刷新 / 换设备重连）；会话没了或已退出就新建
  let session = sid ? sessions.get(sid) : null;
  if (session && session.exited) session = null;
  const reused = !!session;
  if (!session) {
    session = new TermSession({ cols, rows, cwd: url.searchParams.get('cwd') || '' });
  }
  // 重连时**不改**已存在会话的尺寸。理由：手机和电脑同时开着的时候，
  // 谁后连谁把尺寸改掉，另一边的屏幕会被重排成对方的样子（zsh 的
  // 右提示符先掉到第二行、再折成竖排，看起来就是一片方块）。
  // 已有会话沿用自己当前的尺寸，前端 fit 之后会按自己的容器再报一次。}

  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
    'Upgrade: websocket\r\n' +
    'Connection: Upgrade\r\n' +
    `Sec-WebSocket-Accept: ${acceptKey(key)}\r\n` +
    '\r\n'
  );
  // 终端数据可能很密，关掉 Nagle 否则按键回显会有 40ms 级延迟
  try { socket.setNoDelay(true); } catch {}

  const client = new Client(socket, session, cols, rows);
  session.clients.add(client);
  session.lastDetach = 0;
  // 新客户端连上就参与「最小尺寸」计算。首次连接时它就是唯一一端，
  // 等价于直接设定尺寸。
  session.resizeFor(client, cols, rows);

  // 先把已有会话的屏幕内容回放，再打 ready —— 顺序不能反，
  // 否则前端在 ready 里 fit() 触发 resize，回放内容会排在尺寸变更之后
  const snap = session.replay();
  if (snap.length) client.sendBinary(snap);
  client.sendText(JSON.stringify({
    type: 'ready',
    sid: session.sid,
    reused,
    cols: session.cols,
    rows: session.rows,
    exited: session.exited,
  }));

  if (head && head.length) onChunk(head);

  function onChunk(chunk) {
    let frames;
    try { frames = client.parser.push(chunk); } catch {
      client.close();
      return;
    }
    for (const f of frames) {
      if (f.opcode === 0x8) {          // close
        client.close();
        return;
      }
      if (f.opcode === 0x9) {          // ping
        client._send(0xa, f.payload);
        continue;
      }
      if (f.opcode === 0xa) continue;  // pong
      if (f.opcode === 0x2) {          // 二进制 = 键盘输入
        session.write(f.payload);
        continue;
      }
      if (f.opcode === 0x1) {          // 文本 = 控制消息
        let m;
        try { m = JSON.parse(f.payload.toString('utf8')); } catch { continue; }
        if (m.type === 'resize') session.resizeFor(client, m.cols, m.rows);
        else if (m.type === 'ping') client.sendText('{"type":"pong"}');
        else if (m.type === 'kill') { session.destroy(); }
      }
    }
  }

  socket.on('data', onChunk);
  socket.on('error', () => { cleanup(); });
  socket.on('close', () => { cleanup(); });
  socket.on('end', () => { cleanup(); });

  let done = false;
  function cleanup() {
    if (done) return;
    done = true;
    client.alive = false;
    session.clients.delete(client);
    if (!session.clients.size) session.lastDetach = Date.now();
    else {
      // 一端走了，剩下的那端可以拿回自己的完整宽度
      const rest = [...session.clients][0];
      if (rest) session.resizeFor(rest, rest.cols, rest.rows);
    }
    try { socket.destroy(); } catch {}
  }
}

/* ─────────────────────────── 对外的 HTTP 端点 ─────────────────────────── */

export function isTerminalWs(pathname) {
  return pathname === '/terminal/ws';
}

export function handleTerminalUpgrade(req, socket, head) {
  return handleUpgrade(req, socket, head);
}

/** GET /terminal/sessions —— 列出还活着的终端，用于前端恢复标签页 */
export function listSessions() {
  return [...sessions.values()].map((s) => ({
    sid: s.sid,
    cols: s.cols,
    rows: s.rows,
    cwd: s.cwd,
    exited: s.exited,
    clients: s.clients.size,
    createdAt: s.createdAt,
  }));
}

/** POST /terminal/sessions/:sid/kill */
export function killSession(sid) {
  const s = sessions.get(sid);
  if (!s) return false;
  s.destroy();
  return true;
}

export function sessionCount() {
  return sessions.size;
}