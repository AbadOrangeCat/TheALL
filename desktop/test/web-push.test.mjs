import test from 'node:test';
import assert from 'node:assert/strict';
import { createECDH, createDecipheriv, createPublicKey, hkdfSync, randomBytes, randomUUID, verify } from 'node:crypto';
import { encryptPush, vapidAuthorization, pushEndpoint, validateSubscription, validatePushIdentity, newPushIdentity,
  notificationPayload, PushNotifications } from '../src/web-push.mjs';

const b64 = value => Buffer.from(value, 'base64url');
const tick = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
export function browserSubscription(endpoint = 'https://fcm.googleapis.com/fcm/send/fake-test-token') {
  const key = createECDH('prime256v1'); key.generateKeys();
  return { key, subscription: { endpoint, expirationTime: null, keys: { p256dh: key.getPublicKey().toString('base64url'), auth: randomBytes(16).toString('base64url') } } };
}
export function decryptRequest(request, receiver) {
  const body = request.body, salt = body.subarray(0, 16), pub = body.subarray(21, 21 + body[20]), encrypted = body.subarray(21 + body[20]);
  const ikm = hkdfSync('sha256', receiver.key.computeSecret(pub), b64(receiver.subscription.keys.auth), Buffer.concat([Buffer.from('WebPush: info\0'), receiver.key.getPublicKey(), pub]), 32);
  const cek = hkdfSync('sha256', ikm, salt, Buffer.from('Content-Encoding: aes128gcm\0'), 16);
  const nonce = hkdfSync('sha256', ikm, salt, Buffer.from('Content-Encoding: nonce\0'), 12);
  const cipher = createDecipheriv('aes-128-gcm', cek, nonce); cipher.setAuthTag(encrypted.subarray(-16));
  const padded = Buffer.concat([cipher.update(encrypted.subarray(0, -16)), cipher.final()]);
  assert.equal(padded.at(-1), 2); return JSON.parse(padded.subarray(0, -1).toString());
}

// The same official, deterministic cross-platform vector is used by Swift.
test('RFC 8291 Appendix A encryption exactly matches the published ciphertext', () => {
  const subscription = { keys: {
    p256dh: 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4',
    auth: 'BTBZMqHH6r4Tts7J_aSIgg' } };
  const encrypted = encryptPush(subscription, Buffer.from('When I grow up, I want to be a watermelon'), {
    privateKey: b64('yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw'), salt: b64('DGv6ra1nlYgDCS1FRnbzlw') });
  assert.equal(encrypted.subarray(0, 86).toString('base64url'), 'DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8');
  assert.equal(encrypted.subarray(86).toString('base64url'), '8pfeW0KbunFT06SuDKoJH9Ql87S1QUrdirN6GcG7sFz1y1sqLgVi1VhjVkHsUoEsbI_0LpXMuGvnzQ');
});

test('VAPID has a verifiable P1363 ES256 signature, audience and bounded expiry', () => {
  const identity = newPushIdentity(), now = Date.now();
  const authorization = vapidAuthorization(identity, 'https://web.push.apple.com/token', now);
  const [, jwt, publicKey] = authorization.match(/^vapid t=(.*), k=(.*)$/);
  const [header, claims, signature] = jwt.split('.'), pub = b64(publicKey);
  assert.deepEqual(JSON.parse(b64(header)), { typ: 'JWT', alg: 'ES256' });
  assert.deepEqual(JSON.parse(b64(claims)), { aud: 'https://web.push.apple.com', exp: Math.floor(now / 1000) + 43200, sub: 'https://github.com/AbadOrangeCat/TheALL' });
  const key = createPublicKey({ key: { kty: 'EC', crv: 'P-256', x: pub.subarray(1, 33).toString('base64url'), y: pub.subarray(33).toString('base64url') }, format: 'jwk' });
  assert.equal(b64(signature).length, 64);
  assert(verify('sha256', Buffer.from(header + '.' + claims), { key, dsaEncoding: 'ieee-p1363' }, b64(signature)));
  assert.throws(() => validatePushIdentity({ ...identity, publicKey: newPushIdentity().publicKey }), /damaged/);
});

test('push endpoint validation rejects untrusted hosts, ambiguous URLs, ports and invalid key material', () => {
  for (const host of ['push.apple.com', 'web.push.apple.com', 'fcm.googleapis.com', 'updates.push.services.mozilla.com', 'us.updates.push.services.mozilla.com']) assert(pushEndpoint('https://' + host + '/token'));
  for (const url of ['http://fcm.googleapis.com/t', 'https://127.0.0.1/t', 'https://[::1]/t', 'https://localhost/t', 'https://push.apple.com.evil.test/t',
    'https://evilpush.apple.com/t', 'https://user:password@fcm.googleapis.com/t', 'https://fcm.googleapis.com:8443/t',
    'https://fcm.googleapis.com/t#fragment', 'https://fcm.googleapis.com\\@evil.test/t', 'https://fcm.googleapis.com./t', 'https://example.com/t']) assert.throws(() => pushEndpoint(url));
  const { subscription } = browserSubscription();
  assert.deepEqual(validateSubscription(subscription), subscription);
  for (const keys of [{ ...subscription.keys, auth: 'a' }, { ...subscription.keys, p256dh: Buffer.alloc(65).toString('base64url') }, { ...subscription.keys, auth: subscription.keys.auth + '=' }]) assert.throws(() => validateSubscription({ ...subscription, keys }));
  assert.throws(() => encryptPush(subscription, Buffer.alloc(3001)));
});

function fixture(options = {}) {
  const devices = new Map(), delivered = [], receivers = new Map(); let saved = 0, identity = options.identity;
  const store = { state: {}, async readSecret(name) { assert.equal(name, 'web-push'); await options.read?.(); return identity ?? null; },
    async writeSecret(name, value) { assert.equal(name, 'web-push'); identity = structuredClone(value); } };
  let time = Date.now();
  const manager = new PushNotifications({ store, save() { saved++; options.save?.(); }, now: () => time,
    authorized: (record, chatId) => { const device = devices.get(record.deviceId); return !!device && device.origin === record.origin && (!device.chatId || !chatId || device.chatId === chatId) && (!device.expiresAt || device.expiresAt > time); },
    send: async (request, { signal }) => { delivered.push({ request, signal, payload: decryptRequest(request, receivers.get(request.url)) }); return await options.send?.(request, signal) ?? 201; } });
  return { manager, store, devices, delivered, get saved() { return saved; }, get identity() { return identity; }, advance(ms) { time += ms; },
    async pair({ origin = 'https://theall.example', endpoint, chatId } = {}) { const device = { id: randomUUID(), origin, chatId }, receiver = browserSubscription(endpoint); devices.set(device.id, device); receivers.set(receiver.subscription.endpoint, receiver);
      await manager.subscribe(device, { subscription: receiver.subscription, language: 'zh-Hans' }); return { device, receiver }; } };
}

test('insecure origin never creates credentials; concurrent status reuses one durable identity; damaged key is preserved', async () => {
  const f = fixture(), device = { id: randomUUID(), origin: 'http://192.168.1.2:8765' };
  assert.deepEqual(await f.manager.status(device), { available: false, enabled: false, reason: 'https_required' }); assert.equal(f.identity, undefined);
  device.origin = 'https://theall.example'; f.devices.set(device.id, device);
  const states = await Promise.all([f.manager.status(device), f.manager.status(device)]);
  assert.equal(states[0].publicKey, states[1].publicKey); assert.equal(states[0].enabled, false);
  const broken = fixture({ identity: { version: 1, privateKey: 'broken', publicKey: 'broken' } }); broken.devices.set(device.id, device);
  await assert.rejects(broken.manager.status(device), /damaged/); assert.equal(broken.identity.privateKey, 'broken');
});

test('background completion is generic, localized, decryptable, deduplicated and grant scoped', async () => {
  const f = fixture(), chatId = randomUUID();
  const a = await f.pair({ chatId, endpoint: 'https://fcm.googleapis.com/a' });
  await f.pair({ chatId: randomUUID(), endpoint: 'https://web.push.apple.com/b' });
  const event = { id: randomUUID(), chatId }; await f.manager.completed(event); await f.manager.completed(event);
  assert.equal(f.delivered.length, 1); const { request, payload } = f.delivered[0];
  assert.deepEqual(Object.keys(payload).sort(), ['version', 'id', 'type', 'chatId', 'title', 'body', 'url'].sort());
  assert.equal(payload.chatId, chatId); assert.equal(payload.url, '/?chat=' + chatId); assert.equal(payload.title, 'TheAll'); assert.match(payload.body, /任务已完成/);
  assert.equal(request.headers.ttl, '300'); assert.equal(request.headers.urgency, 'normal');
  a.device.chatId = randomUUID(); await f.manager.completed({ id: randomUUID(), chatId }); assert.equal(f.delivered.length, 1);
  for (const language of ['en', 'zh-Hans', 'fr', 'ja', 'ko']) assert.equal(notificationPayload('test', language).url, '/');
});

test('revoking authorization, unsubscribing, disabling origin or closing aborts an in-flight send', async () => {
  for (const action of ['revoke', 'unsubscribe', 'disable', 'close']) {
    const f = fixture({ send: (request, signal) => new Promise(resolve => signal.addEventListener('abort', () => resolve(201), { once: true })) });
    const { device } = await f.pair(), pending = f.manager.completed({ id: randomUUID(), chatId: randomUUID() }); await tick();
    assert.equal(f.delivered.length, 1);
    if (action === 'revoke') { f.devices.delete(device.id); f.manager.sweep(); }
    if (action === 'unsubscribe') f.manager.unsubscribe(device.id);
    if (action === 'disable') f.manager.closeOrigin(device.origin);
    if (action === 'close') f.manager.close();
    await pending; assert.equal(f.delivered[0].signal.aborted, true);
  }
});

test('unsubscribe and disable prevent late key-loading subscriptions, including disable/re-enable race', async () => {
  for (const action of ['unsubscribe', 'disable']) {
    const gate = deferred(), f = fixture({ read: () => gate.promise });
    const device = { id: randomUUID(), origin: 'https://theall.example' }; f.devices.set(device.id, device);
    const pending = f.manager.subscribe(device, { subscription: browserSubscription().subscription, language: 'en' }); await tick();
    if (action === 'unsubscribe') f.manager.unsubscribe(device.id); else { f.manager.closeOrigin(device.origin); f.manager.openOrigin(device.origin); }
    gate.resolve(); await assert.rejects(pending, /cancelled/); assert.equal(f.manager.records.length, 0);
  }
});

test('re-pairing the same endpoint removes its older broader device grant', async () => {
  const f = fixture(), first = await f.pair(), restricted = { id: randomUUID(), origin: first.device.origin, chatId: randomUUID() };
  f.devices.set(restricted.id, restricted);
  await f.manager.subscribe(restricted, { subscription: first.receiver.subscription, language: 'en' });
  assert.equal(f.manager.records.length, 1); assert.equal(f.manager.records[0].deviceId, restricted.id);
  await f.manager.completed({ id: randomUUID(), chatId: randomUUID() }); assert.equal(f.delivered.length, 0);
  assert.equal((await f.manager.status(first.device)).enabled, false);
});

test('expired grants and endpoints suppress delivery; invalid endpoint responses remove saved subscription; tests are rate limited', async () => {
  const f = fixture(), { device } = await f.pair();
  await f.manager.test(device); await assert.rejects(f.manager.test(device), /not sent/); assert.equal(f.delivered.length, 1);
  f.advance(11000); await f.manager.test(device); assert.equal(f.delivered.length, 2);
  device.expiresAt = 1; await f.manager.completed({ id: randomUUID(), chatId: randomUUID() }); assert.equal(f.delivered.length, 2);
  for (const status of [404, 410, 302, 429, 500]) {
    const bad = fixture({ send: () => status }); await bad.pair(); await bad.manager.completed({ id: randomUUID(), chatId: randomUUID() });
    assert.equal(bad.manager.records.length, [404, 410].includes(status) ? 0 : 1); assert.equal(bad.delivered.length, 1);
  }
});

test('failed persistence rolls back subscription changes', async () => {
  const f = fixture({ save() { throw new Error('disk full'); } });
  await assert.rejects(f.pair(), /disk full/); assert.equal(f.manager.records.length, 0);
});

test('closing releases pending work even when an injected sender ignores cancellation', async () => {
  const f = fixture({ send: () => new Promise(() => {}) }); await f.pair();
  const delivery = f.manager.completed({ id: randomUUID(), chatId: randomUUID() }); await tick();
  f.manager.close(); await delivery; assert.equal(f.manager.pending.size, 0); assert.equal(f.delivered[0].signal.aborted, true);
});

test('expired subscriptions and revoked grants do not permanently exhaust the subscription quota', async () => {
  const f = fixture();
  for (let index = 0; index < 20; index++) await f.pair({ endpoint: 'https://fcm.googleapis.com/device/' + index });
  assert.equal(f.manager.records.length, 20);
  f.devices.delete(f.manager.records[0].deviceId); f.manager.records[1].subscription.expirationTime = 1;
  await f.pair({ endpoint: 'https://fcm.googleapis.com/replacement' }); assert.equal(f.manager.records.length, 19);
  assert(f.manager.records.every(record => record.subscription.expirationTime !== 1));
});
