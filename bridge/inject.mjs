/**
 * 在 WorkBuddy 渲染进程里执行的采集逻辑。
 *
 * 这些函数不在这里直接运行 —— bridge 会把它们的源码
 * （通过 Function.prototype.toString）送进浏览器执行。
 * 所以：
 *   1. 函数体内**不能**引用外部变量，参数必须显式传入；
 *   2. 不要写模板字符串或复杂转义 —— 之前就是因为 join('\n') 写在
 *      模板字符串里，被求值成真换行，把注入代码截断，导致 /messages 500。
 */

export function collectMessages(id, tail) {
  return (async () => {
    const c = await wb.conversations.get(id);
    const r = await c.requestEntries({ byteLength: 131072, resultScope: 'page' });
    const all = Array.isArray(r.requests) ? r.requests : (r.requests && r.requests.items) || [];

    const clip = (s, n) => String(s == null ? '' : s).slice(0, n);
    const baseName = (p) => {
      const parts = String(p || '').split('/');
      return parts[parts.length - 1] || '';
    };

    const pickImage = (b) => {
      const mt = b._meta || {};
      return {
        type: 'image',
        filename: mt.filename || mt.fileName || mt.originalFilename || baseName(mt.filePath),
        filePath: mt.filePath || '',
        mimeType: b.mimeType || 'image/png',
      };
    };

    // ── 工具调用 ──
    const trimTool = (b) => {
      const inp = b.rawInput || {};
      const name = b.toolName || b.title || 'tool';

      // AskUserQuestion：问题与选项全在 rawInput.questions 里。
      // 老逻辑只取 file_path/command 之类单值字段，这类工具取不到，
      // 网页上就只剩一行空白的「工具」，用户看不到在问什么。
      if (name === 'AskUserQuestion' && Array.isArray(inp.questions)) {
        return {
          type: 'tool',
          name: name,
          status: b.status,
          kind: 'question',
          questions: inp.questions.map((q) => ({
            question: clip(q.question, 2000),
            header: clip(q.header, 80),
            multiSelect: !!q.multiSelect,
            options: (q.options || []).map((o) => ({
              label: clip(o.label, 200),
              description: clip(o.description, 500),
            })),
          })),
          answer: (() => {
            const ro = b.rawOutput;
            let t = '';
            if (Array.isArray(ro)) t = (ro[0] && ro[0].text) || '';
            else if (ro && typeof ro === 'object') t = ro.text || '';
            return clip(t, 2000);
          })(),
        };
      }

      // present_files：不显示文件名的话同样是一片空白
      if (name === 'present_files' && Array.isArray(inp.files)) {
        return {
          type: 'tool',
          name: name,
          status: b.status,
          detail: clip(inp.explanation, 60),
          files: inp.files.map(baseName),
        };
      }

      const pick = inp.file_path || inp.path || inp.command || inp.pattern || inp.query || '';
      return {
        type: 'tool',
        name: name,
        detail: clip(baseName(pick).replace(/\s+/g, ' '), 48),
        status: b.status,
      };
    };

    // ── 单块裁剪 ──
    const trim = (b) => {
      if (!b) return null;
      if (b.type === 'text' || b.type === 'reasoning') {
        return { type: b.type, text: clip(b.text, 6000) };
      }
      // 排队时追加的引导语，之前整块被丢掉 → 用户以为消息没发出去。
      // 纯图片的消息 text 是空串，内容全在 blocks 里，所以两样都取。
      if (b.type === 'queue-guidance') {
        const bs = Array.isArray(b.blocks) ? b.blocks : [];
        const texts = bs
          .filter((x) => x && x.type === 'text')
          .map((x) => x.text || '')
          .join('\n');
        return {
          type: 'queue-guidance',
          text: clip(b.text || texts, 4000),
          images: bs.filter((x) => x && x.type === 'image').map(pickImage),
          status: b.status,
          queueItemId: b.queueItemId,
          timestamp: b.timestamp,
        };
      }
      if (b.type === 'tool') return trimTool(b);
      if (b.type === 'image') return pickImage(b);
      return { type: b.type };
    };

    const items = all.slice(-tail).map((req) => ({
      id: req.id,
      timestamp: req.timestamp,
      finishTimestamp: req.finishTimestamp,
      state: req.state,
      userMessage: {
        // 之前 .filter(text) 会把带图片的消息过滤成空数组，
        // 那条消息在网页上就整块消失
        content: (req.userMessage && req.userMessage.content ? req.userMessage.content : [])
          .map((b) => {
            if (!b) return null;
            if (b.type === 'text') return { type: 'text', text: clip(b.text, 6000) };
            if (b.type === 'image') return pickImage(b);
            return null;
          })
          .filter(Boolean),
      },
      assistantMessage: {
        content: (req.assistantMessage && req.assistantMessage.content ? req.assistantMessage.content : [])
          .map(trim)
          .filter(Boolean),
      },
    }));

    return {
      items: items,
      total: r.totalRequests,
      loaded: all.length,
      tail: tail,
      hasOlder: r.hasOlder,
    };
  })();
}

/**
 * 回答 AskUserQuestion。依次尝试三条已知通路。
 */
export function answerPending(id, answers, payload) {
  return (async () => {
    const c = await wb.conversations.get(id);
    let lastErr = '';
    const tries = [];
    if (typeof c.resolvePending === 'function') {
      tries.push(['resolvePending', () => c.resolvePending(answers)]);
    }
    if (typeof c.answerPoiQuestion === 'function') {
      tries.push(['answerPoiQuestion', () => c.answerPoiQuestion(payload == null ? answers : payload)]);
    }
    for (const pair of tries) {
      const label = pair[0];
      const fn = pair[1];
      try {
        const res = await fn();
        return { via: label, result: res === undefined ? null : res };
      } catch (e) {
        lastErr = label + ': ' + String(e);
      }
    }
    throw new Error(lastErr || '该会话当前没有待回答的交互');
  })();
}

/**
 * 探针：列出所有块类型与工具名，排查用。
 */
export function probeTypes(id) {
  return (async () => {
    const c = await wb.conversations.get(id);
    const r = await c.requestEntries({ byteLength: 131072, resultScope: 'page' });
    const all = Array.isArray(r.requests) ? r.requests : (r.requests && r.requests.items) || [];
    const types = {};
    for (const req of all) {
      for (const b of (req.assistantMessage && req.assistantMessage.content) || []) {
        const k = 'a:' + b.type + (b.toolName ? '/' + b.toolName : '');
        types[k] = (types[k] || 0) + 1;
      }
      for (const b of (req.userMessage && req.userMessage.content) || []) {
        const k = 'u:' + b.type;
        types[k] = (types[k] || 0) + 1;
      }
    }
    return types;
  })();
}
/**
 * 读会话的待发送队列（WorkBuddy 自己的 queueManager）。
 *
 * 这就是桌面端「排队选项卡」的数据源 —— 消息经 sendPrompt 交给 WorkBuddy
 * 后由它内部串行排队，这里只是把同一份队列读出来给网页端渲染。
 * 网页端不再自己维护队列，所以两边永远一致。
 */
export function readQueue(id) {
  return (async () => {
    const c = await wb.conversations.get(id);
    const q = c.queueManager;
    // 没有 queueManager（老版本 / 非 task 会话）→ 当成空队列，不要报错
    if (!q || typeof q.items !== 'function') {
      return { items: [], paused: false, supported: false };
    }
    let raw = [];
    try {
      raw = q.items() || [];
    } catch (e) {
      return { items: [], paused: false, supported: false };
    }
    const items = raw.map((it) => {
      const blocks = Array.isArray(it.content) ? it.content : [];
      return {
        id: it.id,
        seq: it.acceptedSequence,
        at: it.acceptedAt,
        blocks: blocks.map((b) => {
          if (b.type === 'text') return { type: 'text', text: String(b.text || '') };
          if (b.type === 'image') {
            return {
              type: 'image',
              mimeType: b.mimeType || '',
              name: (b._meta && b._meta.filename) || '',
            };
          }
          return { type: b.type || 'unknown' };
        }),
      };
    });
    let paused = false;
    try {
      paused = !!q.paused;
    } catch (e) {}
    return { items, paused, supported: true };
  })();
}

/**
 * 操作队列：move / delete / sendNow / pause / resume。
 * 直接在 WorkBuddy 的 queueManager 上调用，桌面端会同步变化。
 */
export function mutateQueue(id, op, itemId, index) {
  return (async () => {
    const c = await wb.conversations.get(id);
    const q = c.queueManager;
    if (!q) throw new Error('该会话不支持队列操作');
    if (op === 'move') await q.move(itemId, index);
    else if (op === 'delete') await q.delete(itemId);
    else if (op === 'sendNow') await q.sendNow(itemId);
    else if (op === 'pause') await q.pause(itemId);
    else if (op === 'resume') await q.resume();
    else throw new Error('未知队列操作: ' + op);
    // 队列变更是异步落到后端的，等一下再读，避免读到旧快照
    await new Promise((r) => setTimeout(r, 180));
    return { ok: true };
  })();
}
