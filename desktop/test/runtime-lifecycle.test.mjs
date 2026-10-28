import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { EventEmitter } from 'node:events';
import { randomUUID } from 'node:crypto';
import { createRuntime } from '../src/runtime.mjs';

const tick = () => new Promise(resolve => setImmediate(resolve));
function deferred() { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; }
async function until(predicate) {
  const deadline = Date.now() + 3000;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error('Lifecycle test condition timed out');
    await new Promise(resolve => setTimeout(resolve, 5));
  }
}

async function fixture(t, behavior = {}) {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'theall-lifecycle-'));
  const sessions = [], relays = [], gates = [];
  class Session extends EventEmitter {
    constructor({ chat, connection }) {
      super(); this.chat = chat; this.connection = connection; this.isReady = false; this.isBusy = false;
      this.questions = []; this.closeCount = 0; sessions.push(this);
    }
    async start() { this.chat.conversationID ||= randomUUID(); this.isReady = true; this.emit('change'); }
    async close() { this.isReady = false; this.closeCount++; await this.closeGate; this.emit('change'); }
    async send(input) {
      if (!this.isReady || !input.stillAuthorized()) throw new Error('Conversation was closed');
      this.isBusy = true;
      try {
        await behavior.beforeWrite?.(this, input);
        if (!this.isReady || !input.stillAuthorized()) throw new Error('Conversation was closed');
        this.chat.messages.push({ id: randomUUID(), role: 'user', text: input.text, images: [] }); this.emit('change');
      } finally { this.isBusy = false; }
    }
  }
  class Relay {
    constructor(options) { Object.assign(this, options); this.origin = options.url; this.active = false; this.closeCount = 0; relays.push(this); }
    start() { this.active = true; this.onStatus({ state: 'ready', connected: true, origin: this.origin }); }
    close() { this.active = false; this.closeCount++; this.onStatus({ state: 'stopped', connected: false, origin: this.origin }); }
  }
  const runtime = await createRuntime({ dataDir, Session, Relay,
    encrypt: async value => { await behavior.encrypt?.(value); return Buffer.from(value); },
    decrypt: async value => { await behavior.decrypt?.(); return value.toString(); }
  });
  const f = {
    dataDir, runtime, sessions, relays,
    gate() { const gate = deferred(); gates.push(gate); return gate; },
    async api(route, values) {
      const response = await fetch(runtime.url + route, {
        method: values === undefined ? 'GET' : 'POST',
        headers: { cookie: `TheAllDesktopSession=${runtime.desktopToken}`,
          ...(values === undefined ? {} : { origin: runtime.url, 'content-type': 'application/json', 'x-theall-client': '1' }) },
        body: values === undefined ? undefined : JSON.stringify({ bootID: runtime.bootID, requestId: randomUUID(), ...values })
      });
      return { status: response.status, body: await response.json() };
    },
    send(id, text = 'Lifecycle fixture prompt') { return f.api(`/api/chats/${id}/send`, { text }); },
    async configuredChat() {
      await runtime.desktop('connection.save', { provider: 'claude', apiKey: 'fake-lifecycle-key', baseURL: 'http://127.0.0.1:9' });
      const workspace = await runtime.desktop('workspace.create');
      return runtime.desktop('tab.create', { workspaceId: workspace.id, directory: dataDir, provider: 'claude' });
    },
    async pair(split) {
      await runtime.desktop('connection.save', { provider: 'claude', apiKey: 'fake-lifecycle-key', baseURL: 'http://127.0.0.1:9' });
      const workspace = await runtime.desktop('workspace.create');
      const item = (await f.api('/api/workspaces')).body.workspaces.find(w => w.id === workspace.id);
      const first = item.conversations[0];
      await runtime.desktop('chat.update', { id: first.id, provider: 'claude' });
      const second = split
        ? await runtime.desktop('pane.split', { workspaceId: workspace.id, tabId: first.tabId, terminalId: first.id, direction: 'horizontal', provider: 'claude' })
        : await runtime.desktop('tab.create', { workspaceId: workspace.id, directory: dataDir, provider: 'claude' });
      assert.equal((await f.send(first.id)).status, 200);
      assert.equal((await f.send(second.terminalId)).status, 200);
      return { workspaceId: workspace.id, tabId: first.tabId, first: first.id, second: second.terminalId };
    }
  };
  t.after(async () => {
    gates.forEach(gate => gate.resolve());
    await behavior.release?.();
    await runtime.close();
    relays.forEach(relay => relay.close());
    fs.rmSync(dataDir, { recursive: true, force: true });
  });
  return f;
}

for (const action of ['remove', 'save']) {
  test(`connection.${action} invalidates a startup waiting for old credential decryption`, async t => {
    const entered = deferred(), decrypted = deferred(); let blocking = false;
    const f = await fixture(t, {
      decrypt: async () => { if (blocking) { entered.resolve(); await decrypted.promise; } },
      release: () => decrypted.resolve()
    });
    const { terminalId } = await f.configuredChat(); blocking = true;
    const sending = f.send(terminalId, 'Do not use the revoked connection');
    await entered.promise;
    const changing = f.runtime.desktop(`connection.${action}`, action === 'remove' ? { provider: 'claude' }
      : { provider: 'claude', apiKey: 'fake-replacement-key', baseURL: 'http://127.0.0.1:9' });
    await tick(); blocking = false; decrypted.resolve();
    const [sent, changed] = await Promise.allSettled([sending, changing]);
    assert.equal(changed.status, 'fulfilled', 'Changing an idle provider connection must complete');
    assert.equal(sent.status, 'fulfilled');
    assert.notEqual(sent.value.status, 200, 'An already-decrypted old connection must not accept a prompt');
    assert.equal(f.sessions.length, 0, 'The stale key must not be handed to a new CLI process');
    const settings = await f.runtime.desktop('settings.get');
    assert.equal(settings.connections.claude.configured, action === 'save');
    if (action === 'save') {
      assert.equal((await f.send(terminalId, 'Use the explicitly saved replacement connection')).status, 200);
      assert.equal(f.sessions.at(-1).connection.apiKey, 'fake-replacement-key');
    }
  });
}

test('connection removal during a model ACK is rejected without losing the saved connection', async t => {
  const entered = deferred(), acknowledged = deferred();
  const f = await fixture(t, {
    beforeWrite: async () => { entered.resolve(); await acknowledged.promise; },
    release: () => acknowledged.resolve()
  });
  const { terminalId } = await f.configuredChat();
  const sending = f.send(terminalId, 'Keep the connection while this model change is pending');
  await entered.promise;
  await assert.rejects(f.runtime.desktop('connection.remove', { provider: 'claude' }), error => error.status === 409);
  assert.equal((await f.runtime.desktop('settings.get')).connections.claude.configured, true);
  assert.equal(f.sessions[0].closeCount, 0, 'Rejecting deletion must leave the active CLI intact');
  acknowledged.resolve(); assert.equal((await sending).status, 200);
});

for (const [operation, split] of [['workspace.delete', false], ['tab.close', true]]) {
  test(`${operation} blocks sends to an earlier pane while a later process is stopping`, async t => {
    const f = await fixture(t), pair = await f.pair(split);
    const last = f.sessions.find(s => s.chat.id === pair.second), gate = f.gate();
    last.closeGate = gate.promise;
    const removing = f.runtime.desktop(operation, split ? { workspaceId: pair.workspaceId, tabId: pair.tabId } : { id: pair.workspaceId });
    await until(() => last.closeCount > 0);
    const concurrent = await f.send(pair.first, 'Must not execute while the owner is closing');
    gate.resolve(); await removing;
    assert.notEqual(concurrent.status, 200, 'A closing workspace or split tab must reject new submissions');
    assert.equal(f.sessions.length, 2, 'No replacement CLI may start for a closing pane');
    assert(f.sessions.every(s => !s.isReady && s.closeCount > 0), 'Every owned CLI must be stopped');
    const index = (await f.api('/api/workspaces')).body.workspaces;
    assert(!index.flatMap(w => w.conversations).some(c => c.id === pair.first || c.id === pair.second));
  });
}

for (const action of ['disable', 'close']) {
  test(`relay ${action} cancels configuration awaiting its first encrypted identity write`, async t => {
    const entered = deferred(), encrypted = deferred();
    const f = await fixture(t, {
      encrypt: async value => { if (JSON.parse(value).privateKey) { entered.resolve(); await encrypted.promise; } },
      release: () => encrypted.resolve()
    });
    const configuring = f.runtime.desktop('mobile.relay.configure', { url: 'https://relay.fixture.invalid' });
    await entered.promise;
    const stopping = action === 'disable' ? f.runtime.desktop('mobile.relay.configure', { url: '' }) : f.runtime.close();
    await tick(); encrypted.resolve();
    const results = await Promise.allSettled([configuring, stopping]);
    assert.equal(results[1].status, 'fulfilled', 'Stopping the relay must complete');
    assert(f.relays.every(relay => !relay.active), 'An older configuration must not reopen an outbound connection');
    if (action === 'disable') {
      const status = await f.runtime.desktop('mobile.relay.status');
      assert.equal(status.connected, false); assert.equal(status.url, '');
    }
  });
}
