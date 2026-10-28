import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { EventEmitter } from 'node:events';
import { randomBytes, randomUUID, createCipheriv, createDecipheriv } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { createRuntime, lanAddresses } from '../src/runtime.mjs';
import { Store } from '../src/store.mjs';

const root = fileURLToPath(new URL('../..', import.meta.url));
const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; }
async function until(predicate, timeout = 3000) {
  const deadline = Date.now() + timeout;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error('Test condition timed out');
    await new Promise(resolve => setTimeout(resolve, 5));
  }
}

async function fixture(t, behavior = {}) {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'theall-runtime-regression-'));
  const key = randomBytes(32), stats = { instances: [], starts: 0, accepted: 0, sendsFinished: 0 };
  const encryptRaw = text => {
    const nonce = randomBytes(12), cipher = createCipheriv('aes-256-gcm', key, nonce);
    return Buffer.concat([nonce, cipher.update(text), cipher.final(), cipher.getAuthTag()]);
  };
  const decryptRaw = bytes => {
    const cipher = createDecipheriv('aes-256-gcm', key, bytes.subarray(0, 12));
    cipher.setAuthTag(bytes.subarray(-16)); return Buffer.concat([cipher.update(bytes.subarray(12, -16)), cipher.final()]).toString();
  };
  class Session extends EventEmitter {
    constructor({ chat, connection }) {
      super(); this.chat = chat; this.connection = connection; this.isReady = false; this.isBusy = false;
      this.canInterrupt = false; this.questions = []; this.closeCount = 0;
      this.models = [{ id: 'cli-only', title: 'CLI model' }, { id: 'shared', title: 'CLI shared title' }];
      stats.instances.push(this);
    }
    async start() {
      stats.starts++; this.chat.conversationID ||= randomUUID();
      if (behavior.failFirstStart && stats.starts === 1) throw new Error('Synthetic initial CLI failure');
      await behavior.start?.(this); this.isReady = true; this.emit('change');
    }
    async send(input) {
      this.isBusy = true;
      try {
        await behavior.beforeWrite?.(this, input);
        // Match AISession's default: omission must not accidentally make the
        // fake reject, otherwise a missing runtime guard would pass this test.
        const stillAuthorized = input.stillAuthorized || (() => true);
        if (!stillAuthorized()) throw Object.assign(new Error('Device authorization was revoked before submission'), { code: 'authorization_revoked', status: 401 });
        stats.accepted++; this.chat.model = input.model;
        this.chat.messages.push({ id: randomUUID(), role: 'user', text: input.text, images: [] });
        this.chat.messages.push({ id: randomUUID(), role: 'assistant', text: 'Accepted fixture reply', images: [] });
        this.emit('change');
      } finally { this.isBusy = false; stats.sendsFinished++; }
    }
    async close() { this.closeCount++; await this.closeGate; this.isReady = false; this.emit('change'); }
    async interrupt() { this.isBusy = false; }
    async answer() {}
  }
  const options = { dataDir, webRoot: path.join(root, 'TheAll/Mobile/MobileWeb.bundle'), desktopRoot: path.join(root, 'desktop/renderer'),
    Session, encrypt: async text => { await behavior.encrypt?.(text); return encryptRaw(text); },
    decrypt: async bytes => { await behavior.decrypt?.(bytes); return decryptRaw(bytes); } };
  let runtime = await createRuntime(options), closing;
  const f = {
    dataDir, behavior, stats, decryptRaw,
    get runtime() { return runtime; },
    async close() { return closing ||= runtime.close(); },
    async restart() { await f.close(); runtime = await createRuntime(options); closing = undefined; },
    async api(route, { body, url = runtime.url, cookie = `TheAllDesktopSession=${runtime.desktopToken}` } = {}) {
      const response = await fetch(url + route, { method: body === undefined ? 'GET' : 'POST', headers: {
        cookie, ...(body === undefined ? {} : { origin: url, 'content-type': 'application/json', 'x-theall-client': '1' })
      }, body: body === undefined ? undefined : JSON.stringify(body) });
      return { status: response.status, headers: response.headers, body: await response.json() };
    },
    action(values = {}) { return { requestId: randomUUID(), bootID: runtime.bootID, ...values }; },
    async configure(values = {}) { return runtime.desktop('connection.save', { provider: 'claude', apiKey: 'regression-fake-secret', baseURL: 'http://127.0.0.1:9', model: 'configured-default', ...values }); },
    async create() {
      const result = await f.api('/api/chats', { body: f.action({ provider: 'claude', directory: dataDir }) });
      assert.equal(result.status, 201, JSON.stringify(result.body)); return result.body.id;
    }
  };
  t.after(async () => { await f.beforeClose?.(); await f.close(); fs.rmSync(dataDir, { recursive: true, force: true }); });
  return f;
}

test('concurrent recovery from a failed CLI shares one replacement and closes every instance', async t => {
  const f = await fixture(t, { failFirstStart: true }); await f.configure(); const id = await f.create();
  const failed = await f.api(`/api/chats/${id}/send`, { body: f.action({ text: 'Initial failure' }) });
  assert.notEqual(failed.status, 200); assert.equal(f.stats.instances.length, 1);
  const gate = deferred(), first = f.stats.instances[0]; first.closeGate = gate.promise;
  const a = f.api(`/api/chats/${id}/send`, { body: f.action({ text: 'Recovery A' }) });
  await until(() => first.closeCount > 0);
  const b = f.api(`/api/chats/${id}/send`, { body: f.action({ text: 'Recovery B' }) });
  // Keep the existing process's shutdown pending while both HTTP requests arrive.
  await new Promise(resolve => setTimeout(resolve, 30)); gate.resolve();
  const outcomes = await Promise.all([a, b]);
  assert(outcomes.some(r => r.status === 200));
  assert(outcomes.every(r => [200, 409].includes(r.status)));
  assert.equal(f.stats.instances.length, 2, 'Only one replacement CLI may own the conversation');
  assert.equal(f.stats.starts, 2);
  await f.close(); assert(f.stats.instances.every(s => s.closeCount > 0));
});

test('closing during asynchronous credential decryption cannot start a late CLI', async t => {
  const entered = deferred(), gate = deferred(); let block = false;
  const f = await fixture(t, { decrypt: async () => { if (block) { entered.resolve(); await gate.promise; } } });
  await f.configure(); const id = await f.create(); block = true;
  const sending = f.api(`/api/chats/${id}/send`, { body: f.action({ text: 'Must not execute after close' }) }).catch(error => ({ disconnected: true, error }));
  await entered.promise; const closing = f.close(); await tick(); gate.resolve();
  await Promise.all([sending, closing]);
  assert.equal(f.stats.instances.length, 0); assert.equal(f.stats.starts, 0); assert.equal(f.stats.accepted, 0);
  const saved = JSON.parse(fs.readFileSync(path.join(f.dataDir, 'workspaces.json'), 'utf8'));
  assert.equal(saved.chats[id].messages.length, 0);
});

for (const change of ['revoke device', 'disable LAN entry']) {
  test(`phone ${change} during model ACK prevents prompt submission`, async t => {
    const address = lanAddresses()[0]?.address;
    if (!address) { t.skip('No native private IPv4 interface available'); return; }
    const entered = deferred(), gate = deferred();
    const f = await fixture(t, { beforeWrite: async () => { entered.resolve(); await gate.promise; } });
    await f.configure(); const id = await f.create();
    const { url } = await f.runtime.enableLAN({ address, port: 0, mode: 'quick' });
    const invitation = await f.runtime.desktop('mobile.pair', {});
    const token = new URLSearchParams(new URL(invitation.url).hash.slice(1)).get('pair');
    const paired = await f.api('/api/pair', { url, cookie: '', body: { token, deviceName: 'Regression phone' } });
    assert.equal(paired.status, 200); const cookie = paired.headers.get('set-cookie').split(';')[0];
    const sending = f.api(`/api/chats/${id}/send`, { url, cookie, body: f.action({ text: 'Must not execute', model: 'changed-model' }) }).catch(error => ({ disconnected: true, error }));
    await entered.promise;
    if (change === 'revoke device') {
      const devices = await f.runtime.desktop('mobile.devices');
      await f.runtime.desktop('mobile.revoke', { id: devices.devices[0].id });
    } else await f.runtime.desktop('mobile.disable', {});
    gate.resolve(); const outcome = await sending; await until(() => f.stats.sendsFinished === 1);
    assert(outcome.disconnected || [401, 409].includes(outcome.status));
    assert.equal(f.stats.accepted, 0);
    assert.equal((await f.api(`/api/chats/${id}`)).body.messages.length, 0);
  });
}

test('storage failure after accepted AI send caches outcome_unknown and never resubmits its request ID', async t => {
  const f = await fixture(t); await f.configure(); const id = await f.create();
  const file = path.join(f.dataDir, 'workspaces.json'), previous = fs.readFileSync(file);
  const original = Store.prototype.save;
  Store.prototype.save = function () {
    if (this.directory === f.dataDir && this.state.chats[id]?.messages.length) throw new Error('Synthetic disk full after AI acceptance');
    return original.call(this);
  };
  f.beforeClose = () => { Store.prototype.save = original; };
  try {
    const body = f.action({ text: 'Execute once even if persistence fails' });
    const first = await f.api(`/api/chats/${id}/send`, { body });
    assert.equal(first.status, 503); assert.equal(first.body.code, 'outcome_unknown');
    const retry = await f.api(`/api/chats/${id}/send`, { body });
    assert.deepEqual(retry.body, first.body); assert.equal(retry.status, first.status);
    assert.equal(f.stats.accepted, 1); assert.deepEqual(fs.readFileSync(file), previous);
  } finally { Store.prototype.save = original; }
});

test('concurrent relay identity reads share one generated key and persist it across restart', async t => {
  const entered = deferred(), gate = deferred(); let writes = 0;
  const f = await fixture(t, { encrypt: async text => { if (JSON.parse(text).privateKey) { writes++; entered.resolve(); await gate.promise; } } });
  const requests = Array.from({ length: 12 }, () => f.runtime.desktop('mobile.relay.status'));
  await entered.promise; await tick(); gate.resolve();
  const result = await Promise.all(requests), publicKey = result[0].publicKey;
  assert.equal(new Set(result.map(r => r.publicKey)).size, 1); assert.equal(writes, 1);
  const saved = JSON.parse(f.decryptRaw(fs.readFileSync(path.join(f.dataDir, 'Credentials/relay.bin'))));
  assert.equal(saved.publicKey, publicKey);
  await f.restart(); assert.equal((await f.runtime.desktop('mobile.relay.status')).publicKey, publicKey); assert.equal(writes, 1);
});

test('an explicitly entered API key replaces an inaccessible encrypted record without reading it', async t => {
  let rejectDecrypt = false, decryptAttempts = 0;
  const f = await fixture(t, { decrypt: () => { decryptAttempts++; if (rejectDecrypt) throw new Error('Synthetic old DPAPI identity'); } });
  await f.configure(); const file = path.join(f.dataDir, 'Credentials/claude.bin'), original = fs.readFileSync(file);
  rejectDecrypt = true;
  await assert.rejects(f.runtime.desktop('connection.save', { provider: 'claude', model: 'next' }), /cannot be decrypted/);
  assert.deepEqual(fs.readFileSync(file), original); const attempts = decryptAttempts;
  await f.configure({ apiKey: 'replacement-fake-secret', model: 'new-default' });
  assert.equal(decryptAttempts, attempts, 'A newly supplied key must not depend on reading the inaccessible prior key');
  assert.notDeepEqual(fs.readFileSync(file), original);
  rejectDecrypt = false;
  const decrypted = JSON.parse(f.decryptRaw(fs.readFileSync(file))); assert.equal(decrypted.apiKey, 'replacement-fake-secret');
  assert.equal((await f.runtime.desktop('settings.get')).connections.claude.model, 'new-default');
  assert.equal((await f.api(`/api/chats/${await f.create()}`)).body.model, 'new-default');
});

test('API model catalog merges with CLI models and the saved default applies to a new chat', async t => {
  const requests = [];
  const server = http.createServer((req, res) => {
    requests.push({ path: req.url, apiKey: req.headers['x-api-key'] });
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify({ data: [{ id: 'api-only', display_name: 'API model' }, { id: 'shared', display_name: 'API shared title' }] }));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const f = await fixture(t); await f.configure({ baseURL: `http://127.0.0.1:${server.address().port}` });
  await f.runtime.desktop('models.list', { provider: 'claude' });
  const id = await f.create(); assert.equal((await f.api(`/api/chats/${id}`)).body.model, 'configured-default');
  assert.equal((await f.api(`/api/chats/${id}/send`, { body: f.action({ text: 'Use saved default' }) })).status, 200);
  const chat = (await f.api(`/api/chats/${id}`)).body;
  assert.equal(chat.model, 'configured-default'); assert.equal(f.stats.instances[0].connection.model, 'configured-default');
  assert.deepEqual(new Set(chat.models.map(m => m.id)), new Set(['cli-only', 'api-only', 'shared']));
  assert.equal(chat.models.filter(m => m.id === 'shared').length, 1);
  assert.equal(chat.models.find(m => m.id === 'shared').title, 'API shared title');
  assert.deepEqual(requests, [{ path: '/v1/models', apiKey: 'regression-fake-secret' }]);
});

test('corrupt and oversized in-memory snapshots cannot replace the last valid persisted history', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'theall-store-limit-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const store = new Store(directory); const { chat } = store.newWorkspace({ name: 'Preserve me' }); store.save();
  const file = path.join(directory, 'workspaces.json'), previous = fs.readFileSync(file);
  chat.messages.push({ id: randomUUID(), role: 'user', text: 'x'.repeat(64 * 1024 * 1024), images: [] });
  assert.throws(() => store.save(), /storage is full/); assert.deepEqual(fs.readFileSync(file), previous);
  chat.messages = []; store.state.version = 999;
  assert.throws(() => store.save(), /Unsupported or damaged/); assert.deepEqual(fs.readFileSync(file), previous);
  const restored = new Store(directory); assert.equal(restored.state.workspaces[0].name, 'Preserve me'); assert.equal(restored.chat(chat.id).messages.length, 0);
});
