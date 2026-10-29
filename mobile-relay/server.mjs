import http from 'node:http';
import { createPublicKey, randomBytes, randomUUID, timingSafeEqual, verify } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { WebSocket, WebSocketServer } from 'ws';

export const LIMITS = Object.freeze({
  requestBytes: 32 * 1024 * 1024, responseBytes: 16 * 1024 * 1024, headerBytes: 16 * 1024,
  webSocketBytes: 48 * 1024 * 1024, pending: 8, unverifiedHosts: 4,
  bodyTimeout: 120000, responseTimeout: 50000, authenticationTimeout: 10000, heartbeat: 30000,
  eventBytes: 8192, events: 16, eventHandshakeTimeout: 10000, eventRate: 30, bufferedEventBytes: 65536,
  targetBytes: 4096, bufferedHostBytes: 64 * 1024 * 1024
});
const HOP_HEADERS = new Set(['connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
  'te', 'trailer', 'transfer-encoding', 'upgrade']);
const SECURITY_HEADERS = Object.freeze({
  'cache-control': 'no-store', 'x-content-type-options': 'nosniff', 'referrer-policy': 'no-referrer'
});
const SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

export function decodeBase64(value, maxBytes, exactBytes) {
  if (typeof value !== 'string' || value.length > 4 * Math.ceil(maxBytes / 3) || /[^A-Za-z0-9+/=]/.test(value)) throw new Error('Invalid base64');
  const bytes = Buffer.from(value, 'base64');
  if (bytes.length > maxBytes || (exactBytes !== undefined && bytes.length !== exactBytes) || bytes.toString('base64') !== value) throw new Error('Invalid base64');
  return bytes;
}
export function parseConfig(env = process.env) {
  let origin;
  try { origin = new URL(env.PUBLIC_ORIGIN); } catch { throw new Error('PUBLIC_ORIGIN must be an HTTPS origin, such as https://theall.example.com'); }
  const local = ['localhost', '127.0.0.1', '[::1]'].includes(origin.hostname);
  if ((origin.protocol !== 'https:' && !(origin.protocol === 'http:' && local)) || origin.username || origin.password || origin.pathname !== '/' || origin.search || origin.hash) {
    throw new Error('PUBLIC_ORIGIN must be a root HTTPS origin; HTTP is allowed only for loopback development');
  }
  const publicKey = decodeBase64(env.THEALL_MAC_PUBLIC_KEY, 32, 32);
  const port = Number(env.PORT || 8080);
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error('PORT must be between 0 and 65535');
  return { origin: origin.origin, publicKey, bind: env.BIND_ADDRESS || '127.0.0.1', port };
}
function headerSize(headers) {
  let size = 0;
  for (const [name, value] of Object.entries(headers)) {
    for (const part of Array.isArray(value) ? value : [value]) size += Buffer.byteLength(`${name}: ${part}\r\n`);
  }
  return size;
}
function excludedHeaders(headers) {
  const excluded = new Set(HOP_HEADERS);
  if (typeof headers.connection === 'string') for (const name of headers.connection.split(',')) excluded.add(name.trim().toLowerCase());
  return excluded;
}
function forwardHeaders(req, origin, bodyLength) {
  const headers = {};
  const excluded = excludedHeaders(req.headers);
  for (const [name, value] of Object.entries(req.headers)) {
    if (value === undefined || excluded.has(name) || name === 'forwarded' || name === 'via' || name.startsWith('x-forwarded-')) continue;
    headers[name] = Array.isArray(value) ? value.join(name === 'cookie' ? '; ' : ', ') : value;
  }
  headers.host = new URL(origin).host;
  if (req.method === 'POST') headers['content-length'] = String(bodyLength); else delete headers['content-length'];
  return headers;
}
function responseHeaders(input, bodyLength, maxHeaderBytes) {
  if (!input || typeof input !== 'object' || Array.isArray(input) || headerSize(input) > maxHeaderBytes) throw new Error('Invalid response headers');
  const normalized = {};
  for (const [name, value] of Object.entries(input)) {
    const lower = name.toLowerCase();
    if (Object.hasOwn(normalized, lower) || !/^[!#$%&'*+.^_`|~0-9a-z-]+$/.test(lower)) throw new Error('Invalid response header name');
    const values = Array.isArray(value) ? value : [value];
    if (!values.length || values.some(part => typeof part !== 'string' || /[\r\n\x00]/.test(part)) || (Array.isArray(value) && lower !== 'set-cookie')) throw new Error('Invalid response header value');
    for (const part of values) http.validateHeaderValue(lower, part);
    normalized[lower] = value;
  }
  const excluded = excludedHeaders(normalized);
  for (const name of Object.keys(normalized)) {
    if (excluded.has(name) || name.startsWith('access-control-') || name === 'content-length') delete normalized[name];
  }
  return { ...normalized, ...SECURITY_HEADERS, 'content-length': bodyLength };
}

export function createRelay(config, overrides = {}) {
  const limits = { ...LIMITS, ...overrides };
  const origin = new URL(config.origin);
  const expectedKey = Buffer.from(config.publicKey);
  if (expectedKey.length !== 32) throw new Error('Expected 32-byte Ed25519 public key');
  const verificationKey = createPublicKey({ key: Buffer.concat([SPKI_PREFIX, expectedKey]), format: 'der', type: 'spki' });
  const pending = new Map();
  const admitted = new Set();
  const unauthenticated = new Set();
  const events = new Map();
  let host = null;
  let shuttingDown = false;

  function fail(res, status, error, close = false) {
    if (res.destroyed || res.writableEnded) return;
    const body = Buffer.from(JSON.stringify({ error }));
    res.writeHead(status, { ...SECURITY_HEADERS, 'content-type': 'application/json; charset=utf-8', 'content-length': body.length, ...(close ? { connection: 'close' } : {}) });
    res.end(body);
  }
  function release(record) {
    clearTimeout(record.timer);
    pending.delete(record.id); admitted.delete(record);
  }
  function failRecord(record, status, message) {
    release(record); record.abortBody?.(); fail(record.res, status, message, !record.req.complete);
  }
  function disconnectHost(ws) {
    if (host === ws) host = null;
    for (const record of [...admitted]) if (record.host === ws) failRecord(record, 503, 'Mac offline');
    for (const record of [...events.values()]) if (record.host === ws) closeEvent(record, 1012, false);
  }
  function rejectSocket(socket, status) {
    // An unauthorized client may never finish its TCP half-close (and pending
    // event upgrades are paused). Do not retain a socket after its rejection.
    setTimeout(() => socket.destroy(), 1000).unref();
    socket.end(`HTTP/1.1 ${status} ${http.STATUS_CODES[status]}\r\nConnection: close\r\nContent-Length: 0\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n\r\n`);
  }
  function validHost(req) {
    // Do not trust proxy forwarding headers to choose the app origin.
    const hostCount = req.rawHeaders.filter((_, i) => i % 2 === 0).filter(name => name.toLowerCase() === 'host').length;
    return hostCount === 1 && typeof req.headers.host === 'string' && req.headers.host.toLowerCase() === origin.host;
  }
  function notifyEventHost(record, message) {
    if (host !== record.host || host?.readyState !== WebSocket.OPEN) return false;
    if (host.bufferedAmount > limits.bufferedHostBytes) { closeEvent(record, 1013, false); return false; }
    host.send(JSON.stringify({ ...message, id: record.id }), error => { if (error) closeEvent(record, 1012, false); });
    return true;
  }
  function closeEvent(record, code = 1008, notify = true, status = 503) {
    if (!events.delete(record.id)) return;
    clearTimeout(record.timer);
    if (notify) notifyEventHost(record, { type: 'event_close' });
    if (record.ws) {
      record.ws.close(code, 'Event connection closed');
      setTimeout(() => record.ws.terminate(), 1000).unref();
    } else { rejectSocket(record.socket, status); }
  }
  function openEvents(req, socket, head) {
    if (req.method !== 'GET' || req.headers.origin !== config.origin || req.headers['sec-fetch-site'] === 'cross-site') { rejectSocket(socket, 403); return; }
    if (headerSize(req.headers) > limits.headerBytes || head.length > limits.eventBytes + 14) { rejectSocket(socket, 431); return; }
    if (req.headers['transfer-encoding'] || Number(req.headers['content-length'] || 0) !== 0 ||
        req.headers.upgrade?.toLowerCase() !== 'websocket' || req.headers['sec-websocket-version'] !== '13' ||
        typeof req.headers['sec-websocket-key'] !== 'string' || !/^[+/0-9A-Za-z]{22}==$/.test(req.headers['sec-websocket-key'])) { rejectSocket(socket, 400); return; }
    if (!host || host.readyState !== WebSocket.OPEN || events.size >= limits.events) { rejectSocket(socket, 503); return; }
    const record = { id: randomUUID(), host, req, socket, head, ws: null, timer: null, rateStarted: performance.now(), received: 0 };
    events.set(record.id, record);
    // Hold the TCP socket until the Mac has checked the actual device cookie.
    socket.pause();
    socket.once('close', () => closeEvent(record));
    record.timer = setTimeout(() => closeEvent(record, 1008, true, 504), limits.eventHandshakeTimeout);
    notifyEventHost(record, { type: 'event_open', method: 'GET', target: '/api/events', headers: forwardHeaders(req, config.origin, 0) });
  }
  function handleEventMessage(ws, message) {
    if (typeof message.id !== 'string') throw new Error('Invalid event ID');
    const record = events.get(message.id);
    if (!record || record.host !== ws) return; // A closed channel cannot be resurrected.
    if (message.type === 'event_opened') {
      if (record.ws || !Number.isInteger(message.status) || (message.status !== 101 && (message.status < 400 || message.status > 599))) throw new Error('Invalid event decision');
      clearTimeout(record.timer);
      if (message.status !== 101) { closeEvent(record, 1008, false, message.status); return; }
      eventWSS.handleUpgrade(record.req, record.socket, record.head, phone => {
        record.ws = phone; record.head = null; phone.alive = true;
        phone.on('error', () => {});
        const admittedFrame = () => {
          const now = performance.now();
          if (now - record.rateStarted >= 1000) { record.rateStarted = now; record.received = 0; }
          if (++record.received > limits.eventRate) { closeEvent(record); return false; }
          return true;
        };
        phone.on('ping', () => { admittedFrame(); });
        phone.on('pong', () => { if (admittedFrame()) phone.alive = true; });
        phone.on('close', () => closeEvent(record));
        phone.on('message', (raw, binary) => {
          if (binary || raw.length > limits.eventBytes || !admittedFrame()) { closeEvent(record); return; }
          notifyEventHost(record, { type: 'event_input', text: raw.toString('utf8') });
        });
        record.socket.resume();
      });
    } else if (message.type === 'event_data') {
      if (!record.ws || typeof message.text !== 'string' || Buffer.byteLength(message.text) > limits.eventBytes) throw new Error('Invalid event data');
      if (record.ws.readyState !== WebSocket.OPEN || record.ws.bufferedAmount + Buffer.byteLength(message.text) > limits.bufferedEventBytes) { closeEvent(record, 1013); return; }
      record.ws.send(message.text, error => { if (error) closeEvent(record, 1012); });
    } else if (message.type === 'event_close') { closeEvent(record, 1008, false); }
    else { throw new Error('Invalid event message'); }
  }
  function readBody(req, record) {
    return new Promise((resolve, reject) => {
      let length = 0; const chunks = [];
      const cleanup = () => {
        clearTimeout(timer); req.removeListener('data', data); req.removeListener('end', end);
        req.removeListener('error', error); req.removeListener('aborted', aborted); record.abortBody = null;
      };
      const error = cause => { cleanup(); reject(cause); };
      const abort = (status, message) => { const cause = new Error(message); cause.status = status; error(cause); };
      const aborted = () => abort(400, 'Request interrupted');
      const data = chunk => {
        length += chunk.length;
        if (length > limits.requestBytes) { req.pause(); abort(413, 'Request body too large'); return; }
        chunks.push(chunk);
      };
      const end = () => { cleanup(); resolve(Buffer.concat(chunks, length)); };
      const timer = setTimeout(() => { req.pause(); abort(408, 'Request body timed out'); }, limits.bodyTimeout);
      record.abortBody = () => abort(503, 'Mac offline');
      req.on('data', data); req.once('end', end); req.once('error', error); req.once('aborted', aborted);
    });
  }
  async function handleRequest(req, res) {
    if (shuttingDown) { fail(res, 503, 'Relay unavailable', true); return; }
    if (!validHost(req)) { fail(res, 421, 'Unexpected host', true); return; }
    if (headerSize(req.headers) > limits.headerBytes) { fail(res, 431, 'Request headers too large', true); return; }
    if (!['GET', 'POST'].includes(req.method)) { fail(res, 405, 'Only GET and POST are supported', true); return; }
    if (!req.url.startsWith('/') || req.url.startsWith('//') || req.url.includes('#') || Buffer.byteLength(req.url) > limits.targetBytes) { fail(res, 400, 'Invalid request target', true); return; }
    if (req.headers['sec-fetch-site'] === 'cross-site' || (req.headers.origin !== undefined && req.headers.origin !== config.origin)) { fail(res, 403, 'Cross-origin request rejected', true); return; }
    if (req.method === 'POST' && (req.headers.origin !== config.origin || req.headers['x-theall-client'] !== '1' || req.headers['content-type']?.split(';')[0].trim().toLowerCase() !== 'application/json')) {
      fail(res, 403, 'Same-origin JSON client required', true); return;
    }
    if (req.headers['content-length'] && Number(req.headers['content-length']) > limits.requestBytes) { fail(res, 413, 'Request body too large', true); return; }
    if (req.method === 'GET' && (Number(req.headers['content-length'] || 0) !== 0 || req.headers['transfer-encoding'])) { fail(res, 400, 'GET body is not supported', true); return; }
    if (!host || host.readyState !== WebSocket.OPEN) { fail(res, 503, 'Mac offline', true); return; }
    if (admitted.size >= limits.pending) { fail(res, 503, 'Too many pending requests', true); return; }
    const record = { id: randomUUID(), req, res, host, timer: null, abortBody: null };
    admitted.add(record);
    res.once('close', () => { release(record); record.abortBody?.(); });
    res.once('finish', () => release(record));
    try {
      const body = await readBody(req, record);
      if (!admitted.has(record) || res.destroyed || res.writableEnded) return;
      if (host !== record.host || host.readyState !== WebSocket.OPEN) { failRecord(record, 503, 'Mac offline'); return; }
      const message = JSON.stringify({ type: 'request', id: record.id, method: req.method, target: req.url,
        headers: forwardHeaders(req, config.origin, body.length), body: body.toString('base64') });
      if (host.bufferedAmount + Buffer.byteLength(message) > limits.bufferedHostBytes) { failRecord(record, 503, 'Mac connection busy'); return; }
      pending.set(record.id, record);
      record.timer = setTimeout(() => failRecord(record, 504, 'Mac response timed out'), limits.responseTimeout);
      host.send(message, error => {
        if (error) failRecord(record, 503, 'Mac offline');
      });
    } catch (error) {
      release(record); fail(res, error.status || 400, error.status ? error.message : 'Request interrupted', true);
    }
  }
  const server = http.createServer({ maxHeaderSize: limits.headerBytes, requestTimeout: limits.bodyTimeout + 5000, headersTimeout: limits.bodyTimeout, maxConnections: 128 }, (req, res) => {
    handleRequest(req, res).catch(() => fail(res, 500, 'Relay request failed', true));
  });
  server.maxConnections = 128;
  server.keepAliveTimeout = 5000;
  server.on('checkContinue', (req, res) => fail(res, 417, 'Expect is not supported', true));
  server.on('clientError', (error, socket) => { if (socket.writable) rejectSocket(socket, error.code === 'HPE_HEADER_OVERFLOW' ? 431 : 400); });
  const eventWSS = new WebSocketServer({ noServer: true, maxPayload: limits.eventBytes, perMessageDeflate: false, clientTracking: true, handleProtocols: () => false });
  const wss = new WebSocketServer({ noServer: true, maxPayload: limits.webSocketBytes, perMessageDeflate: false, clientTracking: true });
  server.on('upgrade', (req, socket, head) => {
    socket.on('error', () => {});
    if (shuttingDown || !validHost(req)) { rejectSocket(socket, 421); return; }
    if (req.url === '/api/events') { openEvents(req, socket, head); return; }
    if (req.url !== '/host' || req.method !== 'GET' || req.headers.origin !== undefined) { rejectSocket(socket, 403); return; }
    if (unauthenticated.size >= limits.unverifiedHosts) { rejectSocket(socket, 503); return; }
    wss.handleUpgrade(req, socket, head, ws => {
      unauthenticated.add(ws);
      let nonce = randomBytes(32);
      let authenticated = false;
      const expiresAt = performance.now() + limits.authenticationTimeout;
      ws.alive = true;
      const authTimer = setTimeout(() => ws.terminate(), limits.authenticationTimeout);
      const protocolError = () => { ws.close(1008, 'Invalid host message'); setTimeout(() => ws.terminate(), 1000).unref(); };
      ws.on('error', () => {}); // Never log payloads, cookies, URLs or secrets.
      ws.on('pong', () => { ws.alive = true; });
      ws.on('close', () => { clearTimeout(authTimer); unauthenticated.delete(ws); nonce = null; disconnectHost(ws); });
      ws.on('message', (raw, binary) => {
        try {
          if (binary || (!authenticated && raw.length > 4096)) { protocolError(); return; }
          const message = JSON.parse(raw.toString('utf8'));
          if (!authenticated) {
            if (message?.type !== 'authenticate' || !nonce || performance.now() >= expiresAt) { protocolError(); return; }
            const key = decodeBase64(message.publicKey, 32, 32);
            const signature = decodeBase64(message.signature, 64, 64);
            const challenge = nonce; nonce = null; // A challenge has exactly one attempt, successful or otherwise.
            if (!timingSafeEqual(key, expectedKey) || !verify(null, challenge, verificationKey, signature)) { protocolError(); return; }
            clearTimeout(authTimer); unauthenticated.delete(ws); authenticated = true;
            if (host) { const previous = host; disconnectHost(previous); previous.close(1012, 'Mac connection replaced'); setTimeout(() => previous.terminate(), 1000).unref(); }
            host = ws;
            ws.send(JSON.stringify({ type: 'ready', protocol: 1 }));
            return;
          }
          if (host === ws && ['event_opened', 'event_data', 'event_close'].includes(message?.type)) { handleEventMessage(ws, message); return; }
          if (host !== ws || message?.type !== 'response' || typeof message.id !== 'string') { protocolError(); return; }
          const record = pending.get(message.id);
          if (!record || record.host !== ws) return; // Late responses cannot resurrect timed-out or disconnected requests.
          if (!Number.isInteger(message.status) || message.status < 200 || message.status > 599) throw new Error('Invalid status');
          const body = decodeBase64(message.body, limits.responseBytes);
          const headers = responseHeaders(message.headers, body.length, limits.headerBytes);
          clearTimeout(record.timer); pending.delete(record.id);
          // Keep the admission slot until the browser response flushes, bounding slow readers too.
          record.res.writeHead(message.status, headers); record.res.end(body);
        } catch { protocolError(); }
      });
      ws.send(JSON.stringify({ type: 'challenge', nonce: nonce.toString('base64'), protocol: 1 }));
    });
  });
  const heartbeat = setInterval(() => {
    for (const ws of [...wss.clients, ...eventWSS.clients]) {
      if (ws.readyState !== WebSocket.OPEN) continue;
      if (!ws.alive) { ws.terminate(); continue; }
      ws.alive = false; ws.ping();
    }
  }, limits.heartbeat);
  heartbeat.unref();
  return {
    server,
    listen: () => new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(config.port, config.bind, () => { server.removeListener('error', reject); resolve(server.address()); });
    }),
    close: () => new Promise(resolve => {
      shuttingDown = true; clearInterval(heartbeat);
      for (const record of [...admitted]) failRecord(record, 503, 'Relay shutting down');
      for (const record of [...events.values()]) closeEvent(record, 1001, false);
      for (const ws of [...wss.clients, ...eventWSS.clients]) ws.terminate();
      eventWSS.close();
      wss.close(); server.close(resolve); server.closeIdleConnections();
    })
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const relay = createRelay(parseConfig());
    await relay.listen();
    console.log('TheAll relay is listening. Request and payload logging is disabled.');
    let stopping = false;
    for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, async () => {
      if (stopping) return; stopping = true;
      const forceExit = setTimeout(() => process.exit(1), 10000); forceExit.unref();
      await relay.close(); clearTimeout(forceExit); process.exit(0);
    });
  } catch {
    console.error('TheAll relay could not start. Check PUBLIC_ORIGIN, THEALL_MAC_PUBLIC_KEY and the listen address.');
    process.exitCode = 1;
  }
}
