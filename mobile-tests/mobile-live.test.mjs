import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const bundle = new URL('../TheAll/Mobile/MobileWeb.bundle/', import.meta.url);
const moduleFrom = async name => import(`data:text/javascript;base64,${Buffer.from(await readFile(new URL(name, bundle))).toString('base64')}`);
const { LiveUpdates } = await moduleFrom('live.js');
const { catalog, supportedLanguages, resolveLanguage, setLanguage, language, t } = await moduleFrom('i18n.js');
function fixture() {
  let time = 0, sequence = 0; const timers = new Map(), sockets = [], changes = [], states = [], hello = []; let revoked = 0;
  const api = new LiveUpdates({ url: 'wss://theall.test/api/events',
    onChanged: () => changes.push(time), onHello: data => hello.push(data), onState: state => states.push(state), onRevoked: () => revoked++,
    setTimer: (fn, delay) => { const id = ++sequence; timers.set(id, { at: time + delay, fn }); return id; },
    clearTimer: id => timers.delete(id),
    socket: url => { const socket = { url, sent: [], closed: false, send(raw) { this.sent.push(JSON.parse(raw)); }, close() { this.closed = true; }, message(data) { this.onmessage?.({ data: JSON.stringify(data) }); } }; sockets.push(socket); return socket; }
  });
  function advance(ms) {
    const end = time + ms;
    for (;;) {
      const next = [...timers].filter(([, value]) => value.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
      if (!next) break; timers.delete(next[0]); time = next[1].at; next[1].fn();
    }
    time = end;
  }
  return { api, advance, timers, sockets, changes, states, hello, revoked: () => revoked };
}
test('live handshake refreshes once, coalesces pushes and uses only cookie-authenticated URL', () => {
  const f = fixture(); f.api.start(); assert.equal(f.api.ready, false);
  assert.equal(f.sockets[0].url, 'wss://theall.test/api/events');
  f.sockets[0].message({ type: 'changed' }); assert.equal(f.changes.length, 0);
  f.sockets[0].message({ type: 'hello', bootID: 'boot-1', access: { writable: false, workspaceId: 'w' } });
  assert.equal(f.api.ready, true); assert.equal(f.changes.length, 1); assert.equal(f.hello[0].access.writable, false);
  for (let i = 0; i < 100; i++) f.sockets[0].message({ type: 'changed' });
  f.advance(199); assert.equal(f.changes.length, 1); f.advance(1); assert.equal(f.changes.length, 2);
  assert.deepEqual(f.sockets[0].sent, []); f.api.stop(); assert.equal(f.timers.size, 0);
});
test('heartbeat times out and reconnects with bounded exponential backoff; stale callbacks are ignored', () => {
  const f = fixture(); f.api.start(); const first = f.sockets[0]; first.message({ type: 'hello' });
  const stale = first.onmessage;
  f.advance(20000); assert.deepEqual(first.sent, [{ type: 'ping' }]);
  f.advance(10000); assert.equal(first.closed, true); assert.equal(f.api.ready, false);
  f.advance(499); assert.equal(f.sockets.length, 1); f.advance(1); assert.equal(f.sockets.length, 2);
  stale({ data: '{"type":"hello"}' }); assert.equal(f.api.ready, false);
  for (const delay of [1000, 2000, 4000, 8000, 10000, 10000]) {
    const before = f.sockets.length; f.sockets.at(-1).onclose();
    f.advance(delay - 1); assert.equal(f.sockets.length, before); f.advance(1); assert.equal(f.sockets.length, before + 1);
  }
  f.sockets.at(-1).message({ type: 'hello' }); assert.equal(f.api.delay, 500); assert.equal(f.changes.length, 2);
  f.api.stop(); assert.equal(f.timers.size, 0);
});
test('pong keeps transport alive, suspend cancels all timers, resume reconnects and revoke disposes', () => {
  const f = fixture(); f.api.start(); f.sockets[0].message({ type: 'hello' });
  f.advance(20000); f.sockets[0].message({ type: 'pong' }); f.advance(10000); assert.equal(f.api.ready, true);
  f.api.suspend(); assert.equal(f.timers.size, 0); f.advance(100000); assert.equal(f.sockets.length, 1);
  f.api.resume(); assert.equal(f.sockets.length, 2); f.sockets[1].message({ type: 'hello' });
  f.sockets[1].message({ type: 'revoked' }); assert.equal(f.revoked(), 1); assert.equal(f.api.active, false);
  assert.equal(f.timers.size, 0); f.api.resume(); f.advance(30000); assert.equal(f.sockets.length, 2);
});
test('all five languages have every non-empty client string; regional locales and invalid preference fallbacks work', () => {
  const keys = Object.keys(catalog.en).sort();
  for (const code of Object.keys(supportedLanguages)) {
    assert.deepEqual(Object.keys(catalog[code]).sort(), keys, code);
    for (const [key, value] of Object.entries(catalog[code])) assert.ok(typeof value === 'string' && value.trim(), `${code}/${key}`);
  }
  for (const [input, expected] of [['zh-TW', 'zh-Hans'], ['fr-CA', 'fr'], ['ja-JP', 'ja'], ['ko-KR', 'ko'], ['de-DE', 'en']]) assert.equal(resolveLanguage(input), expected);
  setLanguage('fr'); assert.equal(language(), 'fr'); assert.equal(t('send'), 'Envoyer ↑');
  setLanguage('invalid'); assert.equal(language(), 'fr');
});
