import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { randomBytes, randomUUID, createHash, timingSafeEqual, generateKeyPairSync, createPublicKey } from 'node:crypto';
import { WebSocketServer, WebSocket } from 'ws';
import { Store, UUID, providers, requireID, terminalIDs, leaf, walkReplace, removeLeaf, atomicWrite } from './store.mjs';
import { validateConnection, fetchModels, mergeModelCatalog, selectedReasoningEffort } from './models.mjs';
import { AISession } from './ai.mjs';
import { RelayClient } from './relay.mjs';
import { loadLANIdentity } from './tls.mjs';
import { PushNotifications } from './web-push.mjs';
import { APP_VERSION } from './version.mjs';

const BODY_LIMIT = 3 * 1024 * 1024;
const execute = promisify(execFile);
const hash = value => createHash('sha256').update(value).digest('hex');
const token = () => randomBytes(32).toString('hex');
const json = (value, status = 200, headers = {}) => ({ status, headers: { 'content-type': 'application/json; charset=utf-8', ...headers }, body: Buffer.from(JSON.stringify(value)) });
class APIError extends Error { constructor(status, message, code = 'operation_failed') { super(message); this.status = status; this.code = code; } }
function demand(ok, message, status = 400) { if (!ok) throw new APIError(status, message); }
function equal(a, b) { return typeof a === 'string' && typeof b === 'string' && a.length === b.length && timingSafeEqual(Buffer.from(a), Buffer.from(b)); }
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(k => [k, canonical(value[k])]));
  return value;
}
function cookie(headers, name) {
  const matches = String(headers.cookie || '').split(';').map(s => s.trim()).filter(s => s.startsWith(`${name}=`));
  return matches.length === 1 ? matches[0].slice(name.length + 1) : null;
}
const visible = chat => chat.messages.filter(m => (m.role !== 'tool' || m.isError) && (m.text.trim() || m.images?.length));
const cleanImage = image => Object.fromEntries(['id','name','mimeType','width','height'].map(k => [k, image[k]]));
const cleanMessage = m => ({ id: m.id, role: m.role, text: m.text, model: m.model || '', isError: !!m.isError,
  isIntermediate: !!m.isIntermediate, images: (m.images || []).map(cleanImage),
  ...(m.completedAt ? { completedAt: m.completedAt, durationMs: m.durationMs, completionStatus: m.completionStatus } : {}),
  ...(m.reasoningEffort ? { reasoningEffort: m.reasoningEffort, reasoningEffortVerified: m.reasoningEffortVerified === true } : {}) });
const mime = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.png': 'image/png', '.svg': 'image/svg+xml', '.webmanifest': 'application/manifest+json', '.ico': 'image/x-icon' };

export function isPrivateIPv4(value) {
  if (typeof value !== 'string' || !/^(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}$/.test(value)) return false;
  const p = value.split('.').map(Number);
  return p.every(n => n <= 255) && (p[0] === 10 || (p[0] === 172 && p[1] >= 16 && p[1] <= 31) || (p[0] === 192 && p[1] === 168));
}
export function lanAddresses(interfaces = os.networkInterfaces()) {
  return Object.entries(interfaces).flatMap(([name, records]) => (records || []).filter(r => r.family === 'IPv4' && !r.internal && isPrivateIPv4(r.address))
    .map(r => ({ name, address: r.address }))).sort((a,b) => Number(/docker|veth|vm|utun|tailscale|wsl/i.test(a.name)) - Number(/docker|veth|vm|utun|tailscale|wsl/i.test(b.name)));
}
export function isAbsoluteDirectory(value, platform = process.platform) {
  if (typeof value !== 'string' || value.length >= 4096 || /[\x00-\x1f]/.test(value)) return false;
  if (platform !== 'win32') return path.isAbsolute(value);
  const windows = value.replaceAll('/', '\\');
  if (/^\\\\[?.]\\/.test(windows)) return false;
  return /^[a-z]:\\/i.test(windows) || /^\\\\[^\\.?][^\\]*\\[^\\.][^\\]*(?:\\|$)/.test(windows);
}
function directory(value) {
  demand(isAbsoluteDirectory(value), 'Choose an absolute working folder');
  try { demand(fs.statSync(value).isDirectory(), 'Working folder does not exist'); return fs.realpathSync(value); }
  catch { throw new APIError(400, 'Working folder does not exist or cannot be accessed'); }
}

export async function createRuntime({ dataDir, webRoot, desktopRoot, encrypt, decrypt, selectDirectory,
  normalizeImage, pushSender, Session = AISession, Relay = RelayClient, networkInterfaces = os.networkInterfaces, version = APP_VERSION }) {
  const store = new Store(dataDir, { encrypt, decrypt }), state = store.state;
  const sessions = new Map(), starting = new Map(), receipts = new Map(), pending = new Set(), events = new Set();
  const metadataCache = new Map(), relayTransitions = new Set();
  const providerGenerations = new Map(), changingProviders = new Set(), sessionGenerations = new WeakMap();
  const bootID = randomUUID(), desktopToken = token();
  const entryGeneration = { desktop: 0, lan: 0, relay: 0 };
  let desktopServer, lanServer, relay, relayState = { state: 'stopped', connected: false }, invitation, attempts = [], closed = false;
  let saveTimer, eventTimer, storageError, relayKeysPromise, relayConfiguration=0, lanTransition=Promise.resolve();
  let updateInstalling = false;
  const updateBusy = () => pending.size > 0 || starting.size > 0 || changingProviders.size > 0 || [...sessions.values()].some(s => s.isBusy || s.questions?.length);
  const notifications = new PushNotifications({ store, save, send: pushSender, authorized: (record, chatId) => {
    if (closed || !(lanServer?.origin === record.origin || (relay?.origin === record.origin && relayState.connected))) return false;
    const device = state.devices.find(d => d.id === record.deviceId && d.origin === record.origin && d.expiresAt > Date.now());
    if (!device || (device.access.workspaceId && !state.workspaces.some(w => w.id === device.access.workspaceId))) return false;
    if (chatId) { const owner = store.owner(chatId); return !!owner && allowed(device, owner.id); }
    return true;
  }});
  function save() {
    clearTimeout(saveTimer); saveTimer = undefined;
    try { store.save(); storageError = null; }
    catch (e) { storageError = e.message; throw e; }
  }
  function changed() {
    if (closed) return;
    clearTimeout(saveTimer); saveTimer = setTimeout(() => { try { save(); } catch { notify(); } }, 60);
    if (!eventTimer) eventTimer = setTimeout(() => { eventTimer = undefined; notify(); }, 100);
  }
  function notify() {
    notifications.sweep();
    for (const event of [...events]) {
      if (!event.authorized()) event.revoke(); else event.send({ type: 'changed', bootID });
    }
  }
  function authorize(headers, origin, entry, generation = entryGeneration[entry]) {
    if (closed) throw new APIError(503, 'TheAll is closing');
    demand(generation === entryGeneration[entry], 'Connection was disabled or replaced', 401);
    if (entry === 'lan') demand(lanServer?.origin === origin, 'Phone connection was disabled', 401);
    if (entry === 'relay') demand(relay?.origin === origin && relayState.connected, 'Relay disconnected', 401);
    if (entry === 'desktop' && equal(cookie(headers, 'TheAllDesktopSession'), desktopToken)) {
      return { id: 'desktop', name: 'TheAll', access: { workspaceId: null, writable: true } };
    }
    demand(entry !== 'desktop', 'Desktop session expired', 401);
    const name = origin.startsWith('https:') ? 'TheAllMobileSession' : 'TheAllLANSession';
    const raw = cookie(headers, name);
    demand(raw && raw.length <= 128, 'Please pair this device again', 401);
    const device = state.devices.find(d => d.expiresAt > Date.now() && d.origin === origin && equal(d.tokenHash, hash(raw)));
    demand(device, 'Please pair this device again', 401);
    demand(!device.access.workspaceId || state.workspaces.some(w => w.id === device.access.workspaceId), 'Workspace access was revoked', 403);
    return device;
  }
  function allowed(device, workspaceID) { return !device.access.workspaceId || device.access.workspaceId === workspaceID; }
  function getChat(id, device) {
    demand(UUID.test(id), 'Conversation not found', 404);
    const owner = store.owner(id);
    demand(owner && allowed(device, owner.id), 'Conversation not found', 404);
    return state.chats[id];
  }
  function headersValid(method, headers, origin) {
    demand(String(headers.host || '').toLowerCase() === new URL(origin).host.toLowerCase(), 'Invalid host', 403);
    demand(headers['sec-fetch-site'] !== 'cross-site' && (!headers.origin || headers.origin === origin), 'Cross-origin request rejected', 403);
    demand(method === 'GET' || method === 'POST', 'Method not allowed', 405);
    if (method === 'POST') demand(headers.origin === origin && headers['x-theall-client'] === '1'
      && String(headers['content-type']).split(';')[0].trim().toLowerCase() === 'application/json', 'Same-origin JSON client required', 403);
  }
  function cookieHeader(raw, origin, age = 2592000) {
    const secure = origin.startsWith('https:');
    return `${secure ? 'TheAllMobileSession' : 'TheAllLANSession'}=${raw}; Path=/; HttpOnly; SameSite=Strict; Max-Age=${age}${secure ? '; Secure' : ''}`;
  }
  async function ensureSession(chat) {
    demand(!closed && store.owner(chat.id), 'Conversation was closed', 409);
    demand(!changingProviders.has(chat.provider), 'AI connection is being changed', 409);
    const providerGeneration=providerGenerations.get(chat.provider)||0;
    const currentConnection=()=>!changingProviders.has(chat.provider)&&(providerGenerations.get(chat.provider)||0)===providerGeneration;
    if (starting.has(chat.id)) return starting.get(chat.id);
    const existing = sessions.get(chat.id);
    if (existing?.isReady && sessionGenerations.get(existing)===providerGeneration) return existing;
    const promise = (async () => {
      if (existing) await existing.close();
      demand(providers.has(chat.provider), 'Select Claude or OpenAI in this conversation first', 409);
      const connection = await store.readSecret(chat.provider);
      demand(currentConnection(), 'AI connection changed before startup', 409);
      demand(!closed && store.owner(chat.id), 'Conversation was closed', 409);
      demand(connection, 'Save this AI connection in Settings first', 409);
      directory(chat.directory);
      const session = new Session({ chat, connection, dataDir: store.directory });
      sessions.set(chat.id, session); sessionGenerations.set(session,providerGeneration); session.on('change', changed);
      session.on('completed', event => {
        if (closed || sessions.get(chat.id) !== session || event?.chatId !== chat.id) return;
        try { save(); } catch { return; }
        notifications.completed(event).catch(() => {});
      });
      try { await session.start(); demand(!closed && store.owner(chat.id), 'Conversation was closed', 409); demand(currentConnection(), 'AI connection changed before startup', 409);
        state.settings.modelCapabilities ??= {}; state.settings.modelCapabilities[chat.provider] = session.models || [];
        session.models = mergeModelCatalog(state.settings.models?.[chat.provider] || [], session.models || []); changed(); return session; }
      catch (e) { changed(); throw e; }
    })();
    starting.set(chat.id, promise);
    try { return await promise; } finally { starting.delete(chat.id); }
  }
  async function stopChat(id) {
    if (starting.has(id)) { try { await starting.get(id); } catch {} }
    const session = sessions.get(id);
    if (session) { await session.close(); sessions.delete(id); }
  }
  function snapshot(chat, device, search) {
    const session = sessions.get(chat.id), messages = visible(chat);
    for (const key of ['before','limit']) if (search.has(key)) demand(/^\d+$/.test(search.get(key)), 'Invalid pagination');
    const end = Math.min(Number(search.get('before') ?? messages.length), messages.length);
    const limit = Math.min(Math.max(Number(search.get('limit') ?? 100), 1), 250), start = Math.max(end - limit, 0);
    return { id: chat.id, workspaceId: store.owner(chat.id).id, access: device.access, provider: chat.provider || '',
      model: chat.model || '', reasoningEffort: chat.reasoningEffort || '', directory: chat.directory, messages: messages.slice(start,end).map(cleanMessage), start, total: messages.length,
      isReady: !!session?.isReady, isBusy: !!session?.isBusy, canInterrupt: device.access.writable && !!session?.canInterrupt,
      canResume: device.access.writable && !!chat.provider && !session?.isReady,
      models: modelCatalog(chat), defaultModel: session?.defaultModel || '',
      questions: session?.questions || [], bootID, ...(storageError || session?.error ? { error: storageError || session.error } : {}) };
  }
  function modelCatalog(chat) { return mergeModelCatalog(state.settings.models?.[chat.provider] || [], sessions.get(chat.id)?.models || state.settings.modelCapabilities?.[chat.provider] || []); }
  function workspaceList(device) {
    return { bootID, access: device.access, selectedWorkspaceId: state.selectedWorkspaceId,
      workspaces: state.workspaces.filter(w => allowed(device,w.id)).map(w => ({ id: w.id, name: w.name, tabs: w.tabs, selectedTabId: w.selectedTabId,
        conversations: w.tabs.flatMap(t => terminalIDs(t.layout).map((id,i) => {
          const c = state.chats[id], s = sessions.get(id);
          return { id, workspaceId: w.id, tabId: t.id, title: t.title + (terminalIDs(t.layout).length > 1 ? ` · ${i+1}` : ''),
            provider: c.provider || '', directory: c.directory, model: c.model, status: s?.questions?.length ? 'needsInput' : s?.isBusy ? 'running' : s?.isReady ? 'idle' : c.provider ? 'offline' : 'setup', messageCount: c.messages.length };
        })) })) };
  }
  async function imagesFrom(body) {
    const values = body.images ?? []; demand(Array.isArray(values) && values.length <= 4, 'Attach at most four photos');
    const result = [];
    try {
      for (const image of values) {
        demand(image && typeof image.name === 'string' && image.name.length > 0 && Buffer.byteLength(image.name) <= 255
          && typeof image.data === 'string' && image.data.length <= 4 * Math.ceil(512 * 1024 / 3), 'Invalid photo');
        const input = Buffer.from(image.data, 'base64');
        demand(input.length > 0 && input.length <= 512 * 1024 && input.toString('base64') === image.data, 'Invalid photo');
        demand(typeof normalizeImage === 'function', 'Photo import is unavailable', 503);
        const normalized = await normalizeImage(input);
        demand(normalized && Buffer.isBuffer(normalized.data) && normalized.data.length > 0 && normalized.data.length <= 2 * 1024 * 1024
          && ['image/png','image/jpeg'].includes(normalized.mimeType) && normalized.width > 0 && normalized.height > 0
          && normalized.width <= 2048 && normalized.height <= 2048, 'Invalid photo');
        const id = randomUUID(), file = path.join(store.directory, 'Attachments', id + (normalized.mimeType === 'image/png' ? '.png' : '.jpg'));
        atomicWrite(file, normalized.data);
        result.push({ id, name: image.name, path: file, mimeType: normalized.mimeType, width: normalized.width, height: normalized.height,
          data: normalized.data.toString('base64') });
      }
      return result;
    } catch (e) { for (const image of result) fs.unlinkSync(image.path); throw e; }
  }
  function serveStatic(target, desktopAuthorized) {
    const raw = target.split('?')[0];
    demand(!raw.includes('%') && !raw.includes('\\') && !raw.split('/').includes('..'), 'Invalid asset path', 404);
    let root = webRoot, relative = raw === '/' ? 'index.html' : raw.slice(1);
    if (raw.startsWith('/desktop/')) { demand(desktopAuthorized, 'Not found', 404); root = desktopRoot; relative = raw.slice(9); }
    if (raw === '/chat.html') { demand(desktopAuthorized, 'Not found', 404); relative = 'index.html'; }
    demand(root && relative && !relative.startsWith('.') && relative.split('/').every(p => p && !p.startsWith('.')), 'Not found', 404);
    const file = path.resolve(root, relative);
    demand(file.startsWith(path.resolve(root) + path.sep), 'Not found', 404);
    let stat; try { stat = fs.lstatSync(file); } catch { throw new APIError(404, 'Not found'); }
    demand(stat.isFile() && !stat.isSymbolicLink() && stat.size <= 8 * 1024 * 1024, 'Not found', 404);
    const type = mime[path.extname(file)]; demand(type, 'Not found', 404);
    return { status: 200, headers: { 'content-type': type }, body: fs.readFileSync(file) };
  }

  async function handle({ method, target, headers, body = Buffer.alloc(0), origin, entry }) {
    const generation = entryGeneration[entry];
    try {
      headersValid(method, headers, origin);
      demand(typeof target === 'string' && target.startsWith('/') && !target.startsWith('//') && !target.includes('#') && target.length <= 4096, 'Invalid request');
      demand(body.length <= BODY_LIMIT, 'Request is too large', 413);
      const url = new URL(target, origin), route = url.pathname;
      if (method === 'GET' && !route.startsWith('/api/')) return serveStatic(target, entry === 'desktop' && equal(cookie(headers,'TheAllDesktopSession'),desktopToken));
      let input;
      if (method === 'POST') { try { input = JSON.parse(body.toString('utf8')); } catch { throw new APIError(400,'Invalid JSON'); }
        demand(input && typeof input === 'object' && !Array.isArray(input), 'Invalid request'); }
      if (method === 'POST' && route === '/api/pair') {
        demand(entry !== 'desktop', 'Pair from the phone connection link', 403);
        attempts = attempts.filter(t => Date.now() - t < 60000); demand(attempts.length < 20, 'Too many pairing attempts', 429); attempts.push(Date.now());
        demand(typeof input.token === 'string' && input.token.length <= 128 && invitation && invitation.origin === origin
          && invitation.expiresAt > Date.now() && equal(invitation.hash, hash(input.token)), 'Pairing code expired or already used', 401);
        state.devices = state.devices.filter(d => d.expiresAt > Date.now()); demand(state.devices.length < 20,'Remove an old paired device first',429);
        const raw = token(), device = { id: randomUUID(), name: String(input.deviceName || 'Phone').trim().slice(0,80), tokenHash: hash(raw), origin,
          createdAt: Date.now(), expiresAt: Date.now() + 2592000000, access: invitation.access };
        state.devices.push(device); save(); invitation = null; changed();
        return json({ deviceName: device.name, bootID, access: device.access },200,{'set-cookie': cookieHeader(raw,origin)});
      }
      const device = authorize(headers,origin,entry,generation);
      const stillAuthorized = () => { const now = authorize(headers,origin,entry,generation); demand(now.id === device.id,'Authorization changed',401); return now; };
      if (route === '/api/notifications' || route.startsWith('/api/notifications/')) {
        demand(device.id !== 'desktop', 'Pair this browser before enabling phone notifications', 403);
        demand(body.length <= 8192, 'Notification preferences are too large', 413);
        if (method === 'GET' && route === '/api/notifications') return json(await notifications.status(device));
        if (method === 'POST' && route === '/api/notifications/subscribe') return json(await notifications.subscribe(device, input));
        if (method === 'POST' && route === '/api/notifications/unsubscribe') return json(notifications.unsubscribe(device.id));
        if (method === 'POST' && route === '/api/notifications/test') return json(await notifications.test(device));
        throw new APIError(404, 'Not found');
      }
      if (method === 'GET' && route === '/api/session') return json({ deviceName: device.name, bootID, access: device.access });
      if (method === 'POST' && route === '/api/logout') {
        demand(device.id !== 'desktop','Use the desktop window controls',400);
        state.devices = state.devices.filter(d => d.id !== device.id); notifications.unsubscribe(device.id); notify();
        return json({ ok:true },200,{'set-cookie':cookieHeader('',origin,0)});
      }
      if (method === 'GET' && route === '/api/workspaces') return json(workspaceList(device));
      const parts = route.split('/').filter(Boolean);
      if (method === 'GET' && parts.length === 3 && parts[0] === 'api' && parts[1] === 'chats') return json(snapshot(getChat(parts[2],device),device,url.searchParams));
      if (method === 'GET' && parts.length === 5 && parts[1] === 'chats' && parts[3] === 'images') {
        const chat = getChat(parts[2],device), image = visible(chat).flatMap(m => m.images || []).find(i => i.id === parts[4]);
        demand(image && UUID.test(image.id),'Photo not found',404);
        const file = path.join(store.directory,'Attachments',image.id + (image.mimeType === 'image/png' ? '.png' : '.jpg'));
        const stat = fs.lstatSync(file); demand(stat.isFile() && stat.size <= 2 * 1024 * 1024,'Photo not found',404);
        return { status:200, headers:{'content-type':image.mimeType,'content-disposition':'inline'},body:fs.readFileSync(file) };
      }
      demand(method === 'POST','Not found',404); demand(!updateInstalling,'TheAll is installing an update',503); demand(device.access.writable,'This device has read-only access',403);
      demand(typeof input.requestId === 'string' && UUID.test(input.requestId), 'Invalid request identity');
      demand(input.bootID === bootID,'TheAll restarted. Review the conversation before trying again.',409);
      if (route === '/api/chats') {
        if (device.access.workspaceId) demand(input.workspaceId === device.access.workspaceId,'Workspace access denied',403);
        if (input.workspaceId) demand(state.workspaces.some(w => w.id === input.workspaceId && allowed(device,w.id)),'Workspace not found',404);
      } else { demand(parts.length === 4 && parts[1] === 'chats' && ['send','answer','interrupt'].includes(parts[3]),'Not found',404); getChat(parts[2],device); }
      const key = `${device.id}:${input.requestId}`, fingerprint = hash(route + JSON.stringify(canonical(input)));
      if (receipts.has(key)) { const saved = receipts.get(key); demand(saved.fingerprint === fingerprint,'Request ID was already used for another action',409); return saved.response; }
      if (pending.has(key)) throw new APIError(409,'This request is still running','request_pending');
      demand(receipts.size < 10000 && pending.size < 32,'Request capacity reached; restart TheAll after current tasks finish',429);
      pending.add(key);
      let response, actionAccepted = false;
      try {
        demand(!storageError,'Conversation storage is unavailable',503);
        if (route === '/api/chats') {
          demand(providers.has(input.provider),'Choose Claude or OpenAI');
          const connection=await store.readSecret(input.provider);demand(connection,'Save this AI connection in desktop Settings first',409);
          stillAuthorized();
          const dir = directory(input.directory), model = input.model === undefined ? connection.model : selectedModel(input.model);
          let workspace, chat;
          if (input.workspaceId) {
            workspace = state.workspaces.find(w => w.id === input.workspaceId); demand(workspace,'Workspace was removed',404);
            chat = store.newChat(dir,input.provider,model);
            const tab = {id:randomUUID(),title:'Chat',layout:leaf(chat.id)}; workspace.tabs.push(tab); workspace.selectedTabId=tab.id;
          } else ({workspace,chat}=store.newWorkspace({directory:dir,provider:input.provider,model}));
          save(); changed(); response=json({id:chat.id,workspaceId:workspace.id,access:device.access},201);
        } else {
          const chat = getChat(parts[2],device), action = parts[3];
          if (action === 'send') {
            demand(typeof input.text === 'string' && Buffer.byteLength(input.text) <= 128*1024,'Message is too long');
            demand(input.text.trim() || input.images?.length,'Enter a message or attach a photo'); selectedModel(input.model);
            const session = await ensureSession(chat); stillAuthorized(); getChat(chat.id,device);
            session.models = mergeModelCatalog(state.settings.models?.[chat.provider] || [], session.models || state.settings.modelCapabilities?.[chat.provider] || []);
            demand(!session.isBusy && !session.questions?.length,'Wait for the current reply',409);
            const images = await imagesFrom(input); let retain=false;
            try {
              stillAuthorized(); getChat(chat.id,device);
              await session.send({text:input.text,images,model:input.model ?? chat.model,reasoningEffort:input.reasoningEffort ?? chat.reasoningEffort ?? '',stillAuthorized:()=>{
                try { stillAuthorized();getChat(chat.id,device);return sessions.get(chat.id)===session&&!changingProviders.has(chat.provider)&&sessionGenerations.get(session)===(providerGenerations.get(chat.provider)||0); } catch { return false; }
              }}); retain=true;actionAccepted=true;
              const owner=store.owner(chat.id);
              if(owner?.needsAutomaticName) { owner.name=(input.text.trim().split(/\r?\n/)[0] || 'Photos').slice(0,48); owner.needsAutomaticName=false; }
              save(); changed();
            } catch(e) { retain=e.code==='submission_uncertain' || chat.messages.some(m=>m.images?.some(i=>images.some(v=>v.id===i.id))); throw e; }
            finally { if(!retain) for(const i of images) try{fs.unlinkSync(i.path);}catch{} }
          } else {
            const session=sessions.get(chat.id); demand(session,'Conversation is not running',409); stillAuthorized();
            if(action==='interrupt') await session.interrupt();
            else {await session.answer({approvalId:input.questionId,answers:input.answers,allow:input.allow===true});actionAccepted=true;}
            save(); changed();
          }
          response=json({id:chat.id,access:device.access});
        }
      } catch(e) { const uncertain=actionAccepted||e.code==='submission_uncertain';response=json({error:safeError(e),code:uncertain?'outcome_unknown':e.code||'operation_failed'},uncertain?503:e.status||409); }
      finally { pending.delete(key); }
      receipts.set(key,{fingerprint,response}); return response;
    } catch(e) { return json({error:safeError(e),code:e.code||'operation_failed'},e.status||500); }
  }
  function safeError(e) { return String(e.message || 'Operation failed').slice(0,2000); }
  function selectedModel(value) { demand(value===undefined || (typeof value==='string' && value.length<=256 && !/[\x00-\x1f]/.test(value)),'Invalid model'); return value||''; }
  function securityHeaders(origin) {
    return {'cache-control':'no-store','x-content-type-options':'nosniff','referrer-policy':'no-referrer',
      'content-security-policy':`default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self' ${origin.replace(/^http/,'ws')}; frame-src 'self'; frame-ancestors 'self'; object-src 'none'; base-uri 'none'; form-action 'self'`};
  }
  function openEvents({headers,origin,entry,send,close}) {
    const generation=entryGeneration[entry];
    headersValid('GET',headers,origin); demand(headers.origin===origin,'Invalid event origin',403); authorize(headers,origin,entry,generation);
    demand(events.size<64,'Too many event connections',429);
    const event={authorized:()=>{try{authorize(headers,origin,entry,generation);return true;}catch{return false;}},
      send:message=>send(JSON.stringify(message)), revoke:()=>{event.send({type:'revoked'});event.close();},
      close:()=>{events.delete(event);close();},receive:text=>{
        if(!event.authorized())return event.revoke();
        try{const msg=JSON.parse(text);if(msg.type!=='ping')return event.close();event.send({type:'pong'});}catch{event.close();}
      }};
    events.add(event); queueMicrotask(()=>{if(events.has(event)){if(!event.authorized())return event.revoke();event.send({type:'hello',bootID,access:authorize(headers,origin,entry,generation).access});}});
    return event;
  }
  async function listen(address,port,entry,identity) {
    let origin;
    const sockets=new Set();
    const server=(identity?https:http).createServer({...(identity?{key:identity.key,cert:identity.cert,minVersion:'TLSv1.2'}:{}),maxHeaderSize:16384,requestTimeout:20000,headersTimeout:15000},async(req,res)=>{
      const response=(r)=>{if(!res.destroyed){res.writeHead(r.status,{...securityHeaders(origin),...r.headers,'content-length':r.body.length});res.end(r.body);}};
      try {
        demand(req.rawHeaders.filter((_,i)=>i%2===0&&req.rawHeaders[i].toLowerCase()==='host').length===1,'Invalid host',403);
        headersValid(req.method,req.headers,origin);
        demand(!req.headers.expect,'Expect is unsupported',417);
        let size=0,chunks=[];
        for await(const chunk of req){size+=chunk.length;if(size>BODY_LIMIT)throw new APIError(413,'Request is too large');chunks.push(chunk);}
        demand(req.method!=='GET'||size===0,'GET body is unsupported');
        response(await handle({method:req.method,target:req.url,headers:req.headers,body:Buffer.concat(chunks),origin,entry}));
      }catch(e){response(json({error:safeError(e),code:'operation_failed'},e.status||500));}
    });
    server.maxConnections=128;
    server.on('connection',s=>{sockets.add(s);s.on('close',()=>sockets.delete(s));});
    const wss=new WebSocketServer({noServer:true,maxPayload:8192,perMessageDeflate:false});
    server.on('upgrade',(req,socket,head)=>{
      try{demand(req.url==='/api/events','Not found',404);headersValid('GET',req.headers,origin);demand(req.headers.origin===origin,'Invalid origin',403);authorize(req.headers,origin,entry);
        wss.handleUpgrade(req,socket,head,ws=>{
          let event;
          try{event=openEvents({headers:req.headers,origin,entry,send:text=>{if(ws.readyState===WebSocket.OPEN){if(ws.bufferedAmount>65536)return ws.close();ws.send(text);}},close:()=>ws.close()});}
          catch{ws.close();return;}
          ws.on('message',(data,binary)=>{if(binary)return event.close();event.receive(data.toString());});ws.on('close',()=>events.delete(event));ws.on('error',()=>events.delete(event));
        });
      }catch(e){socket.end(`HTTP/1.1 ${e.status||403} Forbidden\r\nConnection: close\r\n\r\n`);}
    });
    await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(port,address,resolve);});
    origin=`${identity?'https':'http'}://${address}:${server.address().port}`;
    return{origin,server,identity,async close(){for(const client of wss.clients)client.terminate();for(const socket of sockets)socket.destroy();await new Promise(resolve=>server.close(resolve));}};
  }
  function enableLAN(options={}) {
    const operation=lanTransition.catch(()=>{}).then(()=>startLAN(options));lanTransition=operation;return operation;
  }
  async function startLAN({address,port,mode}={}) {
    demand(!closed,'TheAll is closing',503);
    mode=mode||state.settings.lanMode||'quick';demand(['quick','encrypted'].includes(mode),'Invalid phone connection mode');
    if(lanServer&&mode===(lanServer.identity?'encrypted':'quick')&&(!address||address===state.settings.lanAddress)&&(!port||port===state.settings.lanPort))return{url:lanServer.origin,mode};
    if(lanServer){entryGeneration.lan++;invitation=null;notifications.closeOrigin(lanServer.origin);const old=lanServer;lanServer=null;notify();await old.close();}
    const choices=lanAddresses(networkInterfaces());
    address=address||state.settings.lanAddress;
    if(!choices.some(c=>c.address===address))address=choices[0]?.address;
    demand(address&&isPrivateIPv4(address),'Connect this computer to a private Wi-Fi or Ethernet network first',409);
    port=port??state.settings.lanPort??8765;demand(Number.isInteger(port)&&port>=0&&port<=65535,'Invalid phone port');
    const generation=entryGeneration.lan;
    const identity=mode==='encrypted'?await loadLANIdentity({store,address}):undefined;
    demand(!closed&&generation===entryGeneration.lan,'Phone connection was cancelled',409);
    const next=await listen(address,port,'lan',identity);
    if(closed||generation!==entryGeneration.lan){await next.close();throw new APIError(409,'Phone connection was cancelled');}
    lanServer=next;notifications.openOrigin(next.origin);state.settings.lanMode=mode;state.settings.lanAddress=address;state.settings.lanPort=lanServer.server.address().port;save();
    return{url:lanServer.origin,mode};
  }
  function workspace(id){requireID(id);const w=state.workspaces.find(w=>w.id===id);demand(w,'Workspace not found',404);return w;}
  function tabFor(payload){const w=workspace(payload.workspaceId),t=w.tabs.find(t=>t.id===(payload.tabId||payload.id));demand(t,'Tab not found',404);return[w,t];}
  async function desktop(method,payload={}) {
    demand(!closed,'TheAll is closing',503);
    demand(!updateInstalling || ['draft.save','draft.get','settings.get','workspace.metadata','mobile.info','mobile.devices'].includes(method), 'TheAll is installing an update', 503);
    switch(method){
      case 'settings.get':return{...state.settings,version,connections:Object.fromEntries([...providers].map(p=>[p,store.publicConnection(p)])),mobile:{url:lanServer?.origin||null,relay:relayState}};
      case 'settings.save':{
        const settings={...state.settings};
        if(payload.theme!==undefined){demand(typeof payload.theme==='string'&&payload.theme.length<=100&&(['system','dark','light'].includes(payload.theme)||
          (path.basename(payload.theme)===payload.theme&&fs.existsSync(path.join(desktopRoot,'../assets/themes',payload.theme)))),'Invalid theme');settings.theme=payload.theme;}
        if(payload.fontFamily!==undefined){demand(typeof payload.fontFamily==='string'&&payload.fontFamily.length<=100,'Invalid font');settings.fontFamily=payload.fontFamily;}
        if(payload.fontSize!==undefined){demand(Number.isFinite(payload.fontSize)&&payload.fontSize>=6&&payload.fontSize<=72,'Invalid font size');settings.fontSize=payload.fontSize;}
        if(payload.language!==undefined){demand(['en','zh-Hans','fr','ja','ko','system'].includes(payload.language),'Invalid language');settings.language=payload.language;}
        if(payload.defaultDirectory!==undefined)settings.defaultDirectory=directory(payload.defaultDirectory);
        const ranges={lineHeight:[0.5,2],backgroundOpacity:[0,1],contentOpacity:[0,1],contentShadow:[0,1],unfocusedPaneOpacity:[0,1],backgroundBlur:[0,100],paddingX:[0,100],paddingY:[0,100],scrollbackLimit:[0,100000000]};
        for(const[key,[min,max]]of Object.entries(ranges))if(payload[key]!==undefined){demand(Number.isFinite(payload[key])&&payload[key]>=min&&payload[key]<=max,'Invalid display value');settings[key]=payload[key];}
        const choices={cursorStyle:['block','bar','underline'],copyOnSelect:['false','true','clipboard'],confirmClose:['true','false','always']};
        for(const[key,values]of Object.entries(choices))if(payload[key]!==undefined){demand(values.includes(payload[key]),'Invalid display option');settings[key]=payload[key];}
        for(const key of ['cursorBlink','fontThicken','hideMouseWhileTyping'])if(payload[key]!==undefined){demand(typeof payload[key]==='boolean','Invalid display option');settings[key]=payload[key];}
        state.settings=settings;save();notify();return settings;
      }
      case 'connection.save':return changeConnection(payload.provider,async()=>{
        const previous=payload.apiKey?null:await store.readSecret(payload.provider);
        const input={...payload};
        if(!input.apiKey&&previous){demand(!input.baseURL||input.baseURL.replace(/\/+$/,'')===previous.baseURL,'Enter the API key again when changing the endpoint');input.apiKey=previous.apiKey;}
        const connection=validateConnection(payload.provider,input);
        await store.writeSecret(payload.provider,connection);
        for(const [id]of sessions)if(state.chats[id]?.provider===payload.provider)await stopChat(id);
        if(state.settings.modelCapabilities)delete state.settings.modelCapabilities[payload.provider];
        state.settings.connections??={};const{apiKey,...metadata}=connection;state.settings.connections[payload.provider]=metadata;save();notify();return store.publicConnection(payload.provider);
      });
      case 'connection.remove':return changeConnection(payload.provider,async()=>{
        store.removeSecret(payload.provider);if(state.settings.modelCapabilities)delete state.settings.modelCapabilities[payload.provider];if(state.settings.connections)delete state.settings.connections[payload.provider];
        for(const[id]of sessions)if(state.chats[id]?.provider===payload.provider)await stopChat(id);
        save();notify();return{ok:true};
      });
      case 'models.list':{
        const connection=await store.readSecret(payload.provider);demand(connection,'Save an API connection first',409);
        const apiModels=await fetchModels(payload.provider,connection);state.settings.models??={};state.settings.models[payload.provider]=apiModels;
        const models=mergeModelCatalog(apiModels,state.settings.modelCapabilities?.[payload.provider] || []);save();notify();return{models};
      }
      case 'folder.select':return{directory:await selectDirectory?.(payload.directory)||null};
      case 'workspace.create':{const{workspace:w}=store.newWorkspace({name:String(payload.name||'Workspace').slice(0,80)});save();notify();return{id:w.id};}
      case 'workspace.select':{workspace(payload.id);state.selectedWorkspaceId=payload.id;save();return{ok:true};}
      case 'workspace.metadata':{
        const w=workspace(payload.id),id=terminalIDs(w.tabs.find(t=>t.id===w.selectedTabId).layout)[0],folder=state.chats[id].directory;
        const old=metadataCache.get(w.id);if(old&&old.folder===folder&&Date.now()-old.time<5000)return old.result;
        let result={directory:folder,branch:'',changed:0,added:0,modified:0,deleted:0,untracked:0,ahead:0,behind:0,isGit:false};
        try{const{stdout}=await execute('git',['-C',folder,'status','--porcelain=v1','--branch','--untracked-files=normal'],{shell:false,windowsHide:true,timeout:3000,maxBuffer:1024*1024});
          const lines=stdout.split(/\r?\n/).filter(Boolean),first=lines.shift()||'';
          result.branch=first.replace(/^## (?:No commits yet on )?/,'').split('...')[0].split(' [')[0];result.isGit=true;
          result.ahead=Number(first.match(/ahead (\d+)/)?.[1]||0);result.behind=Number(first.match(/behind (\d+)/)?.[1]||0);
          result.changed=lines.length;for(const line of lines){const code=line.slice(0,2);if(code==='??')result.untracked++;else if(code.includes('A'))result.added++;else if(code.includes('D'))result.deleted++;else result.modified++;}
        }catch{}metadataCache.set(w.id,{folder,time:Date.now(),result});return result;
      }
      case 'workspace.rename':{const w=workspace(payload.id);demand(typeof payload.name==='string'&&payload.name.trim()&&payload.name.length<=100,'Enter a workspace name');w.name=payload.name.trim();w.needsAutomaticName=false;save();notify();return{ok:true};}
      case 'workspace.reorder':{demand(Array.isArray(payload.ids)&&payload.ids.length===state.workspaces.length&&new Set(payload.ids).size===payload.ids.length&&payload.ids.every(id=>state.workspaces.some(w=>w.id===id)),'Invalid workspace order');state.workspaces=payload.ids.map(id=>workspace(id));save();notify();return{ok:true};}
      case 'workspace.delete':{const w=workspace(payload.id),ids=w.tabs.flatMap(t=>terminalIDs(t.layout));
        state.workspaces=state.workspaces.filter(v=>v.id!==w.id);if(state.selectedWorkspaceId===w.id)state.selectedWorkspaceId=state.workspaces[0]?.id||null;
        // Remove ownership before awaiting process shutdown: queued sends must
        // immediately lose access, while transcript/attachment bytes remain recoverable.
        try{save();notify();}finally{await Promise.all(ids.map(stopChat));}return{ok:true};}
      case 'tab.create':{const w=workspace(payload.workspaceId);demand(!payload.provider||providers.has(payload.provider),'Unknown AI provider');
        const connection=payload.provider?await store.readSecret(payload.provider):null;
        demand(!closed&&state.workspaces.includes(w),'Workspace was closed',409);
        const chat=store.newChat(directory(payload.directory||state.settings.defaultDirectory),payload.provider||null,payload.model===undefined?connection?.model||'':selectedModel(payload.model));
        const tab={id:randomUUID(),title:'Chat',layout:leaf(chat.id)};w.tabs.push(tab);w.selectedTabId=tab.id;save();notify();return{id:tab.id,terminalId:chat.id};}
      case 'tab.select':{const[w,t]=tabFor(payload);w.selectedTabId=t.id;save();notify();return{ok:true};}
      case 'tab.rename':{const[,t]=tabFor(payload);demand(typeof payload.title==='string'&&payload.title.trim()&&payload.title.length<=100,'Enter a tab name');t.title=payload.title.trim();save();notify();return{ok:true};}
      case 'tab.reorder':{const w=workspace(payload.workspaceId);demand(Array.isArray(payload.ids)&&payload.ids.length===w.tabs.length&&new Set(payload.ids).size===payload.ids.length&&payload.ids.every(id=>w.tabs.some(t=>t.id===id)),'Invalid tab order');w.tabs=payload.ids.map(id=>w.tabs.find(t=>t.id===id));save();notify();return{ok:true};}
      case 'tab.close':{const[w,t]=tabFor(payload),ids=terminalIDs(t.layout);w.tabs=w.tabs.filter(v=>v.id!==t.id);
        if(!w.tabs.length){const chat=store.newChat();w.tabs=[{id:randomUUID(),title:'Chat',layout:leaf(chat.id)}];}if(w.selectedTabId===t.id)w.selectedTabId=w.tabs[0].id;try{save();notify();}finally{await Promise.all(ids.map(stopChat));}return{ok:true};}
      case 'pane.split':{const[w,t]=tabFor(payload);demand(terminalIDs(t.layout).includes(payload.terminalId)&&terminalIDs(t.layout).length<16,'Cannot split this pane');demand(['horizontal','vertical'].includes(payload.direction),'Invalid split');
        const previous=store.chat(payload.terminalId),chat=store.newChat(payload.directory?directory(payload.directory):previous.directory,payload.provider||null);
        t.layout=walkReplace(t.layout,payload.terminalId,n=>({type:'split',direction:payload.direction,ratio:0.5,first:n,second:leaf(chat.id)}));save();notify();return{terminalId:chat.id};}
      case 'pane.close':{const[w,t]=tabFor(payload);demand(terminalIDs(t.layout).includes(payload.terminalId),'Pane not found',404);t.layout=removeLeaf(t.layout,payload.terminalId)||leaf(store.newChat().id);try{save();notify();}finally{await stopChat(payload.terminalId);}return{ok:true};}
      case 'pane.resize':{const[,t]=tabFor(payload);demand(Array.isArray(payload.path)&&payload.path.length<=16&&payload.path.every(i=>i===0||i===1),'Invalid split path');let n=t.layout;for(const i of payload.path){demand(n.type==='split','Invalid split path');n=i===0?n.first:n.second;}
        demand(n.type==='split'&&Number.isFinite(payload.ratio)&&payload.ratio>=0.1&&payload.ratio<=0.9,'Invalid split ratio');n.ratio=payload.ratio;save();return{ok:true};}
      case 'chat.update':{const chat=store.chat(payload.id);demand(!sessions.get(chat.id)?.isBusy&&!sessions.get(chat.id)?.questions?.length,'Wait for the current reply',409);
        if(payload.provider!==undefined){demand(providers.has(payload.provider),'Unknown AI provider');demand(!chat.messages.length||payload.provider===chat.provider,'Start a new conversation to change AI provider');demand(await store.readSecret(payload.provider),'Save this AI connection in Settings first',409);}
        const dir=payload.directory===undefined?chat.directory:directory(payload.directory);
        const model=payload.model===undefined?(payload.provider&&payload.provider!==chat.provider?(await store.readSecret(payload.provider)).model:chat.model):selectedModel(payload.model);
        const changingProvider = payload.provider && payload.provider !== chat.provider;
        const catalog = changingProvider ? mergeModelCatalog(state.settings.models?.[payload.provider] || [], state.settings.modelCapabilities?.[payload.provider] || []) : modelCatalog(chat);
        const previousEffort = chat.reasoningEffort || '', defaultModel = changingProvider ? undefined : sessions.get(chat.id)?.defaultModel;
        const target = catalog.find(m => m.id === model) || (!model && catalog.find(m => m.id === defaultModel));
        const reasoningEffort = selectedReasoningEffort(catalog,model,payload.reasoningEffort ?? (!changingProvider && target?.reasoningEfforts?.includes(previousEffort) ? previousEffort : ''),defaultModel);
        await stopChat(chat.id);if(payload.provider!==undefined)chat.provider=payload.provider;chat.directory=dir;
        if(chat.draft?.model===chat.model)chat.draft.model=model;chat.model=model;chat.reasoningEffort=reasoningEffort;save();notify();return{ok:true};}
      case 'draft.get':return store.chat(payload.id).draft||{text:'',images:[],model:'',reasoningEffort:''};
      case 'draft.save':{const chat=store.chat(payload.id);demand(typeof payload.text==='string'&&Buffer.byteLength(payload.text)<=128*1024,'Draft is too long');
        const images=payload.images||[];demand(Array.isArray(images)&&images.length<=4&&JSON.stringify(images).length<=BODY_LIMIT,'Draft images are too large');
        const model=selectedModel(payload.model),reasoningEffort=payload.reasoningEffort ?? '';
        demand(typeof reasoningEffort==='string' && (reasoningEffort==='' || /^[a-z][a-z0-9_-]{0,31}$/.test(reasoningEffort)), 'Invalid reasoning effort');
        chat.draft={text:payload.text,images,model,reasoningEffort};save();return{ok:true};}
      case 'mobile.enable':return enableLAN(payload);
      case 'mobile.info':return{mode:state.settings.lanMode||'quick',url:lanServer?.origin||null,addresses:lanAddresses(networkInterfaces()),fingerprint:lanServer?.identity?.fingerprint||null};
      case 'mobile.certificate':{demand(lanServer?.identity,'Enable encrypted HTTPS mode first',409);return{pem:lanServer.identity.ca,fingerprint:lanServer.identity.fingerprint};}
      case 'mobile.disable':{invitation=null;entryGeneration.lan++;notifications.closeOrigin(lanServer?.origin);await lanTransition.catch(()=>{});const old=lanServer;lanServer=null;notify();await old?.close();return{ok:true};}
      case 'mobile.pair':{
        const access={workspaceId:payload.workspaceId||null,writable:payload.writable!==false};if(access.workspaceId)workspace(access.workspaceId);
        const origin=payload.mode==='relay'?(demand(relayState.connected,'Relay is not connected',409),relay.origin):(await enableLAN()).url;
        const raw=token();invitation={hash:hash(raw),origin,access,expiresAt:Date.now()+300000};return{url:`${origin}/#pair=${raw}`,expiresAt:invitation.expiresAt};
      }
      case 'mobile.devices':return{devices:state.devices.filter(d=>d.expiresAt>Date.now()).map(({tokenHash,...device})=>device)};
      case 'mobile.revoke':{requireID(payload.id);state.devices=state.devices.filter(d=>d.id!==payload.id);notifications.unsubscribe(payload.id);notify();return{ok:true};}
      case 'mobile.relay.status':return{...relayState,publicKey:await relayPublicKey(),url:state.settings.relayURL||''};
      case 'mobile.relay.configure':return configureRelay(payload.url);
      default:throw new APIError(400,'Unsupported desktop action');
    }
  }
  async function changeConnection(provider,operation){
    demand(providers.has(provider),'Unknown AI provider');
    demand(!changingProviders.has(provider),'This AI connection is already being changed',409);
    for(const session of sessions.values())demand(session.chat?.provider!==provider||(!session.isBusy&&!session.questions?.length),'Stop this provider’s running tasks before changing its connection',409);
    // Invalidate in-flight credential reads before the first await. Their captured
    // keys may still decrypt successfully, but must never start or submit work.
    changingProviders.add(provider);providerGenerations.set(provider,(providerGenerations.get(provider)||0)+1);
    try{return await operation();}finally{changingProviders.delete(provider);}
  }
  function configureRelay(url){
    demand(typeof url==='string','Enter a relay URL');
    const generation=++relayConfiguration,previous=relay;
    entryGeneration.relay++;notifications.closeOrigin(previous?.origin);relay=null;invitation=null;relayState={state:'stopped',connected:false};notify();
    const current=()=>demand(!closed&&generation===relayConfiguration,'Relay configuration was cancelled',409);
    const operation=(async()=>{
      await previous?.close();current();
      if(!url){state.settings.relayURL='';save();return relayState;}
      const keys=await relayKeys();current();
      const next=new Relay({url,privateKey:keys.privateKey,
        handleRequest:async r=>{const response=await handle({...r,entry:'relay'});return{...response,headers:{...securityHeaders(r.origin),...response.headers}};},
        openEvents:r=>openEvents({...r,entry:'relay'}),onStatus:status=>{
          if(closed||generation!==relayConfiguration||relay!==next)return;
          if(relayState.connected&&!status.connected){entryGeneration.relay++;notifications.closeOrigin(next.origin);}
          if(status.connected)notifications.openOrigin(next.origin);
          relayState=status;notify();
        }});
      state.settings.relayURL=url;save();relay=next;next.start();return{...relayState,publicKey:keys.publicKey};
    })();
    relayTransitions.add(operation);
    operation.then(()=>relayTransitions.delete(operation),()=>relayTransitions.delete(operation));
    return operation;
  }
  function relayKeys(){
    if(!relayKeysPromise)relayKeysPromise=(async()=>{let keys=await store.readSecret('relay');if(!keys){const pair=generateKeyPairSync('ed25519');keys={privateKey:pair.privateKey.export({type:'pkcs8',format:'pem'}),publicKey:pair.publicKey.export({type:'spki',format:'der'}).subarray(-32).toString('base64')};await store.writeSecret('relay',keys);}return keys;})().catch(e=>{relayKeysPromise=null;throw e;});
    return relayKeysPromise;
  }
  async function relayPublicKey(){return(await relayKeys()).publicKey;}
  desktopServer=await listen('127.0.0.1',0,'desktop');
  if(state.settings.relayURL)try{await desktop('mobile.relay.configure',{url:state.settings.relayURL});}catch(e){relayState={state:'disconnected',connected:false,error:safeError(e)};}
  return {url:desktopServer.origin,desktopToken,bootID,desktop,enableLAN,
    tryBeginUpdate() { if (closed || updateInstalling || updateBusy()) return false; updateInstalling = true; return true; },
    abortUpdate() { updateInstalling = false; },
    async close(){
      save(); closed=true; clearTimeout(saveTimer); clearTimeout(eventTimer); eventTimer=undefined;
      // Keep listeners and notification/relay services intact until the final
      // history save succeeds. A disk error can then cancel an update and retry.
      try {
        await lanTransition.catch(()=>{}); await Promise.allSettled([...starting.values()]);
        for(const s of sessions.values())await s.close();
        save();
      } catch(error) { closed=false; updateInstalling=false; changed(); throw error; }
      notifications.close();relayConfiguration++;entryGeneration.relay++;invitation=null;
      await relay?.close();await Promise.allSettled([...relayTransitions]);
      for(const event of [...events])event.close();await lanServer?.close();await desktopServer.close();
    },
  };
}
