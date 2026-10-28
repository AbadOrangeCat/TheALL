import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { randomUUID } from 'node:crypto';
import { validateNotificationRecords } from './web-push.mjs';

export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export const providers = new Set(['claude', 'openai']);
export function requireID(value) {
  if (typeof value !== 'string' || !UUID.test(value)) throw new Error('Invalid identifier');
  return value;
}
export function terminalIDs(node) {
  return node.type === 'terminal' ? [node.terminalId] : [...terminalIDs(node.first), ...terminalIDs(node.second)];
}
export function leaf(id = randomUUID()) { return { type: 'terminal', terminalId: id }; }
export function walkReplace(node, id, transform) {
  if (node.type === 'terminal') return node.terminalId === id ? transform(node) : node;
  return { ...node, first: walkReplace(node.first, id, transform), second: walkReplace(node.second, id, transform) };
}
export function removeLeaf(node, id) {
  if (node.type === 'terminal') return node.terminalId === id ? null : node;
  const first = removeLeaf(node.first, id), second = removeLeaf(node.second, id);
  return !first ? second : !second ? first : { ...node, first, second };
}

// Replace in the same directory, flushing first. Never truncate the only copy of
// a conversation, and never turn an unreadable store into an empty workspace.
export function atomicWrite(file, bytes) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  if (fs.existsSync(file) && !fs.lstatSync(file).isFile()) throw new Error('Storage path is not a regular file');
  const temp = `${file}.${randomUUID()}.tmp`;
  let fd;
  try {
    fd = fs.openSync(temp, 'wx', 0o600);
    fs.writeFileSync(fd, bytes); fs.fsyncSync(fd); fs.closeSync(fd); fd = undefined;
    fs.renameSync(temp, file);
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
    if (fs.existsSync(temp)) fs.unlinkSync(temp);
  }
}
function readFile(file, maximum = 64 * 1024 * 1024) {
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.size > maximum) throw new Error('Invalid storage file');
  return fs.readFileSync(file);
}
function validateLayout(node, ids, depth = 0) {
  if (!node || depth > 16) throw new Error('Invalid workspace layout');
  if (node.type === 'terminal') {
    requireID(node.terminalId);
    if (ids.has(node.terminalId)) throw new Error('Duplicate conversation');
    ids.add(node.terminalId);
  } else if (node.type === 'split' && ['horizontal', 'vertical'].includes(node.direction)
      && Number.isFinite(node.ratio) && node.ratio >= 0.1 && node.ratio <= 0.9) {
    validateLayout(node.first, ids, depth + 1); validateLayout(node.second, ids, depth + 1);
  } else throw new Error('Invalid workspace layout');
}
function validateState(state) {
  if (state.version !== 1 || !Array.isArray(state.workspaces) || !Array.isArray(state.devices)
      || !state.settings || !state.chats || typeof state.chats !== 'object' || Array.isArray(state.chats)) throw new Error('Unsupported or damaged workspace store');
  if (state.notifications !== undefined) validateNotificationRecords(state.notifications);
  const ids = new Set(), workspaceIDs = new Set(), tabs = new Set();
  for (const w of state.workspaces) {
    requireID(w.id);
    if (workspaceIDs.has(w.id) || typeof w.name !== 'string' || !Array.isArray(w.tabs) || !w.tabs.length) throw new Error('Invalid workspace');
    workspaceIDs.add(w.id);
    for (const tab of w.tabs) {
      requireID(tab.id);
      if (tabs.has(tab.id) || typeof tab.title !== 'string') throw new Error('Invalid tab');
      tabs.add(tab.id); validateLayout(tab.layout, ids);
    }
    if (!w.tabs.some(t => t.id === w.selectedTabId)) throw new Error('Invalid selected tab');
  }
  for (const id of ids) {
    const chat = state.chats[id];
    if (!chat || chat.id !== id || typeof chat.directory !== 'string' || !Array.isArray(chat.messages)
        || (chat.provider !== null && !providers.has(chat.provider))) throw new Error('Invalid conversation');
    if (chat.codexAppliedReasoningEffort !== undefined && (typeof chat.codexAppliedReasoningEffort !== 'string' || chat.codexAppliedReasoningEffort.length > 32)) throw new Error('Invalid saved provider thinking level');
    if (chat.reasoningEffort !== undefined && (typeof chat.reasoningEffort !== 'string' || chat.reasoningEffort.length > 32)) throw new Error('Invalid thinking level');
    for (const msg of chat.messages) {
      if (typeof msg.id !== 'string' || !['user','assistant','thinking','tool'].includes(msg.role)
          || typeof msg.text !== 'string' || (msg.images && !Array.isArray(msg.images))) throw new Error('Invalid transcript');
      if (msg.completedAt !== undefined && (typeof msg.completedAt !== 'string' || !Number.isFinite(Date.parse(msg.completedAt))
          || !Number.isFinite(msg.durationMs) || msg.durationMs < 0 || !['completed', 'failed', 'interrupted'].includes(msg.completionStatus))) throw new Error('Invalid turn timing');
    }
  }
  return state;
}

export class Store {
  constructor(directory, { encrypt, decrypt } = {}) {
    this.directory = path.resolve(directory); this.encrypt = encrypt; this.decrypt = decrypt;
    fs.mkdirSync(this.directory, { recursive: true, mode: 0o700 });
    if (fs.lstatSync(this.directory).isSymbolicLink()) throw new Error('Application data cannot be a symbolic link');
    this.file = path.join(this.directory, 'workspaces.json');
    try {
      this.state = fs.existsSync(this.file) ? validateState(JSON.parse(readFile(this.file))) : {
        version: 1, workspaces: [], chats: {}, devices: [], selectedWorkspaceId: null,
        settings: { defaultDirectory: os.homedir(), theme: 'dark', fontFamily: 'Cascadia Code', fontSize: 14, language: 'en' }
      };
    } catch (error) {
      throw new Error(`Cannot read saved conversations. Your files were preserved at ${this.directory}. ${error.message}`);
    }
  }
  save() {
    validateState(this.state);
    const encoded = JSON.stringify(this.state);
    if (Buffer.byteLength(encoded) > 64 * 1024 * 1024) throw new Error('Conversation storage is full. Existing saved history was preserved.');
    atomicWrite(this.file, encoded);
  }
  newChat(directory = this.state.settings.defaultDirectory, provider = null, model = '') {
    const id = randomUUID();
    this.state.chats[id] = { id, provider, directory, model, messages: [], conversationID: null, draft: { text: '', images: [], model } };
    return this.state.chats[id];
  }
  newWorkspace({ name = 'Workspace', directory, provider = null, model = '' } = {}) {
    const chat = this.newChat(directory, provider, model), tab = { id: randomUUID(), title: 'Chat', layout: leaf(chat.id) };
    const workspace = { id: randomUUID(), name, needsAutomaticName: true, tabs: [tab], selectedTabId: tab.id };
    this.state.workspaces.push(workspace); this.state.selectedWorkspaceId = workspace.id;
    return { workspace, chat };
  }
  owner(id) { return this.state.workspaces.find(w => w.tabs.some(t => terminalIDs(t.layout).includes(id))); }
  chat(id) { requireID(id); if (!this.owner(id)) throw new Error('Conversation not found'); return this.state.chats[id]; }
  publicConnection(provider) {
    if (!providers.has(provider)) throw new Error('Unknown AI provider');
    return { ...(this.state.settings.connections?.[provider] || {}), configured: fs.existsSync(this.secretPath(provider)) };
  }
  secretPath(name) {
    if (!providers.has(name) && !['relay','lan-tls','web-push'].includes(name)) throw new Error('Invalid credential name');
    return path.join(this.directory, 'Credentials', `${name}.bin`);
  }
  async readSecret(name) {
    const file = this.secretPath(name);
    if (!fs.existsSync(file)) return null;
    if (!this.decrypt) throw new Error('System credential encryption is unavailable');
    try {
      const value = JSON.parse(await this.decrypt(readFile(file, 128 * 1024)));
      if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid credential record');
      return value;
    }
    catch { throw new Error('Saved connection cannot be decrypted for this Windows user. Existing credentials were preserved.'); }
  }
  async writeSecret(name, value) {
    if (!this.encrypt) throw new Error('System credential encryption is unavailable');
    const encrypted = await this.encrypt(JSON.stringify(value));
    if (!Buffer.isBuffer(encrypted) || !encrypted.length) throw new Error('Credential encryption failed');
    atomicWrite(this.secretPath(name), encrypted);
  }
  removeSecret(name) { const file = this.secretPath(name); if (fs.existsSync(file)) fs.unlinkSync(file); }
}
