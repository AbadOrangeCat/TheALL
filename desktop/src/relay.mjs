import { createPrivateKey, createPublicKey, sign, timingSafeEqual } from 'node:crypto';
import { WebSocket } from 'ws';

export const RELAY_LIMITS = Object.freeze({
  requestBytes: 32 * 1024 * 1024, responseBytes: 16 * 1024 * 1024,
  headerBytes: 16 * 1024, frameBytes: 48 * 1024 * 1024,
  pending: 8, bufferedBytes: 64 * 1024 * 1024, events: 16,
  eventBytes: 8192, bufferedEventBytes: 65536, targetBytes: 4096,
});
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const HEADER = /^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/;
const ERROR_BODY = Buffer.from('{"error":"Relay operation failed"}');

export function relayOrigin(value) {
  let url;
  try { url = new URL(value); } catch { throw new Error('Enter a root HTTPS relay address.'); }
  const local = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
  if ((url.protocol !== 'https:' && !(url.protocol === 'http:' && local)) ||
      url.username || url.password || url.pathname !== '/' || url.search || url.hash) {
    throw new Error('Enter a root HTTPS relay address; HTTP is supported only on loopback for testing.');
  }
  return url.origin;
}
function decoded(value, maxBytes, exactBytes) {
  if (typeof value !== 'string' || value.length > 4 * Math.ceil(maxBytes / 3)) throw new Error('Invalid relay data');
  const result = Buffer.from(value, 'base64');
  if (result.length > maxBytes || (exactBytes !== undefined && result.length !== exactBytes) || result.toString('base64') !== value) throw new Error('Invalid relay data');
  return result;
}
function headers(value, response = false) {
  if (!value || Array.isArray(value) || typeof value !== 'object') throw new Error('Invalid relay headers');
  let bytes = 0;
  const result = Object.create(null);
  for (const [name, raw] of Object.entries(value)) {
    const key = name.toLowerCase();
    if (!HEADER.test(name) || Object.hasOwn(result, key)) throw new Error('Invalid relay headers');
    const values = response && key === 'set-cookie' && Array.isArray(raw) ? raw : [raw];
    if (!values.length || values.some(item => typeof item !== 'string' || /[\r\n\0]/.test(item))) throw new Error('Invalid relay headers');
    bytes += Buffer.byteLength(name) + values.reduce((sum, item) => sum + Buffer.byteLength(item), 0);
    if (bytes > RELAY_LIMITS.headerBytes) throw new Error('Relay headers too large');
    result[key] = Array.isArray(raw) ? values : raw;
  }
  return result;
}
function request(message, origin, event = false) {
  if (!UUID.test(message.id) || !['GET', 'POST'].includes(message.method) ||
      typeof message.target !== 'string' || !message.target.startsWith('/') || message.target.startsWith('//') ||
      /[\r\n\0#]/.test(message.target) || Buffer.byteLength(message.target) > RELAY_LIMITS.targetBytes ||
      (event && (message.method !== 'GET' || message.target !== '/api/events'))) throw new Error('Invalid relay request');
  const parsed = headers(message.headers);
  if (parsed.host?.toLowerCase() !== new URL(origin).host || parsed['sec-fetch-site'] === 'cross-site' ||
      (parsed.origin !== undefined && parsed.origin !== origin) ||
      ((message.method === 'POST' || event) && parsed.origin !== origin) ||
      (message.method === 'POST' && (parsed['x-theall-client'] !== '1' || parsed['content-type']?.split(';')[0].trim().toLowerCase() !== 'application/json'))) throw new Error('Invalid relay origin');
  const body = event ? Buffer.alloc(0) : decoded(message.body, RELAY_LIMITS.requestBytes);
  if (message.method === 'GET' && body.length) throw new Error('Invalid GET body');
  return { method: message.method, target: message.target, headers: parsed, body, origin };
}

/** Outbound host for the existing single-host relay v1; public paths have no host-ID prefix. */
export class RelayClient {
  constructor({ url, privateKey, publicKey, handleRequest, openEvents, onStatus = () => {} }) {
    this.origin = relayOrigin(url);
    try {
      this.key = createPrivateKey(privateKey);
      if (this.key.asymmetricKeyType !== 'ed25519') throw new Error();
      const derived = createPublicKey(this.key).export({ type: 'spki', format: 'der' }).subarray(-32);
      if (publicKey && !timingSafeEqual(derived, decoded(publicKey, 32, 32))) throw new Error();
      this.publicKey = derived.toString('base64');
    } catch { throw new Error('Relay identity must be a matching Ed25519 private key.'); }
    if (typeof handleRequest !== 'function') throw new Error('Relay request handler is required.');
    this.handleRequest = handleRequest;
    this.openEvents = openEvents;
    this.onStatus = onStatus;
    this.active = false;
    this.connected = false;
    this.generation = 0;
    this.retryDelay = 2000;
    this.session = null;
    this.retryTimer = null;
  }
  // This is the deployment key identifier, never a URL segment or routing key.
  get hostID() { return this.publicKey; }
  status(state, error) {
    this.connected = state === 'ready';
    try { this.onStatus({ state, connected: this.connected, origin: this.origin, ...(error ? { error } : {}) }); } catch { /* The host UI cannot break transport cleanup. */ }
  }
  start() {
    if (this.active) return this;
    this.active = true;
    this.retryDelay = 2000;
    this.connect();
    return this;
  }
  close() {
    this.active = false;
    clearTimeout(this.retryTimer); this.retryTimer = null;
    this.dispose(this.session);
    this.status('stopped');
  }
  current(session) { return this.active && this.session === session && session.generation === this.generation; }
  connect() {
    if (!this.active) return;
    const endpoint = new URL('/host', this.origin);
    endpoint.protocol = endpoint.protocol === 'https:' ? 'wss:' : 'ws:';
    this.status('connecting');
    if (!this.active) return;
    const socket = new WebSocket(endpoint, { maxPayload: RELAY_LIMITS.frameBytes, perMessageDeflate: false, followRedirects: false, handshakeTimeout: 15000 });
    const session = { socket, generation: ++this.generation, ready: false, challenged: false, pending: new Set(), events: new Map(), alive: true };
    this.session = session;
    session.timeout = setTimeout(() => this.disconnected(session), 15000); session.timeout.unref?.();
    session.heartbeat = setInterval(() => {
      if (!this.current(session) || socket.readyState !== WebSocket.OPEN) return;
      if (!session.alive) { this.disconnected(session); return; }
      session.alive = false;
      socket.ping(error => { if (error) this.disconnected(session); });
    }, 20000); session.heartbeat.unref?.();
    socket.on('pong', () => { if (this.current(session)) session.alive = true; });
    socket.on('message', (raw, binary) => {
      if (!this.current(session)) return;
      this.receive(session, raw, binary).catch(() => this.disconnected(session));
    });
    socket.on('error', () => this.disconnected(session));
    socket.on('close', () => this.disconnected(session));
    socket.on('unexpected-response', (_request, response) => { response.resume(); this.disconnected(session); });
  }
  dispose(session) {
    if (!session) return;
    if (this.session === session) { this.session = null; this.generation++; }
    clearTimeout(session.timeout); clearInterval(session.heartbeat);
    const channels = [...session.events.values()]; session.events.clear(); session.pending.clear();
    for (const record of channels) { record.closed = true; try { record.channel?.close(); } catch {} }
    session.socket.terminate();
  }
  disconnected(session) {
    if (!this.current(session)) return;
    this.dispose(session);
    this.status('disconnected', 'Relay unavailable. Check its address and configured public key.');
    if (!this.active) return;
    const delay = this.retryDelay; this.retryDelay = Math.min(this.retryDelay * 2, 30000);
    clearTimeout(this.retryTimer);
    this.retryTimer = setTimeout(() => { this.retryTimer = null; this.connect(); }, delay);
    this.retryTimer.unref?.();
  }
  send(session, value) {
    if (!this.current(session) || session.socket.readyState !== WebSocket.OPEN) return false;
    const text = JSON.stringify(value);
    // Do not retain a second application-level queue or replay after reconnect.
    if (Buffer.byteLength(text) > RELAY_LIMITS.frameBytes || session.socket.bufferedAmount + Buffer.byteLength(text) > RELAY_LIMITS.bufferedBytes) {
      this.disconnected(session); return false;
    }
    session.socket.send(text, error => { if (error) this.disconnected(session); });
    return true;
  }
  async receive(session, raw, binary) {
    if (binary || raw.length > RELAY_LIMITS.frameBytes || (!session.ready && raw.length > 4096)) throw new Error('Invalid relay message');
    const message = JSON.parse(raw.toString('utf8'));
    if (!message || Array.isArray(message) || typeof message !== 'object') throw new Error('Invalid relay message');
    if (message.type === 'challenge' && !session.ready && !session.challenged && message.protocol === 1) {
      const nonce = decoded(message.nonce, 32, 32);
      session.challenged = true;
      this.send(session, { type: 'authenticate', publicKey: this.publicKey, signature: sign(null, nonce, this.key).toString('base64') });
      return;
    }
    if (message.type === 'ready' && session.challenged && !session.ready && message.protocol === 1) {
      session.ready = true; clearTimeout(session.timeout); this.retryDelay = 2000;
      this.status('ready'); return;
    }
    if (!session.ready) throw new Error('Relay has not authenticated');
    if (message.type === 'request') {
      const incoming = request(message, this.origin);
      if (session.pending.has(message.id)) throw new Error('Repeated relay request');
      if (session.pending.size >= RELAY_LIMITS.pending) {
        this.send(session, { type: 'response', id: message.id, status: 503, headers: { 'content-type': 'application/json' }, body: ERROR_BODY.toString('base64') }); return;
      }
      session.pending.add(message.id);
      try {
        let response;
        try { response = await this.handleRequest(incoming); }
        catch { response = { status: 500, headers: { 'content-type': 'application/json' }, body: ERROR_BODY }; }
        if (!this.current(session)) return;
        if (!Number.isInteger(response?.status) || response.status < 200 || response.status > 599 || !Buffer.isBuffer(response.body)) throw new Error('Invalid relay response');
        if (response.body.length > RELAY_LIMITS.responseBytes || 4 * Math.ceil(response.body.length / 3) + RELAY_LIMITS.headerBytes + 1024 > RELAY_LIMITS.bufferedBytes) response = { status: 413, headers: { 'content-type': 'application/json' }, body: Buffer.from('{"error":"Response too large; request fewer messages."}') };
        const responseHeaders = headers(response.headers ?? {}, true);
        this.send(session, { type: 'response', id: message.id, status: response.status, headers: responseHeaders, body: response.body.toString('base64') });
      } finally { session.pending.delete(message.id); }
      return;
    }
    if (message.type === 'event_open') {
      const incoming = request(message, this.origin, true);
      if (session.events.has(message.id)) throw new Error('Repeated event channel');
      if (session.events.size >= RELAY_LIMITS.events || typeof this.openEvents !== 'function') {
        this.send(session, { type: 'event_opened', id: message.id, status: 503 }); return;
      }
      const record = { channel: null, opened: false, closed: false, queue: [], queuedBytes: 0, rateStart: Date.now(), received: 0 };
      session.events.set(message.id, record);
      const close = (notify = true) => {
        if (record.closed) return;
        record.closed = true; session.events.delete(message.id); record.queue = []; record.queuedBytes = 0;
        try { record.channel?.close(); } catch {}
        if (notify && this.current(session)) this.send(session, { type: 'event_close', id: message.id });
      };
      record.close = close;
      const send = text => {
        if (record.closed || !this.current(session)) return;
        if (typeof text !== 'string' || Buffer.byteLength(text) > RELAY_LIMITS.eventBytes) { close(); return; }
        if (!record.opened) {
          record.queuedBytes += Buffer.byteLength(text);
          if (record.queuedBytes > RELAY_LIMITS.bufferedEventBytes) { close(false); return; }
          record.queue.push(text);
        } else if (!this.send(session, { type: 'event_data', id: message.id, text })) close(false);
      };
      try {
        const channel = await this.openEvents({ headers: incoming.headers, origin: this.origin, send, close });
        if (!channel || typeof channel.receive !== 'function' || typeof channel.close !== 'function') throw new Error('Events unavailable');
        record.channel = channel;
        if (!this.current(session) || record.closed) {
          try { channel.close(); } catch {}
          if (this.current(session)) this.send(session, { type: 'event_opened', id: message.id, status: 503 });
          return;
        }
        record.opened = true;
        if (!this.send(session, { type: 'event_opened', id: message.id, status: 101 })) { close(false); return; }
        for (const text of record.queue) if (!this.send(session, { type: 'event_data', id: message.id, text })) break;
        record.queue = []; record.queuedBytes = 0;
      } catch (error) {
        close(false);
        const status = Number.isInteger(error?.status) && error.status >= 400 && error.status <= 599 ? error.status : 503;
        if (this.current(session)) this.send(session, { type: 'event_opened', id: message.id, status });
      }
      return;
    }
    if (message.type === 'event_input') {
      if (!UUID.test(message.id) || typeof message.text !== 'string' || Buffer.byteLength(message.text) > RELAY_LIMITS.eventBytes) throw new Error('Invalid event input');
      const record = session.events.get(message.id);
      if (record && record.opened && !record.closed) {
        if (Date.now() - record.rateStart >= 1000) { record.rateStart = Date.now(); record.received = 0; }
        if (++record.received > 30) { record.close(); return; }
        try { record.channel.receive(message.text); } catch { record.close(); }
      }
      return;
    }
    if (message.type === 'event_close') {
      if (!UUID.test(message.id)) throw new Error('Invalid event close');
      session.events.get(message.id)?.close(false); return;
    }
    throw new Error('Unknown relay message');
  }
}
