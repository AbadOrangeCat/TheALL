import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, randomBytes, randomUUID, verify } from 'node:crypto';
import { once } from 'node:events';
import http from 'node:http';
import net from 'node:net';
import { WebSocket, WebSocketServer } from 'ws';
import { RelayClient, RELAY_LIMITS, relayOrigin } from '../src/relay.mjs';
import { createRelay } from '../../mobile-relay/server.mjs';

const pair = generateKeyPairSync('ed25519');
const privateKey = pair.privateKey.export({ type: 'pkcs8', format: 'pem' });
const publicKey = pair.publicKey.export({ type: 'spki', format: 'der' }).subarray(-32);
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function eventually(predicate, ms = 4000) {
  const stop = Date.now() + ms;
  while (!predicate()) { if (Date.now() > stop) throw new Error('Condition timed out'); await pause(10); }
}
async function availablePort() {
  const server = net.createServer(); server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const port = server.address().port; await new Promise(resolve => server.close(resolve)); return port;
}
async function fixture(t, overrides = {}) {
  const port = await availablePort(); const origin = `http://127.0.0.1:${port}`;
  const relay = createRelay({ origin, publicKey, bind: '127.0.0.1', port }, { heartbeat: 60000 });
  await relay.listen();
  const states = []; const requests = [];
  const client = new RelayClient({ url: origin, privateKey, publicKey: publicKey.toString('base64'),
    handleRequest: async request => { requests.push(request); return { status: 200, headers: { 'content-type': 'application/json' }, body: Buffer.from('{"ok":true}') }; },
    onStatus: state => states.push(state), ...overrides });
  t.after(async () => { client.close(); await relay.close(); });
  client.start(); await eventually(() => client.connected);
  return { client, relay, origin, states, requests };
}
function post(origin, path, body) {
  return fetch(origin + path, { method: 'POST', headers: { origin, 'x-theall-client': '1', 'content-type': 'application/json', cookie: 'TheAllMobileSession=opaque' }, body });
}
async function fake(t, onMessage = () => {}) {
  const server = http.createServer(); const wss = new WebSocketServer({ server, perMessageDeflate: false });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  let ready; const opened = new Promise(resolve => { ready = resolve; });
  wss.on('connection', socket => {
    const nonce = randomBytes(32);
    socket.on('message', raw => {
      const message = JSON.parse(raw.toString());
      if (message.type === 'authenticate') {
        assert.equal(message.publicKey, publicKey.toString('base64'));
        assert.ok(verify(null, nonce, pair.publicKey, Buffer.from(message.signature, 'base64')));
        socket.send(JSON.stringify({ type: 'ready', protocol: 1 })); ready(socket);
      } else onMessage(message, socket);
    });
    socket.send(JSON.stringify({ type: 'challenge', nonce: nonce.toString('base64'), protocol: 1 }));
  });
  t.after(async () => { for (const socket of wss.clients) socket.terminate(); await new Promise(resolve => wss.close(resolve)); await new Promise(resolve => server.close(resolve)); });
  return { origin, opened, wss };
}
const requestFrame = (origin, overrides = {}) => ({ type: 'request', id: randomUUID(), method: 'GET', target: '/api/workspaces', headers: { host: new URL(origin).host }, body: '', ...overrides });

test('only root HTTPS or local test HTTP and matching Ed25519 identities are accepted', () => {
  assert.equal(relayOrigin('https://relay.example.com/'), 'https://relay.example.com');
  for (const url of ['http://example.com', 'ws://127.0.0.1:8080', 'https://example.com/path', 'https://u:p@example.com', 'https://example.com/#key', 'https://example.com/?x=1']) assert.throws(() => relayOrigin(url));
  for (const url of ['http://localhost:8080', 'http://127.0.0.1:8080', 'http://[::1]:8080']) assert.equal(relayOrigin(url), url);
  assert.throws(() => new RelayClient({ url: 'https://relay.example.com', privateKey, publicKey: randomBytes(32).toString('base64'), handleRequest() {} }));
  assert.throws(() => new RelayClient({ url: 'https://relay.example.com', privateKey: 'bad', handleRequest() {} }));
  assert.equal(RELAY_LIMITS.requestBytes, 3 * 1024 * 1024); assert.equal(RELAY_LIMITS.pending, 8);
});

test('real relay authenticates desktop and preserves POST bytes, queries, origin, cookies and binary responses', async t => {
  const responseBytes = Buffer.from([0, 1, 255]);
  const f = await fixture(t, { handleRequest: async request => {
    f.requests.push(request);
    return { status: 201, headers: { 'Content-Type': 'image/png', 'Set-Cookie': ['one=1; HttpOnly', 'two=2; HttpOnly'] }, body: responseBytes };
  } });
  const body = JSON.stringify({ requestId: randomUUID(), text: '你好，Windows' });
  const response = await post(f.origin, '/api/chats/a/send?limit=3', body);
  assert.equal(response.status, 201); assert.deepEqual(Buffer.from(await response.arrayBuffer()), responseBytes);
  assert.equal(response.headers.getSetCookie().length, 2);
  assert.equal(f.requests.length, 1); const forwarded = f.requests[0];
  assert.equal(forwarded.target, '/api/chats/a/send?limit=3'); assert.equal(forwarded.origin, f.origin);
  assert.equal(forwarded.headers.cookie, 'TheAllMobileSession=opaque'); assert.equal(forwarded.body.toString(), body);
  assert.equal(f.client.origin, f.origin); assert.equal(f.client.hostID, publicKey.toString('base64'));
});

test('real relay sends hello only after accepted event upgrade, forwards ping/pong and closes revoked subscriptions', async t => {
  let revoke, closeCount = 0;
  const f = await fixture(t, { openEvents: ({ headers, origin, send, close }) => {
    assert.equal(headers.cookie, 'TheAllMobileSession=phone'); assert.equal(origin, f.origin);
    revoke = () => { send(JSON.stringify({ type: 'revoked' })); close(); };
    send(JSON.stringify({ type: 'hello', bootID: 'boot', access: { workspaceId: null, writable: true } }));
    return { receive: text => { assert.equal(JSON.parse(text).type, 'ping'); send('{"type":"pong"}'); }, close: () => { closeCount++; } };
  } });
  const browser = new WebSocket(f.origin.replace('http:', 'ws:') + '/api/events', { origin: f.origin, headers: { cookie: 'TheAllMobileSession=phone' } });
  t.after(() => browser.terminate());
  const messages = []; browser.on('message', raw => messages.push(JSON.parse(raw.toString())));
  await eventually(() => messages.length === 1); assert.equal(messages[0].type, 'hello');
  browser.send('{"type":"ping"}'); await eventually(() => messages.length === 2); assert.equal(messages[1].type, 'pong');
  const closed = once(browser, 'close'); revoke(); await closed;
  assert.equal(messages[2].type, 'revoked'); assert.equal(closeCount, 1);
});

test('real relay rejects unauthenticated event open without leaking a hello', async t => {
  const f = await fixture(t, { openEvents: () => { throw Object.assign(new Error('Not paired'), { status: 401 }); } });
  const browser = new WebSocket(f.origin.replace('http:', 'ws:') + '/api/events', { origin: f.origin });
  browser.on('error', () => {}); t.after(() => browser.terminate());
  const [, response] = await once(browser, 'unexpected-response'); assert.equal(response.statusCode, 401); response.resume();
});

test('close during an awaited request suppresses stale response and never reconnects or replays it', async t => {
  let finish, started = false, calls = 0;
  const f = await fixture(t, { handleRequest: () => { calls++; started = true; return new Promise(resolve => { finish = resolve; }); } });
  const pending = fetch(f.origin + '/api/workspaces'); await eventually(() => started);
  f.client.close();
  assert.equal((await pending).status, 503);
  finish({ status: 200, headers: {}, body: Buffer.from('late') }); await pause(50);
  assert.equal(f.client.connected, false); assert.equal(f.client.active, false); assert.equal(calls, 1);
  assert.equal((await fetch(f.origin + '/api/workspaces')).status, 503);
});

test('an authenticated connection replacement reconnects with a fresh challenge and does not replay requests', async t => {
  const f = await fixture(t); let calls = 0;
  const replacement = new RelayClient({ url: f.origin, privateKey, handleRequest: async () => { calls++; return { status: 200, headers: {}, body: Buffer.from('replacement') }; } });
  t.after(() => replacement.close()); replacement.start(); await eventually(() => replacement.connected);
  await eventually(() => f.states.some(state => state.state === 'disconnected'));
  replacement.close(); await eventually(() => f.client.connected, 4500);
  assert.equal((await fetch(f.origin + '/api/workspaces')).status, 200);
  assert.equal(f.requests.length, 1); assert.equal(calls, 0);
});

test('hostile forwarded origin/body and post-auth challenge terminate transport before runtime receives them', async t => {
  for (const bad of [
    origin => requestFrame(origin, { headers: { host: 'evil.example' } }),
    origin => requestFrame(origin, { method: 'POST', body: 'e30=', headers: { host: new URL(origin).host } }),
    origin => requestFrame(origin, { body: 'YQ==' }),
    origin => requestFrame(origin, { body: 'not-base64' }),
    () => ({ type: 'challenge', protocol: 1, nonce: randomBytes(32).toString('base64') }),
  ]) {
    const f = await fake(t); let calls = 0;
    const client = new RelayClient({ url: f.origin, privateKey, handleRequest: async () => { calls++; return { status: 200, headers: {}, body: Buffer.alloc(0) }; } });
    t.after(() => client.close()); client.start(); const host = await f.opened; await eventually(() => client.connected);
    const closed = once(host, 'close'); host.send(JSON.stringify(bad(f.origin))); await closed;
    assert.equal(calls, 0); client.close();
  }
});

test('bounds pending HTTP work before invoking runtime and keeps handler failures uncertain', async t => {
  const responses = []; const waiting = [];
  const f = await fake(t, response => responses.push(response));
  const client = new RelayClient({ url: f.origin, privateKey, handleRequest: () => new Promise(resolve => waiting.push(resolve)) });
  t.after(() => client.close()); client.start(); const host = await f.opened; await eventually(() => client.connected);
  for (let i = 0; i < 9; i++) host.send(JSON.stringify(requestFrame(f.origin)));
  await eventually(() => responses.length === 1); assert.equal(responses[0].status, 503); assert.equal(waiting.length, 8);
  for (const finish of waiting) finish({ status: 200, headers: {}, body: Buffer.alloc(0) });
  await eventually(() => responses.length === 9);
  client.handleRequest = async () => { throw new Error('may have reached agent'); };
  host.send(JSON.stringify(requestFrame(f.origin))); await eventually(() => responses.length === 10);
  assert.equal(responses[9].status, 500); assert.equal(JSON.parse(Buffer.from(responses[9].body, 'base64')).code, undefined);
});

test('oversized outbound snapshot returns a bounded 413 while retaining the connection', async t => {
  const responses = []; const f = await fake(t, response => responses.push(response));
  const client = new RelayClient({ url: f.origin, privateKey, handleRequest: async () => ({ status: 200, headers: {}, body: Buffer.alloc(7 * 1024 * 1024) }) });
  t.after(() => client.close()); client.start(); const host = await f.opened; await eventually(() => client.connected);
  host.send(JSON.stringify(requestFrame(f.origin))); await eventually(() => responses.length === 1);
  assert.equal(responses[0].status, 413); assert.equal(client.connected, true);
});

test('an event subscription still opening at disconnect is disposed and cannot send into a new generation', async t => {
  const replies = []; let finish, closed = 0, oldSend;
  const f = await fake(t, response => replies.push(response));
  const client = new RelayClient({ url: f.origin, privateKey, handleRequest: async () => ({ status: 200, headers: {}, body: Buffer.alloc(0) }),
    openEvents: ({ send }) => { oldSend = send; return new Promise(resolve => { finish = resolve; }); } });
  t.after(() => client.close()); client.start(); const host = await f.opened; await eventually(() => client.connected);
  host.send(JSON.stringify({ type: 'event_open', id: randomUUID(), method: 'GET', target: '/api/events', headers: { host: new URL(f.origin).host, origin: f.origin } }));
  await eventually(() => !!finish); client.close();
  finish({ receive() {}, close() { closed++; } }); oldSend('{"type":"hello"}');
  await pause(30); assert.equal(closed, 1); assert.equal(replies.length, 0);
});

test('oversized incoming photo request is rejected before invoking runtime', async t => {
  const f = await fake(t); let calls = 0;
  const client = new RelayClient({ url: f.origin, privateKey, handleRequest: async () => { calls++; return { status: 200, headers: {}, body: Buffer.alloc(0) }; } });
  t.after(() => client.close()); client.start(); const host = await f.opened; await eventually(() => client.connected);
  const closed = once(host, 'close');
  host.send(JSON.stringify(requestFrame(f.origin, { method: 'POST', headers: { host: new URL(f.origin).host, origin: f.origin, 'content-type': 'application/json', 'x-theall-client': '1' }, body: Buffer.alloc(RELAY_LIMITS.requestBytes + 1).toString('base64') })));
  await closed; assert.equal(calls, 0); client.close();
});
