/* 轻量 Markdown 渲染器：无依赖，先转义再替换，输出可信 HTML */
(function (global) {
  const esc = (s) =>
    s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

  function inline(text) {
    let s = text;
    s = s.replace(/`([^`\n]+)`/g, (_, c) => `<code>${c}</code>`);
    s = s.replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
    s = s.replace(/__([^_\n]+)__/g, '<strong>$1</strong>');
    s = s.replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<em>$2</em>');
    s = s.replace(/(^|[^_])_([^_\n]+)_/g, '$1<em>$2</em>');
    s = s.replace(/~~([^~\n]+)~~/g, '<del>$1</del>');
    s = s.replace(/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>');
    s = s.replace(/(^|\s)(https?:\/\/[^\s<]+)/g, (m, p, u) => `${p}<a href="${u}" target="_blank" rel="noopener noreferrer">${u}</a>`);
    return s;
  }

  function render(src) {
    if (!src) return '';
    const lines = String(src).replace(/\r\n/g, '\n').split('\n');
    const out = [];
    let i = 0;

    const flushParagraph = (buf) => {
      if (buf.length) out.push(`<p>${inline(buf.join('<br>'))}</p>`);
      buf.length = 0;
    };

    const para = [];

    while (i < lines.length) {
      const line = lines[i];

      // 围栏代码块
      const fence = line.match(/^\s*```(\w*)\s*$/);
      if (fence) {
        flushParagraph(para);
        const lang = fence[1];
        const body = [];
        i++;
        while (i < lines.length && !/^\s*```\s*$/.test(lines[i])) body.push(lines[i++]);
        i++;
        out.push(
          `<pre class="md-pre"${lang ? ` data-lang="${esc(lang)}"` : ''}><code>${esc(body.join('\n'))}</code></pre>`
        );
        continue;
      }

      // 标题
      const h = line.match(/^(#{1,6})\s+(.*)$/);
      if (h) {
        flushParagraph(para);
        const lv = Math.min(h[1].length + 2, 6);
        out.push(`<h${lv}>${inline(esc(h[2]))}</h${lv}>`);
        i++;
        continue;
      }

      // 分隔线
      if (/^\s*([-*_])\1{2,}\s*$/.test(line)) {
        flushParagraph(para);
        out.push('<hr>');
        i++;
        continue;
      }

      // 引用
      if (/^\s*>\s?/.test(line)) {
        flushParagraph(para);
        const body = [];
        while (i < lines.length && /^\s*>\s?/.test(lines[i])) body.push(lines[i++].replace(/^\s*>\s?/, ''));
        out.push(`<blockquote>${render(body.join('\n'))}</blockquote>`);
        continue;
      }

      // 表格
      if (/^\s*\|.*\|\s*$/.test(line) && i + 1 < lines.length && /^\s*\|[\s:|-]+\|\s*$/.test(lines[i + 1])) {
        flushParagraph(para);
        const parseRow = (r) =>
          r.trim().replace(/^\||\|$/g, '').split('|').map((c) => c.trim());
        const head = parseRow(lines[i]);
        i += 2;
        const rows = [];
        while (i < lines.length && /^\s*\|.*\|\s*$/.test(lines[i])) rows.push(parseRow(lines[i++]));
        out.push(
          `<div class="md-table"><table><thead><tr>${head
            .map((c) => `<th>${inline(esc(c))}</th>`)
            .join('')}</tr></thead><tbody>${rows
            .map((r) => `<tr>${r.map((c) => `<td>${inline(esc(c))}</td>`).join('')}</tr>`)
            .join('')}</tbody></table></div>`
        );
        continue;
      }

      // 列表
      const ul = line.match(/^\s*[-*+]\s+(.*)$/);
      const ol = line.match(/^\s*(\d+)[.)]\s+(.*)$/);
      if (ul || ol) {
        flushParagraph(para);
        const ordered = !!ol;
        const items = [];
        while (i < lines.length) {
          const m = ordered ? lines[i].match(/^\s*(\d+)[.)]\s+(.*)$/) : lines[i].match(/^\s*[-*+]\s+(.*)$/);
          if (!m) break;
          items.push(ordered ? m[2] : m[1]);
          i++;
        }
        const tag = ordered ? 'ol' : 'ul';
        out.push(`<${tag}>${items.map((t) => `<li>${inline(esc(t))}</li>`).join('')}</${tag}>`);
        continue;
      }

      // 空行
      if (!line.trim()) {
        flushParagraph(para);
        i++;
        continue;
      }

      para.push(esc(line));
      i++;
    }
    flushParagraph(para);
    return out.join('\n');
  }

  global.md = { render };
})(window);
