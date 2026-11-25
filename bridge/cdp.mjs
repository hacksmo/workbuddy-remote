#!/usr/bin/env node
/**
 * WorkBuddy CDP 桥
 *
 * 通过 Chrome DevTools Protocol 在桌面端渲染进程里执行 JS，
 * 从而调用 preload 暴露的全部 electronAPI（等价于桌面端自身操作）。
 *
 * 前置：WorkBuddy 需以 --remote-debugging-port=9333 启动
 *   见 bridge/start-workbuddy.sh
 *
 * 用法：
 *   node bridge/cdp.mjs                 # 起 HTTP 服务 :8797
 *   node bridge/cdp.mjs --probe         # 只探测，列出 target 与可用 API
 */
import http from 'node:http';
import os from 'node:os';
import { gzipSync } from 'node:zlib';
import path from 'node:path';
import { readFile, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
// 注入到页面里执行的代码放在单独文件，靠 fn.toString() 传过去，
// 避免模板字符串里嵌套转义（曾导致 /messages 整体 500）
import { collectMessages, answerPending, probeTypes } from './inject.mjs';
import { parseArgs } from 'node:util';

const WEB_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'web');

// 本机回环地址必须绕过系统代理：WorkBuddy 环境常带 HTTP_PROXY，
// 会让 fetch 把 127.0.0.1 的请求送进代理，表现为 "fetch failed"。
for (const k of ['NO_PROXY', 'no_proxy']) {
  const cur = process.env[k] || '';
  if (!cur.includes('127.0.0.1')) {
    process.env[k] = cur ? `${cur},127.0.0.1,localhost,::1` : '127.0.0.1,localhost,::1';
  }
}

const { values } = parseArgs({
  options: {
    port: { type: 'string', default: '8797' },
    cdp: { type: 'string', default: '9333' },
    probe: { type: 'boolean', default: false },
    token: { type: 'string', default: process.env.WB_BRIDGE_TOKEN || '' },
    host: { type: 'string', default: '127.0.0.1' },
  },
});

const CDP_PORT = Number(values.cdp);
const LISTEN = Number(values.port);

/** 取渲染进程 target（用 node:http，不吃 undici 的代理配置） */
function listTargets() {
  return new Promise((resolve, reject) => {
    const req = http.get(
      { host: '127.0.0.1', port: CDP_PORT, path: '/json/list', timeout: 5000 },
      (res) => {
        let d = '';
        res.setEncoding('utf8');
        res.on('data', (c) => (d += c));
        res.on('end', () => {
          try { resolve(JSON.parse(d)); } catch (e) { reject(new Error('CDP 返回非 JSON: ' + d.slice(0, 200))); }
        });
      }
    );
    req.on('timeout', () => req.destroy(new Error(`CDP ${CDP_PORT} 无响应`)));
    req.on('error', (e) => reject(new Error(`连不上 CDP ${CDP_PORT}：${e.message}（WorkBuddy 是否以 --remote-debugging-port 启动？）`)));
  });
}

/** 极简 CDP 客户端：一条 WS 连接，按 id 配对响应 */
class CDP {
  constructor(wsUrl) {
    this.wsUrl = wsUrl;
    this.seq = 0;
    this.pending = new Map();
    this.closed = false;
    this._queue = Promise.resolve();  // 同一连接内串行，避免 pending 串线
  }
  async connect() {
    this.ws = new WebSocket(this.wsUrl);
    await new Promise((res, rej) => {
      this.ws.addEventListener('open', res, { once: true });
      this.ws.addEventListener('error', (e) => rej(new Error('CDP 连接失败: ' + (e.message || 'unknown'))), { once: true });
      setTimeout(() => rej(new Error('CDP 连接超时')), 5000);
    });
    this.ws.addEventListener('close', () => { this.closed = true; });
    this.ws.addEventListener('message', (ev) => {
      let msg;
      try { msg = JSON.parse(ev.data); } catch { return; }
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        msg.error ? reject(new Error(msg.error.message)) : resolve(msg.result);
      }
    });
    return this;
  }
  send(method, params = {}) {
    const id = ++this.seq;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
      setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error(`CDP ${method} 超时`));
        }
      }, 15000);
    });
  }
  /** 在页面里求值（同连接内串行执行） */
  evaluate(expression) {
    const p = this._queue.then(() => this._evaluate(expression));
    this._queue = p.then(() => {}, () => {});
    return p;
  }

  /**
   * 把一个真实函数送进页面执行，参数走 JSON 序列化。
   *
   * 之前所有注入逻辑都写在模板字符串里，一旦里面有 join('\n') 这类转义，
   * 就会被外层求值成真换行、把注入代码截断，接口直接 500，而且极难定位。
   * 改成 fn.toString()：源码是源码，参数是 JSON，中间没有任何字符串拼接，
   * 转义问题从根上消失。
   */
  evaluateFn(fn, ...args) {
    const src = typeof fn === 'function' ? fn.toString() : String(fn);
    const call = '(' + src + ').apply(null, ' + JSON.stringify(args) + ')';
    return this.evaluate(call);
  }

  async _evaluate(expression) {
    if (this.closed) throw new Error('CDP 连接已关闭');
    const r = await this.send('Runtime.evaluate', {
      expression,
      awaitPromise: true,
      returnByValue: true,
      allowUnsafeEvalBlockedByCSP: true,
      userGesture: true,
    });
    if (r.exceptionDetails) {
      const d = r.exceptionDetails;
      throw new Error(d.exception?.description || d.text || '页面执行异常');
    }
    return r.result?.value;
  }
  close() { try { this.ws?.close(); } catch {} }
}

/** 选一个可用的页面 target（优先主窗口） */
function pickTarget(targets) {
  const pages = targets.filter((t) => t.type === 'page' && !t.url.startsWith('devtools://'));
  return (
    pages.find((t) => t.url.includes('index.html')) ||
    pages.find((t) => !t.url.startsWith('about:')) ||
    pages[0]
  );
}

async function connectPage() {
  const targets = await listTargets();
  const t = pickTarget(targets);
  if (!t) throw new Error('找不到可用的渲染进程 target');
  const cdp = await new CDP(t.webSocketDebuggerUrl).connect();
  return { cdp, target: t, targets };
}

/** 探测：列出 preload 暴露的 API */
async function probe() {
  const { cdp, target, targets } = await connectPage();
  console.log('CDP targets:', targets.map((t) => `${t.type}:${t.title || t.url}`).join(' | '));
  console.log('已连接:', target.title, target.url);
  const info = await cdp.evaluate(`(() => {
    const out = { href: location.href.split('?')[0], title: document.title, apiRoot: null, apis: {}, sub: {} };
    const api = window.wb || window.electronAPI || window.electron || null;
    if (!api) return out;
    out.apiRoot = window.wb === api ? 'wb' : (window.electronAPI === api ? 'electronAPI' : 'electron');
    out.apis = Object.fromEntries(Object.entries(api).map(([k, v]) => [k, typeof v]));
    for (const k of ['conversations', 'spaces', 'skills', 'experts', 'connectors', 'storage']) {
      const o = api[k];
      if (o && typeof o === 'object') out.sub[k] = Object.keys(o);
    }
    return out;
  })()`);
  console.log(JSON.stringify(info, null, 2));
  cdp.close();
}

/** HTTP 服务：给浏览器用 */
async function serve() {
  let sharedConn = null;
  async function getConn() {
    if (!sharedConn) {
      sharedConn = connectPage().then(({ cdp }) => cdp).catch((e) => { sharedConn = null; throw e; });
    }
    const c = await sharedConn;
    if (c.closed) { sharedConn = null; return getConn(); }
    return c;
  }

  // SSE：把渲染进程的全局事件泵给浏览器
  const sseClients = new Set();
  const HOOK = `(() => {
    if (!window.__wbEvtHooked) {
      window.__wbEvtHooked = true;
      window.__wbEvt = [];
      try {
        wb.onAny((e) => {
          window.__wbEvt.push({ t: Date.now(), e: typeof e === 'string' ? e : String(e) });
          if (window.__wbEvt.length > 400) window.__wbEvt.splice(0, 200);
        });
      } catch (err) { return { error: String(err) }; }
    }
    return { events: (window.__wbEvt || []).splice(0) };
  })()`;

  setInterval(async () => {
    if (!sseClients.size) return;
    try {
      const cdp = await getConn();
      const r = await cdp.evaluate(HOOK);
      const evts = (r && r.events) || [];
      if (!evts.length) return;
      const payload = evts.map((x) => `data: ${JSON.stringify(x)}\n\n`).join('');
      for (const c of sseClients) { try { c.write(payload); } catch {} }
    } catch {}
  }, 250);

  const handler = async (req, res) => {

    const allow = {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    };
    if (req.method === 'OPTIONS') { res.writeHead(204, allow); return res.end(); }
    const acceptsGzip = /gzip/.test(req.headers['accept-encoding'] || '');
    const send = (code, obj) => {
      const body = Buffer.from(JSON.stringify(obj), 'utf8');
      const base = { 'Content-Type': 'application/json; charset=utf-8', ...allow };
      if (acceptsGzip && body.length > 1024) {
        const gz = gzipSync(body);
        res.writeHead(code, { ...base, 'Content-Encoding': 'gzip', 'Content-Length': gz.length, 'Vary': 'Accept-Encoding' });
        return res.end(gz);
      }
      res.writeHead(code, { ...base, 'Content-Length': body.length });
      res.end(body);
    };

    const url = new URL(req.url, 'http://localhost');
    const isPublic = url.pathname === '/' || url.pathname === '/index.html' || url.pathname === '/md.js' || url.pathname === '/health' || url.pathname === '/info' || url.pathname === '/manifest.json' || url.pathname.startsWith('/preview/') || url.pathname.startsWith('/fonts/') || url.pathname.startsWith('/icons/');
    if (values.token && !isPublic) {
      const got = (req.headers.authorization || '').replace(/^Bearer\s+/i, '') || url.searchParams.get('token') || '';
      if (got !== values.token) return send(401, { error: 'unauthorized' });
    }

    try {
      if (url.pathname === '/' || url.pathname === '/index.html') {
        const html = await readFile(path.join(WEB_DIR, 'index.html'), 'utf8');
        const buf = Buffer.from(html, 'utf8');
        const base = { 'Content-Type': 'text/html; charset=utf-8', 'Vary': 'Accept-Encoding', ...allow };
        if (acceptsGzip) {
          const gz = gzipSync(buf);
          res.writeHead(200, { ...base, 'Content-Encoding': 'gzip', 'Content-Length': gz.length });
          return res.end(gz);
        }
        res.writeHead(200, { ...base, 'Content-Length': buf.length });
        return res.end(buf);
      }

      if (url.pathname === '/manifest.json') {
        const tk = url.searchParams.get('token') || values.token || '';
        const manifest = {
          name: 'WorkBuddy 远程',
          short_name: 'WorkBuddy',
          description: '远程操作工作机上的 WorkBuddy',
          start_url: tk ? `/?token=${encodeURIComponent(tk)}` : '/',
          scope: '/',
          display: 'standalone',
          display_override: ['window-controls-overlay', 'standalone'],
          orientation: 'any',
          background_color: '#141414',
          theme_color: '#141414',
          icons: [
            { src: '/icons/icon-192.png', sizes: '192x192', type: 'image/png', purpose: 'any' },
            { src: '/icons/icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'any maskable' },
          ],
        };
        res.writeHead(200, { 'Content-Type': 'application/manifest+json; charset=utf-8', ...allow });
        return res.end(JSON.stringify(manifest));
      }

      if (url.pathname.startsWith('/icons/')) {
        const name = path.basename(url.pathname);
        if (!/^[\w.-]+\.png$/.test(name)) return send(404, { error: 'not found' });
        const body = await readFile(path.join(WEB_DIR, 'icons', name));
        res.writeHead(200, { 'Content-Type': 'image/png', 'Cache-Control': 'public, max-age=604800', ...allow });
        return res.end(body);
      }

      if (url.pathname.startsWith('/fonts/')) {
        const name = path.basename(url.pathname);
        if (!/^[\w.-]+\.woff2$/.test(name)) return send(404, { error: 'not found' });
        const body = await readFile(path.join(WEB_DIR, 'fonts', name));
        res.writeHead(200, { 'Content-Type': 'font/woff2', 'Cache-Control': 'public, max-age=31536000', ...allow });
        return res.end(body);
      }

      if (url.pathname === '/md.js') {
        const js = await readFile(path.join(WEB_DIR, 'md.js'), 'utf8');
        res.writeHead(200, { 'Content-Type': 'application/javascript; charset=utf-8', ...allow });
        return res.end(js);
      }

      if (url.pathname.startsWith('/preview/')) {
        const raw = decodeURIComponent(url.pathname.slice('/preview'.length));
        const target = path.resolve(raw);
        const ALLOW = ['/Users/shuimo/WorkBuddy', '/Users/shuimo/Desktop', '/Users/shuimo/Documents', '/Users/shuimo/Downloads', '/tmp'];
        const DENY = [/\.ssh\b/, /\.aws\b/, /\.gnupg\b/, /Library\/Keychains/, /\.workbuddy\/\.credentials/, /\.config\/gh\b/];
        const okRoot = ALLOW.some((r) => target === r || target.startsWith(r + '/'));
        const denied = DENY.some((re) => re.test(target));
        if (!okRoot || denied) return send(403, { error: 'path not allowed' });
        try {
          const st = await stat(target);
          if (st.isDirectory()) {
            const idx = path.join(target, 'index.html');
            const html = await readFile(idx);
            res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', ...allow });
            return res.end(html);
          }
          const ext = path.extname(target).toLowerCase();
          const MIME = {
            '.html': 'text/html; charset=utf-8', '.htm': 'text/html; charset=utf-8',
            '.js': 'application/javascript; charset=utf-8', '.mjs': 'application/javascript; charset=utf-8',
            '.css': 'text/css; charset=utf-8', '.json': 'application/json; charset=utf-8',
            '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
            '.gif': 'image/gif', '.webp': 'image/webp', '.ico': 'image/x-icon',
            '.woff': 'font/woff', '.woff2': 'font/woff2', '.ttf': 'font/ttf',
            '.md': 'text/plain; charset=utf-8', '.txt': 'text/plain; charset=utf-8',
            '.pdf': 'application/pdf', '.mp4': 'video/mp4', '.webm': 'video/webm',
          };
          const body = await readFile(target);
          res.writeHead(200, {
            'Content-Type': MIME[ext] || 'application/octet-stream',
            'Cache-Control': 'no-store',
            ...allow,
          });
          return res.end(body);
        } catch (e) {
          return send(404, { error: 'not found: ' + target });
        }
      }

      if (url.pathname === '/info') {
        const nets = os.networkInterfaces();
        const ips = [];
        for (const [iface, list] of Object.entries(nets)) {
          for (const n of list || []) {
            if (n.family === 'IPv4' && !n.internal) ips.push({ iface, ip: n.address });
          }
        }
        const ts = ips.find((x) => x.ip.startsWith('100.'))?.ip || null;
        const lan = ips.find((x) => x.ip.startsWith('192.168.') || x.ip.startsWith('10.') || /^172\.(1[6-9]|2\d|3[01])\./.test(x.ip))?.ip || null;
        return send(200, { ok: true, value: { hostname: os.hostname(), ips, tailscale: ts, lan } });
      }

      if (url.pathname === '/events' && req.method === 'GET') {
        res.writeHead(200, {
          'Content-Type': 'text/event-stream; charset=utf-8',
          'Cache-Control': 'no-cache, no-transform',
          'Connection': 'keep-alive',
          'X-Accel-Buffering': 'no',
          ...allow,
        });
        res.write(': connected\n\n');
        sseClients.add(res);
        const ping = setInterval(() => { try { res.write(': ping\n\n'); } catch {} }, 25000);
        req.on('close', () => { clearInterval(ping); sseClients.delete(res); });
        return;
      }

      if (url.pathname === '/health') {
        const cdp = await getConn();
        const ok = await cdp.evaluate('1+1');
        return send(200, { ok: ok === 2 });
      }

      if (url.pathname === '/apis') {
        const cdp = await getConn();
        const apis = await cdp.evaluate(`(() => {
          const api = window.electronAPI || window.electron || window.wb;
          if (!api) return null;
          return Object.fromEntries(Object.entries(api).map(([k, v]) => [k, typeof v]));
        })()`);
        return send(200, { apis });
      }

      if (url.pathname === '/eval' && req.method === 'POST') {
        const body = await readBody(req);
        const { code } = JSON.parse(body || '{}');
        if (!code) return send(400, { error: 'code required' });
        const cdp = await getConn();
        const t0 = Date.now();
        const value = await cdp.evaluate(code);
        return send(200, { ok: true, value, ms: Date.now() - t0 });
      }

      if (url.pathname === '/call' && req.method === 'POST') {
        const body = await readBody(req);
        const { path, args = [] } = JSON.parse(body || '{}');
        if (!path) return send(400, { error: 'path required' });
        const expr = `(async () => {
          const segs = ${JSON.stringify(path)}.split('.');
          let parent = null, cur = window;
          for (const s of segs) { parent = cur; cur = cur?.[s]; }
          if (typeof cur !== 'function') throw new Error('not a function: ${path}');
          return await cur.apply(parent, ${JSON.stringify(args)});
        })()`;
        const cdp = await getConn();
        const value = await cdp.evaluate(expr);
        return send(200, { ok: true, value });
      }

      // ---- 语义化端点（推荐前端使用，避免前端拼 JS）----

      if (url.pathname === '/sessions' && req.method === 'GET') {
        const params = {
          space: url.searchParams.get('space') || 'local',
          kind: url.searchParams.get('kind') || 'task',
          view: url.searchParams.get('view') || 'active',
          page: Number(url.searchParams.get('page') || 1),
          size: Number(url.searchParams.get('size') || 50),
        };
        const cdp = await getConn();
        const value = await cdp.evaluate(`wb.conversations.list(${JSON.stringify(params)})`);
        return send(200, { ok: true, value });
      }

      if (url.pathname === '/spaces' && req.method === 'GET') {
        const cdp = await getConn();
        const value = await cdp.evaluate(`(async () => {
          const r = await wb.spaces.list();
          const arr = Array.isArray(r) ? r : (r?.items || r?.spaces || []);
          return arr.map(s => ({
            id: s.id, name: s.name, pinned: s.pinned, sortOrder: s.sortOrder,
            folder: s.createFolderPath || s.primaryFolderPath || '',
            total: s.totalCount, bound: s.boundSessionCount, status: s.status,
          }));
        })()`);
        return send(200, { ok: true, value });
      }

      if (url.pathname === '/models' && req.method === 'GET') {
        const cdp = await getConn();
        const value = await cdp.evaluate(`wb.invoke('wb:models:list')`);
        return send(200, { ok: true, value });
      }

      const mMsg = url.pathname.match(/^\/sessions\/([^/]+)\/messages$/);
      if (mMsg && req.method === 'GET') {
        const id = decodeURIComponent(mMsg[1]);
        const tail = Math.min(50, Math.max(1, Number(url.searchParams.get('tail') || 16)));
        const cdp = await getConn();
        // requestEntries 是增量读取，对正在生成的会话不会阻塞；
        // requests() 在流式期间会等本轮结束，实测直接挂死。
        const value = await Promise.race([
          cdp.evaluateFn(collectMessages, id, tail),
          new Promise((_, rej) => setTimeout(() => rej(new Error('会话正在生成，稍后刷新')), 4000)),
        ]);
        return send(200, { ok: true, value });
      }

      const mCfg = url.pathname.match(/^\/sessions\/([^/]+)\/config$/);
      if (mCfg && req.method === 'GET') {
        const id = decodeURIComponent(mCfg[1]);
        const cdp = await getConn();
        const value = await cdp.evaluate(`(async () => {
          const g = await wb.invoke('wb:conversations:get', ${JSON.stringify(id)});
          const c = g.configManager || {};
          return { model: c.model, mode: c.mode, permissionMode: c.permissionMode, thoughtLevel: c.thoughtLevel };
        })()`);
        return send(200, { ok: true, value });
      }

      const mModel = url.pathname.match(/^\/sessions\/([^/]+)\/model$/);
      if (mModel && req.method === 'POST') {
        const id = decodeURIComponent(mModel[1]);
        const body = JSON.parse((await readBody(req)) || '{}');
        if (!body.model) return send(400, { error: 'model required' });
        const cdp = await getConn();
        const value = await cdp.evaluate(`(async () => {
          await wb.invoke('wb:conversations:configSetModel', ${JSON.stringify(id)}, ${JSON.stringify(body.model)});
          const g = await wb.invoke('wb:conversations:get', ${JSON.stringify(id)});
          return { model: g.configManager?.model };
        })()`);
        return send(200, { ok: true, value });
      }

      const mCancel = url.pathname.match(/^\/sessions\/([^/]+)\/cancel$/);
      if (mCancel && req.method === 'POST') {
        const id = decodeURIComponent(mCancel[1]);
        const cdp = await getConn();
        const value = await cdp.evaluate(`(async () => {
          const c = await wb.conversations.get(${JSON.stringify(id)});
          try { return await c.cancel(); }
          catch (e) { return await c.cancelByUser(); }
        })()`);
        console.log('[messages] done', id);
        return send(200, { ok: true, value });
      }

      // 回答 AskUserQuestion 这类「等用户选」的交互。
      // 之前网页版完全没有这条通路，只能看到桌面端在等，网页上做不了任何操作。
      const mAnswer = url.pathname.match(/^\/sessions\/([^/]+)\/answer$/);
      if (mAnswer && req.method === 'POST') {
        const id = decodeURIComponent(mAnswer[1]);
        const body = JSON.parse((await readBody(req)) || '{}');
        const answers = body.answers == null ? body : body.answers;
        const payload = body.payload == null ? null : body.payload;
        const cdp = await getConn();
        const value = await cdp.evaluateFn(answerPending, id, answers, payload);
        return send(200, { ok: true, value });
      }

      // 排查用：列出会话里所有块类型与工具名
      const mProbe = url.pathname.match(/^\/sessions\/([^/]+)\/probe$/);
      if (mProbe && req.method === 'GET') {
        const id = decodeURIComponent(mProbe[1]);
        const cdp = await getConn();
        const value = await cdp.evaluateFn(probeTypes, id);
        return send(200, { ok: true, value });
      }

      const mSend = url.pathname.match(/^\/sessions\/([^/]+)\/send$/);
      if (mSend && req.method === 'POST') {
        const id = decodeURIComponent(mSend[1]);
        const body = JSON.parse((await readBody(req)) || '{}');
        const blocks = body.blocks || [{ type: 'text', text: String(body.text || '') }];
        if (!blocks.length) return send(400, { error: 'text or blocks required' });
        const opts = body.options || {};
        const cdp = await getConn();
        const value = await cdp.evaluate(`(async () => {
          const c = await wb.conversations.get(${JSON.stringify(id)});
          return await c.sendPrompt(${JSON.stringify(blocks)}, ${JSON.stringify(opts)});
        })()`);
        return send(200, { ok: true, value });
      }

      const mDel = url.pathname.match(/^\/sessions\/([^/]+)\/delete$/);
      if (mDel && req.method === 'POST') {
        const id = decodeURIComponent(mDel[1]);
        const cdp = await getConn();
        const value = await cdp.evaluate(`(async () => {
          try { return await wb.conversations.delete(${JSON.stringify(id)}); }
          catch (e1) {
            const c = await wb.conversations.get(${JSON.stringify(id)});
            if (typeof c.delete === 'function') return await c.delete();
            throw e1;
          }
        })()`);
        return send(200, { ok: true, value });
      }

      if (url.pathname === '/sessions' && req.method === 'POST') {
        const body = JSON.parse((await readBody(req)) || '{}');
        const opts = {};
        if (body.model) opts.model = body.model;
        if (body.cwd) opts.cwd = body.cwd;
        const cdp = await getConn();
        const value = await cdp.evaluate(`(async () => {
          const q = { space: 'local', kind: 'task', view: 'active', page: 1, size: 100 };
          const before = new Set(((await wb.conversations.list(q))?.items || []).map(i => i.id));
          const h = await wb.conversations.create(${JSON.stringify(opts)});
          let id = h && (h.id || h.conversationId);
          for (let i = 0; i < 10 && !id; i++) {
            await new Promise(r => setTimeout(r, 200));
            const items = ((await wb.conversations.list(q))?.items || []);
            const fresh = items.find(x => !before.has(x.id));
            if (fresh) id = fresh.id;
          }
          return { id: id || null };
        })()`);
        return send(200, { ok: true, value });
      }

      if (url.pathname === '/events' && req.method === 'GET') {
        const cdp = await getConn();
        const since = Number(url.searchParams.get('since') || 0);
        const value = await cdp.evaluate(`(() => {
          if (!window.__wbRemoteHooked) {
            window.__wbRemoteHooked = true;
            window.__wbRemoteEvents = [];
            window.__wbRemoteSeq = 0;
            try {
              wb.onAny((e) => {
                let safe;
                try { safe = JSON.parse(JSON.stringify(e)); } catch { safe = { type: String(e?.type || 'event') }; }
                window.__wbRemoteEvents.push({ seq: ++window.__wbRemoteSeq, t: Date.now(), e: safe });
                if (window.__wbRemoteEvents.length > 400) window.__wbRemoteEvents.splice(0, 200);
              });
            } catch (err) { return { hookError: String(err) }; }
          }
          const buf = window.__wbRemoteEvents || [];
          return { seq: window.__wbRemoteSeq || 0, items: buf.filter(x => x && x.seq > ${since}) };
        })()`);
        return send(200, { ok: true, value });
      }

      return send(404, { error: 'not found' });
    } catch (e) {
      // 连接已失效，下次请求会重建
      return send(500, { error: String(e.message || e) });
    }
  };

  const HOSTS = String(values.host || '127.0.0.1').split(',').map((h) => h.trim()).filter(Boolean);
  for (const h of HOSTS) {
    http.createServer(handler).listen(LISTEN, h, () => {
      console.log(`CDP 桥已监听: http://${h}:${LISTEN}`);
    });
  }
  console.log(`  GET  /health  健康检查`);
  console.log(`  GET  /spaces  空间分组`);
  console.log(`  GET  /preview/<绝对路径>  文件预览`);
  console.log(`  POST /call    {"path":"wb.conversations.list","args":[]}`);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let d = '';
    req.on('data', (c) => { d += c; if (d.length > 2.4e7) { req.destroy(); reject(new Error('body too large')); } });
    req.on('end', () => resolve(d));
    req.on('error', reject);
  });
}

if (values.probe) {
  probe().catch((e) => { console.error('probe 失败:', e.message); process.exit(1); });
} else {
  serve();
}
