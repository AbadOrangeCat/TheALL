import https from 'node:https';
import { createECDH, ECDH, createPrivateKey, createCipheriv, hkdfSync, randomBytes, randomUUID, sign } from 'node:crypto';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const LANGUAGES = new Set(['en', 'zh-Hans', 'fr', 'ja', 'ko']);
const SUBJECT = 'https://github.com/AbadOrangeCat/TheALL';
const MESSAGES = {
  en: ['Task completed. Open TheAll to view the conversation.', 'TheAll notifications are working.'],
  'zh-Hans': ['任务已完成，打开 TheAll 查看对话。', 'TheAll 提醒已正常启用。'],
  fr: ['Tâche terminée. Ouvrez TheAll pour voir la conversation.', 'Les notifications TheAll fonctionnent.'],
  ja: ['タスクが完了しました。TheAll で会話を確認できます。', 'TheAll の通知が有効です。'],
  ko: ['작업이 완료되었습니다. TheAll에서 대화를 확인하세요.', 'TheAll 알림이 정상적으로 작동합니다.']
};
function invalid(message) { throw Object.assign(new Error(message), { status: 400 }); }
function decode(value, length) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]+$/.test(value)) invalid('Invalid push subscription key');
  const bytes = Buffer.from(value, 'base64url');
  if (bytes.length !== length || bytes.toString('base64url') !== value) invalid('Invalid push subscription key');
  return bytes;
}
export function pushEndpoint(value) {
  if (typeof value !== 'string' || value.length > 2048 || /[\x00-\x20\\]/.test(value)) invalid('Invalid push service endpoint');
  let url; try { url = new URL(value); } catch { invalid('Invalid push service endpoint'); }
  const host = url.hostname;
  const known = host === 'push.apple.com' || host.endsWith('.push.apple.com') || host === 'fcm.googleapis.com'
    || host === 'updates.push.services.mozilla.com' || host.endsWith('.updates.push.services.mozilla.com');
  if (url.protocol !== 'https:' || url.port || url.username || url.password || url.hash || !known || url.pathname === '/') invalid('Unsupported push service endpoint');
  return url;
}
export function securePushOrigin(value) {
  try { const url = new URL(value); return !url.username && !url.password && url.origin === value
    && (url.protocol === 'https:' || (url.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname))); }
  catch { return false; }
}
export function validateSubscription(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input) || !input.keys) invalid('Invalid push subscription');
  const endpoint = pushEndpoint(input.endpoint).href;
  const publicKey = decode(input.keys.p256dh, 65), auth = decode(input.keys.auth, 16);
  try { if (publicKey[0] !== 4) throw new Error(); ECDH.convertKey(publicKey, 'prime256v1', undefined, undefined, 'uncompressed'); }
  catch { invalid('Invalid push subscription public key'); }
  const expirationTime = input.expirationTime ?? null;
  if (expirationTime !== null && (!Number.isSafeInteger(expirationTime) || expirationTime <= 0)) invalid('Invalid push subscription expiry');
  return { endpoint, expirationTime, keys: { p256dh: publicKey.toString('base64url'), auth: auth.toString('base64url') } };
}
export function validateNotificationRecords(records) {
  if (!Array.isArray(records) || records.length > 20) throw new Error('Unsupported or damaged notification subscriptions');
  const devices = new Set(), endpoints = new Set();
  for (const record of records) {
    if (!record || !UUID.test(record.deviceId) || !securePushOrigin(record.origin) || !LANGUAGES.has(record.language)
      || devices.has(record.deviceId)) throw new Error('Invalid notification subscription record');
    const subscription = validateSubscription(record.subscription);
    if (endpoints.has(subscription.endpoint)) throw new Error('Duplicate notification subscription');
    devices.add(record.deviceId); endpoints.add(subscription.endpoint);
  }
  return records;
}
function ecdh(privateBytes) {
  const key = createECDH('prime256v1'); privateBytes ? key.setPrivateKey(privateBytes) : key.generateKeys(); return key;
}
export function newPushIdentity() {
  const key = ecdh(); return { version: 1, privateKey: Buffer.concat([Buffer.alloc(32 - key.getPrivateKey().length), key.getPrivateKey()]).toString('base64url'), publicKey: key.getPublicKey().toString('base64url') };
}
export function validatePushIdentity(value) {
  try {
    if (value?.version !== 1) throw new Error();
    const key = ecdh(decode(value.privateKey, 32));
    if (!key.getPublicKey().equals(decode(value.publicKey, 65))) throw new Error();
    return value;
  } catch { throw new Error('Saved notification identity is damaged. Existing data was preserved.'); }
}
// RFC 8291 / RFC 8188: one aes128gcm record, fresh ECDH key and salt for each send.
export function encryptPush(subscription, plaintext, { privateKey, salt = randomBytes(16) } = {}) {
  const ua = decode(subscription.keys.p256dh, 65), auth = decode(subscription.keys.auth, 16);
  if (!Buffer.isBuffer(plaintext) || plaintext.length > 3000 || !Buffer.isBuffer(salt) || salt.length !== 16) invalid('Notification payload is too large');
  const key = ecdh(privateKey), as = key.getPublicKey();
  const ikm = Buffer.from(hkdfSync('sha256', key.computeSecret(ua), auth, Buffer.concat([Buffer.from('WebPush: info\0'), ua, as]), 32));
  const cek = Buffer.from(hkdfSync('sha256', ikm, salt, Buffer.from('Content-Encoding: aes128gcm\0'), 16));
  const nonce = Buffer.from(hkdfSync('sha256', ikm, salt, Buffer.from('Content-Encoding: nonce\0'), 12));
  const cipher = createCipheriv('aes-128-gcm', cek, nonce);
  const encrypted = Buffer.concat([cipher.update(Buffer.concat([plaintext, Buffer.from([2])])), cipher.final(), cipher.getAuthTag()]);
  const header = Buffer.alloc(21); salt.copy(header); header.writeUInt32BE(4096, 16); header[20] = as.length;
  return Buffer.concat([header, as, encrypted]);
}
export function vapidAuthorization(identity, endpoint, now = Date.now()) {
  validatePushIdentity(identity); const url = pushEndpoint(endpoint), pub = decode(identity.publicKey, 65);
  const key = createPrivateKey({ key: { kty: 'EC', crv: 'P-256', d: identity.privateKey,
    x: pub.subarray(1, 33).toString('base64url'), y: pub.subarray(33).toString('base64url') }, format: 'jwk' });
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const body = encode({ typ: 'JWT', alg: 'ES256' }) + '.' + encode({ aud: url.origin, exp: Math.floor(now / 1000) + 12 * 3600, sub: SUBJECT });
  const signature = sign('sha256', Buffer.from(body), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url');
  return `vapid t=${body}.${signature}, k=${identity.publicKey}`;
}
export function pushRequest(identity, subscription, payload) {
  const checked = validateSubscription(subscription), data = Buffer.from(JSON.stringify(payload));
  const body = encryptPush(checked, data);
  return { url: checked.endpoint, body, headers: { authorization: vapidAuthorization(identity, checked.endpoint),
    'content-encoding': 'aes128gcm', 'content-type': 'application/octet-stream', 'content-length': String(body.length), ttl: '300', urgency: 'normal' } };
}
export function sendPushRequest(request, { signal } = {}) {
  const endpoint = pushEndpoint(request.url);
  return new Promise((resolve, reject) => {
    if (signal?.aborted) { reject(new Error('Notification cancelled')); return; }
    let settled = false;
    const finish = (error, status) => { if (settled) return; settled = true; clearTimeout(timer); error ? reject(error) : resolve(status); };
    const connection = https.request(endpoint, { method: 'POST', headers: request.headers, agent: false, signal }, response => {
      // Never follow redirects and never expose the service's response body.
      const status = response.statusCode || 500; let bytes = 0;
      response.on('data', data => { bytes += data.length; if (bytes > 16384) { connection.destroy(); finish(new Error('Invalid push service response')); } });
      response.on('end', () => finish(null, status));
      response.on('error', () => finish(new Error('Push service connection failed')));
    });
    const timer = setTimeout(() => { connection.destroy(); finish(new Error('Push service timed out')); }, 10000);
    connection.on('error', () => finish(new Error(signal?.aborted ? 'Notification cancelled' : 'Push service connection failed')));
    connection.end(request.body);
  });
}
export function notificationPayload(type, language, { id = randomUUID(), chatId } = {}) {
  if (!UUID.test(id) || !['completed', 'test'].includes(type) || (type === 'completed' && !UUID.test(chatId))) invalid('Invalid completion event');
  const text = MESSAGES[language] || MESSAGES.en;
  return { version: 1, id, type, ...(type === 'completed' ? { chatId } : {}), title: 'TheAll', body: text[type === 'test' ? 1 : 0],
    url: type === 'completed' ? '/?chat=' + chatId : '/' };
}

function untilCancelled(promise, signal) {
  return new Promise((resolve, reject) => {
    const abort = () => finish(new Error('Notification cancelled'));
    const finish = (error, value) => { signal.removeEventListener('abort', abort); error ? reject(error) : resolve(value); };
    if (signal.aborted) { abort(); return; }
    signal.addEventListener('abort', abort, { once: true });
    Promise.resolve(promise).then(value => finish(null, value), error => finish(error));
  });
}

// Persists only subscriptions and the encrypted VAPID identity. Work does not
// depend on an open browser/WebSocket and never retries an uncertain send.
export class PushNotifications {
  constructor({ store, save, authorized, send = sendPushRequest, now = Date.now }) {
    this.store = store; this.save = save; this.authorized = authorized; this.send = send; this.now = now;
    this.pending = new Set(); this.seen = new Set(); this.rate = new Map(); this.generation = new Map(); this.closed = false; this.closedOrigins = new Set(); this.originGeneration = new Map();
  }
  get records() { return this.store.state.notifications || []; }
  async identity() {
    if (!this.identityPromise) this.identityPromise = (async () => {
      let value = await this.store.readSecret('web-push');
      if (value === null) { value = newPushIdentity(); await this.store.writeSecret('web-push', value); }
      return validatePushIdentity(value);
    })().catch(error => { this.identityPromise = null; throw error; });
    return this.identityPromise;
  }
  exists(device) { return this.records.find(r => r.deviceId === device.id && r.origin === device.origin); }
  checkDevice(device) {
    if (this.closed || this.closedOrigins.has(device.origin) || !UUID.test(device.id) || !securePushOrigin(device.origin) || !this.authorized({ deviceId: device.id, origin: device.origin }))
      throw Object.assign(new Error('Notification access is unavailable'), { status: 403 });
  }
  async status(device) {
    if (!securePushOrigin(device.origin)) return { available: false, enabled: false, reason: 'https_required' };
    this.checkDevice(device); const identity = await this.identity(); this.checkDevice(device);
    return { available: true, enabled: !!this.exists(device), publicKey: identity.publicKey };
  }
  async subscribe(device, input) {
    this.checkDevice(device);
    if (!input || Object.keys(input).some(k => !['subscription', 'language'].includes(k)) || !LANGUAGES.has(input.language)) invalid('Invalid notification preferences');
    const subscription = validateSubscription(input.subscription);
    if (subscription.expirationTime !== null && subscription.expirationTime <= this.now()) invalid('This push subscription has expired');
    const generation = this.generation.get(device.id) || 0, originGeneration = this.originGeneration.get(device.origin) || 0;
    await this.identity(); this.checkDevice(device);
    if ((this.generation.get(device.id) || 0) !== generation || (this.originGeneration.get(device.origin) || 0) !== originGeneration) throw Object.assign(new Error('Notification subscription was cancelled'), { status: 409 });
    const records = this.records.filter(r => this.valid(r) && r.deviceId !== device.id && r.subscription.endpoint !== subscription.endpoint);
    if (records.length >= 20) invalid('Too many notification subscriptions');
    const previous = this.store.state.notifications;
    this.store.state.notifications = [...records, { deviceId: device.id, origin: device.origin, language: input.language, subscription }];
    try { this.save(); } catch (error) { this.store.state.notifications = previous; throw error; }
    this.sweep(); return { enabled: true };
  }
  unsubscribe(id) {
    this.generation.set(id, (this.generation.get(id) || 0) + 1); this.rate.delete(id);
    this.store.state.notifications = this.records.filter(r => r.deviceId !== id);
    this.save(); this.sweep(); return { enabled: false };
  }
  valid(record, chatId) {
    return !this.closed && !this.closedOrigins.has(record.origin) && this.records.includes(record) && (!record.subscription.expirationTime || record.subscription.expirationTime > this.now()) && this.authorized(record, chatId);
  }
  sweep() { for (const item of this.pending) if (!this.valid(item.record, item.chatId)) item.controller.abort(); }
  limit(deviceId, type) {
    const time = this.now(), values = (this.rate.get(deviceId) || []).filter(item => time - item.time < 60000);
    if (values.length >= 30 || (type === 'test' && values.some(item => item.type === 'test' && time - item.time < 10000))) return false;
    values.push({ time, type }); this.rate.set(deviceId, values); return true;
  }
  async test(device) {
    this.checkDevice(device); const record = this.exists(device);
    if (!record) throw Object.assign(new Error('Enable notifications first'), { status: 409 });
    const ok = await this.deliver(record, notificationPayload('test', record.language));
    if (!ok) throw Object.assign(new Error('Test notification was not sent. Check your notification settings and try again.'), { status: 503 });
    return { ok: true };
  }
  async completed({ id, chatId }) {
    if (this.closed || !UUID.test(id) || !UUID.test(chatId) || this.seen.has(id)) return;
    this.seen.add(id); if (this.seen.size > 4096) this.seen.delete(this.seen.values().next().value);
    await Promise.all(this.records.map(record => this.deliver(record, notificationPayload('completed', record.language, { id, chatId }))));
  }
  async deliver(record, payload) {
    if (!this.valid(record, payload.chatId) || this.pending.size >= 40 || !this.limit(record.deviceId, payload.type)) return false;
    const item = { record, chatId: payload.chatId, controller: new AbortController() }; this.pending.add(item);
    const timer = setTimeout(() => item.controller.abort(), 10000);
    const expiry = setInterval(() => { if (!this.valid(record, payload.chatId)) item.controller.abort(); }, 500);
    try {
      const identity = await untilCancelled(this.identity(), item.controller.signal);
      if (item.controller.signal.aborted || !this.valid(record, payload.chatId)) return false;
      const request = pushRequest(identity, record.subscription, payload);
      if (item.controller.signal.aborted || !this.valid(record, payload.chatId)) return false;
      const status = await untilCancelled(this.send(request, { signal: item.controller.signal }), item.controller.signal);
      if (item.controller.signal.aborted || !this.valid(record, payload.chatId)) return false;
      if ([404, 410].includes(status)) { this.store.state.notifications = this.records.filter(r => r !== record); this.save(); this.sweep(); }
      return status >= 200 && status < 300;
    } catch { return false; }
    finally { clearTimeout(timer); clearInterval(expiry); this.pending.delete(item); }
  }
  openOrigin(origin) { this.closedOrigins.delete(origin); }
  closeOrigin(origin) {
    if (!origin) return;
    this.closedOrigins.add(origin); this.originGeneration.set(origin, (this.originGeneration.get(origin) || 0) + 1);
    for (const item of this.pending) if (item.record.origin === origin) item.controller.abort();
  }
  close() { this.closed = true; for (const item of this.pending) item.controller.abort(); this.pending.clear(); this.rate.clear(); }
}
