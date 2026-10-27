import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
const bundle = new URL('../TheAll/Mobile/MobileWeb.bundle/', import.meta.url);
const source = await readFile(new URL('core.js', bundle), 'utf8');
const { APIError, request, chatPath, mergePage, turns, operation, readPairToken, safeLink, randomUUID, isPrivateLANHTTP } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);

test('API reads use same-origin cookies, no-store and no token in headers or query', async () => {
  let observed;
  const data = await request('/api/workspaces', { fetcher: async (path, options) => {
    observed = { path, options }; return new Response('{"workspaces":[]}');
  } });
  assert.deepEqual(data, { workspaces: [] });
  assert.equal(observed.path, '/api/workspaces');
  assert.equal(observed.options.credentials, 'same-origin');
  assert.equal(observed.options.cache, 'no-store');
  assert.equal(observed.options.method, undefined);
  assert.equal(observed.options.headers.Authorization, undefined);
});
test('mutations use JSON and the anti-CSRF client header, retaining bootID/requestId', async () => {
  const action = operation('/api/chats/c/send', { text: 'hello', bootID: 'boot-1' }, 'request-1');
  let attempts = [];
  for (let i = 0; i < 2; i++) await request(action.path, { body: action.body, fetcher: async (path, options) => {
    attempts.push(options); return new Response('{"id":"c"}');
  } });
  assert.deepEqual(attempts[0].body, attempts[1].body);
  assert.equal(attempts[0].headers['X-TheAll-Client'], '1');
  assert.equal(attempts[0].headers['Content-Type'], 'application/json');
  assert.equal(attempts[0].method, 'POST');
  assert.deepEqual(JSON.parse(attempts[0].body), { text: 'hello', bootID: 'boot-1', requestId: 'request-1' });
  assert.throws(() => { action.body.bootID = 'boot-2'; }, TypeError);
});
test('network and server failures have unknown outcome; explicit rejections do not', async () => {
  await assert.rejects(request('/api/chats', { body: {}, fetcher: async () => { throw new TypeError('offline'); } }), error => error instanceof APIError && error.uncertain);
  for (const [status, uncertain] of [[401, false], [409, false], [422, false], [503, true]]) {
    await assert.rejects(request('/api/chats', { fetcher: async () => new Response('{"error":"rejected"}', { status }) }), error => error.status === status && error.uncertain === uncertain);
  }
});
test('an in-flight duplicate preserves the original request for another explicit retry', async () => {
  await assert.rejects(request('/api/chats', { body: {}, fetcher: async () => new Response('{"error":"Still being processed","code":"request_pending"}', { status: 409 }) }), error => error.status === 409 && error.code === 'request_pending' && error.uncertain);
});
test('a recorded Mac submission failure permits editing the retained draft instead of retrying forever', async () => {
  await assert.rejects(request('/api/chats', { body: {}, fetcher: async () => new Response('{"error":"Model rejected","code":"operation_failed"}', { status: 503 }) }), error => error.status === 503 && !error.uncertain);
});
test('non-JSON success is uncertain, not falsely reported as successful mutation', async () => {
  await assert.rejects(request('/api/chats', { body: {}, fetcher: async () => new Response('bad gateway') }), error => error.uncertain);
});
test('chat identifiers are encoded and cannot change request path', () => {
  assert.equal(chatPath('../private?q=1', '/send'), '/api/chats/..%2Fprivate%3Fq%3D1/send');
});
const page = (start, total, ids) => ({ id: 'c', start, total, messages: ids.map(id => ({ id, text: id })), isBusy: false });
test('older pages are retained while latest streaming text updates', () => {
  const earlier = page(0, 4, ['a', 'b', 'c', 'd']);
  const latest = page(2, 5, ['c', 'd', 'e']); latest.messages[1].text = 'd updated'; latest.isBusy = true;
  const merged = mergePage(earlier, latest);
  assert.equal(merged.start, 0); assert.equal(merged.total, 5); assert.equal(merged.isBusy, true);
  assert.deepEqual(merged.messages.map(m => m.text), ['a', 'b', 'c', 'd updated', 'e']);
});
test('history pagination merges earlier page with current live metadata', () => {
  const current = page(2, 4, ['c', 'd']); current.isBusy = true;
  const merged = mergePage(page(0, 4, ['a', 'b']), current);
  assert.deepEqual(merged.messages.map(m => m.id), ['a', 'b', 'c', 'd']);
  assert.equal(merged.isBusy, true);
});
test('gapped or truncated history never masquerades as complete history', () => {
  const next = page(5, 7, ['f', 'g']);
  assert.equal(mergePage(page(0, 2, ['a', 'b']), next), next);
  const cleared = page(0, 1, ['z']);
  assert.equal(mergePage(page(0, 3, ['a', 'b', 'c']), cleared), cleared);
});
test('turns separate user questions, intermediate progress and final answers; tools are hidden', () => {
  const result = turns([
    { id: '1', role: 'user', text: 'hello' },
    { id: '2', role: 'assistant', isIntermediate: true, text: 'checking' },
    { id: '3', role: 'tool', text: 'Bash' },
    { id: '4', role: 'thinking', text: 'thinking' },
    { id: '5', role: 'assistant', text: 'done' },
    { id: '6', role: 'user', text: 'next' }
  ]);
  assert.equal(result.length, 2); assert.equal(result[0].user.id, '1');
  assert.deepEqual(result[0].progress.map(m => m.id), ['2', '4']);
  assert.deepEqual(result[0].answers.map(m => m.id), ['5']);
});
test('pairing token is immediately removed from address and does not enter a request URL', () => {
  let replacement;
  assert.equal(readPairToken({ hash: '#pair=secret%2Btoken', pathname: '/', search: '' }, { replaceState: (...args) => { replacement = args; } }), 'secret+token');
  assert.deepEqual(replacement, [null, '', '/']);
});
test('rendered links cannot run javascript or open local/data resources', () => {
  assert.equal(safeLink('javascript:alert(1)'), null);
  assert.equal(safeLink('file:///etc/passwd'), null);
  assert.equal(safeLink('data:text/html,test'), null);
  assert.equal(safeLink('https://example.com'), 'https://example.com/');
});
test('service worker never intercepts APIs, posts, query secrets or external resources', async () => {
  const handlers = new Map(); const fetched = []; const responses = []; const cached = { ok: true, cached: true };
  vm.runInNewContext(await readFile(new URL('sw.js', bundle), 'utf8'), {
    self: { location: { origin: 'https://mac.example' }, addEventListener: (name, callback) => handlers.set(name, callback) },
    URL, fetch: req => { fetched.push(req); return Promise.resolve({ ok: false }); }, caches: { match: async () => cached }
  });
  const run = (url, method = 'GET') => {
    let intercepted = false;
    handlers.get('fetch')({ request: { url, method }, respondWith(response) { intercepted = true; responses.push(response); } });
    return intercepted;
  };
  assert.equal(run('https://mac.example/api/chats/123'), false);
  assert.equal(run('https://mac.example/api/chats/123/send', 'POST'), false);
  assert.equal(run('https://mac.example/?pair=secret'), false);
  assert.equal(run('https://external.example/app.js'), false);
  assert.equal(run('https://mac.example/app.js'), true);
  assert.equal(await responses[0], cached, 'Relay 503 still shows the cached shell');
});
test('shell references are local; no unsafe HTML assignment or browser-persistent chat storage', async () => {
  const app = await readFile(new URL('app.js', bundle), 'utf8');
  const html = await readFile(new URL('index.html', bundle), 'utf8');
  assert.doesNotMatch(app, /\.innerHTML\s*=|\.outerHTML\s*=|insertAdjacentHTML|localStorage|sessionStorage|indexedDB/);
  assert.doesNotMatch(html, /(?:src|href)="https?:/);
  assert.match(app, /data\?\.isReady \|\| data\?\.canResume/);
  assert.equal((app.match(/bootID: state\.bootID/g) || []).length, 4);
});

test('response body reads share the timeout and retain uncertain mutation outcome', async () => {
  await assert.rejects(request('/api/chats', { body: {}, timeoutMs: 20, fetcher: async (_path, { signal }) => ({
    ok: true, status: 200,
    json: () => new Promise((_, reject) => signal.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true }))
  }) }), error => error instanceof APIError && error.uncertain);
});
test('shifted overlap or changed Mac process discards stale history pages', () => {
  const old = page(0, 4, ['a', 'b', 'c', 'd']);
  const shifted = page(2, 5, ['error', 'c', 'd']);
  assert.equal(mergePage(old, shifted), shifted);
  const restarted = { ...page(2, 4, ['c', 'd']), bootID: 'new-boot' };
  assert.equal(mergePage({ ...old, bootID: 'old-boot' }, restarted), restarted);
});
test('uncertain Mac acknowledgement remains retryable while tool errors remain visible', () => {
  assert.equal(new APIError('Unknown acknowledgement', 503, 'outcome_unknown').uncertain, true);
  assert.equal(turns([{ id: 'error', role: 'tool', isError: true, text: 'Tool failed' }])[0].answers.length, 1);
});


test('quick LAN accepts only canonical RFC1918 IPv4 HTTP addresses', () => {
  for (const hostname of ['10.0.0.1', '10.255.255.254', '172.16.0.1', '172.31.255.254', '192.168.1.2']) {
    assert.equal(isPrivateLANHTTP({ protocol: 'http:', hostname }), true, hostname);
  }
  for (const hostname of ['172.15.1.1', '172.32.0.1', '192.169.1.1', '8.8.8.8', '127.0.0.1', '169.254.1.1',
    '192.168.1.2.example.com', '192.168.1.256', '192.168.001.2', '0xC0A80102', '3232235778', 'localhost', '', '::1']) {
    assert.equal(isPrivateLANHTTP({ protocol: 'http:', hostname }), false, hostname);
  }
  assert.equal(isPrivateLANHTTP({ protocol: 'https:', hostname: '192.168.1.2' }), false);
});
test('UUID generation works without secure-context randomUUID and never falls back to Math.random', () => {
  const fake = { getRandomValues: values => { values.fill(255); return values; } };
  assert.equal(randomUUID(fake), 'ffffffff-ffff-4fff-bfff-ffffffffffff');
  assert.equal(randomUUID({ randomUUID: () => 'native-id' }), 'native-id');
  assert.throws(() => randomUUID({}), /Secure random/);
  assert.match(randomUUID(), /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
});
test('quick connection and shortcut instructions are translated in all five languages', async () => {
  const source = await readFile(new URL('i18n.js', bundle), 'utf8');
  const { catalog } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
  for (const code of ['en', 'zh-Hans', 'fr', 'ja', 'ko']) {
    for (const key of ['pairing', 'quickLANNote', 'installAndroidLAN', 'installNetworkLAN']) assert.ok(catalog[code][key], `${code}.${key}`);
  }
});
