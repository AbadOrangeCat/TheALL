// No credentials or conversation data are written to browser storage.
export class APIError extends Error {
  constructor(message, status = 0, code = '') { super(message); this.status = status; this.code = code; }
  get uncertain() { return this.code !== 'operation_failed' && (this.status === 0 || this.status >= 500 || this.code === 'request_pending'); }
}

export async function request(path, { body, fetcher = globalThis.fetch, signal, timeoutMs = body === undefined ? 20000 : 45000 } = {}) {
  const controller = new AbortController();
  const cancel = () => controller.abort();
  if (signal?.aborted) controller.abort(); else signal?.addEventListener('abort', cancel, { once: true });
  const timeout = setTimeout(cancel, timeoutMs);
  const options = { credentials: 'same-origin', cache: 'no-store', signal: controller.signal,
    headers: { Accept: 'application/json' } };
  if (body !== undefined) {
    options.method = 'POST';
    options.headers['Content-Type'] = 'application/json';
    options.headers['X-TheAll-Client'] = '1';
    options.body = JSON.stringify(body);
  }
  try {
    const response = await fetcher(path, options);
    let data;
    try { data = await response.json(); }
    catch (error) {
      if (controller.signal.aborted) throw error;
      throw new APIError('Invalid server response', response.ok ? 502 : response.status);
    }
    if (!response.ok) throw new APIError(data.error || `HTTP ${response.status}`, response.status, data.code);
    return data;
  } catch (error) {
    if (signal?.aborted || error instanceof APIError) throw error;
    throw new APIError('connection');
  } finally { clearTimeout(timeout); signal?.removeEventListener('abort', cancel); }
}

export function chatPath(id, suffix = '') { return `/api/chats/${encodeURIComponent(id)}${suffix}`; }

// Pagination carries absolute indices so polling the latest page does not discard older pages.
export function mergePage(previous, incoming) {
  if (!previous || previous.id !== incoming.id || incoming.total < previous.total ||
      (previous.bootID && incoming.bootID && previous.bootID !== incoming.bootID)) return incoming;
  const slots = new Map();
  previous.messages.forEach((message, offset) => slots.set(previous.start + offset, message));
  // Late-visible errors or restored transcripts can shift absolute indices.
  // Drop stale pages rather than splicing messages from different revisions.
  for (const [offset, message] of incoming.messages.entries()) {
    const index = incoming.start + offset;
    if (slots.has(index) && slots.get(index).id !== message.id) return incoming;
    slots.set(index, message);
  }
  const start = Math.min(previous.start, incoming.start);
  const messages = [];
  for (let i = start; i < incoming.total; i++) {
    if (!slots.has(i)) return incoming; // A disconnected tail is refetched, never shown as complete.
    messages.push(slots.get(i));
  }
  return { ...incoming, start, messages };
}

export function turns(messages) {
  const result = [];
  for (const message of messages) {
    if (message.role === 'user' || !result.length) result.push({ id: message.id, user: null, progress: [], answers: [] });
    const turn = result.at(-1);
    if (message.role === 'user') turn.user = message;
    else if (message.role === 'thinking' || message.isIntermediate) turn.progress.push(message);
    else if (message.role !== 'tool' || message.isError) turn.answers.push(message);
  }
  return result;
}

// LAN HTTP is not a secure context. getRandomValues remains available there;
// never replace request identity with a non-cryptographic random source.
export function randomUUID(crypto = globalThis.crypto) {
  if (typeof crypto?.randomUUID === 'function') return crypto.randomUUID();
  if (typeof crypto?.getRandomValues !== 'function') throw new Error('Secure random values are unavailable');
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export function isPrivateLANHTTP(location) {
  if (location.protocol !== 'http:') return false;
  const host = location.hostname;
  if (typeof host !== 'string' || !/^(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}$/.test(host)) return false;
  const parts = host.split('.').map(Number);
  if (parts.some(part => part > 255)) return false;
  return parts[0] === 10 || (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) ||
    (parts[0] === 192 && parts[1] === 168);
}

// The caller explicitly retries uncertain requests using the SAME object/requestId.
export function operation(path, body, requestId = randomUUID()) {
  return Object.freeze({ path, body: Object.freeze({ ...body, requestId }) });
}

export function readPairToken(location, history) {
  const token = new URLSearchParams(location.hash.slice(1)).get('pair');
  if (location.hash) history.replaceState(null, '', location.pathname + location.search);
  return token || '';
}

export function safeLink(value) {
  try { const url = new URL(value); return ['https:', 'http:'].includes(url.protocol) ? url.href : null; }
  catch { return null; }
}
