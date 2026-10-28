// Browser subscription state is owned by PushManager. No credentials or chat data
// are stored here; server preferences are bound to the authenticated device.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const notificationChatID = value => typeof value === 'string' && UUID.test(value) ? value : null;
export function readNotificationChat(location, history) {
  const query = new URLSearchParams(location.search);
  if (!query.has('chat')) return null;
  const values = query.getAll('chat'); query.delete('chat');
  history.replaceState(null, '', location.pathname + (query.size ? '?' + query : '') + location.hash);
  return values.length === 1 ? notificationChatID(values[0]) : null;
}
export function notificationMessage(event, origin) {
  try {
    const source = new URL(event.source?.scriptURL);
    const data = event.data;
    if (source.origin !== origin || source.pathname !== '/sw.js' || source.search || source.hash ||
        (event.origin && event.origin !== origin) || data?.type !== 'theall:open-notification' || !UUID.test(data.id)) return null;
    if (data.kind === 'test' && data.chatId === null) return { id: data.id.toLowerCase(), chatId: null };
    if (data.kind === 'completed' && notificationChatID(data.chatId)) return { id: data.id.toLowerCase(), chatId: data.chatId };
  } catch { /* Cross-origin or stale worker. */ }
  return null;
}
export function notificationCapability(env = globalThis) {
  if (env.desktop) return 'desktop';
  if (!env.isSecureContext) return 'https';
  const nav = env.navigator || {};
  const ios = /iPad|iPhone|iPod/.test(nav.userAgent || '') || (nav.platform === 'MacIntel' && nav.maxTouchPoints > 1);
  const standalone = nav.standalone === true || !!env.matchMedia?.('(display-mode: standalone)').matches;
  if (ios && !standalone) return 'install';
  if (!nav.serviceWorker || !env.PushManager || !env.Notification) return 'unsupported';
  return null;
}
export function applicationKey(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{87}$/.test(value)) throw new NotificationPreferenceError('notificationsUnavailable');
  const bytes = Uint8Array.from(atob(value.replace(/-/g, '+').replace(/_/g, '/') + '='), c => c.charCodeAt(0));
  if (bytes.length !== 65 || bytes[0] !== 4) throw new NotificationPreferenceError('notificationsUnavailable');
  return bytes;
}
export function subscriptionMatches(subscription, key) {
  const bytes = subscription?.options?.applicationServerKey;
  if (!bytes || (subscription.expirationTime && subscription.expirationTime <= Date.now())) return false;
  const expected = applicationKey(key), actual = new Uint8Array(bytes);
  return actual.length === expected.length && actual.every((value, index) => value === expected[index]);
}
export class NotificationPreferenceError extends Error {
  constructor(key) { super(key); this.key = key; }
}
export class NotificationPreferences {
  constructor({ request, env = globalThis, language = () => 'en', onChange = () => {} }) {
    Object.assign(this, { request, env, language, onChange });
    this.generation = 0; this.authenticated = false; this.pending = null; this.languagePending = false; this.refreshID = 0; this.refreshTasks = new Set();
    this.state = { available: false, enabled: false, busy: false, reason: notificationCapability(env) || 'loading', error: null };
  }
  emit(patch = {}) { Object.assign(this.state, patch); this.onChange({ ...this.state }); }
  current(generation) { return this.authenticated && generation === this.generation; }
  async registration() {
    const sw = this.env.navigator.serviceWorker;
    const existing = await sw.getRegistration('/');
    if (existing?.active) return existing;
    let timer;
    try { return await Promise.race([sw.ready, new Promise((_, reject) => { timer = setTimeout(() => reject(new NotificationPreferenceError('notificationsUnavailable')), 10000); })]); }
    finally { clearTimeout(timer); }
  }
  async removeSubscription(registration, subscription) {
    if (!subscription) return;
    try {
      if (!await subscription.unsubscribe() && (await registration.pushManager.getSubscription())?.endpoint === subscription.endpoint) throw new Error();
    } catch { throw new NotificationPreferenceError('notificationsUnsubscribeFailed'); }
  }
  async connect() { this.authenticated = true; this.generation++; return this.refresh(); }
  async refresh() {
    const task = this.refreshPreference(); this.refreshTasks.add(task);
    try { await task; } finally { this.refreshTasks.delete(task); }
  }
  async refreshPreference() {
    const generation = this.generation, reason = notificationCapability(this.env), refreshID = ++this.refreshID;
    const current = () => this.current(generation) && refreshID === this.refreshID;
    if (!this.authenticated || this.pending) return;
    if (reason) { this.emit({ available: false, enabled: false, reason, error: null }); return; }
    this.emit({ busy: true, reason: 'loading', error: null });
    try {
      const status = await this.request('/api/notifications');
      if (!current()) return;
      if (status.available !== true) { this.emit({ available: false, enabled: false, reason: status.reason === 'https_required' ? 'https' : 'unavailable' }); return; }
      applicationKey(status.publicKey);
      const registration = await this.registration(), subscription = await registration.pushManager.getSubscription();
      if (!current()) return;
      this.registrationValue = registration; this.publicKey = status.publicKey;
      const enabled = status.enabled === true && this.env.Notification.permission === 'granted' && subscriptionMatches(subscription, status.publicKey);
      // A fresh pairing grant must not inherit a browser subscription that the
      // current authenticated device did not enable.
      if (!status.enabled && subscription) await this.removeSubscription(registration, subscription);
      if (!current()) return;
      this.emit({ available: true, enabled, reason: this.env.Notification.permission === 'denied' ? 'blocked' : enabled ? 'enabled' : 'disabled' });
    } catch (error) {
      if (current()) this.emit({ available: false, enabled: false, reason: [404, 405].includes(error.status) ? 'update' : 'unavailable', error: [404, 405].includes(error.status) ? null : error });
    } finally { if (current()) this.emit({ busy: false }); }
  }
  async enable() {
    if (this.pending || !this.authenticated || !this.state.available) return;
    if (this.env.Notification.permission === 'denied') throw new NotificationPreferenceError('notificationsBlocked');
    // Invoke requestPermission before the first await, preserving iOS user activation.
    const permission = this.env.Notification.permission === 'granted' ? Promise.resolve('granted') : this.env.Notification.requestPermission();
    return this.perform(async (generation, signal) => {
      if (await permission !== 'granted') throw new NotificationPreferenceError('notificationsBlocked');
      if (!this.current(generation)) return;
      const registration = this.registrationValue || await this.registration();
      let subscription = await registration.pushManager.getSubscription(), created = false;
      if (!this.current(generation)) return;
      if (subscription && !subscriptionMatches(subscription, this.publicKey)) { await this.removeSubscription(registration, subscription); subscription = null; }
      if (!this.current(generation)) return;
      try {
        if (!subscription) { subscription = await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: applicationKey(this.publicKey) }); created = true; }
        if (!this.current(generation)) { if (created) await subscription.unsubscribe(); return; }
        const response = await this.request('/api/notifications/subscribe', { body: { subscription: subscription.toJSON(), language: this.language() }, signal });
        if (response.enabled !== true) throw new NotificationPreferenceError('notificationsUnavailable');
        if (this.current(generation)) this.emit({ enabled: true, reason: 'enabled', error: null });
      } catch (error) {
        if (created && subscription) await subscription.unsubscribe().catch(() => {});
        throw error;
      }
    });
  }
  async syncLanguage() {
    if (!this.authenticated) return;
    if (this.pending) { this.languagePending = true; return; }
    if (!this.state.enabled) return;
    return this.perform(async (generation, signal) => {
      const registration = this.registrationValue || await this.registration();
      const subscription = await registration.pushManager.getSubscription();
      if (!this.current(generation)) return;
      if (!subscriptionMatches(subscription, this.publicKey)) { this.emit({ enabled: false, reason: 'disabled' }); return; }
      const response = await this.request('/api/notifications/subscribe', { body: { subscription: subscription.toJSON(), language: this.language() }, signal });
      if (response.enabled !== true) throw new NotificationPreferenceError('notificationsUnavailable');
    });
  }
  async disable() {
    if (this.pending || !this.authenticated) return;
    return this.perform(async (generation, signal) => {
      const response = await this.request('/api/notifications/unsubscribe', { body: {}, signal });
      if (response.enabled !== false) throw new NotificationPreferenceError('notificationsUnavailable');
      if (!this.current(generation)) return;
      this.emit({ enabled: false, reason: 'disabled' });
      const registration = this.registrationValue || await this.registration();
      const subscription = await registration.pushManager.getSubscription();
      if (subscription) await this.removeSubscription(registration, subscription);
    });
  }
  async test() {
    if (!this.authenticated || !this.state.enabled || this.pending) return;
    return this.perform(async (generation, signal) => {
      const response = await this.request('/api/notifications/test', { body: {}, signal });
      if (response.ok !== true) throw new NotificationPreferenceError('notificationsUnavailable');
      if (this.current(generation)) this.emit({ reason: 'sent' });
    });
  }
  async perform(action) {
    const generation = this.generation, controller = new AbortController();
    const operation = { controller }; this.pending = operation;
    this.emit({ busy: true, error: null });
    operation.promise = (async () => {
      try { return await action(generation, controller.signal); }
      catch (error) { if (this.current(generation)) { this.emit({ error, reason: error.key === 'notificationsBlocked' ? 'blocked' : this.state.reason }); throw error; } }
      finally { if (this.pending === operation) {
        this.pending = null; this.emit({ busy: false });
        if (this.languagePending) { this.languagePending = false; queueMicrotask(() => this.syncLanguage().catch(() => {})); }
      } }
    })();
    return operation.promise;
  }
  async disconnect() {
    this.authenticated = false; this.generation++; this.refreshID++; this.languagePending = false;
    const pending = this.pending; pending?.controller.abort();
    this.emit({ enabled: false, available: false, error: null, reason: notificationCapability(this.env) || 'disabled' });
    await Promise.allSettled([pending?.promise, ...this.refreshTasks]);
    if (notificationCapability(this.env)) return;
    const registration = await this.env.navigator.serviceWorker.getRegistration('/');
    const subscription = await registration?.pushManager.getSubscription();
    if (subscription) await this.removeSubscription(registration, subscription);
    this.registrationValue = null;
  }
}
