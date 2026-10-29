// Optional integration smoke test. Uses an isolated headless Chrome profile and a local mock Mac API.
// Run: node mobile-tests/browser-smoke.mjs
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { readFile, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { tmpdir, networkInterfaces } from 'node:os';
import { join, extname } from 'node:path';
import assert from 'node:assert/strict';
const root = new URL('../TheAll/Mobile/MobileWeb.bundle/', import.meta.url);
const temporary = await mkdtemp(join(tmpdir(), 'theall-mobile-smoke-'));
const chrome = process.env.CHROME_BIN || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
let browser, socket;
const lanMode = process.env.MOBILE_TEST_LAN === '1';
const privateIPv4 = value => /^(?:10\.|192\.168\.|172\.(?:1[6-9]|2[0-9]|3[01])\.)/.test(value);
const bindAddress = lanMode ? Object.values(networkInterfaces()).flat().find(address => address?.family === 'IPv4' && !address.internal && privateIPv4(address.address))?.address : '127.0.0.1';
if (!bindAddress) throw new Error('MOBILE_TEST_LAN requires an active RFC1918 IPv4 interface; do not simulate a secure localhost origin.');
const cookieName = lanMode ? 'TheAllLANSession' : 'TheAllMobileSession';
let paired = false, unknown = true, macOnline = true, pairRequests = 0;
let invitation = 'one-time-token', sessionToken = '', nextSessionDelay = 0;
const creations = [];
const hasSession = req => paired && (req.headers.cookie || '').split(';').some(part => part.trim() === `${cookieName}=${sessionToken}`);
let sessionProbes = 0, workspaceReads = 0, eventConnections = 0, bootID = 'boot-1';
let access = { workspaceId: null, writable: true };
const notificationChat = 'F8D37844-CC8D-45F7-B56A-363E156FA233';
let includeNotificationChat = false, notificationReads = 0;
const rejectedNotificationChat = 'ed942fc9-7358-415d-bdc2-71c2e0977b99';
let unauthorizedNotificationReads = 0;
let rejectEvents = false; const eventSockets = new Set();
function wsSend(socket, message) {
  const data = Buffer.from(JSON.stringify(message)); const header = Buffer.alloc(data.length < 126 ? 2 : 4);
  header[0] = 0x81; header[1] = data.length < 126 ? data.length : 126; if (data.length >= 126) header.writeUInt16BE(data.length, 2);
  socket.write(Buffer.concat([header, data]));
}
function push(message = { type: 'changed', bootID }) { for (const socket of eventSockets) wsSend(socket, message); }
const screenshotPath = process.env.SCREENSHOT_PATH || join(tmpdir(), 'theall-mobile-preview.png');
let running = false, steerReady = true, rejectSteer = false, unknownSteer = false, interruptCount = 0;
const steers = [];
const requests = []; let rejectFileSend = false; const uploadedFiles = new Map();
const all = Array.from({ length: 122 }, (_, n) => ({ id: `m${n}`, role: n % 2 ? 'assistant' : 'user', text: `Historical message ${n}`, isIntermediate: false }));
all.push({ id: 'u', role: 'user', text: '查看当前项目的状态，并运行测试。' }, { id: 'p', role: 'assistant', isIntermediate: true, text: '正在检查工作目录与提交状态。' }, { id: 'a', role: 'assistant', completedAt: '2026-10-28T00:01:02.123Z', durationMs: 65432, completionStatus: 'completed', reasoningEffort: 'high', reasoningEffortVerified: true, text: '检查已完成，所有测试通过。\n\n```sh\nnpm test\n```\nhttps://example.com\n<script>alert("xss")</script>' });
const server = createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const json = (status, body, headers = {}) => { res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', ...headers }); res.end(JSON.stringify(body)); };
  if (url.pathname.startsWith('/api/')) {
    let raw = ''; for await (const chunk of req) raw += chunk;
    const body = raw ? JSON.parse(raw) : null;
    if (url.pathname === '/api/session') {
      sessionProbes++;
      const status = !macOnline ? 503 : hasSession(req) ? 200 : 401;
      const value = !macOnline ? { error: 'Mac offline' } : hasSession(req) ? { deviceName: 'Test phone', bootID, access } : { error: 'Pair first' };
      const delay = nextSessionDelay; nextSessionDelay = 0;
      if (delay) await new Promise(resolve => setTimeout(resolve, delay));
      return json(status, value);
    }
    if (url.pathname === '/api/pair') {
      pairRequests++; assert.equal(req.headers['x-theall-client'], '1');
      assert.equal(req.headers.origin, `http://${bindAddress}:${port}`);
      if (!invitation || body.token !== invitation) return json(401, { error: 'Pairing code expired. Scan a new code on your Mac.' });
      invitation = ''; paired = true; sessionToken = `session-${pairRequests}`;
      return json(200, { deviceName: body.deviceName, bootID, access }, { 'Set-Cookie': `${cookieName}=${sessionToken}; Path=/; HttpOnly; SameSite=Strict; Max-Age=300${lanMode ? '' : '; Secure'}` });
    }
    if (url.pathname === '/api/logout') { paired = false; return json(200, {}, { 'Set-Cookie': `${cookieName}=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0${lanMode ? '' : '; Secure'}` }); }
    if (!hasSession(req)) return json(401, { error: 'Pair first' });
    if (url.pathname === '/api/chats') { creations.push(body); return json(200, { id: 'd' }); }
    if (url.pathname === '/api/workspaces') { workspaceReads++; return json(200, { bootID, access, workspaces: [{ id: 'w', name: 'Project Atlas', conversations: [{ id: 'c', title: '检查项目状态', directory: '/Users/you/Projects/atlas', provider: 'claude', model: 'claude-sonnet', status: 'idle', messageCount: all.length }, { id: 'd', title: 'Another conversation', directory: '/Users/you/Projects/atlas', provider: 'openai', status: 'idle', messageCount: 0 }, ...(includeNotificationChat ? [{ id: notificationChat, title: 'Notification target', provider: 'claude', status: 'idle', messageCount: 0 }] : [])] }].filter(w => !access.workspaceId || w.id === access.workspaceId) }); }
    if (url.pathname === '/api/chats/' + rejectedNotificationChat) { unauthorizedNotificationReads++; return json(403, { error: 'Forbidden' }); }
    if (url.pathname === '/api/chats/' + notificationChat) { notificationReads++; return json(200, { id: notificationChat, bootID, access, provider: 'claude', model: '', messages: [], start: 0, total: 0, canResume: true, isBusy: false, models: [] }); }
    if (url.pathname.startsWith('/api/chats/c/files/')) {
      const file = uploadedFiles.get(url.pathname.split('/').pop()); if (!file) return json(404, {});
      res.writeHead(200, {'Content-Type':'application/octet-stream','Content-Disposition':'attachment','X-Content-Type-Options':'nosniff'}); return res.end(Buffer.from(file.data,'base64'));
    }
    if (url.pathname === '/api/chats/c/steer') {
      assert.equal(req.headers['x-theall-client'], '1'); steers.push(body);
      assert.equal(body.steerToken, 'task-1'); assert.equal(body.model, undefined); assert.equal(body.reasoningEffort, undefined);
      if (!running || !steerReady || rejectSteer) { rejectSteer = false; return json(409, { error: 'The task no longer accepts instructions.' }); }
      if (unknownSteer) { unknownSteer = false; return json(503, { code: 'outcome_unknown', error: 'Steer acknowledgement lost' }); }
      all.push({id:'steer-applied',role:'user',text:body.text,isSteering:true});
      return json(200, { id: 'c' });
    }
    if (url.pathname === '/api/chats/c/interrupt') { interruptCount++; running = false; return json(200, { id: 'c' }); }
    if (url.pathname === '/api/chats/c/send') {
      assert.equal(req.headers['x-theall-client'], '1'); requests.push(body);
      if (unknown) { unknown = false; all.push({ id: 'sent', role: 'user', text: body.text }); return json(503, { code: 'outcome_unknown', error: 'Mac acknowledgement was lost' }); }
      if (rejectFileSend) { rejectFileSend = false; return json(409, {error:'File fixture rejected once'}); }
      if (body.files?.length) {
        const files=body.files.map((file,index)=>{const id='00000000-0000-4000-8000-'+String(index+1).padStart(12,'0');uploadedFiles.set(id,file);return {id,name:file.name,byteCount:Buffer.from(file.data,'base64').length,mimeType:'application/octet-stream'};});
        all.push({id:'file-message',role:'user',text:body.text,files});
      }
      return json(200, { id: 'c' });
    }
    if (['/api/chats/c', '/api/chats/d'].includes(url.pathname)) {
      const messages = url.pathname.endsWith('/c') ? all : [];
      const end = Math.min(Number(url.searchParams.get('before') ?? messages.length), messages.length);
      const start = Math.max(0, end - 100);
      return json(200, { id: url.pathname.endsWith('/c') ? 'c' : 'd', bootID, access, provider: 'claude', model: 'claude-sonnet', directory: '/Users/you/Projects/atlas', messages: messages.slice(start, end), start, total: messages.length, isReady: running, canResume: !running, isBusy: running, canSteer: access.writable && running && steerReady, steerToken: running ? 'task-1' : null, canInterrupt: running, questions: url.pathname.endsWith('/d') ? [{ id: 'qg', title: 'Pick an option', questions: [{ id: 'q', prompt: 'Which task?', options: ['Build', 'Test'], multiple: true, secret: false }] }] : [], defaultModel: 'claude-sonnet', reasoningEffort: '', models: [{ id: 'claude-sonnet', title: 'Claude Sonnet', reasoningEfforts: ['low', 'high'], defaultReasoningEffort: 'high' }, { id: 'no-reasoning', title: 'No effort support' }] });
    }
    return json(404, { error: 'Unknown test endpoint' });
  }
  const path = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
  if (path.includes('..')) { res.writeHead(404); return res.end(); }
  try {
    const file = await readFile(new URL(path, root));
    const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.webmanifest': 'application/manifest+json', '.png': 'image/png' };
    res.writeHead(200, { 'Content-Type': mime[extname(path)] || 'application/octet-stream', 'Content-Security-Policy': "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'" }); res.end(file);
  } catch { res.writeHead(404); res.end(); }
});
// Minimal RFC 6455 fixture: real browser upgrade, masked JSON ping and close handling.
server.on('upgrade', (req, socket) => {
  if (req.url !== '/api/events' || !hasSession(req) || !macOnline || rejectEvents) { socket.end('HTTP/1.1 503 Service Unavailable\r\n\r\n'); return; }
  assert.equal(new URL(req.url, 'http://localhost').search, '');
  const accept = createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  eventSockets.add(socket); eventConnections++; let buffered = Buffer.alloc(0);
  socket.on('error', () => {}); socket.on('close', () => eventSockets.delete(socket));
  socket.on('data', chunk => {
    buffered = Buffer.concat([buffered, chunk]);
    while (buffered.length >= 6) {
      const opcode = buffered[0] & 15; let length = buffered[1] & 127, offset = 2;
      if (length === 126) { if (buffered.length < 8) return; length = buffered.readUInt16BE(2); offset = 4; }
      if (length === 127 || !(buffered[1] & 128)) { socket.destroy(); return; }
      if (buffered.length < offset + 4 + length) return;
      const mask = buffered.subarray(offset, offset + 4); offset += 4;
      const body = Buffer.from(buffered.subarray(offset, offset + length));
      for (let i = 0; i < body.length; i++) body[i] ^= mask[i % 4];
      buffered = buffered.subarray(offset + length);
      if (opcode === 8) { socket.end(Buffer.from([0x88, 0])); return; }
      if (opcode === 1 && JSON.parse(body).type === 'ping') wsSend(socket, { type: 'pong' });
    }
  });
  wsSend(socket, { type: 'hello', bootID, access });
});
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(check, description) {
  for (let i = 0; i < 120; i++) { if (await check()) return; await pause(100); }
  throw new Error(`Timed out: ${description}; eventConnections=${eventConnections}`);
}
await new Promise(resolve => server.listen(0, bindAddress, resolve));
const port = server.address().port;
try {
  browser = spawn(chrome, ['--headless=new', `--user-data-dir=${temporary}`, '--remote-debugging-port=0', '--no-first-run', '--no-default-browser-check', '--disable-background-networking', 'about:blank'], { stdio: 'ignore' });
  let debugPort;
  await until(async () => { try { debugPort = Number((await readFile(join(temporary, 'DevToolsActivePort'), 'utf8')).split('\n')[0]); return !!debugPort; } catch { return false; } }, 'Chrome startup');
  const targets = await (await fetch(`http://127.0.0.1:${debugPort}/json/list`)).json();
  socket = new WebSocket(targets.find(t => t.type === 'page').webSocketDebuggerUrl);
  await new Promise(resolve => socket.addEventListener('open', resolve, { once: true }));
  let sequence = 0; const callbacks = new Map(); const exceptions = [];
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (message.id) { const cb = callbacks.get(message.id); callbacks.delete(message.id); message.error ? cb.reject(message.error) : cb.resolve(message.result); }
    if (message.method === 'Runtime.exceptionThrown') exceptions.push(message.params.exceptionDetails.text);
  });
  const call = (method, params = {}) => new Promise((resolve, reject) => { const id = ++sequence; callbacks.set(id, { resolve, reject }); socket.send(JSON.stringify({ id, method, params })); });
  const evaluate = async expression => { const value = await call('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true }); if (value.exceptionDetails) throw Error(value.exceptionDetails.text); return value.result.value; };
  await call('Runtime.enable'); await call('Page.enable');
  await call('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  await call('Page.navigate', { url: `http://${bindAddress}:${port}/#pair=one-time-token` });

  await until(() => evaluate('document.querySelectorAll(".conversation").length === 2'), 'automatic QR pairing without a button click');
  assert.equal(pairRequests, 1, 'scanned invitation is submitted once');
  assert.equal(await evaluate('location.hash'), '');
  assert.equal(await evaluate('document.cookie'), '', 'session cookie is HttpOnly');
  assert.equal(await evaluate('window.isSecureContext'), !lanMode);
  if (lanMode) {
    assert.equal(await evaluate('typeof crypto.randomUUID'), 'undefined');
    assert.equal(await evaluate('typeof crypto.getRandomValues'), 'function');
    assert.equal(await evaluate("'serviceWorker' in navigator"), false);
  }
  const browserCookies = (await call('Network.getCookies', { urls: [`http://${bindAddress}:${port}/`] })).cookies;
  const cookie = browserCookies.find(value => value.name === cookieName);
  assert.ok(cookie); assert.equal(cookie.httpOnly, true); assert.equal(cookie.sameSite, 'Strict'); assert.equal(cookie.secure, !lanMode);
  await evaluate('document.querySelector(".conversation").click()');
  await until(() => evaluate('document.querySelectorAll(".message").length === 100'), 'latest history page');
  assert.equal(await evaluate('document.querySelector(".progress").open'), false);
  assert.equal(await evaluate('document.querySelector(".message-body script")'), null);
  assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth'), true);
  await evaluate('document.getElementById("load-older").click()');
  await until(() => evaluate('document.querySelectorAll(".message").length === 125'), 'history pagination');
  assert.equal(await evaluate('document.getElementById("load-older").hidden'), true);
  await evaluate('document.getElementById("draft").value="A draft kept across navigation"; document.getElementById("draft").dispatchEvent(new Event("input"))');
  await evaluate('document.querySelectorAll(".conversation")[1].click()');
  await until(() => evaluate('document.getElementById("chat-title").textContent === "Another conversation"'), 'second conversation');
  await until(() => evaluate('document.querySelectorAll(".question-option input").length === 2'), 'question input');
  await evaluate('document.querySelector(".question-option input").click(); document.querySelector(".question-card input[type=text]").value="Also lint"; document.querySelector(".question-card input[type=text]").dispatchEvent(new Event("input", { bubbles: true }))');
  await evaluate('document.querySelectorAll(".conversation")[0].click()');
  await until(() => evaluate('document.getElementById("draft").value === "A draft kept across navigation"'), 'preserved draft');
  await evaluate('document.getElementById("jump-bottom").click()'); await pause(500);
  const screenshot = await call('Page.captureScreenshot', { format: 'png' });
  await writeFile(screenshotPath, Buffer.from(screenshot.data, 'base64'));
  await until(() => evaluate('document.getElementById("connection").textContent === "Live"'), 'WebSocket hello');
  const readsBeforeQuiet = workspaceReads;
  await pause(5500); assert.equal(workspaceReads, readsBeforeQuiet, 'live transport disables idle polling');
  all.at(-1).text += '\nLive pushed update'; push();
  await until(() => evaluate('document.getElementById("messages").textContent.includes("Live pushed update")'), 'event-driven transcript update');
  assert.equal(await evaluate('document.getElementById("send").disabled'), false, 'archived canResume chat can send');
  assert.equal(await evaluate('document.querySelectorAll(".message-timing").length'), 1);
  assert.match(await evaluate('document.querySelector(".message-timing").textContent'), /Completed.*Took.*1 min/);
  assert.match(await evaluate('document.querySelector(".message-timing").textContent'), /CLI confirmed effort: high/);
  assert.deepEqual(await evaluate('[...document.getElementById("effort").options].map(option => option.value)'), ['', 'low', 'high']);
  await evaluate('document.getElementById("effort").value="high"; document.getElementById("effort").dispatchEvent(new Event("change")); document.getElementById("model").value="no-reasoning"; document.getElementById("model").dispatchEvent(new Event("change"))');
  assert.equal(await evaluate('document.getElementById("effort").hidden'), false, 'effort control keeps its location when unavailable');
  assert.equal(await evaluate('document.getElementById("effort").disabled'), true);
  assert.equal(await evaluate('document.getElementById("draft").value'), 'A draft kept across navigation');
  await evaluate('document.getElementById("model").value=""; document.getElementById("model").dispatchEvent(new Event("change"))');
  assert.equal(await evaluate('document.getElementById("effort").hidden'), false, 'resolved default model has real capability metadata');
  assert.equal(await evaluate('document.getElementById("effort").value'), '');
  await evaluate('document.getElementById("effort").value="high"; document.getElementById("effort").dispatchEvent(new Event("change"))');
  await evaluate('document.getElementById("open-notifications").click()');
  await until(() => evaluate('!document.getElementById("notification-status").textContent.includes("Updating")'), 'notification capability status');
  assert.match(await evaluate('document.getElementById("notification-status").textContent'), lanMode ? /HTTPS/ : /Update the desktop/);
  assert.equal(await evaluate('document.getElementById("notification-enable").hidden'), true);
  await evaluate('document.getElementById("close-notifications").click()');

  await evaluate('document.getElementById("composer").requestSubmit()');
  await until(() => evaluate('!document.getElementById("mutation-error").hidden'), 'unknown send outcome');
  assert.equal(await evaluate('document.getElementById("draft").value'), 'A draft kept across navigation');
  const connectionCount = eventConnections;
  for (const eventSocket of eventSockets) eventSocket.destroy();
  await until(() => eventConnections > connectionCount, 'automatic WebSocket reconnect');
  assert.equal(requests.length, 1, 'reconnect never repeats uncertain mutation');
  await evaluate('window.dispatchEvent(new Event("online"))');
  await until(() => evaluate('!document.getElementById("retry-operation").disabled'), 'retry enabled after reconnect');
  await evaluate('document.getElementById("retry-operation").click()');
  await until(() => evaluate('document.getElementById("draft").value === ""'), 'successful explicit retry');
  assert.equal(requests.length, 2); assert.deepEqual(requests[0], requests[1]);
  assert.equal(requests[0].bootID, 'boot-1'); assert.equal(requests[0].reasoningEffort, 'high');
  await evaluate('window.dispatchEvent(new Event("offline"))');
  assert.equal(await evaluate('document.getElementById("send").disabled'), true);
  await evaluate('window.dispatchEvent(new Event("online")); document.querySelectorAll(".conversation")[1].click()');
  await until(() => evaluate('document.querySelector(".question-option input")?.checked === true'), 'question selections retained');
  assert.equal(await evaluate('document.querySelector(".question-card input[type=text]").value'), 'Also lint');
  // A paired phone opening while its Mac is offline recovers without pairing again or refreshing.
  macOnline = false;
  await call('Page.reload');
  await until(() => evaluate('document.getElementById("pair-error")?.textContent === "Mac offline"'), 'initial offline state');
  const previousProbes = sessionProbes;
  macOnline = true;
  await until(() => evaluate('!document.getElementById("application").hidden && document.querySelectorAll(".conversation").length === 2'), 'automatic session recovery');
  assert.ok(sessionProbes > previousProbes);
  assert.equal(requests.length, 2, 'session recovery never resubmits an action');
  await evaluate('document.querySelector(".conversation").click()');
  await until(() => evaluate('!document.getElementById("load-older").hidden'), 'history after reconnect');
  await evaluate('document.getElementById("load-older").click()');
  await until(() => evaluate('document.getElementById("load-older").hidden'), 'full history before restart');
  await evaluate('document.getElementById("draft").value="Survive Mac restart"; document.getElementById("draft").dispatchEvent(new Event("input"))');
  bootID = 'boot-2';
  all.splice(0, 1, { id: 'replacement', role: 'user', text: 'Restored transcript' });
  await evaluate('window.dispatchEvent(new Event("online"))');
  await until(() => evaluate('!document.getElementById("load-older").hidden && document.querySelectorAll(".message").length === 100'), 'Mac restart invalidates older cached pages');
  assert.equal(await evaluate('document.getElementById("draft").value'), 'Survive Mac restart');
  // Read-only changes remove every action, but keep the authorized chat draft.
  access = { workspaceId: 'w', writable: false }; push();
  await until(() => evaluate('document.getElementById("composer").hidden'), 'read-only access');
  assert.equal(await evaluate('document.getElementById("new-chat").hidden && document.getElementById("welcome-new").hidden && document.getElementById("stop").hidden'), true);
  await evaluate('document.getElementById("composer").requestSubmit()'); assert.equal(requests.length, 2);
  assert.equal(await evaluate('document.getElementById("draft").value'), 'Survive Mac restart');
  access = { workspaceId: 'w', writable: true }; push();
  await until(() => evaluate('!document.getElementById("composer").hidden'), 'restored write access');
  await evaluate('document.getElementById("new-chat").click()');
  assert.deepEqual(await evaluate('[...document.getElementById("new-workspace").options].map(o => o.value)'), ['w']);
  await evaluate('document.getElementById("close-new").click()');
  for (const [locale, send] of [['zh-Hans', '发送 ↑'], ['fr', 'Envoyer ↑'], ['ja', '送信 ↑'], ['ko', '보내기 ↑']]) {
    await evaluate(`document.querySelector('.language-select').value = ${JSON.stringify(locale)}; document.querySelector('.language-select').dispatchEvent(new Event('change'))`);
    assert.equal(await evaluate('document.documentElement.lang'), locale);
    assert.equal(await evaluate('document.getElementById("send").textContent'), send);
    assert.equal(await evaluate('document.getElementById("draft").value'), 'Survive Mac restart');
    assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth'), true, locale);
    if (locale === 'fr') {
      await evaluate('document.getElementById("open-sidebar").click()');
      await pause(300);
      const frenchShot = await call('Page.captureScreenshot', { format: 'png' });
      await writeFile(join(tmpdir(), 'theall-mobile-french-preview.png'), Buffer.from(frenchShot.data, 'base64'));
      await evaluate('document.getElementById("close-sidebar").click()');
    }
  }
  assert.deepEqual(await evaluate('Object.keys(localStorage)'), ['theall.language']);
  // Rejected WebSocket falls back to HTTP, then foreground immediately restores push.
  rejectEvents = true; for (const eventSocket of eventSockets) eventSocket.destroy();
  const beforeFallback = workspaceReads; await until(() => workspaceReads > beforeFallback, 'fallback polling');
  rejectEvents = false; const beforeReconnect = eventConnections;
  await evaluate('window.dispatchEvent(new Event("online"))'); await until(() => eventConnections > beforeReconnect, 'foreground live restore');
  assert.equal(requests.length, 2, 'fallback and foreground never repeat actions');
  // Exercise request and photo UUID generation in a real insecure LAN context.
  await evaluate('document.getElementById("new-chat").click(); document.getElementById("new-directory").value="/Users/you/Projects/atlas"; document.getElementById("new-form").requestSubmit()');
  await until(() => creations.length === 1, 'new conversation request');
  assert.match(creations[0].requestId, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  await until(() => evaluate('!document.getElementById("new-dialog").open'), 'new conversation complete');
  await evaluate('document.querySelectorAll(".conversation")[0].click()');
  await until(() => evaluate('document.getElementById("chat-title").textContent === "检查项目状态"'), 'photo conversation');
  await evaluate(`(async () => {
    const canvas = document.createElement('canvas'); canvas.width = canvas.height = 16;
    const ctx = canvas.getContext('2d'); ctx.fillStyle = '#ff0000'; ctx.fillRect(0, 0, 16, 16);
    const blob = await new Promise(resolve => canvas.toBlob(resolve, 'image/jpeg'));
    const transfer = new DataTransfer(); transfer.items.add(new File([blob], 'local-photo.jpg', { type: 'image/jpeg' }));
    document.getElementById('photo-files').files = transfer.files;
    document.getElementById('photo-files').dispatchEvent(new Event('change'));
  })()`);
  await until(() => evaluate('document.querySelectorAll(".photo-draft").length === 1'), 'LAN photo preparation');
  await evaluate('document.getElementById("draft").value=""; document.getElementById("draft").dispatchEvent(new Event("input")); document.getElementById("composer").requestSubmit()');
  await until(() => requests.length === 3, 'LAN image-only request');
  assert.equal(requests[2].text, ''); assert.equal(requests[2].images.length, 1);
  assert.equal(requests[2].images[0].name, 'local-photo.jpg'); assert.ok(Buffer.from(requests[2].images[0].data, 'base64').length > 0);
  assert.match(requests[2].requestId, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  await until(() => evaluate('document.querySelectorAll(".photo-draft").length === 0'), 'photo draft cleared after success');
  // The same picker accepts files. An asynchronous import stays with its original chat.
  assert.equal(await evaluate('document.getElementById("photo-files").hasAttribute("accept")'),false);
  await evaluate(`(() => {
    const read=File.prototype.arrayBuffer;
    File.prototype.arrayBuffer=function(){if(this.name==='empty.txt'){const file=this;return new Promise(resolve=>{window.finishFileImport=async()=>{File.prototype.arrayBuffer=read;resolve(await read.call(file));};});}return read.call(this);};
    const transfer=new DataTransfer();transfer.items.add(new File([],'empty.txt',{type:'text/plain'}));
    const input=document.getElementById('photo-files');input.files=transfer.files;input.dispatchEvent(new Event('change'));
  })()`);
  await until(()=>evaluate('typeof window.finishFileImport === "function"'),'file read started');
  assert.equal(await evaluate('document.getElementById("send").disabled'),true);
  await evaluate('document.querySelectorAll(".conversation")[1].click()');
  await until(()=>evaluate('document.getElementById("chat-title").textContent === "Another conversation"'),'switch during import');
  await evaluate('window.finishFileImport()');await pause(100);
  assert.equal(await evaluate('document.querySelectorAll("#file-previews .file-chip").length'),0);
  await evaluate('document.querySelectorAll(".conversation")[0].click()');
  await until(()=>evaluate('document.querySelectorAll("#file-previews .file-chip").length === 1'),'file remains on original chat');
  // Mixed drop atomically keeps the image and opaque active document bytes.
  await evaluate(`(async()=>{
    const canvas=document.createElement('canvas');canvas.width=canvas.height=8;
    const blob=await new Promise(resolve=>canvas.toBlob(resolve,'image/png'));
    const transfer=new DataTransfer();transfer.items.add(new File([blob],'mixed.png',{type:'image/png'}));
    transfer.items.add(new File(['%PDF-fixture'],'中文报告.pdf',{type:'application/pdf'}));
    transfer.items.add(new File(['<script>window.fileExecuted=true</script>'],'active.html',{type:'text/html'}));
    document.getElementById('draft').dispatchEvent(new DragEvent('drop',{dataTransfer:transfer,bubbles:true,cancelable:true}));
  })()`);
  await until(()=>evaluate('document.querySelectorAll("#file-previews .file-chip").length === 3 && document.querySelectorAll(".photo-draft").length === 1'),'mixed drop prepared');
  assert.equal(await evaluate('window.fileExecuted === undefined'),true);
  await call('Emulation.setDeviceMetricsOverride', {width:320,height:844,deviceScaleFactor:1,mobile:true});
  await evaluate(`document.querySelector('.language-select').value='zh-Hans';document.querySelector('.language-select').dispatchEvent(new Event('change'));`);
  await pause(200);assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth'),true,'320px attachment layout');
  const attachmentShot=await call('Page.captureScreenshot',{format:'png'});await writeFile(process.env.FILE_SCREENSHOT_PATH || join(tmpdir(),'theall-file-attachments-preview.png'),Buffer.from(attachmentShot.data,'base64'));
  await call('Emulation.setDeviceMetricsOverride', {width:390,height:844,deviceScaleFactor:1,mobile:true});
  // Removing the image leaves a valid files-only submission.
  await evaluate('document.querySelector(".photo-remove").click()');
  assert.equal(await evaluate('document.getElementById("send").disabled'),false);
  rejectFileSend=true;await evaluate('document.getElementById("composer").requestSubmit()');
  await until(()=>requests.length===4,'file rejection');await until(()=>evaluate('!document.getElementById("send").disabled'),'rejection keeps file draft');
  assert.equal(await evaluate('document.querySelectorAll("#file-previews .file-chip").length'),3);
  await evaluate('document.getElementById("composer").requestSubmit()');
  await until(()=>requests.length===5,'file retry');
  assert.deepEqual(requests[3].files,requests[4].files);assert.equal(requests[4].text,'');assert.equal(requests[4].images.length,0);
  assert.equal(requests[4].files[0].data,'');assert.equal(Buffer.from(requests[4].files[1].data,'base64').toString(),'%PDF-fixture');
  await until(()=>evaluate('document.querySelectorAll("#file-previews .file-chip").length === 0 && document.querySelectorAll(".file-download").length === 3'),'files saved in history');
  assert.equal(await evaluate('document.querySelectorAll(".file-download[download]").length'),3);
  assert.equal(await evaluate(`(async()=>{const link=[...document.querySelectorAll('.file-download')].find(a=>a.textContent.includes('active.html'));const response=await fetch(link.href);return response.headers.get('content-disposition')==='attachment' && (await response.text()).includes('fileExecuted');})()`),true);
  assert.equal(await evaluate('window.fileExecuted === undefined && document.documentElement.scrollWidth <= innerWidth'),true);
  for(const locale of ['en','zh-Hans','fr','ja','ko']){
    await evaluate(`document.querySelector('.language-select').value=${JSON.stringify(locale)};document.querySelector('.language-select').dispatchEvent(new Event('change'));`);
    assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth'),true,locale+' files layout');
    assert(await evaluate('document.getElementById("add-photos").ariaLabel.length > 0'));
  }
  // A running task accepts supplemental instructions without changing its next-turn settings.
  running = true; push();
  await until(() => evaluate('!document.getElementById("stop").hidden && !document.getElementById("send").hidden'), 'steer and stop coexist');
  await evaluate(`document.querySelector('.language-select').value='en';document.querySelector('.language-select').dispatchEvent(new Event('change'));
    document.getElementById('model').value='no-reasoning';document.getElementById('model').dispatchEvent(new Event('change'));
    document.getElementById('draft').value='Please inspect tests first';document.getElementById('draft').dispatchEvent(new Event('input'));
    const transfer=new DataTransfer();transfer.items.add(new File(['steer attachment'],'notes.txt',{type:'text/plain'}));
    document.getElementById('draft').dispatchEvent(new DragEvent('drop',{dataTransfer:transfer,bubbles:true,cancelable:true}));`);
  await until(() => evaluate('!document.getElementById("send").disabled'), 'steer with file ready');
  assert.equal(await evaluate('document.getElementById("send").textContent'), 'Steer ↑');
  assert.equal(await evaluate('document.getElementById("model-notice").hidden'), false);
  for(const locale of ['en','zh-Hans','fr','ja','ko']) {
    await call('Emulation.setDeviceMetricsOverride', {width:320,height:844,deviceScaleFactor:1,mobile:true});
    await evaluate(`document.querySelector('.language-select').value=${JSON.stringify(locale)};document.querySelector('.language-select').dispatchEvent(new Event('change'));`);
    assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth'), true, locale+' steer controls fit at 320px');
    const boxes=await evaluate(`['model','effort','send','stop'].map(id=>{const b=document.getElementById(id).getBoundingClientRect();return {x:b.x,right:b.right,width:b.width};})`);
    assert.ok(boxes.every(b=>b.width>20&&b.x>=0&&b.right<=320), locale+' steer controls usable');
    assert.ok(boxes.every((b,i)=>!i||b.x>=boxes[i-1].right),locale+' steer controls do not overlap');
  }
  await evaluate(`document.querySelector('.language-select').value='zh-Hans';document.querySelector('.language-select').dispatchEvent(new Event('change'));`);
  const steerShot=await call('Page.captureScreenshot',{format:'png'});await writeFile(process.env.STEER_SCREENSHOT_PATH || join(tmpdir(),'theall-steer-preview.png'),Buffer.from(steerShot.data,'base64'));
  rejectSteer = true;
  await evaluate(`document.getElementById('draft').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',ctrlKey:true,bubbles:true,cancelable:true}));`);
  await until(() => steers.length === 1, 'keyboard submits steer');
  await until(() => evaluate('!document.getElementById("send").disabled'), 'rejected steer restores submit');
  assert.equal(await evaluate('document.getElementById("draft").value'), 'Please inspect tests first');
  assert.equal(await evaluate('document.querySelectorAll("#file-previews .file-chip").length'), 1);
  assert.equal(requests.length,5,'rejection never falls back to ordinary send');
  // A missing capability (old server or a transition) disables, rather than queues, busy input.
  steerReady = false; push();
  await until(() => evaluate('document.getElementById("send").disabled'), 'busy task not ready for steer');
  await evaluate('document.getElementById("composer").requestSubmit()');await pause(100);
  assert.equal(steers.length,1);
  steerReady = true; push();
  await until(() => evaluate('!document.getElementById("send").disabled'), 'steer capability restored');
  unknownSteer = true; await evaluate('document.getElementById("composer").requestSubmit()');
  await until(() => evaluate('!document.getElementById("mutation-error").hidden'), 'uncertain steer remains explicit');
  assert.equal(await evaluate('document.getElementById("draft").value'), 'Please inspect tests first');
  await evaluate('document.getElementById("retry-operation").click()');
  await until(() => evaluate('document.getElementById("draft").value === ""'), 'confirmed steer clears only submitted draft');
  assert.equal(steers.length,3);assert.deepEqual(steers[1],steers[2]);assert.equal(steers[2].text,'Please inspect tests first');
  assert.equal(Buffer.from(steers[2].files[0].data,'base64').toString(),'steer attachment');
  assert.equal(await evaluate('document.querySelectorAll("#file-previews .file-chip").length'),0);
  assert.equal(await evaluate('document.getElementById("model-notice").hidden'),false,'steer retains next-turn model notice');
  assert.equal(await evaluate('document.getElementById("stop").hidden'),false,'steer does not end the task');
  assert.equal(await evaluate('document.querySelectorAll(".steer-status").length'),0,'accepted steer has no failure caption');
  all.find(message=>message.id==='steer-applied').isError=true;push();
  await until(()=>evaluate('document.querySelector(".steer-status")?.textContent === "这条补充指令未执行。"'),'later cancelled steer clearly marked');
  assert.equal(await evaluate('document.querySelector("[data-message-id=steer-applied] .message-body").textContent'),'Please inspect tests first','failure caption preserves original instruction');
  assert.equal(await evaluate('document.querySelector("[data-message-id=steer-applied]").closest(".turn").querySelectorAll(".message.user").length >= 2'),true,'cancelled steer remains in the original task');
  await evaluate('document.getElementById("stop").click()');
  await until(() => interruptCount===1 && evaluate('document.getElementById("stop").hidden'), 'separate stop interrupts');
  assert.equal(requests.length,5,'steer and stop never issue ordinary send');
  // Read-only grants suppress steer even when a task is running.
  running=true;access={workspaceId:null,writable:false};push();
  await until(()=>evaluate('document.getElementById("composer").hidden && document.getElementById("send").hidden && document.getElementById("stop").hidden'),'read-only hides steer');
  running=false;
  await evaluate(`document.querySelector('.language-select').value='ko';document.querySelector('.language-select').dispatchEvent(new Event('change'));`);
  // A scope change must remove previously authorized transcript and its draft.
  access = { workspaceId: 'other', writable: false }; push();
  await until(() => evaluate('document.getElementById("chat-area").hidden && document.querySelectorAll(".conversation").length === 0'), 'scope invalidation');
  assert.equal(await evaluate('document.getElementById("messages").textContent'), '');
  assert.equal(await evaluate('document.getElementById("draft").value'), '');
  push({ type: 'revoked' }); paired = false;
  await until(() => evaluate('!document.getElementById("pair-screen").hidden'), 'revocation clears access');
  assert.equal(await evaluate('document.getElementById("messages").textContent'), '');
  await call('Page.reload');
  await until(() => evaluate('document.documentElement.lang === "ko"'), 'language preference survives reload');
  assert.equal(await evaluate('document.getElementById("draft").value'), '', 'transcripts and drafts never persist in browser storage');
  // An expired invitation is tried once, then allows an explicit retry with a new code.
  await call('Page.navigate', { url: `http://${bindAddress}:${port}/#pair=expired-token` });
  await until(() => evaluate('document.getElementById("pair-error").textContent.includes("expired")'), 'expired QR error');
  assert.equal(pairRequests, 2); assert.equal(await evaluate('location.hash'), '');
  assert.equal(await evaluate('document.getElementById("pair-form").hidden'), false);
  await pause(1200); assert.equal(pairRequests, 2, 'no automatic replay of failed pairing');
  invitation = 'retry-token'; access = { workspaceId: null, writable: true };
  await evaluate('document.getElementById("pair-token").value="retry-token"; document.getElementById("pair-form").requestSubmit(); document.getElementById("pair-form").requestSubmit()');
  await until(() => evaluate('!document.getElementById("application").hidden'), 'manual QR retry');
  assert.equal(pairRequests, 3, 'double submit shares one pairing attempt');
  await call('Page.reload');
  await until(() => evaluate('!document.getElementById("application").hidden'), 'saved session cookie restores without QR');
  assert.equal(pairRequests, 3);
  // A stale session probe cannot replace the grant from a newly scanned invitation.
  paired = false; nextSessionDelay = 900;
  const probesBeforeRace = sessionProbes;
  await call('Page.reload');
  await until(() => sessionProbes > probesBeforeRace, 'delayed session probe started');
  invitation = 'scoped-invitation'; access = { workspaceId: 'w', writable: false };
  await call('Page.navigate', { url: `http://${bindAddress}:${port}/#pair=scoped-invitation` });
  await until(() => evaluate('!document.getElementById("application").hidden && document.getElementById("new-chat").hidden'), 'scanned grant wins over previous probe');
  assert.equal(pairRequests, 4);
  await pause(1000);
  assert.equal(await evaluate('document.getElementById("pair-screen").hidden && document.getElementById("new-chat").hidden'), true);
  // Completion links wait for authentication and resolve IDs only against authorized workspaces.
  includeNotificationChat = true;
  await call('Page.navigate', { url: `http://${bindAddress}:${port}/?chat=${notificationChat.toLowerCase()}` });
  await until(() => evaluate('document.getElementById("chat-title").textContent === "Notification target"'), 'notification opens canonical authorized conversation');
  assert.equal(await evaluate('location.search'), ''); assert.ok(notificationReads > 0);
  await call('Page.navigate', { url: `http://${bindAddress}:${port}/?chat=${rejectedNotificationChat}` });
  await until(() => evaluate('document.getElementById("global-error").textContent.length > 0'), 'unknown notification target explained');
  assert.equal(unauthorizedNotificationReads, 0, 'unknown chat was never fetched');
  paired = false;
  await call('Page.navigate', { url: `http://${bindAddress}:${port}/?chat=${notificationChat.toLowerCase()}` });
  await until(() => evaluate('!document.getElementById("pair-screen").hidden && document.getElementById("pair-form").hidden === false'), 'expired notification session requires pairing');
  invitation = 'notification-invitation';
  await evaluate('document.getElementById("pair-token").value="notification-invitation"; document.getElementById("pair-form").requestSubmit()');
  await until(() => evaluate('document.getElementById("chat-title").textContent === "Notification target"'), 'notification target survives re-pairing');
  assert.equal(requests.length, 5, 'notification clicks never submit messages');
  assert.deepEqual(exceptions, []);
  console.log(`PASS (${lanMode ? 'insecure LAN HTTP' : 'secure-context loopback'}): automatic pairing/cookies/UUID/photo/file/mixed-drop/new-chat/steer, history pagination, safe rendering, mobile layout, archived resume, draft retention, unknown-outcome retry, offline guard, question drafts, initial offline recovery, Mac restart, WebSocket push/backoff/fallback, scope, read-only, revocation, five languages. Screenshot: ${screenshotPath}`);
} finally {
  socket?.close(); browser?.kill(); for (const eventSocket of eventSockets) eventSocket.destroy(); server.closeAllConnections(); server.close();
  await pause(600); await rm(temporary, { recursive: true, force: true });
}
