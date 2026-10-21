import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import { generateKeyPairSync, sign } from 'node:crypto';
import { once } from 'node:events';
import { WebSocket } from 'ws';
import { createRelay, parseConfig, decodeBase64, LIMITS } from '../server.mjs';

const pair = generateKeyPairSync('ed25519');
const publicKey = pair.publicKey.export({ format: 'der', type: 'spki' }).subarray(-32);
const origin = 'http://localhost';
async function fixture(t, limits = {}) {
  const relay = createRelay({ origin, publicKey, bind: '127.0.0.1', port: 0 }, { heartbeat: 60000, ...limits });
  const { port } = await relay.listen();
  t.after(() => relay.close());
  return { relay, port };
}
function httpCall(port, { method = 'GET', target = '/api/workspaces', headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, method, path: target, headers: { host: 'localhost', ...headers } }, res => {
      const chunks = []; res.on('data', chunk => chunks.push(chunk)); res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString('utf8'), bytes: Buffer.concat(chunks) }));
    });
    req.on('error', reject); req.end(body);
  });
}
function connect(port, options = {}) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}${options.path || '/host'}`, { ...options, headers: { host: 'localhost', ...options.headers } });
  const messages = []; const readers = [];
  ws.on('error', () => {});
  ws.on('message', raw => { const data = JSON.parse(raw.toString()); if (readers.length) readers.shift()(data); else messages.push(data); });
  ws.next = () => messages.length ? Promise.resolve(messages.shift()) : new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('No host message within 3 seconds')), 3000); timer.unref();
    readers.push(data => { clearTimeout(timer); resolve(data); });
  });
  return ws;
}
async function authenticate(port) {
  const ws = connect(port); const challenge = await ws.next();
  assert.equal(challenge.type, 'challenge'); assert.equal(challenge.protocol, 1);
  ws.send(JSON.stringify({ type: 'authenticate', publicKey: publicKey.toString('base64'), signature: sign(null, Buffer.from(challenge.nonce, 'base64'), pair.privateKey).toString('base64') }));
  assert.deepEqual(await ws.next(), { type: 'ready', protocol: 1 });
  return ws;
}
function respond(ws, request, body, headers = {}, status = 200) {
  ws.send(JSON.stringify({ type: 'response', id: request.id, status, headers, body: Buffer.from(body).toString('base64') }));
}
const postHeaders = { origin, 'x-theall-client': '1', 'content-type': 'application/json' };

test('configuration requires a root HTTPS origin or loopback development and a canonical Ed25519 key', () => {
  const env = { PUBLIC_ORIGIN: 'https://theall.example.com', THEALL_MAC_PUBLIC_KEY: publicKey.toString('base64') };
  assert.equal(parseConfig(env).bind, '127.0.0.1');
  for (const value of ['http://public.example.com', 'https://example.com/path', 'https://example.com/?token=x', 'https://user:pass@example.com', 'https://example.com/#secret']) assert.throws(() => parseConfig({ ...env, PUBLIC_ORIGIN: value }));
  for (const value of ['http://localhost:8080', 'http://127.0.0.1:8080', 'http://[::1]:8080']) assert.equal(parseConfig({ ...env, PUBLIC_ORIGIN: value }).origin, value);
  assert.throws(() => parseConfig({ ...env, THEALL_MAC_PUBLIC_KEY: 'short' }));
  assert.throws(() => decodeBase64('YQ', 16)); assert.throws(() => decodeBase64('YQ==\n', 16));
  assert.equal(LIMITS.requestBytes, 524288); assert.equal(LIMITS.responseBytes, 16777216);
  assert.equal(LIMITS.pending, 32); assert.equal(LIMITS.unverifiedHosts, 4);
});
test('offline returns explicit uncached 503 and never retries requests', async t => {
  const { port } = await fixture(t);
  const res = await httpCall(port);
  assert.equal(res.status, 503); assert.deepEqual(JSON.parse(res.body), { error: 'Mac offline' });
  assert.equal(res.headers['cache-control'], 'no-store'); assert.equal(res.headers['x-content-type-options'], 'nosniff');
  assert.equal(res.headers['referrer-policy'], 'no-referrer'); assert.equal(res.headers['access-control-allow-origin'], undefined);
});
test('authenticates the configured Mac and forwards cookies, exact target/body, response cookies and binary bytes', async t => {
  const { port } = await fixture(t); const ws = await authenticate(port);
  const body = '{"text":"你好","requestId":"one","bootID":"boot"}';
  const response = httpCall(port, { method: 'POST', target: '/api/chats/a/send?limit=1', headers: { ...postHeaders, cookie: 'session=opaque', 'x-forwarded-host': 'evil.example', connection: 'keep-alive, x-strip', 'x-strip': 'gone' }, body });
  const forwarded = await ws.next();
  assert.equal(forwarded.type, 'request'); assert.match(forwarded.id, /^[0-9a-f-]{36}$/);
  assert.equal(forwarded.method, 'POST'); assert.equal(forwarded.target, '/api/chats/a/send?limit=1');
  assert.equal(Buffer.from(forwarded.body, 'base64').toString(), body);
  assert.equal(forwarded.headers.cookie, 'session=opaque'); assert.equal(forwarded.headers.host, 'localhost');
  assert.equal(forwarded.headers.origin, origin); assert.equal(forwarded.headers['x-forwarded-host'], undefined); assert.equal(forwarded.headers['x-strip'], undefined);
  assert.equal(forwarded.headers['content-length'], String(Buffer.byteLength(body)));
  respond(ws, forwarded, 'ok', { 'Content-Type': 'text/plain', 'Set-Cookie': ['session=opaque; HttpOnly; Secure; SameSite=Strict', 'other=value; HttpOnly; Secure'], 'Cache-Control': 'public', 'Access-Control-Allow-Origin': '*', Connection: 'keep-alive' }, 201);
  const result = await response;
  assert.equal(result.status, 201); assert.equal(result.body, 'ok');
  assert.equal(result.headers['set-cookie'].length, 2); assert.equal(result.headers['cache-control'], 'no-store');
  assert.equal(result.headers['access-control-allow-origin'], undefined);
  const get = httpCall(port, { target: '/icons/icon-192.png' }); const image = await ws.next();
  assert.equal(image.body, ''); assert.equal(image.headers['content-length'], undefined);
  respond(ws, image, Buffer.from([0, 1, 255]), { 'Content-Type': 'image/png' });
  const imageResult = await get;
  assert.equal(imageResult.headers['content-length'], '3'); assert.deepEqual(imageResult.bytes, Buffer.from([0, 1, 255]));
});
test('wrong public key or signature cannot become the Mac', async t => {
  const { port } = await fixture(t); const wrong = generateKeyPairSync('ed25519');
  for (const wrongKey of [true, false]) {
    const ws = connect(port); const challenge = await ws.next(); const closed = once(ws, 'close');
    ws.send(JSON.stringify({ type: 'authenticate', publicKey: (wrongKey ? wrong.publicKey.export({ format: 'der', type: 'spki' }).subarray(-32) : publicKey).toString('base64'), signature: sign(null, Buffer.from(challenge.nonce, 'base64'), wrong.privateKey).toString('base64') }));
    assert.equal((await closed)[0], 1008);
  }
  assert.equal((await httpCall(port)).status, 503);
});
test('challenge signatures cannot be replayed on another socket or after authentication', async t => {
  const { port } = await fixture(t); const first = connect(port); const challenge = await first.next();
  const auth = { type: 'authenticate', publicKey: publicKey.toString('base64'), signature: sign(null, Buffer.from(challenge.nonce, 'base64'), pair.privateKey).toString('base64') };
  first.send(JSON.stringify(auth)); await first.next();
  const second = connect(port); const secondChallenge = await second.next(); assert.notEqual(secondChallenge.nonce, challenge.nonce);
  const secondClosed = once(second, 'close'); second.send(JSON.stringify(auth)); assert.equal((await secondClosed)[0], 1008);
  const firstClosed = once(first, 'close'); first.send(JSON.stringify(auth)); assert.equal((await firstClosed)[0], 1008);
});
test('authentication expires and limits unauthenticated hosts', async t => {
  const { port } = await fixture(t, { authenticationTimeout: 100, unverifiedHosts: 2 });
  const one = connect(port); const two = connect(port); await Promise.all([one.next(), two.next()]);
  const closed = [once(one, 'close'), once(two, 'close')];
  const three = connect(port); const unexpected = once(three, 'unexpected-response');
  const [, response] = await unexpected; assert.equal(response.statusCode, 503); response.resume(); three.terminate();
  await Promise.all(closed);
});
test('only newest authenticated Mac remains and pending requests fail on replacement/disconnect', async t => {
  const { port } = await fixture(t); const first = await authenticate(port);
  const pending = httpCall(port); await first.next(); const firstClosed = once(first, 'close');
  const second = await authenticate(port); assert.equal((await firstClosed)[0], 1012);
  assert.equal((await pending).status, 503);
  const next = httpCall(port); const forwarded = await second.next(); respond(second, forwarded, 'new Mac'); assert.equal((await next).body, 'new Mac');
  const interrupted = httpCall(port); await second.next(); second.terminate(); assert.equal((await interrupted).status, 503);
});
test('rejects hostile Host/Origin, cross-site fetches, unsupported methods and unsafe POSTs', async t => {
  const { port } = await fixture(t); await authenticate(port);
  for (const [options, status] of [
    [{ headers: { host: 'evil.example', 'x-forwarded-host': 'localhost' } }, 421],
    [{ headers: { origin: 'https://evil.example' } }, 403],
    [{ headers: { 'sec-fetch-site': 'cross-site' } }, 403],
    [{ method: 'DELETE' }, 405], [{ method: 'HEAD' }, 405],
    [{ method: 'POST', body: '{}' }, 403],
    [{ method: 'POST', headers: { origin, 'x-theall-client': '1', 'content-type': 'text/plain' }, body: '{}' }, 403],
    [{ method: 'POST', headers: { ...postHeaders, origin: 'null' }, body: '{}' }, 403],
    [{ target: '//evil.example/api' }, 400],
    [{ target: 'http://evil.example/api' }, 400]
  ]) assert.equal((await httpCall(port, options)).status, status);
});
test('WebSocket upgrade accepts only /host and rejects every browser Origin', async t => {
  const { port } = await fixture(t);
  for (const options of [{ path: '/other' }, { headers: { origin } }, { headers: { origin: 'null' } }, { headers: { host: 'evil.example' } }]) {
    const ws = connect(port, options); const [, res] = await once(ws, 'unexpected-response');
    assert.ok([403, 421].includes(res.statusCode)); res.resume(); ws.terminate();
  }
});
test('enforces body, header and pending limits before forwarding', async t => {
  const { port } = await fixture(t, { requestBytes: 32, pending: 1, responseTimeout: 2000 }); const ws = await authenticate(port);
  assert.equal((await httpCall(port, { method: 'POST', headers: postHeaders, body: 'x'.repeat(33) })).status, 413);
  assert.equal((await httpCall(port, { method: 'POST', headers: { ...postHeaders, 'transfer-encoding': 'chunked' }, body: 'x'.repeat(33) })).status, 413);
  assert.equal((await httpCall(port, { headers: { 'x-large': 'x'.repeat(17 * 1024) } })).status, 431);
  const first = httpCall(port); const one = await ws.next();
  assert.equal((await httpCall(port)).status, 503);
  respond(ws, one, 'done'); assert.equal((await first).body, 'done');
});
test('pending limit includes slow bodies, which time out rather than being queued', async t => {
  const { port } = await fixture(t, { bodyTimeout: 100, pending: 1 }); await authenticate(port);
  const socket = net.connect(port, '127.0.0.1'); await once(socket, 'connect');
  socket.write('POST /api/chats HTTP/1.1\r\nHost: localhost\r\nOrigin: http://localhost\r\nX-TheAll-Client: 1\r\nContent-Type: application/json\r\nContent-Length: 10\r\n\r\n{');
  await new Promise(resolve => setTimeout(resolve, 25));
  assert.equal((await httpCall(port)).status, 503);
  const [raw] = await once(socket, 'data'); assert.match(raw.toString(), /408 Request Timeout/); socket.destroy();
});
test('Mac response timeout returns 504; late responses cannot answer the next request', async t => {
  const { port } = await fixture(t, { responseTimeout: 100 }); const ws = await authenticate(port);
  const first = httpCall(port); const old = await ws.next(); assert.equal((await first).status, 504);
  const second = httpCall(port); const current = await ws.next();
  respond(ws, old, 'late'); respond(ws, current, 'current'); assert.equal((await second).body, 'current');
});
test('rejects oversized/malformed host responses and header injection', async t => {
  for (const corrupt of [
    response => { response.body = Buffer.alloc(17).toString('base64'); },
    response => { response.body = 'not base64!'; },
    response => { response.headers = { 'set-cookie': 'x=y\r\ninjected: 1' }; },
    response => { response.status = 101; },
    response => { response.headers = { 'x-large': 'x'.repeat(17 * 1024) }; }
  ]) {
    const { port } = await fixture(t, { responseBytes: 16 }); const ws = await authenticate(port);
    const result = httpCall(port); const request = await ws.next(); const closed = once(ws, 'close');
    const response = { type: 'response', id: request.id, status: 200, headers: {}, body: '' }; corrupt(response);
    ws.send(JSON.stringify(response)); assert.equal((await closed)[0], 1008); assert.equal((await result).status, 503);
  }
});
test('WebSocket frames are bounded and missing pong disconnects the Mac', async t => {
  const { port } = await fixture(t, { webSocketBytes: 512 }); const ws = await authenticate(port);
  const closed = once(ws, 'close'); ws.send('x'.repeat(513)); assert.equal((await closed)[0], 1009);
  const other = await fixture(t, { heartbeat: 50 }); const silent = connect(other.port, { autoPong: false });
  const challenge = await silent.next(); silent.send(JSON.stringify({ type: 'authenticate', publicKey: publicKey.toString('base64'), signature: sign(null, Buffer.from(challenge.nonce, 'base64'), pair.privateKey).toString('base64') }));
  await silent.next(); const silentClosed = once(silent, 'close'); assert.equal((await silentClosed)[0], 1006);
});

test('phone events wait for Mac authorization, carry the original cookie, and stream both ways', async t => {
  const { port } = await fixture(t); const host = await authenticate(port);
  const phone = connect(port, { path: '/api/events', headers: { origin, cookie: 'device=opaque', 'x-forwarded-host': 'evil.invalid' } });
  let opened = false; phone.on('open', () => { opened = true; });
  const request = await host.next();
  assert.equal(request.type, 'event_open'); assert.equal(request.method, 'GET'); assert.equal(request.target, '/api/events');
  assert.equal(request.headers.cookie, 'device=opaque'); assert.equal(request.headers.origin, origin);
  assert.equal(request.headers.host, 'localhost'); assert.equal(request.headers['x-forwarded-host'], undefined);
  assert.equal(opened, false);
  host.send(JSON.stringify({ type: 'event_opened', id: request.id, status: 101 }));
  host.send(JSON.stringify({ type: 'event_data', id: request.id, text: JSON.stringify({ type: 'hello', revision: 1 }) }));
  assert.deepEqual(await phone.next(), { type: 'hello', revision: 1 });
  phone.send(JSON.stringify({ type: 'ping' }));
  assert.deepEqual(await host.next(), { type: 'event_input', id: request.id, text: '{"type":"ping"}' });
  const closed = once(phone, 'close');
  host.send(JSON.stringify({ type: 'event_close', id: request.id }));
  assert.equal((await closed)[0], 1008); // Revoked cookies close the already-open stream.
});

test('phone event authentication rejects before upgrade and rejects hostile origins', async t => {
  const { port } = await fixture(t); const host = await authenticate(port);
  const phone = connect(port, { path: '/api/events', headers: { origin } });
  const denied = once(phone, 'unexpected-response'); const request = await host.next();
  host.send(JSON.stringify({ type: 'event_opened', id: request.id, status: 401 }));
  const [, response] = await denied; assert.equal(response.statusCode, 401); response.resume(); phone.terminate();
  for (const headers of [{}, { origin: 'https://evil.invalid' }, { origin, 'sec-fetch-site': 'cross-site' }, { origin, host: 'evil.invalid' }]) {
    const bad = connect(port, { path: '/api/events', headers });
    const [, res] = await once(bad, 'unexpected-response');
    assert.ok([403, 421].includes(res.statusCode)); res.resume(); bad.terminate();
  }
});

test('event channel slots, handshake deadline, phone cleanup and host disconnect are bounded', async t => {
  const { port } = await fixture(t, { events: 1, eventHandshakeTimeout: 100 }); const host = await authenticate(port);
  const pending = connect(port, { path: '/api/events', headers: { origin } });
  const timeout = once(pending, 'unexpected-response'); const first = await host.next();
  const excess = connect(port, { path: '/api/events', headers: { origin } });
  const [, overloaded] = await once(excess, 'unexpected-response'); assert.equal(overloaded.statusCode, 503); overloaded.resume(); excess.terminate();
  const [, expired] = await timeout; assert.equal(expired.statusCode, 504); expired.resume(); pending.terminate();
  assert.deepEqual(await host.next(), { type: 'event_close', id: first.id });
  const phone = connect(port, { path: '/api/events', headers: { origin } }); const opening = once(phone, 'open');
  const second = await host.next(); host.send(JSON.stringify({ type: 'event_opened', id: second.id, status: 101 })); await opening;
  const closed = once(phone, 'close'); host.terminate(); assert.equal((await closed)[0], 1012);
  const offline = connect(port, { path: '/api/events', headers: { origin } });
  const [, res] = await once(offline, 'unexpected-response'); assert.equal(res.statusCode, 503); res.resume(); offline.terminate();
});

test('phone disconnect notifies the Mac and late event output cannot revive its stream', async t => {
  const { port } = await fixture(t, { events: 1 }); const host = await authenticate(port);
  const phone = connect(port, { path: '/api/events', headers: { origin } }); const opening = once(phone, 'open');
  const first = await host.next(); host.send(JSON.stringify({ type: 'event_opened', id: first.id, status: 101 })); await opening;
  phone.close(); assert.deepEqual(await host.next(), { type: 'event_close', id: first.id });
  host.send(JSON.stringify({ type: 'event_data', id: first.id, text: '{"stale":true}' }));
  const next = connect(port, { path: '/api/events', headers: { origin } }); const nextOpen = once(next, 'open');
  const second = await host.next(); assert.notEqual(first.id, second.id);
  host.send(JSON.stringify({ type: 'event_opened', id: second.id, status: 101 })); await nextOpen;
  next.close(); assert.deepEqual(await host.next(), { type: 'event_close', id: second.id });
});

test('binary, oversized and excessive phone event messages close only that channel', async t => {
  const { port } = await fixture(t, { eventRate: 2 }); const host = await authenticate(port);
  for (const kind of ['binary', 'oversized', 'rate']) {
    const phone = connect(port, { path: '/api/events', headers: { origin } }); const opening = once(phone, 'open');
    const request = await host.next(); host.send(JSON.stringify({ type: 'event_opened', id: request.id, status: 101 })); await opening;
    const closed = once(phone, 'close');
    if (kind === 'binary') phone.send(Buffer.from('bad'));
    else if (kind === 'oversized') phone.send('x'.repeat(8193));
    else { phone.send('{}'); phone.send('{}'); phone.send('{}'); await host.next(); await host.next(); }
    assert.ok([1008, 1009].includes((await closed)[0]));
    assert.deepEqual(await host.next(), { type: 'event_close', id: request.id });
    assert.equal(host.readyState, WebSocket.OPEN);
  }
});
