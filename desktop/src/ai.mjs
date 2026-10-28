import { EventEmitter } from 'node:events';
import { spawn } from 'node:child_process';
import { access, mkdir, readFile, stat } from 'node:fs/promises';
import { constants } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { randomUUID } from 'node:crypto';
import { StringDecoder } from 'node:string_decoder';
import { modelCapabilities, mergeModelCatalog, selectedReasoningEffort } from './models.mjs';
import { APP_VERSION } from './version.mjs';

const MAX_FRAME = 16 * 1024 * 1024;
const MAX_QUEUED = 32 * 1024 * 1024;
const TIMEOUT = 30_000;
const SECRET_ENV = ['ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL',
  'CLAUDE_CODE_OAUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR',
  'CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR', 'ANTHROPIC_CUSTOM_HEADERS', 'ANTHROPIC_UNIX_SOCKET',
  'OPENAI_API_KEY', 'OPENAI_BASE_URL', 'THEALL_OPENAI_API_KEY'];
const PACKAGE = { claude: ['@anthropic-ai/claude-code', 'cli.js'], openai: ['@openai/codex', 'bin/codex.js'] };

function environmentValue(env, name) {
  return Object.entries(env).find(([key]) => key.toLowerCase() === name.toLowerCase())?.[1];
}

async function executableFile(file, platform) {
  try {
    if (!(await stat(file)).isFile()) return false;
    await access(file, platform === 'win32' ? constants.F_OK : constants.X_OK);
    return true;
  } catch { return false; }
}

/** Resolve native executables or known npm entry points. Never execute a .cmd/.bat shell. */
export async function resolveCLI(provider, { executable, platform = process.platform, env = process.env } = {}) {
  if (!PACKAGE[provider]) throw new Error('Unsupported AI provider.');
  const windows = platform === 'win32';
  const paths = String(environmentValue(env, 'PATH') || '').split(windows ? ';' : path.delimiter).filter(Boolean);
  if (windows) {
    const home = environmentValue(env, 'USERPROFILE') || os.homedir();
    const appdata = environmentValue(env, 'APPDATA');
    paths.unshift(path.join(home, '.local', 'bin'));
    if (appdata) paths.push(path.join(appdata, 'npm'));
    const local = environmentValue(env, 'LOCALAPPDATA');
    if (local) paths.push(path.join(local, 'Microsoft', 'WinGet', 'Links'));
  } else {
    paths.unshift(path.join(os.homedir(), '.local', 'bin'), '/opt/homebrew/bin', '/usr/local/bin');
  }
  const basename = provider === 'claude' ? 'claude' : 'codex';
  const extensions = windows ? ['.exe', '.cmd', '.bat', ''] : [''];
  const candidates = executable ? [executable] : [...new Set(paths)].flatMap(p => extensions.map(ext => path.join(p, basename + ext)));
  for (const candidate of candidates) {
    if (!await executableFile(candidate, windows ? 'win32' : platform)) continue;
    const ext = path.extname(candidate).toLowerCase();
    let script;
    if (windows && ['.cmd', '.bat', ''].includes(ext)) {
      // npm shims are shell programs. Use the provider's fixed, installed JS entry,
      // never interpolate a user directory, model or prompt into cmd.exe.
      const [pkg, entry] = PACKAGE[provider];
      const proposed = path.join(path.dirname(candidate), 'node_modules', pkg, entry);
      try { if ((await stat(proposed)).isFile()) script = proposed; } catch { /* Try next candidate. */ }
      if (!script) {
        if (executable) throw new Error('This CLI shell wrapper is unsupported. Select the native .exe or the provider’s npm JavaScript entry.');
        continue;
      }
    } else if (['.js', '.mjs', '.cjs'].includes(ext)) script = candidate;
    else if (windows && ext !== '.exe') continue;
    if (script) {
      const nodeCandidates = [path.join(path.dirname(candidate), windows ? 'node.exe' : 'node'),
        ...paths.map(p => path.join(p, windows ? 'node.exe' : 'node'))];
      let node = process.execPath;
      for (const proposed of nodeCandidates) if (await executableFile(proposed, platform)) { node = proposed; break; }
      // Electron itself can run npm CLI JavaScript without a separately installed Node.
      return { command: node, prefix: [script], runAsNode: node === process.execPath };
    }
    return { command: candidate, prefix: [], runAsNode: false };
  }
  throw new Error(`${basename} CLI was not found. Install it for this Windows user or choose its executable in Settings.`);
}

export async function makeLaunchConfiguration({ provider, connection, chat, dataDir, platform, env }) {
  const cli = await resolveCLI(provider, { executable: connection.executable, platform, env });
  const childEnv = { ...env };
  for (const key of Object.keys(childEnv)) {
    if (SECRET_ENV.some(name => name.toLowerCase() === key.toLowerCase()) || key.toUpperCase().startsWith('CLAUDE_CODE_USE_') ||
        ['ELECTRON_RUN_AS_NODE', 'NODE_OPTIONS', 'CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CONFIG_DIR',
          'CLAUDE_CODE_EFFORT_LEVEL', 'CLAUDE_CODE_EXTRA_BODY', 'CODEX_HOME'].includes(key.toUpperCase())) delete childEnv[key];
  }
  if (cli.runAsNode) childEnv.ELECTRON_RUN_AS_NODE = '1';
  for (const key of ['BEDROCK', 'VERTEX', 'FOUNDRY', 'ANTHROPIC_AWS', 'ANTHROPIC_GOOGLE_CLOUD', 'MANTLE', 'GATEWAY']) childEnv[`CLAUDE_CODE_USE_${key}`] = '0';
  const args = [...cli.prefix];
  if (provider === 'claude') {
    const configurationDirectory = path.join(dataDir, 'claude');
    await mkdir(configurationDirectory, { recursive: true, mode: 0o700 });
    childEnv.CLAUDE_CONFIG_DIR = configurationDirectory;
    childEnv[connection.useBearerToken ? 'ANTHROPIC_AUTH_TOKEN' : 'ANTHROPIC_API_KEY'] = connection.apiKey;
    childEnv.ANTHROPIC_BASE_URL = connection.baseURL || 'https://api.anthropic.com';
    args.push('--setting-sources', '', '--settings', '{"apiKeyHelper":""}', '--print', '--input-format', 'stream-json',
      '--output-format', 'stream-json', '--verbose', '--include-partial-messages', '--permission-prompt-tool', 'stdio', '--dangerously-skip-permissions');
    if (chat.conversationID) args.push('--resume', chat.conversationID);
  } else {
    childEnv.CODEX_HOME = path.join(dataDir, 'codex');
    await mkdir(childEnv.CODEX_HOME, { recursive: true, mode: 0o700 });
    childEnv.THEALL_OPENAI_API_KEY = connection.apiKey;
    args.push('--no-daemon');
    const overrides = { model_provider: 'theall', 'model_providers.theall.name': 'OpenAI',
      'model_providers.theall.base_url': connection.baseURL || 'https://api.openai.com/v1',
      'model_providers.theall.env_key': 'THEALL_OPENAI_API_KEY', 'model_providers.theall.wire_api': 'responses',
      'model_providers.theall.requires_openai_auth': false, approval_policy: 'never', sandbox_mode: 'danger-full-access' };
    for (const [key, value] of Object.entries(overrides)) args.push('-c', `${key}=${JSON.stringify(value)}`);
  }
  if (chat.model) args.push('--model', chat.model);
  if (provider === 'openai') args.push('app-server', '--listen', 'stdio://');
  return { command: cli.command, args, env: childEnv };
}

function backendError(message) { return Object.assign(new Error(message), { code: 'backend_rejected' }); }
function uncertain(error) { error.code = 'submission_uncertain'; return error; }
function imageMetadata(image) { const { data, path: file, ...metadata } = image; return metadata; }

/** Owns one long-lived Claude Code or Codex process. The caller persists `chat` on change. */
export class AISession extends EventEmitter {
  constructor({ chat, connection, dataDir, spawnImpl = spawn, platform = process.platform, env = process.env, timeout = TIMEOUT, now = Date.now, elapsedNow = () => performance.now() }) {
    super();
    this.chat = chat;
    this.connection = connection;
    this.dataDir = dataDir;
    this.spawnImpl = spawnImpl;
    this.platform = platform;
    this.env = { ...env };
    this.timeout = timeout; this.now = now; this.elapsedNow = elapsedNow; this.turnTiming = null; this.turnInterrupted = false;
    this.isReady = false; this.isBusy = false; this.canInterrupt = false;
    this.questions = []; this.error = null; this.models = [];
    this.chat.messages ||= []; this.chat.model ||= '';
    this.child = null; this.stopped = true; this.generation = 0;
    this.responses = new Map(); this.questionReplies = new Map(); this.writes = new Set();
    this.queuedBytes = 0; this.buffer = ''; this.decoder = new StringDecoder('utf8'); this.stderr = '';
    this.deferred = []; this.deferredBytes = 0; this.pendingSubmission = false;
    this.thinkingStart = chat.messages.length; this.turnID = null; this.defaultModel = null;
    this.completionToken = null; this.completedClaudeResults = new Set();
    this.appliedModel = chat.model; this.turnModel = chat.model; this.appliedReasoningEffort = chat.provider === 'openai' ? chat.codexAppliedReasoningEffort || '' : undefined;
    this.streamed = new Set(); this.streamedThoughts = new Set(); this.thoughtCounts = new Map();
    this.stopReasons = new Map(); this.phases = new Map(); this.reasoning = new Map(); this.messageID = '';
  }

  redact(value) {
    const secret = this.connection.apiKey;
    return secret ? String(value).split(secret).join('••••') : String(value);
  }

  changed() { this.emit('change'); }

  async start() {
    if (this.isReady) return;
    if (this.starting) return this.starting;
    this.starting = this.initialize().finally(() => { this.starting = null; });
    return this.starting;
  }

  async initialize() {
    if (this.chat.messages.length && !this.chat.conversationID) throw new Error('The saved provider session ID is missing. History is preserved; start a new conversation to continue.');
    const generation = ++this.generation;
    this.error = null; this.stopped = false;
    try {
      await this.termination;
      if (this.generation !== generation || this.stopped) throw new Error('Connection closed.');
      const launch = await makeLaunchConfiguration({ provider: this.chat.provider, connection: this.connection,
        chat: this.chat, dataDir: this.dataDir, platform: this.platform, env: this.env });
      if (this.generation !== generation || this.stopped) throw new Error('Connection closed.');
      this.buffer = ''; this.decoder = new StringDecoder('utf8'); this.stderr = '';
      this.child = this.spawnImpl(launch.command, launch.args, { cwd: this.chat.directory, env: launch.env,
        stdio: ['pipe', 'pipe', 'pipe'], shell: false, windowsHide: true });
      const child = this.child;
      child.stdout.on('data', data => {
        if (this.generation !== generation || this.stopped) return;
        this.buffer += this.decoder.write(data);
        if (Buffer.byteLength(this.buffer) > MAX_FRAME) return this.fail(new Error('The AI process returned an oversized message.'), true);
        let end;
        while ((end = this.buffer.indexOf('\n')) !== -1) {
          const line = this.buffer.slice(0, end).trim(); this.buffer = this.buffer.slice(end + 1);
          if (!line) continue;
          try { this.receive(JSON.parse(line)); } catch (error) { this.fail(error, true); break; }
        }
      });
      child.stderr.on('data', data => { if (this.generation === generation) this.stderr = (this.stderr + data.toString()).slice(-16_000); });
      child.stdin.on('error', error => { if (this.generation === generation && !this.stopped) this.fail(error, true); });
      child.on('error', error => { if (this.generation === generation && !this.stopped) this.fail(error, true); });
      child.on('close', (code, signal) => {
        if (this.generation !== generation || this.stopped) return;
        this.child = null;
        const message = this.stderr.trim() || `The AI process exited (${signal || code}). Reconnect to continue this conversation.`;
        this.fail(new Error(message), true);
      });
      if (this.chat.provider === 'claude') {
        const initialized = await this.control('initialize', { hooks: null });
        this.models = mergeModelCatalog([], (initialized.models || []).filter(m => typeof m.value === 'string').map(m => ({ id: m.value === 'default' ? '' : m.value, title: m.displayName || m.value, ...modelCapabilities(m, 'claude') })));
        if (!this.models.length) this.models = ['default', 'sonnet', 'opus', 'haiku'].map(id => ({ id: id === 'default' ? '' : id, title: id === 'default' ? 'Default' : id, reasoningEfforts: [] }));
        this.appliedReasoningEffort = undefined;
      } else {
        await this.rpc('initialize', { clientInfo: { name: 'theall', title: 'TheAll', version: APP_VERSION } });
        await this.write({ method: 'initialized' });
        try {
          const list = await this.rpc('model/list', { limit: 100 });
          this.models = (list.data || []).filter(m => typeof m.model === 'string').map(m => ({ id: m.model, title: m.displayName || m.model, ...modelCapabilities(m, 'openai') }));
          this.defaultModel = list.data?.find(m => m.isDefault)?.model || this.models[0]?.id;
        } catch (error) { if (error.code !== 'backend_rejected') throw error; }
        const resume = this.chat.conversationID;
        const params = { cwd: this.chat.directory, modelProvider: 'theall', approvalPolicy: 'never', sandbox: 'danger-full-access' };
        if (this.chat.model) params.model = this.chat.model;
        if (resume) { params.threadId = resume; params.excludeTurns = true; }
        const result = await this.rpc(resume ? 'thread/resume' : 'thread/start', params);
        if (typeof result.thread?.id !== 'string' || (resume && result.thread.id !== resume)) throw new Error('The AI process returned a different conversation. Saved history was preserved.');
        this.chat.conversationID = result.thread.id;
        this.defaultModel ||= result.model;
      }
      if (this.generation !== generation || this.stopped) throw new Error('Connection closed.');
      this.isReady = true; this.appliedModel = this.chat.model; this.changed();
    } catch (error) {
      if (this.generation === generation && !this.stopped) this.fail(error, true);
      throw Object.assign(new Error(this.redact(error.message)), { code: error.code });
    }
  }

  async write(message) {
    if (this.stopped || !this.child?.stdin?.writable) throw new Error('The AI process is not connected.');
    const data = JSON.stringify(message) + '\n';
    const size = Buffer.byteLength(data);
    if (size > MAX_FRAME || this.queuedBytes + size > MAX_QUEUED) throw new Error('The AI input queue is full.');
    const generation = this.generation;
    this.queuedBytes += size;
    return new Promise((resolve, reject) => {
      let finished = false;
      const finish = error => {
        if (finished) return;
        finished = true; clearTimeout(timer); this.writes.delete(finish); this.queuedBytes -= size;
        error ? reject(error) : resolve();
      };
      const timer = setTimeout(() => { const error = new Error('Timed out writing to the AI process.'); finish(error); this.fail(error, true); }, this.timeout);
      timer.unref?.();
      this.writes.add(finish);
      try {
        this.child.stdin.write(data, error => finish(error || (this.stopped || generation !== this.generation ? new Error('Connection closed while writing.') : undefined)));
      } catch (error) { finish(error); }
    });
  }

  request(message, id) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.responses.delete(id);
        const error = new Error('The AI process did not respond in time.');
        reject(error); this.fail(error, true);
      }, this.timeout);
      timer.unref?.();
      this.responses.set(id, { resolve, reject, timer });
      this.write(message).catch(error => { const pending = this.responses.get(id); if (!pending) return; clearTimeout(timer); this.responses.delete(id); reject(error); });
    });
  }

  control(subtype, fields = {}) {
    const id = randomUUID();
    return this.request({ type: 'control_request', request_id: id, request: { subtype, ...fields } }, id);
  }

  rpc(method, params) {
    const id = randomUUID();
    return this.request({ id, method, params }, id);
  }

  complete(id, result, error) {
    const pending = this.responses.get(String(id));
    if (!pending) return false;
    this.responses.delete(String(id)); clearTimeout(pending.timer);
    error ? pending.reject(backendError(this.redact(error))) : pending.resolve(result || {});
    return true;
  }

  async send({ text = '', images = [], model = this.chat.model, reasoningEffort = this.chat.reasoningEffort || '', stillAuthorized = () => true }) {
    const generation = this.generation;
    const requireAuthorization = () => {
      if (this.generation !== generation || this.stopped || !this.isReady) throw new Error('Connection closed before the message was sent.');
      if (!stillAuthorized()) throw Object.assign(new Error('This device is no longer authorized.'), { code: 'authorization_revoked' });
    };
    requireAuthorization();
    if (!this.isReady || this.isBusy || this.questions.length) throw new Error('This conversation is not ready for another message.');
    if (typeof text !== 'string' || Buffer.byteLength(text) > 128 * 1024 || (!text.trim() && !images.length)) throw new Error('Enter a message or attach an image.');
    if (images.length > 4 || new Set(images.map(i => i.id)).size !== images.length) throw new Error('Attach up to four different images.');
    if (typeof model !== 'string' || model.length > 256 || /[\0\r\n]/.test(model)) throw new Error('Invalid model.');
    reasoningEffort = selectedReasoningEffort(this.models, model, reasoningEffort, this.defaultModel);
    const codexEffort = reasoningEffort || this.models.find(m => m.id === (model || this.defaultModel))?.defaultReasoningEffort || null;
    if (this.chat.provider === 'openai' && !codexEffort && this.appliedReasoningEffort) throw new Error('The default thinking level for this model is unknown. Choose a model with published thinking levels before resetting to Default.');
    const input = [];
    for (const image of images) {
      if (!image.path || !['image/jpeg', 'image/png'].includes(image.mimeType)) throw new Error('An image is unavailable.');
      const bytes = await readFile(image.path);
      if (!bytes.length || bytes.length > 2 * 1024 * 1024) throw new Error('An image is unavailable.');
      input.push(this.chat.provider === 'claude' ? { type: 'image', source: { type: 'base64', media_type: image.mimeType, data: bytes.toString('base64') } } : { type: 'localImage', path: image.path });
    }
    if (text) input.unshift({ type: 'text', text });
    // Awaiting file reads may allow another sender to win admission.
    requireAuthorization();
    if (!this.isReady || this.isBusy || this.questions.length) throw new Error('This conversation is not ready for another message.');
    this.isBusy = true; this.error = null; this.turnModel = model;
    this.turnAppliedEffort = null; this.turnEffortVerified = false;
    this.chat.model = model; this.chat.reasoningEffort = reasoningEffort; this.thinkingStart = this.chat.messages.length;
    this.changed();
    let written = false;
    const previousCodexEffort = this.chat.codexAppliedReasoningEffort;
    try {
      if (this.chat.provider === 'claude') {
        if (this.appliedModel !== model) { await this.control('set_model', { model: model || null }); this.appliedModel = model; }
        requireAuthorization();
        await this.control('apply_flag_settings', { settings: { effortLevel: reasoningEffort || null } });
        requireAuthorization();
        const settings = await this.control('get_settings').catch(error => {
          if (error.code === 'backend_rejected' && /Unsupported control request.*get_settings/.test(error.message)) {
            throw backendError('Claude Code could not confirm the thinking level. Update Claude Code and reconnect. Your draft was kept.');
          }
          throw error;
        });
        const actual = settings.applied?.effort;
        if (actual !== null && (typeof actual !== 'string' || !/^[a-z]{1,32}$/.test(actual))) {
          throw backendError('Claude Code could not confirm the thinking level. Update Claude Code and reconnect. Your draft was kept.');
        }
        if (reasoningEffort && actual !== reasoningEffort) {
          throw backendError(`Claude Code applied ${actual ?? 'an unknown thinking level'} instead of ${reasoningEffort}. Check its effort limits or choose a supported level. Your draft was kept.`);
        }
        this.turnAppliedEffort = actual; this.turnEffortVerified = typeof actual === 'string';
        requireAuthorization();
        this.pendingSubmission = true;
        written = true;
        await this.write({ type: 'user', message: { role: 'user', content: images.length ? input : text }, parent_tool_use_id: null, session_id: this.chat.conversationID || '' });
        this.appendUser(text, images); this.canInterrupt = true;
      } else {
        if (!this.chat.conversationID || (!model && !this.defaultModel)) throw new Error('No model is available for this connection.');
        requireAuthorization();
        this.pendingSubmission = true;
        written = true;
        // A lost ACK may still have applied this override in the provider thread.
        this.chat.codexAppliedReasoningEffort = codexEffort || ''; this.appliedReasoningEffort = codexEffort;
        this.turnAppliedEffort = codexEffort;
        const result = await this.rpc('turn/start', { threadId: this.chat.conversationID, cwd: this.chat.directory,
          approvalPolicy: 'never', sandboxPolicy: { type: 'dangerFullAccess' }, model: model || this.defaultModel, effort: codexEffort, input });
        this.turnID = result.turn?.id || null; this.appliedReasoningEffort = codexEffort;
        this.appendUser(text, images); this.canInterrupt = true;
      }
      const deferred = this.deferred;
      this.pendingSubmission = false; this.deferred = []; this.deferredBytes = 0;
      for (const message of deferred) this.receive(message);
      this.changed();
      return { accepted: true };
    } catch (error) {
      if (this.chat.provider === 'openai' && error.code === 'backend_rejected') {
        if (previousCodexEffort === undefined) delete this.chat.codexAppliedReasoningEffort; else this.chat.codexAppliedReasoningEffort = previousCodexEffort;
        this.appliedReasoningEffort = previousCodexEffort || '';
      }
      this.pendingSubmission = false; this.deferred = []; this.deferredBytes = 0;
      if (written && error.code !== 'backend_rejected') {
        if (!this.chat.messages.slice(this.thinkingStart).some(m => m.role === 'user')) this.appendUser(text, images);
        error = uncertain(error);
      }
      this.fail(error, written && error.code !== 'backend_rejected');
      throw Object.assign(new Error(this.redact(error.message)), { code: error.code });
    }
  }

  appendUser(text, images) {
    const id = randomUUID(); this.completionToken = id;
    this.turnTiming = { started: this.elapsedNow() }; this.turnInterrupted = false;
    this.chat.messages.push({ id, role: 'user', text: this.redact(text), model: this.turnModel,
      isError: false, isIntermediate: false, images: images.map(imageMetadata) });
    this.emit('submitted', text); this.changed();
  }

  async interrupt() {
    if (!this.isBusy || !this.canInterrupt) return false;
    this.completionToken = null; this.turnInterrupted = true;
    if (this.chat.provider === 'claude') await this.control('interrupt');
    else {
      if (!this.turnID) throw new Error('The turn is still starting. Try stopping again shortly.');
      await this.rpc('turn/interrupt', { threadId: this.chat.conversationID, turnId: this.turnID });
    }
    return true;
  }

  async answer({ approvalId, answers = {}, allow = true }) {
    const reply = this.questionReplies.get(String(approvalId));
    if (!reply) throw new Error('This question is no longer pending.');
    if (!answers || typeof answers !== 'object' || Array.isArray(answers) || Object.values(answers).some(value => !Array.isArray(value) || value.some(v => typeof v !== 'string' || v.length > 16_384))) throw new Error('Invalid answers.');
    await reply(allow, answers);
    this.removeQuestion(String(approvalId)); this.changed(); return true;
  }

  removeQuestion(id) { this.questions = this.questions.filter(q => q.id !== id); this.questionReplies.delete(id); }

  finishTurn(status) {
    if (this.turnTiming && status) {
      const messages = this.chat.messages.slice(this.thinkingStart);
      const answer = messages.findLast(m => m.role === 'assistant' && !m.isIntermediate) || messages.findLast(m => m.role === 'assistant');
      if (answer) {
        answer.completedAt = new Date(this.now()).toISOString();
        answer.durationMs = Math.max(0, Math.round(this.elapsedNow() - this.turnTiming.started));
        answer.completionStatus = this.turnInterrupted ? 'interrupted' : status;
        if (this.turnAppliedEffort) {
          answer.reasoningEffort = this.turnAppliedEffort;
          answer.reasoningEffortVerified = this.turnEffortVerified;
        }
      }
    }
    this.turnTiming = null; this.completionToken = null; this.isBusy = false; this.canInterrupt = false;
    this.turnID = null; this.questions = []; this.questionReplies.clear();
  }

  fail(error, disconnect = false) {
    this.error = this.redact(error?.message || error);
    this.finishTurn('failed');
    if (disconnect) {
      this.isReady = false; this.stopped = true;
      this.buffer = ''; this.deferred = []; this.deferredBytes = 0;
      for (const pending of this.responses.values()) { clearTimeout(pending.timer); pending.reject(new Error(this.error)); }
      this.responses.clear();
      for (const finish of [...this.writes]) finish(new Error(this.error));
      this.terminate();
    }
    this.changed();
  }

  terminate() {
    const child = this.child;
    this.child = null;
    if (!child) return this.termination || Promise.resolve();
    this.termination = new Promise(resolve => {
      let finished = false;
      const finish = () => { if (finished) return; finished = true; clearTimeout(timeout); clearTimeout(force); resolve(); };
      const timeout = setTimeout(finish, 3000);
      const force = setTimeout(() => { try { child.kill('SIGKILL'); } catch { /* Already closed. */ } }, 1000);
      const windowsTree = this.platform === 'win32' && child.pid && this.spawnImpl === spawn;
      if (!windowsTree) child.once('close', finish);
      try { child.stdin.end(); } catch { /* Already closed. */ }
      if (windowsTree) {
        // Windows has no POSIX process-group kill. Terminate only the owned PID tree.
        const systemRoot = environmentValue(this.env, 'SystemRoot') || 'C:\\Windows';
        const killer = spawn(path.join(systemRoot, 'System32', 'taskkill.exe'), ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, shell: false, stdio: 'ignore' });
        killer.once('close', finish);
        killer.once('error', () => { child.once('close', finish); try { child.kill(); } catch { finish(); } });
      } else { try { child.kill(); } catch { finish(); } }
    });
    return this.termination;
  }

  async close() {
    this.stopped = true; this.generation++;
    this.isReady = false; this.finishTurn('interrupted');
    const error = new Error('Connection closed.');
    for (const pending of this.responses.values()) { clearTimeout(pending.timer); pending.reject(error); }
    this.responses.clear();
    for (const finish of [...this.writes]) finish(error);
    this.deferred = []; this.deferredBytes = 0; this.pendingSubmission = false;
    await this.terminate(); this.changed();
  }

  update(id, role, text, { append = false, isError = false } = {}) {
    if (!id) return;
    let message = this.chat.messages.find(m => m.id === id);
    if (!message) {
      message = { id, role, text: '', model: this.turnModel, isError: false, isIntermediate: false, images: [] };
      this.chat.messages.push(message);
    }
    message.text = this.redact(append ? message.text + text : text);
    message.isError ||= isError;
  }

  trailingAnswers() {
    const messages = this.chat.messages.slice(this.thinkingStart);
    const lastTool = messages.findLastIndex(m => m.role === 'tool');
    return new Set(messages.slice(lastTool + 1).filter(m => m.role === 'assistant' && m.text.trim() && !m.isError &&
      this.phases.get(m.id) !== 'commentary' && !['tool_use', 'max_tokens'].includes(this.stopReasons.get(m.id))).map(m => m.id));
  }

  collapse(answers) {
    if (!answers.size) return;
    for (const message of this.chat.messages.slice(this.thinkingStart)) {
      if (!message.isError && (message.role === 'thinking' || (message.role === 'assistant' && !answers.has(message.id)))) message.isIntermediate = true;
    }
  }

  completeClaude(result) {
    if (result.is_error || (result.subtype && result.subtype !== 'success') || (result.terminal_reason && result.terminal_reason !== 'completed') ||
      (result.stop_reason && !['end_turn', 'stop_sequence'].includes(result.stop_reason))) return;
    let answers = this.trailingAnswers();
    if (typeof result.result === 'string' && result.result.trim()) {
      const finalText = this.redact(result.result);
      const candidates = this.chat.messages.slice(this.thinkingStart).filter(m => m.role === 'assistant');
      const match = candidates.findLast(m => m.text.trim() === finalText.trim());
      if (match) answers = new Set([match.id]);
      else if (candidates.filter(m => answers.has(m.id)).map(m => m.text).join('\n\n') !== finalText) {
        const last = candidates.at(-1);
        const id = last && answers.has(last.id) && last.text && finalText.startsWith(last.text) ? last.id : 'result-' + randomUUID();
        this.update(id, 'assistant', finalText); answers = new Set([id]);
      }
    }
    this.collapse(answers);
  }

  receive(message) {
    if (!message || typeof message !== 'object' || Array.isArray(message)) throw new Error('Invalid AI protocol message.');
    if (this.chat.provider === 'claude' && message.type === 'control_response') {
      const response = message.response || {};
      this.complete(response.request_id, response.response, response.subtype === 'error' ? response.error || 'AI request failed.' : null); return;
    }
    if (this.chat.provider === 'openai' && !message.method && Object.hasOwn(message, 'id')) {
      this.complete(message.id, message.result, message.error ? message.error.message || 'AI request failed.' : null); return;
    }
    const serverRequest = this.chat.provider === 'claude'
      ? ['control_request', 'control_cancel_request'].includes(message.type)
      : (message.method && Object.hasOwn(message, 'id')) || message.method === 'serverRequest/resolved';
    if (this.pendingSubmission && !serverRequest) {
      const bytes = Buffer.byteLength(JSON.stringify(message));
      if (this.deferredBytes + bytes > MAX_FRAME) throw new Error('Too much AI output arrived before submission was acknowledged.');
      this.deferred.push(message); this.deferredBytes += bytes; return;
    }
    this.chat.provider === 'claude' ? this.receiveClaude(message) : this.receiveCodex(message);
    this.changed();
  }

  reply(message) { this.write(message).catch(error => this.fail(error, true)); }

  receiveClaude(message) {
    switch (message.type) {
      case 'control_request': {
        const id = message.request_id, request = message.request || {}, input = request.input || {};
        if (typeof id !== 'string') return;
        const respond = response => this.write({ type: 'control_response', response: { subtype: 'success', request_id: id, response } });
        if (request.subtype !== 'can_use_tool') return this.reply({ type: 'control_response', response: { subtype: 'error', request_id: id, error: 'Unsupported control request' } });
        if (request.tool_name !== 'AskUserQuestion') { respond({ behavior: 'allow', updatedInput: input }).catch(error => this.fail(error, true)); return; }
        const questions = (input.questions || []).filter(q => typeof q.question === 'string').map(q => ({ id: q.question, prompt: q.question,
          options: (q.options || []).map(o => o.label).filter(x => typeof x === 'string'), multiple: !!q.multiSelect, secret: false }));
        if (!questions.length) return this.reply({ type: 'control_response', response: { subtype: 'error', request_id: id, error: 'No supported questions' } });
        this.removeQuestion(id); this.questions.push({ id, title: 'Question', questions });
        this.questionReplies.set(id, (allow, answers) => respond(allow ? { behavior: 'allow', updatedInput: { ...input, answers: Object.fromEntries(Object.entries(answers).map(([k, v]) => [k, v.join(', ')])) } } : { behavior: 'deny', message: 'The user declined this operation.' }));
        break;
      }
      case 'control_cancel_request': this.removeQuestion(message.request_id); break;
      case 'system':
        if (typeof message.session_id === 'string') this.chat.conversationID = message.session_id;
        if (message.subtype === 'init' && typeof message.model === 'string') this.defaultModel = message.model;
        break;
      case 'stream_event': {
        const event = message.event || {};
        if (typeof message.api_message_id === 'string') this.messageID = message.api_message_id;
        if (event.type === 'message_start' && event.message?.id) this.messageID = event.message.id;
        if (event.delta?.stop_reason) this.stopReasons.set(this.messageID, event.delta.stop_reason);
        if (event.delta?.type === 'text_delta' && typeof event.delta.text === 'string') {
          this.streamed.add(this.messageID); this.update(this.messageID, 'assistant', event.delta.text, { append: true });
        }
        const id = `thinking-${this.messageID}-${event.index || 0}`;
        if (event.delta?.type === 'thinking_delta' && typeof event.delta.thinking === 'string') {
          this.streamedThoughts.add(this.messageID); this.update(id, 'thinking', event.delta.thinking, { append: true });
        } else if (event.type === 'content_block_start' && event.content_block?.type === 'thinking' && event.content_block.thinking) {
          this.streamedThoughts.add(this.messageID); this.update(id, 'thinking', event.content_block.thinking);
        }
        break;
      }
      case 'assistant': {
        const body = message.message || {}, id = body.id;
        if (!id || !Array.isArray(body.content)) return;
        if (body.stop_reason) this.stopReasons.set(id, body.stop_reason);
        const text = body.content.filter(b => b.type === 'text').map(b => b.text || '').join('\n');
        if (text && !this.streamed.has(id)) this.update(id, 'assistant', text);
        for (const block of body.content) {
          if (block.type === 'thinking' && block.thinking && !this.streamedThoughts.has(id)) {
            const index = this.thoughtCounts.get(id) || 0; this.thoughtCounts.set(id, index + 1);
            this.update(`thinking-${id}-${index}`, 'thinking', block.thinking);
          } else if (block.type === 'tool_use') this.update(block.id, 'tool', `${block.name || 'Tool'}\n${JSON.stringify(block.input || {})}`);
        }
        break;
      }
      case 'user':
        for (const block of (Array.isArray(message.message?.content) ? message.message.content : [])) {
          if (block.type === 'tool_result' && block.tool_use_id) this.update(block.tool_use_id, 'tool', '\n' + (typeof block.content === 'string' ? block.content : JSON.stringify(block.content || [])).slice(-30_000), { append: true, isError: !!block.is_error });
        }
        break;
      case 'result': {
        if (message.parent_tool_use_id != null) return;
        if (!this.turnTiming) {
          if (message.is_error) this.error = this.redact(message.errors?.join('\n') || message.result || 'The AI request failed.');
          return;
        }
        if (typeof message.uuid === 'string') {
          if (this.completedClaudeResults.has(message.uuid)) return;
          this.completedClaudeResults.add(message.uuid);
          if (this.completedClaudeResults.size > 4096) this.completedClaudeResults.delete(this.completedClaudeResults.values().next().value);
        }
        if (typeof message.session_id === 'string') this.chat.conversationID = message.session_id;
        if (message.is_error) this.error = this.redact(message.errors?.join('\n') || message.result || 'The AI request failed.');
        const token = this.completionToken;
        const success = message.subtype === 'success' && !message.is_error
          && (!message.terminal_reason || message.terminal_reason === 'completed')
          && (!message.stop_reason || ['end_turn', 'stop_sequence'].includes(message.stop_reason));
        this.completeClaude(message); this.finishTurn(success ? 'completed' : 'failed');
        if (token && success) this.emit('completed', { id: token, chatId: this.chat.id });
        break;
      }
      default: break;
    }
  }

  receiveCodex(message) {
    const method = message.method, params = message.params || {};
    if (!method) return;
    if (Object.hasOwn(message, 'id')) {
      const requestID = message.id, id = String(requestID);
      if (['item/commandExecution/requestApproval', 'item/fileChange/requestApproval'].includes(method)) return this.reply({ id: requestID, result: { decision: 'accept' } });
      if (['execCommandApproval', 'applyPatchApproval'].includes(method)) return this.reply({ id: requestID, result: { decision: 'approved' } });
      if (method === 'item/permissions/requestApproval') return this.reply({ id: requestID, result: { permissions: params.permissions || {}, scope: 'turn' } });
      if (method === 'item/tool/requestUserInput') {
        const questions = (params.questions || []).filter(q => typeof q.id === 'string' && typeof q.question === 'string').map(q => ({ id: q.id, prompt: q.question,
          options: (q.options || []).map(o => o.label).filter(x => typeof x === 'string'), multiple: false, secret: !!q.isSecret }));
        if (!questions.length) return this.reply({ id: requestID, error: { code: -32602, message: 'No supported questions' } });
        this.removeQuestion(id); this.questions.push({ id, title: 'Question', questions });
        this.questionReplies.set(id, (allow, answers) => this.write({ id: requestID, result: { answers: Object.fromEntries(Object.entries(allow ? answers : {}).map(([k, v]) => [k, { answers: v }])) } }));
        return;
      }
      return this.reply({ id: requestID, error: { code: -32601, message: 'Unsupported request: ' + method } });
    }
    if (method !== 'serverRequest/resolved' && params.threadId && this.chat.conversationID && params.threadId !== this.chat.conversationID) return;
    switch (method) {
      case 'turn/started':
        if (!this.turnTiming) return;
        if (this.turnTiming && this.turnID && typeof params.turn?.id === 'string' && params.turn.id !== this.turnID) return;
        if (!this.isBusy) this.thinkingStart = this.chat.messages.length;
        this.turnID = params.turn?.id || this.turnID; this.isBusy = true; this.canInterrupt = true; break;
      case 'serverRequest/resolved': this.removeQuestion(String(params.requestId)); break;
      case 'item/agentMessage/delta': this.update(params.itemId, 'assistant', params.delta || '', { append: true }); break;
      case 'item/reasoning/summaryTextDelta': case 'item/reasoning/textDelta': {
        let parts = this.reasoning.get(params.itemId);
        if (!parts) { parts = { summary: [], content: [] }; this.reasoning.set(params.itemId, parts); }
        const values = method.includes('summaryText') ? parts.summary : parts.content;
        const index = params.summaryIndex ?? params.contentIndex ?? 0;
        if (!Number.isInteger(index) || index < 0 || index > 1000) return;
        values[index] = (values[index] || '') + (params.delta || '');
        this.update(params.itemId, 'thinking', (parts.summary.some(Boolean) ? parts.summary : parts.content).filter(Boolean).join('\n\n')); break;
      }
      case 'item/started': case 'item/completed': {
        const item = params.item || {};
        if (!item.id) return;
        if (item.type === 'agentMessage') {
          if (['commentary', 'partial_answer', 'final_answer'].includes(item.phase)) this.phases.set(item.id, item.phase);
          if (item.text) this.update(item.id, 'assistant', item.text);
        } else if (item.type === 'reasoning') {
          const parts = this.reasoning.get(item.id) || { summary: [], content: [] };
          if (item.summary?.length) parts.summary = item.summary;
          if (item.content?.length) parts.content = item.content;
          this.reasoning.set(item.id, parts);
          this.update(item.id, 'thinking', (parts.summary.length ? parts.summary : parts.content).join('\n\n'));
        } else if (item.type === 'commandExecution') this.update(item.id, 'tool', ((item.command || '') + '\n' + (item.aggregatedOutput || '')).slice(-30_000), { isError: item.status === 'failed' || (item.exitCode != null && item.exitCode !== 0) });
        else if (['fileChange', 'mcpToolCall'].includes(item.type)) this.update(item.id, 'tool', JSON.stringify(item).slice(-30_000), { isError: item.status === 'failed' });
        break;
      }
      case 'turn/completed': {
        if (!this.turnTiming) return;
        const turn = params.turn || {};
        if (this.turnTiming && this.turnID && typeof turn.id === 'string' && turn.id !== this.turnID) return;
        const token = this.completionToken && typeof turn.id === 'string' && turn.id === this.turnID ? this.completionToken : null;
        if (turn.error) this.error = this.redact(turn.error.message || 'The AI request failed.');
        if (turn.status === 'completed' && !turn.error) {
          for (const item of turn.items || []) this.receiveCodex({ method: 'item/completed', params: { item } });
          const answers = this.trailingAnswers();
          for (const message of this.chat.messages.slice(this.thinkingStart)) if (message.role === 'assistant' && ['partial_answer', 'final_answer'].includes(this.phases.get(message.id))) answers.add(message.id);
          this.collapse(answers);
        }
        this.finishTurn(turn.status === 'completed' && !turn.error ? 'completed' : turn.status === 'interrupted' ? 'interrupted' : 'failed');
        if (token && turn.status === 'completed' && !turn.error) this.emit('completed', { id: token, chatId: this.chat.id });
        break;
      }
      case 'error': if (params.error) this.error = this.redact(params.error.message || 'The AI request failed.'); break;
      default: break;
    }
  }
}
