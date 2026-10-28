import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { EventEmitter } from 'node:events';
import { createECDH, randomBytes, randomUUID } from 'node:crypto';
import { createRuntime } from '../src/runtime.mjs';
import { Store } from '../src/store.mjs';

const tick = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
function subscription() { const key = createECDH('prime256v1'); key.generateKeys(); return { endpoint: 'https://fcm.googleapis.com/fake/' + randomUUID(), expirationTime: null,
  keys: { p256dh: key.getPublicKey().toString('base64url'), auth: randomBytes(16).toString('base64url') } }; }
async function fixture(t, behavior = {}) {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'theall-notifications-')), sessions = [], relays = [], sent = [];
  class Session extends EventEmitter {
    constructor({ chat }) { super(); this.chat = chat; this.questions = []; this.isReady = false; this.models = [{ id: 'known', title: 'Known', reasoningEfforts: ['low', 'high'] }]; sessions.push(this); }
    async start() { this.chat.conversationID ||= randomUUID(); this.isReady = true; this.emit('change'); }
    async close() { this.isReady = false; }
    async send(input) { assert(input.stillAuthorized()); this.chat.model=input.model; this.chat.messages.push({ id: randomUUID(), role: 'user', text: input.text }); this.emit('change'); }
    complete(id = randomUUID()) { this.chat.messages.push({ id: randomUUID(), role: 'assistant', text: 'Do not include this private answer in a push', completedAt: new Date().toISOString(), durationMs: 1200, completionStatus: 'completed' }); this.emit('completed', { id, chatId: this.chat.id }); return id; }
  }
  class Relay {
    constructor(options) { Object.assign(this, options); this.origin = options.url; relays.push(this); }
    start() { this.onStatus({ state: 'ready', connected: true }); }
    close() { this.onStatus({ state: 'stopped', connected: false }); }
  }
  const runtime = await createRuntime({ dataDir, Session, Relay,
    encrypt: async value => { await behavior.encrypt?.(JSON.parse(value)); return Buffer.from('sealed:' + value); },
    decrypt: async bytes => bytes.toString().replace(/^sealed:/, ''),
    pushSender: async (request, { signal }) => { sent.push({ request, signal }); return await behavior.send?.(request, signal) ?? 201; } });
  t.after(async () => { behavior.release?.(); await runtime.close(); fs.rmSync(dataDir, { recursive: true, force: true }); });
  const f = { runtime, sessions, relays, sent, dataDir,
    async desktopAPI(route, body) { const response = await fetch(runtime.url + route, { method: body ? 'POST' : 'GET', headers: { cookie: `TheAllDesktopSession=${runtime.desktopToken}`,
      ...(body ? { origin: runtime.url, 'content-type': 'application/json', 'x-theall-client': '1' } : {}) }, body: body ? JSON.stringify({ bootID: runtime.bootID, requestId: randomUUID(), ...body }) : undefined }); return { status: response.status, body: await response.json() }; },
    async mobile(route, body, cookie = f.cookie, extraHeaders = {}) { const relay = relays.at(-1), origin = relay.origin;
      const response = await relay.handleRequest({ method: body === undefined ? 'GET' : 'POST', target: route, origin,
        headers: { host: new URL(origin).host, ...(cookie ? { cookie } : {}), ...(body === undefined ? {} : { origin, 'content-type': 'application/json', 'x-theall-client': '1' }), ...extraHeaders }, body: body === undefined ? Buffer.alloc(0) : Buffer.from(JSON.stringify(body)) });
      return { status: response.status, body: JSON.parse(response.body), headers: response.headers }; },
    async pair(access = {}) { await runtime.desktop('mobile.relay.configure', { url: 'https://relay.fixture.invalid' });
      const invitation = await runtime.desktop('mobile.pair', { mode: 'relay', ...access });
      const result = await f.mobile('/api/pair', { token: new URL(invitation.url).hash.slice(6), deviceName: 'Synthetic phone' }, ''); assert.equal(result.status, 200);
      f.cookie = result.headers['set-cookie'].split(';')[0]; return f.cookie; },
    async chat() { await runtime.desktop('connection.save', { provider: 'claude', apiKey: 'fake-key', baseURL: 'http://127.0.0.1:9' });
      const w = await runtime.desktop('workspace.create'); const chat = await runtime.desktop('tab.create', { workspaceId: w.id, directory: dataDir, provider: 'claude' });
      assert.equal((await f.desktopAPI('/api/chats/' + chat.terminalId + '/send', { text: 'Private test prompt', model: 'known' })).status, 200); return { workspaceId: w.id, id: chat.terminalId }; }
  }; return f;
}

test('notification API requires a paired device and CSRF validation but read-only devices may subscribe themselves', async t => {
  const f = await fixture(t), chat = await f.chat();
  assert.equal((await f.desktopAPI('/api/notifications')).status, 403);
  await f.pair({ writable: false, workspaceId: chat.workspaceId });
  assert.equal((await f.mobile('/api/notifications', undefined, '')).status, 401);
  assert.equal((await f.mobile('/api/notifications', undefined, undefined, { origin: 'https://evil.invalid' })).status, 403);
  const state = await f.mobile('/api/notifications'); assert.equal(state.status, 200); assert.equal(state.body.available, true); assert.equal(state.body.enabled, false);
  const input = { subscription: subscription(), language: 'en' };
  assert.equal((await f.mobile('/api/notifications/subscribe', input, undefined, { 'x-theall-client': '0' })).status, 403);
  assert.equal((await f.mobile('/api/notifications/subscribe', { ...input, deviceId: randomUUID() })).status, 400);
  assert.equal((await f.mobile('/api/notifications/subscribe', input)).status, 200);
  assert.equal((await f.mobile('/api/notifications')).body.enabled, true);
  assert.equal((await f.mobile('/api/notifications/test', {})).status, 200); assert.equal(f.sent.length, 1);
  assert.equal((await f.mobile('/api/notifications/unsubscribe', {})).body.enabled, false);
  assert.equal((await f.mobile('/api/notifications')).body.enabled, false);
});

test('completion sends in the background without WebSockets, honors current ownership and persists timing plus encrypted identity', async t => {
  const f = await fixture(t), first = await f.chat(); await f.pair({ workspaceId: first.workspaceId, writable: false });
  await f.mobile('/api/notifications/subscribe', { subscription: subscription(), language: 'ko' });
  const eventID = f.sessions[0].complete(); await tick(); assert.equal(f.sent.length, 1);
  f.sessions[0].emit('completed', { id: eventID, chatId: first.id }); await tick(); assert.equal(f.sent.length, 1);
  const snapshot = await f.mobile('/api/chats/' + first.id); assert.equal(snapshot.body.messages.at(-1).durationMs, 1200);
  const other = await f.chat(); f.sessions.at(-1).complete(); await tick(); assert.equal(f.sent.length, 1);
  const devices = (await f.runtime.desktop('mobile.devices')).devices;
  await f.runtime.desktop('mobile.revoke', { id: devices[0].id }); f.sessions[0].complete(); await tick(); assert.equal(f.sent.length, 1);
  assert.equal((await f.mobile('/api/notifications')).status, 401);
  const persisted = JSON.parse(fs.readFileSync(path.join(f.dataDir, 'workspaces.json')));
  assert.equal(persisted.chats[first.id].messages.find(m => m.durationMs).completionStatus, 'completed');
  assert.equal(persisted.notifications.length, 0); assert.equal(persisted.privateKey, undefined);
  assert(fs.readFileSync(path.join(f.dataDir, 'Credentials/web-push.bin'), 'utf8').startsWith('sealed:'));
  const restored = new Store(f.dataDir); assert.equal(restored.state.chats[other.id].messages.at(-1).durationMs, 1200);
});

test('revoking a mobile device or disabling relay cancels pending notification delivery', async t => {
  for (const mode of ['revoke', 'disable']) {
    const f = await fixture(t, { send: (request, signal) => new Promise(resolve => signal.addEventListener('abort', () => resolve(201), { once: true })) });
    await f.chat(); await f.pair(); await f.mobile('/api/notifications/subscribe', { subscription: subscription(), language: 'fr' });
    f.sessions[0].complete(); await tick(); assert.equal(f.sent.length, 1);
    if (mode === 'revoke') await f.runtime.desktop('mobile.revoke', { id: (await f.runtime.desktop('mobile.devices')).devices[0].id });
    else await f.runtime.desktop('mobile.relay.configure', { url: '' });
    assert.equal(f.sent[0].signal.aborted, true);
  }
});

test('disabling relay while first VAPID key is being encrypted cannot leave an enabled subscription', async t => {
  const gate = deferred(), entered = deferred();
  const f = await fixture(t, { encrypt: async value => { if (value.version === 1 && value.privateKey) { entered.resolve(); await gate.promise; } }, release: gate.resolve });
  await f.pair(); const pending = f.mobile('/api/notifications/subscribe', { subscription: subscription(), language: 'ja' }); await entered.promise;
  await f.runtime.desktop('mobile.relay.configure', { url: '' }); gate.resolve();
  assert.notEqual((await pending).status, 200);
  assert.equal(JSON.parse(fs.readFileSync(path.join(f.dataDir, 'workspaces.json'))).notifications, undefined);
});

test('damaged notification storage and key are preserved instead of silently replacing histories or credentials', async t => {
  const f = await fixture(t); await f.chat(); await f.pair();
  fs.mkdirSync(path.join(f.dataDir, 'Credentials'), { recursive: true });
  const file = path.join(f.dataDir, 'Credentials/web-push.bin'); fs.writeFileSync(file, 'sealed:{"version":1,"privateKey":"bad"}');
  const before = fs.readFileSync(file); assert.equal((await f.mobile('/api/notifications')).status, 500); assert.deepEqual(fs.readFileSync(file), before);
  const storeFile = path.join(f.dataDir, 'workspaces.json'), data = JSON.parse(fs.readFileSync(storeFile));
  data.notifications = [{ deviceId: 'bad' }]; fs.writeFileSync(storeFile, JSON.stringify(data)); const original = fs.readFileSync(storeFile);
  assert.throws(() => new Store(f.dataDir), /preserved/); assert.deepEqual(fs.readFileSync(storeFile), original);
});

test('draft effort survives unavailable model capabilities; malformed effort does not replace a saved draft', async t => {
  const f = await fixture(t), chat = await f.chat();
  await f.runtime.desktop('draft.save', { id: chat.id, text: 'Keep this draft', images: [], model: 'unlisted-model', reasoningEffort: 'high' });
  await assert.rejects(f.runtime.desktop('draft.save', { id: chat.id, text: 'Wrong', images: [], model: 'known', reasoningEffort: 'invalid value' }), /Invalid reasoning effort/);
  assert.equal((await f.runtime.desktop('draft.get', { id: chat.id })).text, 'Keep this draft');
  await f.runtime.desktop('chat.update', { id: chat.id, reasoningEffort: 'low' });
  const restored = new Store(f.dataDir); assert.equal(restored.chat(chat.id).reasoningEffort, 'low'); assert.equal(restored.chat(chat.id).draft.reasoningEffort, 'high');
});
