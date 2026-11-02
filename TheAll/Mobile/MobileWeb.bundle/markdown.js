// A small, streaming-tolerant Markdown renderer. All model text enters the DOM
// through text nodes; raw HTML, executable URLs and arbitrary local files never do.
const fence = line => /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line);
const heading = line => /^ {0,3}(#{1,6})\s+(.+?)\s*#*\s*$/.exec(line);
const listItem = line => /^\s{0,3}([-+*]|\d+[.)])\s+(.+)$/.exec(line);
const rule = line => /^ {0,3}(?:\*\s*){3,}$|^ {0,3}(?:-\s*){3,}$|^ {0,3}(?:_\s*){3,}$/.test(line);

export function splitTableRow(line = '') {
  if (/^(?: {4}| {0,3}\t)/.test(line)) return null;
  const value = line.trim();
  if (value.startsWith('\\|') || !value.includes('|')) return null;
  const cells = []; let cell = '', ticks = 0;
  for (let i = 0; i < value.length; i++) {
    const char = value[i];
    if (char === '\\' && i + 1 < value.length) { cell += char + value[++i]; continue; }
    if (char === '`') {
      let end = i + 1; while (value[end] === '`') end++;
      const count = end - i;
      // An unmatched backtick is ordinary text, including in partial responses.
      if (!ticks && value.indexOf('`'.repeat(count), end) >= 0) ticks = count;
      else if (ticks === count) ticks = 0;
      cell += value.slice(i, end); i = end - 1; continue;
    }
    if (char === '|' && !ticks) { cells.push(cell.trim()); cell = ''; }
    else cell += char;
  }
  cells.push(cell.trim());
  if (value.startsWith('|')) cells.shift();
  if (value.endsWith('|') && cells.at(-1) === '') cells.pop();
  return cells.length ? cells : null;
}
function nextContent(lines, index) { while (index < lines.length && !lines[index].trim()) index++; return index; }
function tableAt(lines, index) {
  const headers = splitTableRow(lines[index]);
  if (!headers) return null;
  const separator = nextContent(lines, index + 1), cells = splitTableRow(lines[separator] || '');
  if (!cells || cells.length !== headers.length || !cells.every(cell => /^:?-{3,}:?$/.test(cell))) return null;
  const alignments = cells.map(cell => cell.endsWith(':') ? cell.startsWith(':') ? 'center' : 'right' : 'left');
  return { headers, alignments, next: separator + 1 };
}
function readCode(lines, start, opening) {
  const marker = opening[1], content = []; let index = start + 1;
  const close = new RegExp('^ {0,3}' + marker[0] + '{' + marker.length + ',}\\s*$');
  while (index < lines.length && !close.test(lines[index])) content.push(lines[index++]);
  const closed = index < lines.length;
  // A closing fence occupies a new line, so preserve that final newline too.
  const text = content.join('\n') + (closed && content.length ? '\n' : '');
  return { block: { type: 'code', language: opening[2].trim().split(/\s+/)[0], text }, next: index + Number(closed) };
}
function startsBlock(lines, index) {
  const line = lines[index];
  return !line.trim() || fence(line) || heading(line) || rule(line) || listItem(line) || /^ {0,3}>/.test(line) || tableAt(lines, index);
}
export function parseMarkdown(text) {
  const lines = String(text || '').replace(/\r\n?/g, '\n').split('\n'), blocks = [];
  let index = 0;
  while (index < lines.length) {
    const line = lines[index];
    if (!line.trim()) { index++; continue; }
    const opening = fence(line);
    if (opening) { const code = readCode(lines, index, opening); blocks.push(code.block); index = code.next; continue; }
    const table = tableAt(lines, index);
    if (table) {
      const rows = []; index = table.next;
      while (index < lines.length) {
        const next = nextContent(lines, index), cells = splitTableRow(lines[next] || '');
        // A blank gap may separate rows, but a new header/separator starts its own table.
        if (next > index && tableAt(lines, next)) break;
        if (!cells || cells.length > table.headers.length) break;
        rows.push([...cells, ...Array(table.headers.length - cells.length).fill('')]); index = next + 1;
      }
      blocks.push({ type: 'table', headers: table.headers, alignments: table.alignments, rows }); continue;
    }
    const title = heading(line);
    if (title) { blocks.push({ type:'heading', level:title[1].length, text:title[2] }); index++; continue; }
    if (rule(line)) { blocks.push({ type:'rule' }); index++; continue; }
    const item = listItem(line);
    if (item) {
      const ordered = /^\d/.test(item[1]), items = []; const start = ordered ? parseInt(item[1], 10) : 1;
      while (index < lines.length) {
        const entry = listItem(lines[index]); if (!entry || /^\d/.test(entry[1]) !== ordered) break;
        items.push(entry[2]); index++;
      }
      blocks.push({ type:'list', ordered, start, items }); continue;
    }
    if (/^ {0,3}>/.test(line)) {
      const quote = []; while (index < lines.length && /^ {0,3}>/.test(lines[index])) quote.push(lines[index++].replace(/^ {0,3}> ?/, ''));
      blocks.push({ type:'quote', text:quote.join('\n') }); continue;
    }
    const paragraph = [line]; index++;
    while (index < lines.length && !startsBlock(lines, index)) paragraph.push(lines[index++]);
    blocks.push({ type:'paragraph', text:paragraph.join('\n') });
  }
  return blocks;
}
export function safeMarkdownLink(value) {
  if (typeof value !== 'string' || !/^https?:\/\//i.test(value) || /[\x00-\x20\x7f]/.test(value)) return null;
  try { const url = new URL(value); return url.username || url.password ? null : url.href; } catch { return null; }
}
export function safeMarkdownImage(value, chatID) {
  if (typeof value !== 'string') return null;
  if (value.length <= 8 * 1024 * 1024 && /^data:image\/(?:png|jpeg|gif|webp);base64,[A-Za-z0-9+/]+={0,2}$/.test(value)) return value;
  const prefix = '/api/chats/' + encodeURIComponent(chatID || '') + '/images/';
  return chatID && value.startsWith(prefix) && /^[0-9a-f-]{36}$/i.test(value.slice(prefix.length)) ? value : null;
}
function element(tag, className, text) {
  const node = document.createElement(tag); if (className) node.className = className;
  if (text !== undefined) node.textContent = text; return node;
}
function linkNode(label, url) {
  const node = element('a', '', label); node.href = url; node.target = '_blank'; node.rel = 'noopener noreferrer'; node.referrerPolicy = 'no-referrer'; return node;
}
function imageNode(alt, source, options) {
  const safe = safeMarkdownImage(source, options.chatID);
  if (!safe) {
    const url = safeMarkdownLink(source);
    return url ? linkNode(`${alt || options.t('markdownOpenImage')} ↗`, url) : element('span', 'muted', alt || options.t('photosUnavailable'));
  }
  const wrapper = element('span', 'markdown-image');
  const button = element('button', 'markdown-image-open'); button.type = 'button'; button.ariaLabel = options.t('photosPreview') + (alt ? ': ' + alt : '');
  const image = element('img'); image.alt = alt; image.loading = 'lazy'; image.decoding = 'async'; image.src = safe;
  image.onerror = () => { button.replaceChildren(document.createTextNode(options.t('photosUnavailable'))); button.disabled = true; };
  button.append(image); button.onclick = () => options.openImage?.(safe, alt);
  wrapper.append(button); if (alt) wrapper.append(element('span', 'markdown-caption', alt)); return wrapper;
}
// Delimiters are intentionally conservative: unsupported Markdown remains visible.
// Code tokens win before emphasis/links, so code is never interpreted a second time.
function appendInline(parent, text, options, depth = 0) {
  if (depth > 8) { parent.append(document.createTextNode(text)); return; }
  const token = /\\([\\`*{}\[\]()#+\-.!_|>~])|(`+)([\s\S]*?)\2(?!`)|(!?)\[([^\]\n]*)\]\((<[^<>\n]+>|[^\s()]+(?:\([^\s()]*\)[^\s()]*)*)(?:\s+"[^"]*")?\)|(\*\*|__)(?=\S)([\s\S]*?\S)\7|(\*|_)(?=\S)([^\n]*?\S)\9|https?:\/\/[^\s<>]+/g;
  let cursor = 0;
  for (const match of text.matchAll(token)) {
    parent.append(document.createTextNode(text.slice(cursor, match.index))); cursor = match.index + match[0].length;
    if (match[1]) { parent.append(document.createTextNode(match[1])); continue; }
    if (match[2]) { parent.append(element('code', 'inline-code', match[3].replace(/\n/g, ' '))); continue; }
    if (match[5] !== undefined) {
      const source = match[6].replace(/^<|>$/g, '');
      if (match[4]) { parent.append(imageNode(match[5], source, options)); continue; }
      const url = safeMarkdownLink(source);
      if (url) { const node = linkNode('', url); appendInline(node, match[5], options, depth + 1); parent.append(node); }
      else parent.append(document.createTextNode(match[5]));
      continue;
    }
    if (match[7] || match[9]) {
      const node = element(match[7] ? 'strong' : 'em'); appendInline(node, match[8] || match[10], options, depth + 1); parent.append(node); continue;
    }
    const raw = match[0], trimmed = raw.replace(/[.,;!?]+$/, ''), url = safeMarkdownLink(trimmed);
    parent.append(url ? linkNode(trimmed, url) : document.createTextNode(trimmed));
    parent.append(document.createTextNode(raw.slice(trimmed.length)));
  }
  parent.append(document.createTextNode(text.slice(cursor)));
}
async function copyText(text) {
  if (globalThis.isSecureContext && navigator.clipboard?.writeText) {
    try { await navigator.clipboard.writeText(text); return; } catch { /* LAN and denied clipboard use selection fallback. */ }
  }
  const active = document.activeElement, selection = getSelection(), ranges = [];
  for (let i = 0; i < (selection?.rangeCount || 0); i++) ranges.push(selection.getRangeAt(i).cloneRange());
  const field = element('textarea', 'markdown-copy-buffer'); field.value = text; field.readOnly = true; document.body.append(field);
  try { field.select(); if (!document.execCommand('copy')) throw new Error('Copy unavailable'); }
  finally { field.remove(); active?.focus({ preventScroll:true }); selection?.removeAllRanges(); for (const range of ranges) selection?.addRange(range); }
}
function codeNode(block, options) {
  const card = element('section', 'markdown-code'), bar = element('div', 'markdown-code-bar');
  bar.append(element('span', '', block.language || options.t('markdownCode')));
  const button = element('button', 'markdown-copy', options.t('markdownCopy')); button.type = 'button';
  const status = element('span', 'markdown-copy-status'); status.setAttribute('role', 'status');
  button.onclick = async () => {
    try { await copyText(block.text); status.textContent = options.t('markdownCopied'); }
    catch { status.textContent = options.t('markdownCopyFailed'); }
    setTimeout(() => { status.textContent = ''; }, 2500);
  };
  bar.append(status, button);
  const pre = element('pre'); pre.tabIndex = 0; pre.setAttribute('aria-label', block.language || options.t('markdownCode'));
  pre.append(element('code', '', block.text)); card.append(bar, pre); return card;
}
function tableNode(block, options) {
  const wrapper = element('div', 'markdown-table-scroll'); wrapper.tabIndex = 0; wrapper.setAttribute('role', 'region'); wrapper.setAttribute('aria-label', options.t('markdownTable'));
  const table = element('table'), head = element('thead'), body = element('tbody');
  function row(cells, header) {
    const tr = element('tr'); cells.forEach((value, index) => {
      const cell = element(header ? 'th' : 'td', 'align-' + block.alignments[index]); if (header) cell.scope = 'col';
      appendInline(cell, value, options); tr.append(cell);
    }); return tr;
  }
  head.append(row(block.headers, true)); for (const cells of block.rows) body.append(row(cells, false));
  table.append(head, body); wrapper.append(table); return wrapper;
}
export function renderMarkdown(parent, text, options) {
  parent.classList.add('markdown-body');
  for (const block of parseMarkdown(text)) {
    if (block.type === 'code') { parent.append(codeNode(block, options)); continue; }
    if (block.type === 'table') { parent.append(tableNode(block, options)); continue; }
    if (block.type === 'rule') { parent.append(element('hr')); continue; }
    if (block.type === 'list') {
      const list = element(block.ordered ? 'ol' : 'ul'); if (block.ordered) list.start = block.start;
      for (const item of block.items) { const li = element('li'); appendInline(li, item, options); list.append(li); }
      parent.append(list); continue;
    }
    const node = element(block.type === 'heading' ? 'h' + Math.min(6, block.level + 1) : block.type === 'quote' ? 'blockquote' : 'p');
    appendInline(node, block.text, options); parent.append(node);
  }
}
