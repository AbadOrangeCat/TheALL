import { APIError, request, chatPath, mergePage, turns, operation, readPairToken, safeLink, isPrivateLANHTTP } from './core.js';

import { NotificationPreferences, readNotificationChat, notificationMessage } from './notifications.js';
import { turnTiming } from './timing.js';
import { reasoningOptions, selectedReasoningEffort } from './effort.js';

import { FILE_LIMITS, FileError, validateFileSelection, prepareFile, splitAttachments, filePath, fileSize, freezeFileSubmission, removeSubmittedFiles } from './files.js';
import { PHOTO_LIMITS, PhotoError, validatePhotoSelection, preparePhoto, imagePath, freezePhotoSubmission, removeSubmittedPhotos } from './photos.js';

const $ = id => document.getElementById(id);
const secure = window.isSecureContext;
const quickLAN = isPrivateLANHTTP(location);
const connectionAllowed = secure || quickLAN;
// A scanned invitation stays in memory only, never in browser history or storage.
let scannedToken = readPairToken(location, history);
import { LiveUpdates } from './live.js';
import { t, language, setLanguage, supportedLanguages } from './i18n.js';
let notificationPreferences;
let notificationCleanup = Promise.resolve();
let pendingNotification = readNotificationChat(location, history);
pendingNotification = pendingNotification ? { chatId: pendingNotification } : undefined;
const receivedNotifications = new Set();
let notificationNavigationError = '';
let notificationDesktop = !!window.theall;
try { notificationDesktop ||= window.parent !== window && !!window.parent.theall; } catch { /* Embedded on another origin. */ }
function translatePage() {
  document.documentElement.lang = language();
  document.querySelectorAll('[data-i18n]').forEach(node => { node.textContent = t(node.dataset.i18n); });
  document.querySelectorAll('[data-i18n-placeholder]').forEach(node => { node.placeholder = t(node.dataset.i18nPlaceholder); });
  for (const [id, key] of Object.entries({ 'open-sidebar': 'openWorkspaces', 'close-sidebar': 'close',
    'drawer-shade': 'close', 'new-chat': 'newChat', 'jump-bottom': 'jumpBottom',
    'open-notifications': 'notificationsTitle', 'close-notifications': 'close', 'effort': 'reasoningEffort', 'close-new': 'close', 'close-install': 'close', 'close-photo': 'close', 'add-photos': 'filesAdd', transcript: 'history', sidebar: 'workspaces' })) $(id).ariaLabel = t(key);
  $('directory').title = $('directory').textContent || t('directory');
  document.querySelectorAll('.language-select').forEach(select => { select.value = language(); });
  $('connection-note').textContent = quickLAN ? t('quickLANNote') : '';
  $('connection-note').hidden = !quickLAN;
  $('install-android').textContent = t(quickLAN ? 'installAndroidLAN' : 'installAndroid');
  $('install-network').textContent = t(quickLAN ? 'installNetworkLAN' : 'installNetwork');
  $('open-notifications').title = t('notificationsTitle');
  if (notificationPreferences) renderNotificationSettings();
  if (notificationNavigationError) showError('global-error', t(notificationNavigationError));
}
translatePage();
$('device-name').value = /iPad/.test(navigator.userAgent) ? 'iPad' : /iPhone/.test(navigator.userAgent) ? 'iPhone' : /Android/.test(navigator.userAgent) ? 'Android' : t('deviceMobile');

const state = {
  suspended: false, authenticated: false, connected: false, sessionGeneration: 0, access: { workspaceId: null, writable: true }, live: false, refreshQueued: false, bootID: null, workspaces: [], selected: null, selection: 0,
  chats: new Map(), drafts: new Map(), imageDrafts: new Map(), fileDrafts: new Map(), imageLoading: new Set(), models: new Map(), efforts: new Map(), modelNotices: new Set(), scroll: new Map(),
  progress: new Map(), errors: new Map(), answerDrafts: new Map(), pending: new Map(), rendering: '', questionRendering: '',
  recoveryTimer: null, sessionProbe: null, pairingAttempt: null, pollTimer: null, polling: false, loadingOlder: false, newOperation: null, installPrompt: null
};
notificationPreferences = new NotificationPreferences({ request, language,
  env: { navigator, Notification: window.Notification, PushManager: window.PushManager,
    isSecureContext: secure, matchMedia: window.matchMedia.bind(window), desktop: notificationDesktop },
  onChange: () => renderNotificationSettings()
});
function renderNotificationSettings() {
  const status = notificationPreferences.state;
  $('notification-settings').hidden = $('open-notifications').hidden = notificationDesktop;
  $('open-notifications').classList.toggle('enabled', status.enabled);
  const keys = { https: 'notificationsHTTPS', install: 'notificationsInstall', unsupported: 'notificationsUnsupported',
    blocked: 'notificationsBlocked', update: 'notificationsUpdate', unavailable: 'notificationsUnavailable',
    enabled: 'notificationsEnabled', disabled: 'notificationsDisabled', sent: 'notificationsTestSent' };
  $('notification-status').textContent = t(status.busy || status.reason === 'loading' ? 'notificationsWorking' : keys[status.reason] || 'notificationsUnavailable');
  showError('notification-error', status.error ? t(status.error.key || 'notificationsUnavailable') : '');
  $('notification-enable').hidden = !status.available || status.enabled || status.reason === 'blocked';
  $('notification-disable').hidden = !status.enabled && status.error?.key !== 'notificationsUnsubscribeFailed';
  $('notification-test').hidden = !status.enabled;
  $('notification-install').hidden = status.reason !== 'install';
  for (const id of ['notification-enable', 'notification-disable', 'notification-test']) $(id).disabled = status.busy;
}
function openNotifications() {
  if (notificationDesktop) return;
  drawer(false); $('notification-dialog').showModal(); notificationPreferences.refresh();
}
$('notification-settings').onclick = $('open-notifications').onclick = openNotifications;
$('close-notifications').onclick = () => $('notification-dialog').close();
$('notification-enable').onclick = () => notificationPreferences.enable().catch(() => {});
$('notification-disable').onclick = () => notificationPreferences.disable().catch(() => {});
$('notification-test').onclick = () => notificationPreferences.test().catch(() => {});
$('notification-install').onclick = () => { $('notification-dialog').close(); $('install-dialog').showModal(); };
renderNotificationSettings();
function clearNotificationSubscription() {
  const session = state.sessionGeneration;
  notificationCleanup = Promise.all([notificationCleanup.catch(() => {}), notificationPreferences.disconnect()]).catch(() => {
    if (!state.authenticated && state.sessionGeneration === session) showError('pair-error', t('notificationsUnsubscribeFailed'));
  });
}
// Notification clicks only select an authorized existing chat. They never submit
// a prompt, retry a pending operation, or discard an in-memory draft.
async function openPendingNotification() {
  if (!state.authenticated || pendingNotification === undefined) return;
  const target = pendingNotification; pendingNotification = undefined; notificationNavigationError = '';
  if (target.chatId === null) {
    rememberDraft(); closePhoto(); state.selected = null; state.selection++;
    state.rendering = ''; state.questionRendering = '';
    $('messages').replaceChildren(); $('questions').replaceChildren(); $('draft').value = '';
    $('chat-area').hidden = true; $('welcome').hidden = false; renderWorkspaces(); return;
  }
  const chat = state.workspaces.flatMap(workspace => workspace.conversations).find(item => item.id.toLowerCase() === target.chatId.toLowerCase());
  if (chat) { if (state.selected !== chat.id) await selectChat(chat.id); }
  else { notificationNavigationError = 'notificationChatUnavailable'; showError('global-error', t(notificationNavigationError)); }
}
if (!notificationDesktop && navigator.serviceWorker) navigator.serviceWorker.addEventListener('message', event => {
  const message = notificationMessage(event, location.origin); if (!message) return;
  event.ports?.[0]?.postMessage({ id: message.id, accepted: true });
  if (receivedNotifications.has(message.id)) return;
  receivedNotifications.add(message.id);
  if (receivedNotifications.size > 256) receivedNotifications.delete(receivedNotifications.values().next().value);
  pendingNotification = message;
  if (state.authenticated) poll();
});
const liveURL = new URL('/api/events', location.href); liveURL.protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
const live = new LiveUpdates({ url: liveURL.href,
  onHello: data => { updateBootID(data.bootID); applyAccess(data.access); },
  onChanged: () => poll(),
  onRevoked: () => pairScreen(t('authExpired')),
  onState: ready => {
    const changed = state.live !== ready; state.live = ready; connected(state.connected);
    // Failed handshakes must not keep postponing the independent fallback timer.
    if (ready || changed || !state.pollTimer) schedulePoll();
  }
});
document.querySelectorAll('.language-select').forEach(select => {
  for (const [value, name] of Object.entries(supportedLanguages)) {
    const option = document.createElement('option'); option.value = value; option.textContent = name; select.append(option);
  }
  select.value = language();
  select.onchange = () => {
    setLanguage(select.value); translatePage();
    notificationPreferences.syncLanguage().catch(() => {});
    state.rendering = ''; state.questionRendering = '';
    renderWorkspaces(); renderAccess(); connected(state.connected);
    if (state.selected) renderChat();
    if ($('new-dialog').open && !state.newOperation) {
      const fresh = [...$('new-workspace').options].find(option => !option.value);
      if (fresh) fresh.textContent = t('newWorkspace');
    }
    if (state.newOperation) $('create-chat').textContent = t('retry');
  };
});
function applyAccess(value) {
  const next = { workspaceId: typeof value?.workspaceId === 'string' ? value.workspaceId : null, writable: value?.writable !== false };
  const scopeChanged = next.workspaceId !== state.access.workspaceId;
  if (scopeChanged) {
    const allowed = new Set(state.workspaces.filter(w => !next.workspaceId || w.id === next.workspaceId).flatMap(w => w.conversations.map(c => c.id)));
    for (const key of ['chats', 'drafts', 'imageDrafts', 'fileDrafts', 'models', 'efforts', 'scroll', 'errors', 'pending']) {
      for (const id of state[key].keys()) if (!allowed.has(id)) state[key].delete(id);
    }
    for (const key of ['answerDrafts', 'progress']) {
      for (const id of state[key].keys()) if (![...allowed].some(chat => id.startsWith(`${chat}:`))) state[key].delete(id);
    }
    for (const id of state.modelNotices) if (!allowed.has(id)) state.modelNotices.delete(id);
    state.workspaces = state.workspaces.filter(w => !next.workspaceId || w.id === next.workspaceId);
    if (state.selected && !allowed.has(state.selected)) {
      state.selected = null; state.selection++; state.rendering = ''; state.questionRendering = '';
      $('messages').replaceChildren(); $('questions').replaceChildren(); $('draft').value = '';
      $('chat-area').hidden = true; $('welcome').hidden = false;
    }
  }
  if (!next.writable || scopeChanged) {
    state.pending.clear(); state.newOperation = null;
    closePhoto();
    if ($('new-dialog').open) $('new-dialog').close();
  }
  state.access = next; renderAccess(); updateComposer();
}
function renderAccess() {
  const name = state.workspaces.find(w => w.id === state.access.workspaceId)?.name;
  const scope = state.access.workspaceId ? `${t('scopedWorkspace')}${name ? `: ${name}` : ''}` : t('allWorkspaces');
  $('access-summary').textContent = `${t(state.access.writable ? 'writable' : 'readOnly')} · ${scope}`;
  $('new-chat').hidden = $('welcome-new').hidden = !state.access.writable;
  $('welcome').querySelector('p').textContent = t(state.access.writable ? 'welcomeDetail' : 'readOnlyWelcome');
}
if (scannedToken) $('pair-token').value = scannedToken;

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}
function showError(id, message) { $(id).textContent = message || ''; $(id).hidden = !message; }
function describe(error) { return error.status === 0 ? t('networkError') : error.message; }
function connected(value) {
  state.connected = value;
  $('connection').textContent = t(value ? state.live ? 'live' : 'polling' : 'offline');
  $('connection').classList.toggle('disconnected', !value);
  updateComposer();
}
function drawer(open) {
  $('sidebar').classList.toggle('open', open); $('drawer-shade').hidden = !open;
  if (open) $('close-sidebar').focus();
}
$('open-sidebar').onclick = () => drawer(true);
$('close-sidebar').onclick = () => drawer(false);
$('drawer-shade').onclick = () => drawer(false);
document.addEventListener('keydown', event => { if (event.key === 'Escape') drawer(false); });

function pairScreen(error = '') {
  cancelSessionRecovery(); cancelPairing(); live.stop(); state.sessionGeneration++; state.refreshQueued = false;
  state.authenticated = false; state.connected = false; notificationNavigationError = '';
  if ($('notification-dialog').open) $('notification-dialog').close();
  clearNotificationSubscription();
  clearTimeout(state.pollTimer);
  state.selection++; state.selected = null; state.workspaces = [];
  for (const key of ['chats', 'drafts', 'imageDrafts', 'fileDrafts', 'models', 'efforts', 'scroll', 'progress', 'errors', 'answerDrafts', 'pending']) state[key].clear();
  state.imageLoading.clear(); closePhoto(); $('photo-previews').replaceChildren(); $('photo-files').value = ''; $('file-previews').replaceChildren();
  state.modelNotices.clear(); state.rendering = ''; state.questionRendering = ''; state.newOperation = null;
  $('messages').replaceChildren(); $('questions').replaceChildren(); $('workspace-list').replaceChildren(); $('draft').value = '';
  if ($('new-dialog').open) $('new-dialog').close();
  $('application').hidden = true; $('pair-screen').hidden = false;
  showError('pair-error', error);
}
function updateBootID(bootID) {
  if (!bootID) return;
  if (state.bootID && state.bootID !== bootID) {
    // Keep local drafts and immutable pending request IDs, but refetch history.
    state.chats.clear(); state.rendering = ''; state.questionRendering = '';
    $('messages').replaceChildren(); closePhoto();
  }
  state.bootID = bootID;
}
function cancelSessionRecovery() {
  clearTimeout(state.recoveryTimer); state.sessionProbe = null;
}
async function recoverSession() {
  clearTimeout(state.recoveryTimer);
  if (!connectionAllowed || state.suspended || state.authenticated || state.sessionProbe || state.pairingAttempt) return;
  const probe = Symbol(); state.sessionProbe = probe;
  let retry = false;
  try {
    if (!navigator.onLine) throw new APIError('connection');
    const data = await request('/api/session');
    if (state.sessionProbe !== probe) return;
    await startSession(data);
  } catch (error) {
    if (state.sessionProbe !== probe) return;
    if (error.status === 401) { showError('pair-error', ''); clearNotificationSubscription(); }
    else if (error.status === 403) { pairScreen(error.message); }
    else {
      showError('pair-error', describe(error));
      retry = !error.status || error.status >= 500;
    }
  } finally {
    if (state.sessionProbe === probe) {
      state.sessionProbe = null;
      if (retry) state.recoveryTimer = setTimeout(recoverSession, document.hidden ? 15000 : 5000);
    }
  }
}
async function startSession(data) {
  cancelSessionRecovery();
  state.sessionGeneration++; state.imageLoading.clear(); state.authenticated = true; updateBootID(data.bootID); applyAccess(data.access);
  $('pair-token').value = '';
  $('pair-screen').hidden = true; $('application').hidden = false;
  $('device-label').textContent = data.deviceName || '';
  connected(true); await poll(); if (state.authenticated && !state.suspended) live.start();
  const session = state.sessionGeneration;
  notificationCleanup.then(() => { if (state.authenticated && session === state.sessionGeneration) return notificationPreferences.connect(); }).catch(() => {});
}
function pairingUI(active) {
  $('pair-form').hidden = active;
  $('pair-status').hidden = !active;
  $('pair-submit').disabled = active || !connectionAllowed;
}
function cancelPairing() {
  const attempt = state.pairingAttempt; state.pairingAttempt = null;
  attempt?.controller.abort(); pairingUI(false);
}
async function pair() {
  if (state.pairingAttempt || state.suspended) return;
  if (!connectionAllowed) { pairingUI(false); showError('pair-error', t('secureRequired')); return; }
  if (!navigator.onLine) { pairingUI(false); showError('pair-error', t('networkError')); return; }
  const token = $('pair-token').value.trim();
  if (!token) { pairingUI(false); return; }
  cancelSessionRecovery();
  const attempt = { token, controller: new AbortController() }; state.pairingAttempt = attempt;
  pairingUI(true); showError('pair-error', '');
  try {
    const data = await request('/api/pair', { signal: attempt.controller.signal,
      body: { token, deviceName: $('device-name').value.trim() || t('deviceMobile') } });
    if (state.pairingAttempt !== attempt || state.suspended) return;
    await startSession(data);
  } catch (error) {
    if (state.pairingAttempt === attempt && !state.suspended) showError('pair-error', describe(error));
  } finally {
    if (state.pairingAttempt === attempt) { state.pairingAttempt = null; pairingUI(false); }
  }
}
$('pair-form').onsubmit = event => { event.preventDefault(); pair(); };
window.addEventListener('hashchange', () => {
  const token = readPairToken(location, history);
  if (!token || state.pairingAttempt?.token === token) return;
  // Scanning into an existing tab is a same-document navigation. A fresh grant
  // must not leave content from the previous grant visible while it connects.
  pairScreen(); $('pair-token').value = token; pair();
});
$('logout').onclick = async () => {
  $('logout').disabled = true;
  try { await request('/api/logout', { body: {} }); pairScreen(); }
  catch { showError('global-error', t('logoutFailed')); }
  finally { $('logout').disabled = false; }
};

function renderWorkspaces() {
  const fragment = document.createDocumentFragment();
  if (!state.workspaces.length) fragment.append(el('p', 'empty-workspace', t(state.access.writable ? 'emptyList' : 'emptyReadOnly')));
  for (const workspace of state.workspaces) {
    const section = el('section', 'workspace');
    section.append(el('div', 'workspace-name', workspace.name));
    for (const chat of workspace.conversations) {
      const button = el('button', 'conversation'); button.type = 'button';
      button.setAttribute('aria-current', String(state.selected === chat.id));
      button.append(el('span', `status-dot ${['running', 'needsInput'].includes(chat.status) ? chat.status : ''}`), el('span', 'title', chat.title || t('newChat')));
      button.title = `${chat.title || ''} · ${t(chat.status)}`;
      button.onclick = () => selectChat(chat.id);
      section.append(button);
    }
    if (!workspace.conversations.length) section.append(el('p', 'empty-workspace', t('emptyWorkspace')));
    fragment.append(section);
  }
  const position = $('workspace-list').scrollTop;
  $('workspace-list').replaceChildren(fragment); $('workspace-list').scrollTop = position;
  updateHeader(); renderAccess();
}
function chatSummary(id = state.selected) { return state.workspaces.flatMap(w => w.conversations).find(c => c.id === id); }
function updateHeader() {
  const summary = chatSummary(); const chat = state.chats.get(state.selected);
  $('chat-title').textContent = summary?.title || t('chooseChat');
  $('chat-subtitle').textContent = state.selected ? `${(chat?.provider || summary?.provider) === 'openai' ? 'Codex' : 'Claude Code'} · ${t(chat?.isBusy ? 'running' : summary?.status || 'idle')}` : '';
  $('directory').textContent = chat?.directory || summary?.directory || '';
  $('directory').title = $('directory').textContent;
}
function rememberDraft() {
  if (!state.selected) return;
  state.drafts.set(state.selected, $('draft').value);
  state.scroll.set(state.selected, { top: $('transcript').scrollTop, bottom: atBottom() });
}
async function selectChat(id) {
  notificationNavigationError = ''; showError('global-error', '');
  rememberDraft(); closePhoto(); state.selected = id; const selection = ++state.selection; const hadCached = state.chats.has(id);
  state.rendering = ''; state.questionRendering = ''; state.loadingOlder = false;
  $('welcome').hidden = true; $('chat-area').hidden = false;
  $('messages').replaceChildren(); $('questions').replaceChildren(); showError('chat-error', ''); showError('photo-error', '');
  $('draft').value = state.drafts.get(id) || ''; resizeDraft(); drawer(false); renderWorkspaces();
  renderChat(true); updateComposer();
  try {
    const data = await request(chatPath(id, '?limit=100'));
    if (selection !== state.selection || !state.authenticated) return;
    updateBootID(data.bootID); applyAccess(data.access);
    if (selection !== state.selection) return;
    state.chats.set(id, mergePage(state.chats.get(id), data)); connected(true); renderChat(!hadCached);
  } catch (error) { if (selection === state.selection) handleReadError(error, 'chat-error'); }
}
function handleReadError(error, target = 'global-error') {
  if ([401, 403].includes(error.status)) { pairScreen(error.status === 403 ? error.message : t('authExpired')); return; }
  connected(false); showError(target, describe(error));
}
async function poll() {
  clearTimeout(state.pollTimer);
  if (!state.authenticated || state.suspended) return;
  if (state.polling) { state.refreshQueued = true; return; }
  if (!navigator.onLine) { connected(false); showError('global-error', t('networkError')); schedulePoll(); return; }
  state.polling = true; const session = state.sessionGeneration;
  try {
    const result = await request('/api/workspaces');
    if (!state.authenticated || session !== state.sessionGeneration) return;
    updateBootID(result.bootID); applyAccess(result.access);
    state.workspaces = result.workspaces.filter(w => !state.access.workspaceId || state.access.workspaceId === w.id);
    if (state.selected && !chatSummary()) {
      state.chats.delete(state.selected); state.drafts.delete(state.selected); state.imageDrafts.delete(state.selected); state.fileDrafts.delete(state.selected); closePhoto(); state.selected = null; state.selection++;
      $('messages').replaceChildren(); $('questions').replaceChildren(); $('draft').value = '';
      $('chat-area').hidden = true; $('welcome').hidden = false;
    }
    renderWorkspaces();
    const id = state.selected; const selection = state.selection;
    if (id && !state.loadingOlder) {
      const chat = await request(chatPath(id, '?limit=100'));
      if (selection === state.selection && state.authenticated && session === state.sessionGeneration) {
        updateBootID(chat.bootID); applyAccess(chat.access);
        if (selection !== state.selection) return;
        state.chats.set(id, mergePage(state.chats.get(id), chat)); renderChat();
      }
    }
    connected(true); showError('global-error', notificationNavigationError ? t(notificationNavigationError) : '');
    await openPendingNotification();
  } catch (error) { if (session === state.sessionGeneration) handleReadError(error); }
  finally {
    state.polling = false;
    if (state.refreshQueued && state.authenticated) { state.refreshQueued = false; queueMicrotask(poll); }
    else schedulePoll();
  }
}
function schedulePoll() {
  clearTimeout(state.pollTimer);
  if (state.authenticated && !state.suspended && !state.live) state.pollTimer = setTimeout(poll, document.hidden ? 15000 : state.chats.get(state.selected)?.isBusy ? 1000 : 5000);
}
window.addEventListener('offline', () => { live.suspend(); connected(false); showError('global-error', t('networkError')); });
function reconnect() { state.suspended = false; if (state.authenticated) { live.resume(); poll(); } else recoverSession(); }
window.addEventListener('online', reconnect);
document.addEventListener('visibilitychange', () => { if (!document.hidden) reconnect(); });
window.addEventListener('pagehide', () => { state.suspended = true; live.stop(); cancelSessionRecovery(); cancelPairing(); clearTimeout(state.pollTimer); state.sessionGeneration++; state.imageLoading.clear(); });
window.addEventListener('pageshow', event => { if (event.persisted) { state.suspended = false; if (state.authenticated && !state.suspended) live.start(); reconnect(); } });

function atBottom() { const node = $('transcript'); return node.scrollHeight - node.scrollTop - node.clientHeight < 70; }
function jumpBottom(behavior = 'auto') { $('transcript').scrollTo({ top: $('transcript').scrollHeight, behavior }); updateJump(); }
function updateJump() { $('jump-bottom').hidden = atBottom(); }
$('transcript').addEventListener('scroll', updateJump, { passive: true });
$('jump-bottom').onclick = () => jumpBottom(matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth');
// iOS keyboards shrink the visual viewport rather than the layout viewport.
// Keep the composer visible without moving the user's reading position.
function fitViewport() {
  const wasAtBottom = atBottom();
  document.documentElement.style.setProperty('--viewport-height', `${window.visualViewport?.height || innerHeight}px`);
  if (wasAtBottom && state.selected) requestAnimationFrame(() => jumpBottom());
  else updateJump();
}
window.visualViewport?.addEventListener('resize', fitViewport);
window.addEventListener('resize', fitViewport);
fitViewport();
new ResizeObserver(() => {
  $('jump-bottom').style.bottom = `${$('composer').offsetHeight + 14}px`;
  updateJump();
}).observe($('composer'));
function readingAnchor() {
  const top = $('transcript').getBoundingClientRect().top;
  const node = [...$('messages').querySelectorAll('[data-message-id]')].find(n => n.getBoundingClientRect().bottom >= top);
  return node ? { id: node.dataset.messageId, offset: node.getBoundingClientRect().top - top } : null;
}
function restoreAnchor(anchor, fallback) {
  const node = anchor && [...$('messages').querySelectorAll('[data-message-id]')].find(n => n.dataset.messageId === anchor.id);
  if (node) $('transcript').scrollTop += node.getBoundingClientRect().top - $('transcript').getBoundingClientRect().top - anchor.offset;
  else $('transcript').scrollTop = fallback;
}
function appendText(parent, text) {
  // Safe lightweight formatting: code fences and clickable http(s) URLs; never parse HTML.
  const pieces = String(text || '').split(/(```[^\n]*\n[\s\S]*?(?:```|$))/g);
  for (const piece of pieces) {
    if (piece.startsWith('```')) {
      const code = piece.replace(/^```[^\n]*\n/, '').replace(/```$/, ''); parent.append(el('pre', '', code));
    } else {
      for (const part of piece.split(/(https?:\/\/[^\s<>]+)/g)) {
        const link = /^https?:/.test(part) && safeLink(part);
        if (link) { const a = el('a', '', part); a.href = link; a.target = '_blank'; a.rel = 'noopener noreferrer'; parent.append(a); }
        else parent.append(document.createTextNode(part));
      }
    }
  }
}
function messageNode(message, provider, chatID, previousNodes) {
  const signature = JSON.stringify([message, provider, chatID, language()]);
  const previous = previousNodes.get(message.id);
  if (previous?.dataset.renderSignature === signature) return previous;
  const node = el('article', `message ${message.role === 'user' ? 'user' : ''} ${message.isError ? 'error' : ''}`);
  node.dataset.messageId = message.id;
  node.dataset.renderSignature = signature;
  node.append(el('div', 'author', message.role === 'user' ? t('you') : provider === 'openai' ? 'Codex' : 'Claude Code'));
  const body = el('div', 'message-body'); appendText(body, message.text); node.append(body);
  if (message.images?.length) {
    const images = el('div', 'message-photos');
    for (const photo of message.images) {
      const source = imagePath(chatID, photo.id); if (!source) continue;
      const button = photoButton(source, photo.name || t('photosPreview'));
      images.append(button);
    }
    node.append(images);
  }
  if (message.files?.length) {
    const files = el('div', 'message-files');
    for (const file of message.files) {
      const source = filePath(chatID, file.id); if (!source) continue;
      const link = el('a', 'file-chip file-download'); link.href = source; link.download = safeDownloadName(file.name);
      link.append(el('span', 'file-symbol', '↧'), el('span', 'file-name', file.name), el('span', 'file-size', fileSize(file.byteCount, language())));
      link.ariaLabel = `${t('filesDownload')}: ${file.name}`; files.append(link);
    }
    node.append(files);
  }
  if (message.role === 'user' && message.isSteering === true && message.isError === true) {
    const status = el('p', 'steer-status small error', t('steerNotApplied'));
    status.setAttribute('role', 'status'); node.append(status);
  }
  const timing = turnTiming(message, language());
  if (timing) {
    const footer = el('div', 'message-timing');
    const at = el('time', '', `${t(timing.status === 'failed' ? 'turnFailedAt' : timing.status === 'interrupted' ? 'turnInterruptedAt' : 'turnCompletedAt')} ${timing.time}`);
    at.dateTime = timing.iso;
    footer.append(at, el('span', '', `${t('turnDuration')} ${timing.duration}`));
    if (typeof message.reasoningEffort === 'string' && /^[a-z]{1,32}$/.test(message.reasoningEffort)) {
      footer.append(el('span', '', `${t(message.reasoningEffortVerified === true ? 'effortConfirmed' : 'effortRequested')}: ${message.reasoningEffort}`));
    }
    node.append(footer);
  }
  return node;
}
function renderChat(initial = false) {
  const data = state.chats.get(state.selected); updateHeader();
  if (!data) { $('messages').replaceChildren(el('p', 'muted small', t('loading'))); updateComposer(); return; }
  const signature = JSON.stringify([data.messages, data.provider, language(), state.access.writable]);
  const nearBottom = atBottom(); const anchor = readingAnchor(); const oldTop = $('transcript').scrollTop;
  if (signature !== state.rendering) {
    state.rendering = signature;
    // Reuse unchanged message nodes so streaming text does not download every
    // authenticated photo again. Only the currently authorized DOM is reused.
    const previousNodes = new Map([...$('messages').querySelectorAll('[data-message-id]')].map(node => [node.dataset.messageId, node]));
    const fragment = document.createDocumentFragment();
    if (!data.messages.length) fragment.append(el('p', 'muted small', t(state.access.writable ? 'noMessages' : 'readOnlyMessages')));
    for (const turn of turns(data.messages)) {
      const section = el('section', 'turn');
      if (turn.user) section.append(messageNode(turn.user, data.provider, data.id, previousNodes));
      if (turn.progress.length) {
        const key = `${data.id}:${turn.id}`; const hasAnswer = turn.answers.some(m => m.role === 'assistant' && m.text?.trim());
        const saved = state.progress.get(key);
        const open = hasAnswer && !saved?.finished ? false : saved?.open ?? !hasAnswer;
        const details = el('details', 'progress'); details.open = open;
        state.progress.set(key, { open, finished: hasAnswer });
        details.append(el('summary', '', `${t('thinking')} · ${turn.progress.length} ${t('updates')}`));
        for (const message of turn.progress) details.append(messageNode(message, data.provider, data.id, previousNodes));
        details.addEventListener('toggle', () => { if (details.isConnected) state.progress.set(key, { open: details.open, finished: hasAnswer }); updateJump(); });
        section.append(details);
      }
      for (const message of turn.answers) section.append(messageNode(message, data.provider, data.id, previousNodes));
      fragment.append(section);
    }
    $('messages').replaceChildren(fragment);
  }
  $('load-older').hidden = data.start <= 0; $('load-older').disabled = state.loadingOlder;
  $('thinking-indicator').hidden = !data.isBusy;
  showError('chat-error', state.errors.get(data.id) || data.error || '');
  renderQuestions(data); updateComposer();
  if (initial) {
    const saved = state.scroll.get(data.id);
    if (!saved || saved.bottom) jumpBottom(); else $('transcript').scrollTop = saved.top;
  } else if (nearBottom) jumpBottom(); else restoreAnchor(anchor, oldTop);
  updateJump();
}
$('load-older').onclick = async () => {
  const data = state.chats.get(state.selected); if (!data || state.loadingOlder || data.start <= 0) return;
  const selection = state.selection; state.loadingOlder = true; $('load-older').disabled = true;
  const oldHeight = $('transcript').scrollHeight; const oldTop = $('transcript').scrollTop;
  try {
    const older = await request(chatPath(data.id, `?before=${data.start + 1}&limit=100`));
    if (selection !== state.selection || !state.authenticated) return;
    applyAccess(older.access); if (selection !== state.selection) return;
    if (older.bootID && older.bootID !== state.bootID) {
      updateBootID(older.bootID); await selectChat(data.id); return;
    }
    // Prefer current metadata while expanding the older transcript.
    const current = state.chats.get(data.id);
    const merged = mergePage(older, current);
    state.chats.set(data.id, merged); renderChat();
    $('transcript').scrollTop = oldTop + $('transcript').scrollHeight - oldHeight;
  } catch (error) { if (selection === state.selection) handleReadError(error, 'chat-error'); }
  finally { if (selection === state.selection) { state.loadingOlder = false; $('load-older').disabled = false; updateJump(); if (state.live) poll(); } }
};

function renderQuestions(data) {
  const signature = JSON.stringify([data.id, data.questions || [], language(), state.access.writable]);
  if (signature === state.questionRendering) return;
  state.questionRendering = signature; $('questions').replaceChildren();
  for (const group of data.questions || []) {
    const form = el('form', 'question-card'); form.append(el('h3', '', group.title || t('needsInput')));
    const fields = [];
    for (const question of group.questions) {
      const field = el('fieldset'); field.append(el('legend', '', question.prompt));
      const inputs = [];
      for (const [index, option] of question.options.entries()) {
        const label = el('label', 'question-option'); const input = el('input'); input.type = question.multiple ? 'checkbox' : 'radio';
        input.name = question.id; input.value = option; input.id = `question-${group.id}-${question.id}-${index}`;
        label.append(input, document.createTextNode(option)); field.append(label); inputs.push(input);
      }
      const free = el('input'); free.type = question.secret ? 'password' : 'text'; free.placeholder = t('otherAnswer');
      free.autocomplete = 'off'; free.ariaLabel = question.prompt; field.append(free); form.append(field);
      const draftKey = `${data.id}:${group.id}:${question.id}`;
      const saved = state.answerDrafts.get(draftKey);
      if (saved) { for (const input of inputs) input.checked = saved.checked.includes(input.value); free.value = saved.free; }
      field.oninput = () => state.answerDrafts.set(draftKey, { checked: inputs.filter(input => input.checked).map(input => input.value), free: free.value });
      fields.push({ question, inputs, free });
    }
    const error = el('p', 'error small'); error.hidden = true;
    const submit = el('button', 'primary', t('submitAnswer')); submit.type = 'submit'; form.append(error, submit);
    form.onsubmit = async event => {
      event.preventDefault();
      const answers = {};
      for (const { question, inputs, free } of fields) {
        const checked = inputs.filter(i => i.checked).map(i => i.value);
        answers[question.id] = free.value.trim() ? question.multiple ? [...checked, free.value.trim()] : [free.value.trim()] : checked;
        if (!answers[question.id].length) { error.hidden = false; error.textContent = t('requiredAnswer'); return; }
      }
      error.hidden = true;
      if (!canMutate(data.id)) return;
      await runOperation(data.id, { kind: 'answer', request: operation(chatPath(data.id, '/answer'), { bootID: state.bootID, questionId: group.id, answers, allow: true }) });
    };
    $('questions').append(form);
  }
}
function updateComposer() {
  const data = state.chats.get(state.selected); const pending = state.pending.get(state.selected);
  const available = state.connected && navigator.onLine && state.authenticated;
  const writable = state.access.writable && available && (data?.isReady || data?.canResume) && !pending;
  const steering = !!data?.isBusy;
  $('composer').classList.toggle('steering', steering);
  $('send').dataset.i18n = steering ? 'steer' : 'send';
  $('send').textContent = t(steering ? 'steer' : 'send');
  $('send').title = steering ? t('steerHelp') : '';
  $('draft').dataset.i18nPlaceholder = steering ? 'steerPlaceholder' : 'messagePlaceholder';
  $('draft').placeholder = t($('draft').dataset.i18nPlaceholder);
  $('stop').textContent = '■'; $('stop').ariaLabel = t('stop'); $('stop').title = t('stop');
  $('send').disabled = (state.fileDrafts.get(state.selected) || []).some(file => file.unavailable || typeof file.data !== 'string') || !writable || (steering && (!data?.canSteer || !data?.steerToken)) || state.imageLoading.has(state.selected) || (! $('draft').value.trim() && !(state.imageDrafts.get(state.selected)?.length) && !(state.fileDrafts.get(state.selected)?.length));
  $('add-photos').disabled = !data || !state.access.writable || !!pending || state.imageLoading.has(state.selected);
  $('photo-loading').hidden = !state.imageLoading.has(state.selected);
  renderPhotoDrafts(); renderFileDrafts();
  $('composer').hidden = !state.access.writable; $('questions').hidden = !state.access.writable;
  $('send').hidden = !state.access.writable;
  $('stop').hidden = !state.access.writable || !data?.isBusy; $('stop').disabled = !available || !data?.canInterrupt || !!pending;
  $('setup-notice').hidden = !data || data.isReady || data.canResume;
  $('draft').disabled = !data; // Offline drafts remain editable, but can never be submitted/queued.
  $('model').hidden = !state.access.writable; $('model').disabled = !state.access.writable || !data || !!pending;
  $('model-notice').hidden = !state.modelNotices.has(state.selected);
  const options = [{ id: '', title: t('defaultModel') }, ...(data?.models || []).filter(model => model.id !== '')];
  if (data?.model && !options.some(m => m.id === data.model)) options.push({ id: data.model, title: data.model });
  const selected = state.models.has(state.selected) ? state.models.get(state.selected) : data?.model || '';
  if (selected && !options.some(m => m.id === selected)) options.push({ id: selected, title: selected });
  if ($('model').dataset.options !== JSON.stringify(options)) {
    $('model').replaceChildren(...options.map(item => { const opt = el('option', '', item.title); opt.value = item.id; return opt; }));
    $('model').dataset.options = JSON.stringify(options);
  }
  $('model').value = selected;
  const efforts = reasoningOptions(data, selected);
  const effort = state.efforts.get(state.selected) ?? data?.reasoningEffort ?? '';
  $('effort').hidden = !state.access.writable; $('effort').disabled = !data || !!pending || !efforts.length;
  const effortOptions = [{ id: '', title: t('defaultEffort') }, ...efforts.map(id => ({ id, title: t('effort_' + id) === 'effort_' + id ? id : t('effort_' + id) }))];
  if (effort && !efforts.includes(effort)) effortOptions.push({ id: effort, title: effort, disabled: true });
  if ($('effort').dataset.options !== JSON.stringify(effortOptions)) {
    $('effort').replaceChildren(...effortOptions.map(item => { const option = el('option', '', item.title); option.value = item.id; option.disabled = !!item.disabled; return option; }));
    $('effort').dataset.options = JSON.stringify(effortOptions);
  }
  $('effort').value = effort; $('effort').title = t(efforts.length ? 'reasoningEffort' : 'effortUnavailable');
  $('mutation-error').hidden = !pending?.error;
  $('mutation-error').firstElementChild.textContent = pending?.error || '';
  $('retry-operation').hidden = !pending?.uncertain;
  $('discard-operation').hidden = !pending?.uncertain;
  $('discard-operation').disabled = !!pending?.running;
  $('retry-operation').disabled = !available || pending?.running;
  $('questions').querySelectorAll('button, input').forEach(node => { node.disabled = !available || !!pending; });
}
function closePhoto() {
  if ($('photo-dialog').open) $('photo-dialog').close();
  $('photo-full').removeAttribute('src');
}
$('close-photo').onclick = closePhoto;
$('photo-dialog').addEventListener('close', () => $('photo-full').removeAttribute('src'));
function photoButton(source, name) {
  const button = el('button', 'photo-open'); button.type = 'button'; button.ariaLabel = `${t('photosPreview')}: ${name}`;
  const image = el('img'); image.src = source; image.alt = name; image.loading = 'lazy'; image.decoding = 'async';
  image.onerror = () => { image.hidden = true; button.classList.add('photo-unavailable'); button.textContent = t('photosUnavailable'); button.disabled = true; };
  button.append(image); button.onclick = () => { $('photo-full').src = source; $('photo-full').alt = name; $('photo-dialog').showModal(); };
  return button;
}
function renderPhotoDrafts() {
  const id = state.selected, photos = state.imageDrafts.get(id) || [], pending = state.pending.has(id);
  const signature = JSON.stringify([id, photos.map(photo => photo.id), pending, language()]);
  if ($('photo-previews').dataset.signature === signature) return;
  $('photo-previews').dataset.signature = signature;
  $('photo-previews').replaceChildren();
  for (const photo of photos) {
    const item = el('div', 'photo-draft');
    item.append(photoButton(photo.preview, photo.name));
    const remove = el('button', 'photo-remove', '×'); remove.type = 'button'; remove.ariaLabel = `${t('photosRemove')}: ${photo.name}`; remove.disabled = pending;
    remove.onclick = () => { if (!state.pending.has(id)) { state.imageDrafts.set(id, (state.imageDrafts.get(id) || []).filter(value => value.id !== photo.id)); updateComposer(); } };
    item.append(remove); $('photo-previews').append(item);
  }
  $('photo-previews').hidden = photos.length === 0;
}
function safeDownloadName(name) { return String(name || 'attachment').split(/[\\/]/).pop().replace(/[\x00-\x1f\x7f]/g, ''); }
function renderFileDrafts() {
  const id = state.selected, files = state.fileDrafts.get(id) || [], pending = state.pending.has(id);
  const signature = JSON.stringify([id, files.map(file => [file.id, file.name, file.byteCount]), pending, language()]);
  const container = $('file-previews'); if (container.dataset.signature === signature) return;
  container.dataset.signature = signature; container.replaceChildren(); container.hidden = !files.length;
  for (const file of files) {
    const item = el('div', 'file-chip'); item.append(el('span', 'file-symbol', '▤'), el('span', 'file-name', file.name), el('span', 'file-size', fileSize(file.byteCount, language())));
    const remove = el('button', 'file-remove', '×'); remove.type = 'button'; remove.disabled = pending;
    remove.ariaLabel = `${t('filesRemove')}: ${file.name}`;
    remove.onclick = () => { if (!state.pending.has(id)) { state.fileDrafts.set(id, (state.fileDrafts.get(id) || []).filter(value => value.id !== file.id)); updateComposer(); } };
    if (file.unavailable || typeof file.data !== 'string') { item.classList.add('file-unavailable'); item.append(el('span', 'file-size', t('filesMissing'))); }
    item.append(remove); container.append(item);
  }
}
$('add-photos').onclick = () => $('photo-files').click();
$('photo-files').onchange = () => { const files = Array.from($('photo-files').files || []); $('photo-files').value = ''; return importAttachments(files); };
const attachmentImports = new Set();
function importAttachments(files) {
  const task = prepareAttachments(files); attachmentImports.add(task);
  return task.finally(() => attachmentImports.delete(task));
}
async function prepareAttachments(files) {
  const id = state.selected, generation = state.sessionGeneration;
  if (!files.length || !id || !state.authenticated || !state.access.writable || state.pending.has(id) || state.imageLoading.has(id)) return;
  const stillAllowed = () => state.sessionGeneration === generation && state.authenticated && state.access.writable && !!chatSummary(id);
  try {
    const { images, documents } = splitAttachments(files);
    validatePhotoSelection(images, (state.imageDrafts.get(id) || []).length);
    validateFileSelection(documents, state.fileDrafts.get(id) || []);
    state.imageLoading.add(id); updateComposer(); showError('photo-error', '');
    const preparedImages = [], preparedFiles = [];
    for (const file of images) { preparedImages.push(await preparePhoto(file)); if (!stillAllowed()) return; }
    for (const file of documents) { preparedFiles.push(await prepareFile(file)); if (!stillAllowed()) return; }
    const currentImages = state.imageDrafts.get(id) || [], currentFiles = state.fileDrafts.get(id) || [];
    validatePhotoSelection([], currentImages.length + preparedImages.length);
    validateFileSelection([], [...currentFiles, ...preparedFiles]);
    // Commit the entire selection only after every attachment has been prepared.
    state.imageDrafts.set(id, [...currentImages, ...preparedImages]);
    state.fileDrafts.set(id, [...currentFiles, ...preparedFiles]);
  } catch (error) {
    if (stillAllowed() && state.selected === id) showError('photo-error', t(error instanceof PhotoError || error instanceof FileError ? error.key : 'filesUnavailable'));
  } finally {
    if (generation === state.sessionGeneration) { state.imageLoading.delete(id); updateComposer(); }
  }
}
let dragDepth = 0;
const draggingFiles = event => [...(event.dataTransfer?.types || [])].includes('Files');
document.addEventListener('dragenter', event => { if (draggingFiles(event)) { event.preventDefault(); dragDepth++; if (state.selected && state.access.writable) { document.body.dataset.dropLabel = t('filesDrop'); document.body.classList.add('attachment-drop-target'); } } });
document.addEventListener('dragover', event => { if (draggingFiles(event)) { event.preventDefault(); event.dataTransfer.dropEffect = state.access.writable ? 'copy' : 'none'; } });
document.addEventListener('dragleave', () => { if (--dragDepth <= 0) { dragDepth = 0; document.body.classList.remove('attachment-drop-target'); } });
document.addEventListener('drop', event => {
  if (!draggingFiles(event)) return; event.preventDefault(); dragDepth = 0; document.body.classList.remove('attachment-drop-target');
  if ([...(event.dataTransfer.items || [])].some(item => item.webkitGetAsEntry?.()?.isDirectory)) { showError('photo-error', t('filesFolders')); return; }
  importAttachments([...event.dataTransfer.files]);
});
$('draft').addEventListener('paste', event => {
  const files = [...(event.clipboardData?.items || [])].filter(item => item.kind === 'file').map(item => item.getAsFile()).filter(Boolean);
  if (files.length) { event.preventDefault(); importAttachments(files); }
});
function resizeDraft() { $('draft').style.height = 'auto'; $('draft').style.height = `${Math.min(180, $('draft').scrollHeight)}px`; }
$('draft').oninput = () => { state.drafts.set(state.selected, $('draft').value); resizeDraft(); updateComposer(); };
$('model').onchange = () => {
  if (!state.access.writable) return;
  const data = state.chats.get(state.selected), model = $('model').value;
  state.efforts.set(state.selected, selectedReasoningEffort(data, model, state.efforts.get(state.selected)));
  state.models.set(state.selected, model); state.modelNotices.add(state.selected); updateComposer();
};
$('effort').onchange = () => { if (!state.access.writable) return; state.efforts.set(state.selected, $('effort').value); updateComposer(); };
$('draft').onkeydown = event => {
  if (event.key === 'Enter' && (event.metaKey || event.ctrlKey) && !event.isComposing) { event.preventDefault(); $('composer').requestSubmit(); }
};
function canMutate(id) {
  if (!state.authenticated || !state.access.writable || !chatSummary(id)) return false;
  if (!navigator.onLine || !state.connected) { showError('global-error', t('networkError')); return false; }
  return !state.pending.has(id);
}
$('composer').onsubmit = async event => {
  event.preventDefault(); const id = state.selected; const data = state.chats.get(id); const text = $('draft').value;
  const photos = state.imageDrafts.get(id) || [], files = state.fileDrafts.get(id) || [];
  if (files.some(file => file.unavailable || typeof file.data !== 'string') || (!text.trim() && !photos.length && !files.length) || state.imageLoading.has(id) || !(data?.isReady || data?.canResume) || (data.isBusy && (!data.canSteer || !data.steerToken)) || !canMutate(id)) return;
  const model = state.models.has(id) ? state.models.get(id) : data.model;
  const kind = data.isBusy ? 'steer' : 'send';
  // A steer belongs to the running task. Model/effort choices remain for the
  // next ordinary turn, and a rejected steer is never retried as a new send.
  const settings = kind === 'send' ? { model: model || '', reasoningEffort: state.efforts.has(id) ? state.efforts.get(id) : data.reasoningEffort || '' } : { steerToken: data.steerToken };
  await runOperation(id, { kind, text, imageIDs: photos.map(photo => photo.id), fileIDs: files.map(file => file.id), request: operation(chatPath(id, '/' + kind), { bootID: state.bootID, text, images: freezePhotoSubmission(photos), files: freezeFileSubmission(files), ...settings }) });
};
$('stop').onclick = async () => {
  const id = state.selected;
  if (!state.chats.get(id)?.canInterrupt || !canMutate(id)) return;
  await runOperation(id, { kind: 'interrupt', request: operation(chatPath(id, '/interrupt'), { bootID: state.bootID }) });
};
$('retry-operation').onclick = () => { const pending = state.pending.get(state.selected); if (pending?.uncertain && !pending.running) runOperation(state.selected, pending); };
$('discard-operation').onclick = () => {
  const pending = state.pending.get(state.selected);
  if (pending?.uncertain && !pending.running) { state.pending.delete(state.selected); updateComposer(); }
};
async function runOperation(id, pending) {
  if (!state.access.writable || !state.authenticated || !chatSummary(id)) return;
  const session = state.sessionGeneration;
  state.errors.delete(id); state.pending.set(id, pending); pending.running = true; pending.error = ''; updateComposer();
  try {
    await request(pending.request.path, { body: pending.request.body, ...(pending.request.body.files?.length ? { timeoutMs: 180000 } : {}) });
    if (session !== state.sessionGeneration || state.pending.get(id) !== pending) return;
    state.pending.delete(id);
    if (pending.kind === 'send' || pending.kind === 'steer') {
      if (state.drafts.get(id) === pending.text) state.drafts.set(id, '');
      state.imageDrafts.set(id, removeSubmittedPhotos(state.imageDrafts.get(id) || [], pending.imageIDs || []));
      state.fileDrafts.set(id, removeSubmittedFiles(state.fileDrafts.get(id) || [], pending.fileIDs || []));
      if (pending.kind === 'send') state.modelNotices.delete(id);
      if (state.selected === id && $('draft').value === pending.text) { $('draft').value = ''; resizeDraft(); }
    }
    if (pending.kind === 'answer' && state.selected === id) { state.questionRendering = ''; $('questions').replaceChildren(); }
    await poll();
  } catch (error) {
    if (session !== state.sessionGeneration || state.pending.get(id) !== pending) return;
    if ([401, 403].includes(error.status)) { pairScreen(error.status === 403 ? error.message : t('authExpired')); return; }
    pending.uncertain = error instanceof APIError && error.uncertain;
    pending.error = pending.uncertain ? t('unknownResult') : describe(error);
    if (!pending.uncertain) {
      state.pending.delete(id); state.errors.set(id, pending.error);
      if (state.selected === id) showError('chat-error', pending.error);
    }
    if (!error.status) connected(false);
  } finally { pending.running = false; updateComposer(); }
}
function openNewChat() {
  if (!state.access.writable) return;
  if (!state.newOperation) {
    const select = $('new-workspace'); select.replaceChildren();
    if (!state.access.workspaceId) { const fresh = el('option', '', t('newWorkspace')); fresh.value = ''; select.append(fresh); }
    for (const workspace of state.workspaces) { const option = el('option', '', workspace.name); option.value = workspace.id; select.append(option); }
    const current = state.workspaces.find(w => w.conversations.some(c => c.id === state.selected));
    select.value = state.access.workspaceId || current?.id || ''; $('new-directory').value = state.chats.get(state.selected)?.directory || chatSummary()?.directory || '';
    $('new-provider').value = state.chats.get(state.selected)?.provider || chatSummary()?.provider || 'claude';
    showError('new-error', '');
  }
  $('new-dialog').showModal();
}
$('new-chat').onclick = openNewChat; $('welcome-new').onclick = openNewChat;
$('close-new').onclick = () => $('new-dialog').close();
$('new-workspace').onchange = () => {
  const workspace = state.workspaces.find(w => w.id === $('new-workspace').value);
  if (workspace?.conversations[0]?.directory) $('new-directory').value = workspace.conversations[0].directory;
};
$('discard-create').onclick = () => {
  state.newOperation = null; $('discard-create').hidden = true;
  for (const id of ['new-workspace', 'new-provider', 'new-directory']) $(id).disabled = false;
  $('create-chat').textContent = t('create'); showError('new-error', '');
};
$('new-form').onsubmit = async event => {
  event.preventDefault();
  if (!state.authenticated || !state.access.writable) return;
  if (state.access.workspaceId && $('new-workspace').value !== state.access.workspaceId) return;
  if (!navigator.onLine || !state.connected) { showError('new-error', t('networkError')); return; }
  if (!state.newOperation) {
    const directory = $('new-directory').value.trim();
    if (!directory.startsWith('/')) { showError('new-error', t('absoluteDirectory')); return; }
    state.newOperation = operation('/api/chats', { bootID: state.bootID, provider: $('new-provider').value, directory,
      ...($('new-workspace').value ? { workspaceId: $('new-workspace').value } : {}) });
  }
  const session = state.sessionGeneration;
  const newOperation = state.newOperation;
  $('create-chat').disabled = true;
  $('discard-create').hidden = true;
  for (const id of ['new-workspace', 'new-provider', 'new-directory']) $(id).disabled = true;
  try {
    const data = await request(state.newOperation.path, { body: state.newOperation.body });
    if (session !== state.sessionGeneration || state.newOperation !== newOperation) return;
    state.newOperation = null; $('new-dialog').close(); await poll(); await selectChat(data.id);
  } catch (error) {
    if (session !== state.sessionGeneration || state.newOperation !== newOperation) return;
    if ([401, 403].includes(error.status)) { pairScreen(error.status === 403 ? error.message : t('authExpired')); return; }
    if (error instanceof APIError && error.uncertain) { showError('new-error', t('unknownResult')); $('create-chat').textContent = t('retry'); }
    else { state.newOperation = null; showError('new-error', describe(error)); }
  } finally {
    $('create-chat').disabled = false;
    $('discard-create').hidden = !state.newOperation;
    for (const id of ['new-workspace', 'new-provider', 'new-directory']) $(id).disabled = !!state.newOperation;
    if (!state.newOperation) $('create-chat').textContent = t('create');
  }
};

document.querySelectorAll('.install-help').forEach(button => { button.onclick = () => $('install-dialog').showModal(); });
$('close-install').onclick = () => $('install-dialog').close();
window.addEventListener('beforeinstallprompt', event => { event.preventDefault(); state.installPrompt = event; $('install-prompt').hidden = false; });
$('install-prompt').onclick = async () => {
  if (!state.installPrompt) return;
  await state.installPrompt.prompt(); state.installPrompt = null; $('install-prompt').hidden = true;
};
if (secure && 'serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js').catch(() => {});
if (!connectionAllowed) { pairingUI(false); showError('pair-error', t('secureRequired')); }
else if (scannedToken) { pair(); } // Consume a scanned invitation once; errors require an explicit retry.
else { pairingUI(false); recoverSession(); }
scannedToken = '';
