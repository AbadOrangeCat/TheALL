import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFile } from 'node:fs/promises';
const root = new URL('../TheAll/Mobile/MobileWeb.bundle/', import.meta.url);
const moduleSource = await readFile(new URL('notifications.js', root), 'utf8');
const { NotificationPreferences, notificationCapability, applicationKey, subscriptionMatches, readNotificationChat, notificationMessage } = await import('data:text/javascript;base64,' + Buffer.from(moduleSource).toString('base64'));
const uuid = 'ed942fc9-7358-415d-bdc2-71c2e0977b99', chatID = 'f8d37844-cc8d-45f7-b56a-363e156fa233';
const publicKey = Buffer.from([4, ...Array.from({ length: 64 }, (_, n) => n)]).toString('base64url');
const otherKey = Buffer.from([4, ...Array(64).fill(1)]).toString('base64url');
function fixture({ enabled = false, permission = 'default', key = null, statusError, postError, removeError = false } = {}) {
  const calls = [], changes = []; let prompts = 0, subscribed = 0, removed = 0, current, locale = 'en', beforePost;
  const create = key => ({ endpoint: 'https://push.test/subscription-' + ++subscribed, options: { applicationServerKey: applicationKey(key) }, expirationTime: null,
    toJSON() { return { endpoint: this.endpoint, keys: { p256dh: 'public-test-key', auth: 'test-only' } }; },
    async unsubscribe() { removed++; if (removeError) return false; if (current === this) current = null; return true; } });
  current = key ? create(key) : null;
  const registration = { active: {}, pushManager: { getSubscription: async () => current, subscribe: async () => (current = create(publicKey)) } };
  const env = { isSecureContext: true, navigator: { userAgent: 'Android', serviceWorker: { getRegistration: async () => registration, ready: Promise.resolve(registration) } }, PushManager: {},
    Notification: { permission, requestPermission() { prompts++; env.Notification.permission = 'granted'; return Promise.resolve('granted'); } } };
  const request = async (path, options) => {
    calls.push({ path, ...options });
    if (!options) { if (statusError) throw statusError; return { available: true, enabled, publicKey }; }
    if (beforePost) await beforePost(path, options);
    if (postError) throw postError;
    if (path.endsWith('/subscribe')) { enabled = true; return { enabled: true }; }
    if (path.endsWith('/unsubscribe')) { enabled = false; return { enabled: false }; }
    return { ok: true };
  };
  const controller = new NotificationPreferences({ request, env, language: () => locale, onChange: state => changes.push(state) });
  return { controller, calls, changes, env, registration, get current() { return current; }, get prompts() { return prompts; }, get removed() { return removed; }, setLocale(value) { locale = value; }, setPost(value) { beforePost = value; } };
}

test('phone capability requires HTTPS and iOS Home Screen; desktop controls stay off', () => {
  const base = fixture().env;
  assert.equal(notificationCapability(base), null);
  assert.equal(notificationCapability({ ...base, isSecureContext: false }), 'https');
  assert.equal(notificationCapability({ ...base, desktop: true }), 'desktop');
  assert.equal(notificationCapability({ ...base, PushManager: undefined }), 'unsupported');
  const ios = { ...base, navigator: { ...base.navigator, userAgent: 'iPhone' } };
  assert.equal(notificationCapability(ios), 'install');
  assert.equal(notificationCapability({ ...ios, matchMedia: () => ({ matches: true }) }), null);
  assert.equal(notificationCapability({ ...base, navigator: { ...base.navigator, userAgent: 'Macintosh', platform: 'MacIntel', maxTouchPoints: 5 } }), 'install');
});

test('opening settings never asks permission; explicit enable does so before yielding and sends the device subscription', async () => {
  const f = fixture(); await f.controller.connect(); assert.equal(f.prompts, 0); assert.equal(f.controller.state.enabled, false);
  const promise = f.controller.enable(); assert.equal(f.prompts, 1); await promise;
  assert.equal(f.controller.state.enabled, true);
  assert.equal(f.calls.at(-1).path, '/api/notifications/subscribe');
  assert.equal(f.calls.at(-1).body.language, 'en'); assert.ok(f.calls.at(-1).body.subscription.endpoint);
  await f.controller.test(); assert.equal(f.calls.at(-1).path, '/api/notifications/test'); assert.equal(f.controller.state.reason, 'sent');
});

test('permission alone is not an enabled preference; a fresh device grant removes a previous subscription', async () => {
  const f = fixture({ enabled: false, permission: 'granted', key: publicKey });
  await f.controller.connect(); assert.equal(f.controller.state.enabled, false); assert.equal(f.current, null); assert.equal(f.removed, 1);
  await f.controller.enable(); assert.equal(f.prompts, 0); assert.equal(f.controller.state.enabled, true);
});

test('server-enabled preference requires matching application key, valid expiration and browser permission', async () => {
  const f = fixture({ enabled: true, permission: 'granted', key: otherKey }); await f.controller.connect();
  assert.equal(f.controller.state.enabled, false); await f.controller.enable(); assert.equal(f.removed, 1);
  assert.equal(subscriptionMatches(f.current, publicKey), true);
  f.current.expirationTime = Date.now() - 1; assert.equal(subscriptionMatches(f.current, publicKey), false);
  for (const invalid of ['', 'x'.repeat(87), 'https://elsewhere', 'AAAA']) assert.throws(() => applicationKey(invalid));
});

test('failed subscription does not pretend enabled and removes its newly-created browser subscription', async () => {
  const f = fixture({ postError: new Error('offline') }); await f.controller.connect();
  await assert.rejects(f.controller.enable(), /offline/); assert.equal(f.current, null); assert.equal(f.controller.state.enabled, false); assert.ok(f.controller.state.error);
});

test('failed server unsubscribe retains enabled status, and browser cleanup failures are visible', async () => {
  const f = fixture({ enabled: true, permission: 'granted', key: publicKey, postError: new Error('offline') });
  await f.controller.connect(); await assert.rejects(f.controller.disable()); assert.equal(f.controller.state.enabled, true); assert.equal(f.removed, 0);
  const local = fixture({ enabled: true, permission: 'granted', key: publicKey, removeError: true });
  await local.controller.connect(); await assert.rejects(local.controller.disable(), { key: 'notificationsUnsubscribeFailed' });
  assert.equal(local.controller.state.enabled, false); assert.equal(local.controller.state.error.key, 'notificationsUnsubscribeFailed');
});

test('disconnect cancels an in-flight enable, clears subscription and cannot re-enable a stale device', async () => {
  const f = fixture(); await f.controller.connect();
  let release, arrived;
  const posted = new Promise(resolve => { arrived = resolve; });
  f.setPost(async () => { arrived(); await new Promise(resolve => { release = resolve; }); });
  const enable = f.controller.enable(); await posted;
  const disconnect = f.controller.disconnect(); release(); await Promise.all([enable, disconnect]);
  assert.equal(f.controller.state.enabled, false); assert.equal(f.current, null); assert.equal(f.controller.authenticated, false);
});

test('language changes rebind the existing subscription without prompting, including while another operation runs', async () => {
  const f = fixture({ enabled: true, permission: 'granted', key: publicKey }); await f.controller.connect();
  const endpoint = f.current.endpoint; f.setLocale('ja'); await f.controller.syncLanguage();
  assert.equal(f.calls.at(-1).body.language, 'ja'); assert.equal(f.current.endpoint, endpoint); assert.equal(f.prompts, 0);
  let release, arrived; const posted = new Promise(resolve => { arrived = resolve; });
  f.setPost(async path => { if (path.endsWith('/test')) { arrived(); await new Promise(resolve => { release = resolve; }); } });
  const testing = f.controller.test(); await posted; f.setLocale('fr'); await f.controller.syncLanguage(); release(); await testing;
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.calls.at(-1).body.language, 'fr'); assert.equal(f.prompts, 0);
});

test('old backend and denied permissions degrade without prompting or impacting chat', async () => {
  const f = fixture({ statusError: Object.assign(new Error('old'), { status: 404 }) }); await f.controller.connect();
  assert.equal(f.controller.state.reason, 'update'); assert.equal(f.prompts, 0); await f.controller.enable(); assert.equal(f.calls.length, 1);
  const blocked = fixture({ permission: 'denied' }); await blocked.controller.connect();
  await assert.rejects(blocked.controller.enable(), { key: 'notificationsBlocked' }); assert.equal(blocked.prompts, 0);
});

test('deep links strip the query even when invalid and accept only one UUID; worker messages require our worker', () => {
  let replaced;
  const history = { replaceState(_a, _b, url) { replaced = url; } };
  const location = { pathname: '/', hash: '#pair=one-time', search: '?chat=' + chatID + '&other=1' };
  assert.equal(readNotificationChat(location, history), chatID); assert.equal(replaced, '/?other=1#pair=one-time');
  for (const search of ['?chat=https://evil.test', '?chat=' + chatID + '&chat=' + chatID, '?chat=../api/logout']) {
    assert.equal(readNotificationChat({ ...location, search }, history), null); assert.equal(replaced, '/#pair=one-time');
  }
  const event = { origin: 'https://theall.test', source: { scriptURL: 'https://theall.test/sw.js' }, data: { type: 'theall:open-notification', id: uuid, kind: 'completed', chatId: chatID } };
  assert.equal(notificationMessage(event, event.origin).chatId, chatID);
  assert.equal(notificationMessage({ ...event, source: { scriptURL: 'https://evil.test/sw.js' } }, event.origin), null);
  assert.equal(notificationMessage({ ...event, data: { ...event.data, chatId: 'https://evil.test' } }, event.origin), null);
  assert.equal(notificationMessage({ ...event, data: { ...event.data, kind: 'test', chatId: null } }, event.origin).chatId, null);
});

const swSource = await readFile(new URL('sw.js', root), 'utf8');
function worker({ failShow = false, windows = [], channel } = {}) {
  const handlers = {}, notifications = [], opened = [], posted = []; let closed = 0, fetched = 0;
  const self = { location: { origin: 'https://theall.test' }, addEventListener(name, fn) { handlers[name] = fn; },
    registration: { async showNotification(title, options) { if (failShow) { failShow = false; throw new Error('OS temporarily unavailable'); } notifications.push({ title, ...options }); } },
    clients: { async matchAll() { return windows; }, async openWindow(url) { opened.push(url); return {}; } } };
  vm.runInNewContext(swSource, { self, URL, setTimeout, clearTimeout, MessageChannel: channel, fetch: () => { fetched++; throw Error('no network needed'); } });
  async function trigger(name, value) { let waiting; handlers[name]({ ...(name === 'push' ? { data: { json: () => value } } : { notification: { data: value, close() { closed++; } } }), waitUntil(promise) { waiting = promise; } }); await waiting; }
  return { self, notifications, opened, posted, trigger, get fetched() { return fetched; }, get closed() { return closed; } };
}
const payload = { version: 1, id: uuid, type: 'completed', chatId: chatID, title: 'TheAll', body: 'Your task is complete.', url: '/?chat=' + chatID };

test('background push shows generic payload without fetching chats, once per event, and invalid links never show', async () => {
  const w = worker(); await w.trigger('push', payload); await w.trigger('push', payload);
  assert.equal(w.notifications.length, 1); assert.equal(w.notifications[0].title, 'TheAll'); assert.equal(w.notifications[0].data.body, undefined); assert.equal(w.fetched, 0);
  for (const value of [null, { ...payload, url: 'https://evil.test' }, { ...payload, chatId: '../api' }, { ...payload, version: 2 }, { ...payload, body: '' }]) await w.trigger('push', value);
  assert.equal(w.notifications.length, 1);
});

test('failed OS display can retry the same event without being lost to deduplication', async () => {
  const w = worker({ failShow: true }); await assert.rejects(w.trigger('push', payload)); await w.trigger('push', payload); assert.equal(w.notifications.length, 1);
});

test('click opens only our exact conversation, test opens home, and duplicate clicks never reopen', async () => {
  const w = worker(); await w.trigger('notificationclick', payload); await w.trigger('notificationclick', payload);
  assert.deepEqual(w.opened, ['https://theall.test/?chat=' + chatID]);
  const testPayload = { ...payload, id: chatID, type: 'test', chatId: undefined, url: '/' };
  await w.trigger('notificationclick', testPayload); assert.equal(w.opened.at(-1), 'https://theall.test/');
  await w.trigger('notificationclick', { ...payload, url: 'https://evil.test' }); assert.equal(w.opened.length, 2);
});

test('click focuses an existing authorized app window and acknowledges navigation instead of reloading its drafts', async () => {
  let focused = 0, message;
  class Channel {
    constructor() { this.port1 = { close() {} }; this.port2 = { close() {}, reply: value => this.port1.onmessage?.({ data: value }) }; }
  }
  const client = { url: 'https://theall.test/', visibilityState: 'visible', async focus() { focused++; }, postMessage(value, ports) { message = value; ports[0].reply({ id: value.id, accepted: true }); } };
  const w = worker({ windows: [client], channel: Channel }); await w.trigger('notificationclick', payload);
  assert.equal(focused, 1); assert.equal(message.chatId, chatID); assert.equal(message.type, 'theall:open-notification'); assert.equal(w.opened.length, 0);
});

test('notification, timing and reasoning controls have nonempty translations in all five languages', async () => {
  const source = await readFile(new URL('i18n.js', root), 'utf8');
  const { catalog } = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
  for (const values of Object.values(catalog)) for (const key of Object.keys(catalog.en).filter(key => /^(notification|turn|effort_|reasoningEffort|defaultEffort)/.test(key))) assert.ok(values[key]?.trim(), key);
});

test('offline notification navigation uses only the public shell; arbitrary query and API requests stay untouched', async () => {
  const handlers = {}, matched = []; let response;
  vm.runInNewContext(swSource, {
    self: { location: { origin: 'https://theall.test' }, addEventListener(name, callback) { handlers[name] = callback; } }, URL,
    fetch: async () => { throw new Error('offline'); }, caches: { async match(path) { matched.push(path); return { shell: true }; } }
  });
  const request = { method: 'GET', mode: 'navigate', url: 'https://theall.test/?chat=' + chatID };
  handlers.fetch({ request, respondWith(promise) { response = promise; } }); assert.equal((await response).shell, true); assert.deepEqual(matched, ['/']);
  for (const url of ['https://theall.test/?chat=' + chatID + '&token=secret', 'https://theall.test/?chat=https://evil.test', 'https://theall.test/api/chats/' + chatID, 'https://evil.test/?chat=' + chatID]) {
    response = undefined; handlers.fetch({ request: { ...request, url }, respondWith(promise) { response = promise; } }); assert.equal(response, undefined);
  }
});
