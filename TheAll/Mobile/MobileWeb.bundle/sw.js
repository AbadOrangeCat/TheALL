// Cache only the public app shell. API data, tokens and mutation requests NEVER enter Cache Storage.
const CACHE = 'theall-shell-v5';
const SHELL = ['/', '/index.html', '/styles.css', '/app.js', '/core.js', '/live.js', '/photos.js', '/notifications.js', '/timing.js', '/effort.js', '/i18n.js', '/manifest.webmanifest',
  '/icons/icon-192.png', '/icons/icon-512.png', '/icons/apple-touch-icon.png'];
self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(SHELL)));
});
self.addEventListener('activate', event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(key => key.startsWith('theall-shell-') && key !== CACHE)
    .map(key => caches.delete(key)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);
  // A notification may be opened with the phone offline. Load the public shell
  // for this one validated navigation, without caching its query or any API data.
  const chat = url.searchParams.get('chat');
  if (event.request.method === 'GET' && event.request.mode === 'navigate' && url.origin === self.location.origin &&
      url.pathname === '/' && url.searchParams.size === 1 && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(chat || '')) {
    event.respondWith(fetch(event.request).then(response => response.ok ? response : caches.match('/').then(cached => cached || response)).catch(() => caches.match('/')));
    return;
  }
  if (event.request.method !== 'GET' || url.origin !== self.location.origin || url.search || !SHELL.includes(url.pathname)) return;
  event.respondWith(fetch(event.request).then(response => {
    if (response.ok) { const clone = response.clone(); caches.open(CACHE).then(cache => cache.put(event.request, clone)); }
    return response.ok ? response : caches.match(event.request).then(cached => cached || response);
  }).catch(() => caches.match(event.request)));
});

// Persist only opaque delivery IDs/timestamps for deduplication. No chat content,
// subscription keys, cookies or API responses enter this store.
const seenFallback = new Set();
function notificationPayload(input) {
  const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
  if (!input || input.version !== 1 || !uuid(input.id) || !['completed', 'test'].includes(input.type)) return null;
  const chatId = input.type === 'completed' ? input.chatId : null;
  if (input.type === 'completed' && !uuid(chatId)) return null;
  const url = chatId ? '/?chat=' + chatId : '/';
  if (input.url !== url || typeof input.body !== 'string' || !input.body.trim() || input.body.length > 400) return null;
  return { version: 1, id: input.id.toLowerCase(), type: input.type, chatId, url,
    body: input.body.replace(/[\x00-\x1f\x7f]/g, ' ') };
}
function notificationDatabase() {
  return new Promise((resolve, reject) => {
    const request = self.indexedDB.open('theall-notification-deliveries', 1);
    request.onupgradeneeded = () => request.result.createObjectStore('seen', { keyPath: 'id' }).createIndex('at', 'at');
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}
async function markNotification(id, remove = false) {
  let database;
  try {
    database = await notificationDatabase();
    return await new Promise((resolve, reject) => {
      const transaction = database.transaction('seen', 'readwrite'), store = transaction.objectStore('seen');
      let fresh = true;
      const check = store.get(id);
      check.onsuccess = () => {
        fresh = !check.result;
        if (remove) store.delete(id); else if (fresh) store.put({ id, at: Date.now() });
      };
      // Bound old delivery metadata; notification payloads themselves are not kept.
      const cutoff = Date.now() - 7 * 86400000, cursor = store.index('at').openCursor(null, 'prev'); let count = 0;
      cursor.onsuccess = () => { const row = cursor.result; if (!row) return; if (row.value.at < cutoff || ++count > 1024) row.delete(); row.continue(); };
      transaction.oncomplete = () => resolve(fresh);
      transaction.onerror = transaction.onabort = () => reject(transaction.error);
    });
  } catch {
    const fresh = !seenFallback.has(id);
    if (remove) seenFallback.delete(id); else seenFallback.add(id);
    while (seenFallback.size > 1024) seenFallback.delete(seenFallback.values().next().value);
    return fresh;
  } finally { database?.close(); }
}
let pushQueue = Promise.resolve();
self.addEventListener('push', event => {
  let payload;
  try { payload = notificationPayload(event.data?.json()); } catch { return; }
  if (!payload) return;
  const delivery = pushQueue.catch(() => {}).then(async () => {
    if (!await markNotification('push:' + payload.id)) return;
    try {
      await self.registration.showNotification('TheAll', {
        body: payload.body, icon: '/icons/icon-192.png', badge: '/icons/icon-192.png',
        tag: 'theall:' + payload.id, renotify: false,
        data: { ...payload, body: undefined }
      });
    } catch (error) { await markNotification('push:' + payload.id, true); throw error; }
  });
  pushQueue = delivery; event.waitUntil(delivery);
});
async function notifyOpenClient(client, payload) {
  // An acknowledgement avoids losing a click while an existing window is still
  // loading its scripts. Failure opens a second window without destroying drafts.
  if (typeof MessageChannel === 'undefined') { client.postMessage({ type: 'theall:open-notification', id: payload.id, kind: payload.type, chatId: payload.chatId }); return true; }
  const channel = new MessageChannel(); let timer;
  try {
    return await new Promise(resolve => {
      channel.port1.onmessage = event => { if (event.data?.id === payload.id && event.data?.accepted === true) resolve(true); };
      timer = setTimeout(() => resolve(false), 1500);
      client.postMessage({ type: 'theall:open-notification', id: payload.id, kind: payload.type, chatId: payload.chatId }, [channel.port2]);
    });
  } catch { return false; }
  finally { clearTimeout(timer); channel.port1.close(); channel.port2.close(); }
}
self.addEventListener('notificationclick', event => {
  event.notification.close();
  const data = event.notification.data;
  // Revalidate stored notification data. Never trust a URL supplied by an event.
  const payload = notificationPayload({ ...data, body: 'Notification' });
  if (!payload) return;
  event.waitUntil((async () => {
    if (!await markNotification('click:' + payload.id)) return;
    try {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const candidates = windows.filter(client => {
      try { const url = new URL(client.url); return url.origin === self.location.origin && ['/', '/index.html'].includes(url.pathname); }
      catch { return false; }
    }).sort((a, b) => Number(b.visibilityState === 'visible') - Number(a.visibilityState === 'visible'));
    for (const client of candidates) {
      try { await client.focus(); if (await notifyOpenClient(client, payload)) return; } catch { /* Closed window. */ }
    }
    if (!await self.clients.openWindow(new URL(payload.url, self.location.origin).href)) throw new Error('Notification window could not be opened');
    }
    catch (error) { await markNotification('click:' + payload.id, true); throw error; }
  })());
});
