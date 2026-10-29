import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough, Writable } from 'node:stream';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { AISession, resolveCLI, makeLaunchConfiguration } from '../src/ai.mjs';

const tick = () => new Promise(resolve => setImmediate(resolve));
class Child extends EventEmitter {
  constructor(handler) {
    super(); this.stdout = new PassThrough(); this.stderr = new PassThrough(); this.sent = []; this.killed = false;
    this.stdin = new Writable({ write: (chunk, encoding, done) => {
      const message = JSON.parse(chunk.toString()); this.sent.push(message);
      if (handler?.(message, this, done) === false) return;
      done();
    } });
  }
  emitJSON(message) { this.stdout.write(JSON.stringify(message) + '\n'); }
  respond(message, result = {}) {
    if (message.type === 'control_request') this.emitJSON({ type: 'control_response', response: { subtype: 'success', request_id: message.request_id, response: result } });
    else this.emitJSON({ id: message.id, result });
  }
  reject(message, error = 'Rejected') {
    if (message.type === 'control_request') this.emitJSON({ type: 'control_response', response: { subtype: 'error', request_id: message.request_id, error } });
    else this.emitJSON({ id: message.id, error: { code: -1, message: error } });
  }
  kill() { this.killed = true; this.emit('close', 0); }
}

async function fixture(t, provider = 'claude', handler, chatOverrides = {}, options = {}) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'theall-ai-'));
  const executable = path.join(root, process.platform === 'win32' ? 'fake-cli.exe' : 'fake-cli'); await writeFile(executable, '', { mode: 0o700 });
  let launched;
  const child = new Child((message, child, done) => {
    if (handler?.(message, child, done) === false) return false;
    if (message.request?.subtype === 'initialize' || message.request?.subtype === 'apply_flag_settings' || message.method === 'initialize') child.respond(message);
    else if (message.request?.subtype === 'get_settings') {
      const last = child.sent.findLast(m => m.request?.subtype === 'apply_flag_settings');
      child.respond(message, { applied: { effort: last?.request.settings.effortLevel ?? 'medium' } });
    }
    else if (message.method === 'model/list') child.respond(message, { data: [{ model: 'model-a', isDefault: true, displayName: 'Model A' }] });
    else if (['thread/start', 'thread/resume'].includes(message.method)) child.respond(message, { thread: { id: 'thread-1' }, model: 'model-a' });
  });
  const chat = { id: 'chat-1', provider, directory: root, model: 'model-a', messages: [], conversationID: null, ...chatOverrides };
  const session = new AISession({ chat, connection: { apiKey: 'fake-secret-key', baseURL: 'http://127.0.0.1:9000', executable }, dataDir: root,
    spawnImpl: (command, args, options) => { launched = { command, args, options }; return child; }, timeout: 2000, ...options });
  t.after(async () => { await session.close(); await rm(root, { recursive: true, force: true }); });
  return { session, child, chat, root, launch: () => launched };
}

test('Claude handshake isolates credentials and launches without a command shell', async t => {
  const inherited = { ...process.env, ANTHROPIC_AUTH_TOKEN: 'wrong', OPENAI_API_KEY: 'wrong', claude_config_dir: 'wrong', CLAUDE_CODE_USE_VERTEX: '1', CLAUDECODE: '1',
    CLAUDE_CODE_EFFORT_LEVEL: '40', claude_code_extra_body: '{"output_config":{"effort":40}}' };
  const f = await fixture(t, 'claude', null, {}, { env: inherited }); await f.session.start();
  const launch = f.launch();
  assert.equal(launch.options.shell, false); assert.equal(launch.options.windowsHide, true);
  assert.equal(launch.options.env.ANTHROPIC_API_KEY, 'fake-secret-key');
  assert.equal(launch.options.env.ANTHROPIC_AUTH_TOKEN, undefined);
  assert.equal(launch.options.env.OPENAI_API_KEY, undefined);
  assert.equal(launch.options.env.claude_config_dir, undefined);
  assert.equal(launch.options.env.CLAUDE_CODE_USE_VERTEX, '0');
  assert.equal(launch.options.env.CLAUDECODE, undefined);
  assert.equal(launch.options.env.CLAUDE_CODE_EFFORT_LEVEL, undefined);
  assert.equal(launch.options.env.claude_code_extra_body, undefined);
  assert.equal(inherited.CLAUDE_CODE_EFFORT_LEVEL, '40');
  assert.equal(inherited.ANTHROPIC_AUTH_TOKEN, 'wrong');
  assert.ok(!launch.args.join(' ').includes('fake-secret-key'));
  assert.ok(launch.args.includes('--dangerously-skip-permissions')); assert.ok(f.session.isReady);
});

test('Claude model ACK precedes send and a rejected model never sends the prompt', async t => {
  const f = await fixture(t); await f.session.start();
  const promise = f.session.send({ text: 'Keep draft', model: 'model-b' }); await tick();
  const request = f.child.sent.at(-1); assert.equal(request.request.subtype, 'set_model');
  assert.equal(f.child.sent.filter(m => m.type === 'user').length, 0);
  f.child.reject(request, 'bad model'); await assert.rejects(promise, /bad model/);
  assert.equal(f.chat.messages.length, 0); assert.equal(f.session.isBusy, false); assert.equal(f.session.isReady, true);
  const second = f.session.send({ text: 'Retry', model: 'model-b' }); await tick(); f.child.respond(f.child.sent.at(-1)); await second;
  assert.equal(f.child.sent.at(-1).message.content, 'Retry'); assert.equal(f.chat.messages[0].text, 'Retry');
});

test('Claude early streaming output follows accepted user message and preserves final reply', async t => {
  const f = await fixture(t, 'claude', (m, child, done) => {
    if (m.type !== 'user') return;
    child.emitJSON({ type: 'system', session_id: 'session-1' });
    child.emitJSON({ type: 'stream_event', api_message_id: 'reply', event: { delta: { type: 'text_delta', text: 'Hello' } } });
    child.emitJSON({ type: 'assistant', message: { id: 'reply', content: [{ type: 'text', text: 'Hello' }] } });
    child.emitJSON({ type: 'result', subtype: 'success', result: 'Hello', session_id: 'session-1' });
    setImmediate(done); return false;
  });
  await f.session.start(); await f.session.send({ text: 'Hi' });
  assert.deepEqual(f.chat.messages.map(m => [m.role, m.text]), [['user', 'Hi'], ['assistant', 'Hello']]);
  assert.equal(f.chat.conversationID, 'session-1'); assert.equal(f.session.isBusy, false);
});

test('Claude finished intermediate progress collapses while final answer stays visible', async t => {
  const f = await fixture(t); await f.session.start(); await f.session.send({ text: 'Go' });
  f.child.emitJSON({ type: 'assistant', message: { id: 'progress', stop_reason: 'tool_use', content: [{ type: 'text', text: 'Checking files' }, { type: 'thinking', thinking: 'Plan' }, { type: 'tool_use', id: 'tool', name: 'Read', input: {} }] } });
  f.child.emitJSON({ type: 'assistant', message: { id: 'final', stop_reason: 'end_turn', content: [{ type: 'text', text: 'Done' }] } });
  f.child.emitJSON({ type: 'result', subtype: 'success', result: 'Done' });
  assert.equal(f.chat.messages.find(m => m.id === 'progress').isIntermediate, true);
  assert.equal(f.chat.messages.find(m => m.role === 'thinking').isIntermediate, true);
  assert.equal(f.chat.messages.find(m => m.id === 'final').isIntermediate, false);
});

test('Claude error/interruption leaves progress expanded', async t => {
  const f = await fixture(t); await f.session.start(); await f.session.send({ text: 'Go' });
  f.child.emitJSON({ type: 'assistant', message: { id: 'progress', content: [{ type: 'thinking', thinking: 'Plan' }] } });
  f.child.emitJSON({ type: 'result', is_error: true, errors: ['failed fake-secret-key'] });
  assert.equal(f.chat.messages.at(-1).isIntermediate, false); assert.equal(f.session.error, 'failed ••••');
});

test('Claude tools auto-approve unchanged inputs; questions require actual answers', async t => {
  const f = await fixture(t); await f.session.start();
  const input = { command: 'rm example; echo $VAR' };
  f.child.emitJSON({ type: 'control_request', request_id: 'tool', request: { subtype: 'can_use_tool', tool_name: 'Bash', input } });
  await tick(); assert.deepEqual(f.child.sent.at(-1).response.response, { behavior: 'allow', updatedInput: input });
  f.child.emitJSON({ type: 'control_request', request_id: 'question', request: { subtype: 'can_use_tool', tool_name: 'AskUserQuestion', input: { questions: [{ question: 'Choose', multiSelect: true, options: [{ label: 'A' }] }] } } });
  assert.equal(f.session.questions[0].questions[0].multiple, true);
  await f.session.answer({ approvalId: 'question', answers: { Choose: ['A', 'Custom'] } });
  assert.deepEqual(f.child.sent.at(-1).response.response.updatedInput.answers, { Choose: 'A, Custom' });
  assert.equal(f.session.questions.length, 0);
});

test('Claude question cancellation and unknown control request do not hang', async t => {
  const f = await fixture(t); await f.session.start();
  f.child.emitJSON({ type: 'control_request', request_id: 'q', request: { subtype: 'can_use_tool', tool_name: 'AskUserQuestion', input: { questions: [{ question: 'Why?' }] } } });
  f.child.emitJSON({ type: 'control_cancel_request', request_id: 'q' }); assert.equal(f.session.questions.length, 0);
  f.child.emitJSON({ type: 'control_request', request_id: 'unknown', request: { subtype: 'future' } }); await tick();
  assert.equal(f.child.sent.at(-1).response.subtype, 'error');
});

test('Claude streams Unicode across chunk boundaries', async t => {
  const f = await fixture(t); await f.session.start(); await f.session.send({ text: '你好' });
  const bytes = Buffer.from(JSON.stringify({ type: 'assistant', message: { id: 'u', content: [{ type: 'text', text: '好的😊' }] } }) + '\n');
  for (let i = 0; i < bytes.length; i++) f.child.stdout.write(bytes.subarray(i, i + 1));
  assert.equal(f.chat.messages.at(-1).text, '好的😊');
});

test('Codex initialization and turn changes use the original thread and full-auto policy', async t => {
  const f = await fixture(t, 'openai', (m, child) => { if (m.method === 'turn/start') child.respond(m, { turn: { id: 'turn-1' } }); });
  await f.session.start(); assert.equal(f.chat.conversationID, 'thread-1'); assert.deepEqual(f.session.models, [{ id: 'model-a', title: 'Model A', reasoningEfforts: [] }]);
  await f.session.send({ text: 'First', model: 'model-b' });
  const send = f.child.sent.at(-1); assert.equal(send.params.threadId, 'thread-1'); assert.equal(send.params.model, 'model-b');
  assert.equal(send.params.approvalPolicy, 'never'); assert.deepEqual(send.params.sandboxPolicy, { type: 'dangerFullAccess' });
  assert.equal(f.session.canInterrupt, true);
  assert.equal(f.launch().options.env.OPENAI_API_KEY, undefined); assert.equal(f.launch().options.env.THEALL_OPENAI_API_KEY, 'fake-secret-key');
  assert.equal(f.launch().options.env.CODEX_HOME, path.join(f.root, 'codex'));
});

test('Codex buffers pre-ACK notifications and does not duplicate completed items', async t => {
  const f = await fixture(t, 'openai', (m, child) => {
    if (m.method !== 'turn/start') return;
    child.emitJSON({ method: 'item/agentMessage/delta', params: { threadId: 'thread-1', itemId: 'answer', delta: 'Hello' } });
    child.emitJSON({ method: 'turn/completed', params: { threadId: 'thread-1', turn: { id: 'turn-1', status: 'completed', items: [{ id: 'answer', type: 'agentMessage', text: 'Hello', phase: 'final_answer' }] } } });
    child.respond(m, { turn: { id: 'turn-1' } });
  });
  await f.session.start(); await f.session.send({ text: 'Hi' });
  assert.deepEqual(f.chat.messages.map(m => m.text), ['Hi', 'Hello']); assert.equal(f.session.isBusy, false);
});

test('Codex child approvals preserve ID zero, structured questions and resolution', async t => {
  const f = await fixture(t, 'openai'); await f.session.start();
  f.child.emitJSON({ id: 0, method: 'item/commandExecution/requestApproval', params: { threadId: 'child-thread' } }); await tick();
  assert.deepEqual(f.child.sent.at(-1), { id: 0, result: { decision: 'accept' } });
  f.child.emitJSON({ id: 1, method: 'item/permissions/requestApproval', params: { permissions: { network: { enabled: true } } } }); await tick();
  assert.deepEqual(f.child.sent.at(-1).result, { permissions: { network: { enabled: true } }, scope: 'turn' });
  f.child.emitJSON({ id: 2, method: 'item/tool/requestUserInput', params: { threadId: 'child-thread', questions: [{ id: 'q', question: 'Password?', isSecret: true }] } });
  assert.equal(f.session.questions[0].questions[0].secret, true);
  await f.session.answer({ approvalId: '2', answers: { q: ['reply'] } });
  assert.deepEqual(f.child.sent.at(-1), { id: 2, result: { answers: { q: { answers: ['reply'] } } } });
  f.child.emitJSON({ id: 3, method: 'item/tool/requestUserInput', params: { questions: [{ id: 'q', question: 'Again?' }] } });
  f.child.emitJSON({ method: 'serverRequest/resolved', params: { threadId: 'child-thread', requestId: 3 } }); assert.equal(f.session.questions.length, 0);
  f.child.emitJSON({ id: 4, method: 'future/request', params: {} }); await tick(); assert.equal(f.child.sent.at(-1).error.code, -32601);
});

test('Codex ignores child transcript while keeping explicit partial/final answers expanded', async t => {
  const f = await fixture(t, 'openai', (m, child) => { if (m.method === 'turn/start') child.respond(m, { turn: { id: 'turn-1' } }); });
  await f.session.start(); await f.session.send({ text: 'Go' });
  f.child.emitJSON({ method: 'item/completed', params: { threadId: 'child-thread', item: { id: 'other', type: 'agentMessage', text: 'Hidden child' } } });
  for (const [id, phase] of [['comment', 'commentary'], ['partial', 'partial_answer'], ['final', 'final_answer'], ['last-progress', 'commentary']]) f.child.emitJSON({ method: 'item/completed', params: { threadId: 'thread-1', item: { id, type: 'agentMessage', text: id, phase } } });
  f.child.emitJSON({ method: 'turn/completed', params: { threadId: 'thread-1', turn: { status: 'completed' } } });
  assert.ok(!f.chat.messages.some(m => m.id === 'other'));
  for (const id of ['comment', 'last-progress']) assert.equal(f.chat.messages.find(m => m.id === id).isIntermediate, true);
  for (const id of ['partial', 'final']) assert.equal(f.chat.messages.find(m => m.id === id).isIntermediate, false);
});

test('Codex reasoning prefers summary, and tools retain failures', async t => {
  const f = await fixture(t, 'openai'); await f.session.start();
  f.child.emitJSON({ method: 'item/reasoning/textDelta', params: { itemId: 'thought', contentIndex: 0, delta: 'raw' } });
  f.child.emitJSON({ method: 'item/reasoning/summaryTextDelta', params: { itemId: 'thought', summaryIndex: 0, delta: 'summary' } });
  f.child.emitJSON({ method: 'item/completed', params: { item: { id: 'tool', type: 'commandExecution', command: 'test', exitCode: 1, aggregatedOutput: 'failed' } } });
  assert.equal(f.chat.messages[0].text, 'summary'); assert.equal(f.chat.messages[1].isError, true);
});

test('Resume is explicit and mismatched provider IDs fail without clearing saved history', async t => {
  const messages = [{ id: 'saved', role: 'user', text: 'Keep me' }];
  const f = await fixture(t, 'openai', null, { conversationID: 'thread-old', messages });
  await assert.rejects(f.session.start(), /different conversation/);
  assert.deepEqual(f.chat.messages, messages); assert.equal(f.chat.conversationID, 'thread-old');
  assert.equal(f.child.sent.at(-1).method, 'thread/resume'); assert.equal(f.child.sent.at(-1).params.excludeTurns, true);
});

test('Missing provider session never silently drops existing context', async t => {
  const f = await fixture(t, 'claude', null, { messages: [{ id: 'old', role: 'assistant', text: 'Old' }] });
  await assert.rejects(f.session.start(), /session ID is missing/); assert.equal(f.launch(), undefined);
});

test('Claude resume argument and session ID persist across a new process', async t => {
  const f = await fixture(t, 'claude', null, { conversationID: 'saved-session', messages: [{ id: 'old', role: 'user', text: 'Old' }] });
  await f.session.start(); assert.equal(f.launch().args.at(-1), 'model-a'); assert.ok(f.launch().args.includes('saved-session'));
  await f.session.send({ text: 'Continue' }); assert.equal(f.child.sent.at(-1).session_id, 'saved-session');
});

test('Images sent to Claude as base64 and Codex as localImage without duplicating bytes in history', async t => {
  for (const provider of ['claude', 'openai']) {
    const f = await fixture(t, provider, (m, child) => { if (m.method === 'turn/start') child.respond(m, { turn: { id: 't' } }); });
    const file = path.join(f.root, 'photo.png'); await writeFile(file, Buffer.from('fixture-image'));
    const image = { id: 'image-1', name: 'photo.png', mimeType: 'image/png', path: file, data: 'ignored' };
    await f.session.start(); await f.session.send({ text: '', images: [image] });
    if (provider === 'claude') assert.deepEqual(f.child.sent.at(-1).message.content, [{ type: 'image', source: { type: 'base64', media_type: 'image/png', data: Buffer.from('fixture-image').toString('base64') } }]);
    else assert.deepEqual(f.child.sent.at(-1).params.input, [{ type: 'localImage', path: file }]);
    assert.equal(f.chat.messages[0].images[0].data, undefined); assert.equal(f.chat.messages[0].images[0].path, undefined);
  }
});

test('Missing photo rejects before sending text or changing busy state', async t => {
  const f = await fixture(t); await f.session.start(); const count = f.child.sent.length;
  await assert.rejects(f.session.send({ text: 'No silent text only', images: [{ id: 'i', path: path.join(f.root, 'absent'), mimeType: 'image/png' }] }));
  assert.equal(f.child.sent.length, count); assert.equal(f.session.isBusy, false);
});

test('Simultaneous sends admit only one turn', async t => {
  const f = await fixture(t); await f.session.start();
  const results = await Promise.allSettled([f.session.send({ text: 'First' }), f.session.send({ text: 'Second' })]);
  assert.equal(results.filter(r => r.status === 'fulfilled').length, 1); assert.equal(f.child.sent.filter(m => m.type === 'user').length, 1);
});

test('Lost Codex submission acknowledgement is uncertain and never retried', async t => {
  const f = await fixture(t, 'openai', (m, child) => {
    if (m.method === 'turn/start') setImmediate(() => child.emit('close', 1));
  });
  await f.session.start();
  await assert.rejects(f.session.send({ text: 'May have run' }), e => e.code === 'submission_uncertain');
  assert.equal(f.child.sent.filter(m => m.method === 'turn/start').length, 1);
  assert.equal(f.chat.messages.filter(m => m.role === 'user').length, 1); assert.equal(f.session.isReady, false);
});

test('Explicit Codex rejection is safe failure and does not add an accepted user message', async t => {
  const f = await fixture(t, 'openai', (m, child) => { if (m.method === 'turn/start') child.reject(m, 'Model unavailable'); });
  await f.session.start(); await assert.rejects(f.session.send({ text: 'Keep draft' }), e => e.code === 'backend_rejected');
  assert.equal(f.chat.messages.length, 0); assert.equal(f.session.isReady, true);
});

test('Stop calls the backend protocol and preserves the transcript', async t => {
  for (const provider of ['claude', 'openai']) {
    const f = await fixture(t, provider, (m, child) => {
      if (m.method === 'turn/start') child.respond(m, { turn: { id: 't' } });
      if (m.method === 'turn/interrupt' || m.request?.subtype === 'interrupt') child.respond(m);
    });
    await f.session.start(); await f.session.send({ text: 'Go' }); assert.equal(await f.session.interrupt(), true);
    assert.equal(f.chat.messages[0].text, 'Go');
    assert.equal(provider === 'claude' ? f.child.sent.at(-1).request.subtype : f.child.sent.at(-1).method, provider === 'claude' ? 'interrupt' : 'turn/interrupt');
  }
});

test('Malformed stdout disconnects safely and errors redact the API key', async t => {
  const f = await fixture(t); await f.session.start();
  f.child.stdout.write('not JSON fake-secret-key\n');
  assert.equal(f.session.isReady, false); assert.ok(!f.session.error.includes('fake-secret-key')); assert.equal(f.child.killed, true);
});

test('Windows native executable supports spaces and shell metacharacters without interpolation', async t => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'theall-win path & ')); t.after(() => rm(root, { recursive: true, force: true }));
  const file = path.join(root, 'claude.exe'); await writeFile(file, 'fixture');
  const result = await resolveCLI('claude', { platform: 'win32', env: { Path: root } });
  assert.deepEqual(result, { command: file, prefix: [], runAsNode: false });
});

test('Windows npm cmd resolves its fixed JS entry and never executes cmd.exe', async t => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'theall-win npm & ')); t.after(() => rm(root, { recursive: true, force: true }));
  const shim = path.join(root, 'codex.cmd'); await writeFile(shim, 'arbitrary shell text must never run');
  const script = path.join(root, 'node_modules/@openai/codex/bin/codex.js'); await mkdir(path.dirname(script), { recursive: true }); await writeFile(script, '// fixture');
  const node = path.join(root, 'node.exe'); await writeFile(node, 'fixture');
  const result = await resolveCLI('openai', { platform: 'win32', env: { PATH: root } });
  assert.equal(result.command, node); assert.deepEqual(result.prefix, [script]);
});

test('Unknown Windows shell wrapper is rejected, never run with shell:true', async t => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'theall-win-wrap-')); t.after(() => rm(root, { recursive: true, force: true }));
  const file = path.join(root, 'custom.cmd'); await writeFile(file, 'echo nope');
  await assert.rejects(resolveCLI('claude', { executable: file, platform: 'win32', env: {} }), /wrapper is unsupported/);
});

test('Windows mixed-case inherited credentials cannot take priority', async t => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'theall-win-env-')); t.after(() => rm(root, { recursive: true, force: true }));
  const file = path.join(root, 'claude.exe'); await writeFile(file, 'fixture');
  const launch = await makeLaunchConfiguration({ provider: 'claude', connection: { executable: file, apiKey: 'selected' }, chat: { model: '' }, dataDir: root,
    platform: 'win32', env: { anthropic_api_key: 'wrong', Anthropic_Auth_Token: 'wrong', claude_code_use_vertex: '1' } });
  assert.equal(launch.env.anthropic_api_key, undefined); assert.equal(launch.env.Anthropic_Auth_Token, undefined);
  assert.equal(launch.env.ANTHROPIC_API_KEY, 'selected'); assert.equal(launch.env.claude_code_use_vertex, undefined);
});

test('Codex approval arriving before turn ACK is answered without deadlock', async t => {
  let turn;
  const f = await fixture(t, 'openai', (m, child) => {
    if (m.method === 'turn/start') { turn = m; child.emitJSON({ id: 0, method: 'item/commandExecution/requestApproval', params: {} }); }
    if (m.id === 0 && m.result) child.respond(turn, { turn: { id: 'turn-1' } });
  });
  await f.session.start(); await f.session.send({ text: 'Proceed' });
  assert.equal(f.chat.messages[0].text, 'Proceed'); assert.equal(f.session.canInterrupt, true);
});

test('Blocked stdin times out, marks submission uncertain and tears down the child', async t => {
  const f = await fixture(t, 'claude', (m) => { if (m.type === 'user') return false; }, {}, { timeout: 25 });
  await f.session.start();
  const keepAlive = setTimeout(() => {}, 200); t.after(() => clearTimeout(keepAlive));
  await assert.rejects(f.session.send({ text: 'May be written' }), e => e.code === 'submission_uncertain');
  assert.equal(f.child.killed, true); assert.equal(f.session.isReady, false); assert.equal(f.session.queuedBytes, 0);
});

test('Oversized provider output fails safely without allocating an unbounded queue', async t => {
  const f = await fixture(t); await f.session.start();
  f.child.stdout.write('x'.repeat(16 * 1024 * 1024 + 1));
  assert.equal(f.session.isReady, false); assert.match(f.session.error, /oversized/); assert.equal(f.child.killed, true);
});

test('Oversized outgoing JSON is rejected before touching stdin', async t => {
  const f = await fixture(t); await f.session.start(); await tick(); const count = f.child.sent.length;
  await assert.rejects(f.session.write({ text: 'x'.repeat(16 * 1024 * 1024) }), /queue is full/);
  assert.equal(f.child.sent.length, count); assert.equal(f.session.queuedBytes, 0);
});

test('Revocation while Claude model ACK is pending never writes the prompt', async t => {
  const f = await fixture(t); await f.session.start(); let authorized = true;
  const send = f.session.send({ text: 'Must not execute', model: 'next-model', stillAuthorized: () => authorized });
  await tick(); authorized = false; f.child.respond(f.child.sent.at(-1));
  await assert.rejects(send, e => e.code === 'authorization_revoked');
  assert.equal(f.child.sent.filter(m => m.type === 'user').length, 0); assert.equal(f.chat.messages.length, 0);
});

test('Revoked Codex device cannot begin a turn', async t => {
  const f = await fixture(t, 'openai'); await f.session.start();
  await assert.rejects(f.session.send({ text: 'Denied', stillAuthorized: () => false }), e => e.code === 'authorization_revoked');
  assert.equal(f.child.sent.filter(m => m.method === 'turn/start').length, 0);
});

test('Close during asynchronous startup never launches a late process', async t => {
  const f = await fixture(t);
  const start = f.session.start(); const closed = f.session.close();
  await assert.rejects(start, /closed/); await closed;
  assert.equal(f.launch(), undefined); assert.equal(f.session.isReady, false);
});

test('Close during pending model change never submits a stale turn', async t => {
  const f = await fixture(t); await f.session.start();
  const send = f.session.send({ text: 'Must not execute', model: 'next-model' }); await tick();
  const closed = f.session.close(); await assert.rejects(send, /closed/); await closed;
  assert.equal(f.child.sent.filter(m => m.type === 'user').length, 0); assert.equal(f.chat.messages.length, 0);
});

test('Claude successful turn emits one local completion and persists elapsed timing; replay and failures do not notify', async t => {
  let wall = 1_800_000_000_000, elapsed = 10;
  const f = await fixture(t, 'claude', undefined, {}, { now: () => wall, elapsedNow: () => elapsed });
  const completed = []; f.session.on('completed', event => completed.push(event)); await f.session.start();
  await f.session.send({ text: 'First' }); elapsed = 1510; wall += 1500;
  f.child.emitJSON({ type: 'assistant', message: { id: 'final-1', content: [{ type: 'text', text: 'Done' }] } });
  const result = { type: 'result', uuid: 'result-1', subtype: 'success', result: 'Done' };
  f.child.emitJSON(result); f.child.emitJSON(result);
  assert.equal(completed.length, 1); assert.equal(completed[0].id, f.chat.messages[0].id);
  assert.equal(f.chat.messages.at(-1).durationMs, 1500); assert.equal(f.chat.messages.at(-1).completedAt, new Date(wall).toISOString());
  assert.equal(f.chat.messages.at(-1).completionStatus, 'completed');
  await f.session.send({ text: 'Second' }); f.child.emitJSON(result); assert.equal(f.session.isBusy, true);
  f.child.emitJSON({ type: 'assistant', message: { id: 'final-2', content: [{ type: 'text', text: 'Could not finish' }] } });
  f.child.emitJSON({ type: 'result', uuid: 'result-2', subtype: 'error_during_execution', is_error: true, errors: ['Failed'] });
  assert.equal(completed.length, 1); assert.equal(f.chat.messages.at(-1).completionStatus, 'failed');
});

test('Claude restored result and stopped turn never produce task-completion notifications', async t => {
  const f = await fixture(t, 'claude', (m, child) => { if (m.request?.subtype === 'interrupt') child.respond(m); }, { conversationID: 'previous', messages: [{ id: 'saved', role: 'assistant', text: 'Saved' }] });
  const completed = []; f.session.on('completed', event => completed.push(event)); await f.session.start();
  f.child.emitJSON({ type: 'result', uuid: 'old', subtype: 'success', result: 'Saved' }); assert.equal(completed.length, 0);
  assert.equal(f.chat.messages[0].completedAt, undefined);
  await f.session.send({ text: 'New' }); f.child.emitJSON({ type: 'assistant', message: { id: 'stopped', content: [{ type: 'text', text: 'Partial' }] } });
  await f.session.interrupt(); f.child.emitJSON({ type: 'result', uuid: 'new', subtype: 'success', result: 'Partial' });
  assert.equal(completed.length, 0); assert.equal(f.chat.messages.at(-1).completionStatus, 'interrupted');
});

test('Codex completion matches the accepted turn, ignores child/replayed results and excludes failed/interrupted turns', async t => {
  let n = 0;
  const f = await fixture(t, 'openai', (m, child) => {
    if (m.method === 'turn/start') child.respond(m, { turn: { id: 'turn-' + (++n) } });
    if (m.method === 'turn/interrupt') child.respond(m);
  });
  const completed = []; f.session.on('completed', event => completed.push(event)); await f.session.start();
  const emit = (id, status = 'completed', threadId = 'thread-1') => f.child.emitJSON({ method: 'turn/completed', params: { threadId, turn: { id, status, items: [{ id: 'answer-' + id, type: 'agentMessage', text: 'Answer', phase: 'final_answer' }] } } });
  emit('old'); assert.equal(completed.length, 0);
  await f.session.send({ text: 'First' }); emit('turn-1', 'completed', 'child'); emit('old'); assert.equal(f.session.isBusy, true);
  emit('turn-1'); emit('turn-1'); assert.equal(completed.length, 1); assert.equal(f.chat.messages.at(-1).completionStatus, 'completed');
  await f.session.send({ text: 'Second' }); emit('turn-1'); assert.equal(f.session.isBusy, true); emit('turn-2', 'failed'); assert.equal(completed.length, 1);
  await f.session.send({ text: 'Third' }); await f.session.interrupt(); emit('turn-3'); assert.equal(completed.length, 1);
});

test('Claude effort is derived from actual model capabilities, ACKed before sending and explicitly reset to Default', async t => {
  let rejectEffort = false;
  const f = await fixture(t, 'claude', (m, child, done) => {
    if (m.request?.subtype === 'initialize') { child.respond(m, { models: [{ value: 'model-a', displayName: 'Actual A', supportsEffort: true, supportedEffortLevels: ['low', 'high'] }] }); done(); return false; }
    if (m.request?.subtype === 'apply_flag_settings' && rejectEffort) { child.reject(m, 'effort rejected'); done(); return false; }
  });
  await f.session.start(); assert.deepEqual(f.session.models[0].reasoningEfforts, ['low', 'high']);
  await assert.rejects(f.session.send({ text: 'Keep draft', reasoningEffort: 'max' }), /does not support/); assert.equal(f.chat.messages.length, 0);
  rejectEffort = true; await assert.rejects(f.session.send({ text: 'Keep draft', reasoningEffort: 'high' }), /effort rejected/); assert.equal(f.chat.messages.length, 0);
  rejectEffort = false; await f.session.send({ text: 'Go', reasoningEffort: 'high' });
  assert.deepEqual(f.child.sent.findLast(m => m.request?.subtype === 'apply_flag_settings').request, { subtype: 'apply_flag_settings', settings: { effortLevel: 'high' } });
  assert.equal(f.child.sent.at(-1).type, 'user'); f.child.emitJSON({ type: 'result', subtype: 'success', result: 'Done' });
  await f.session.send({ text: 'Default next', reasoningEffort: '' });
  assert.deepEqual(f.child.sent.findLast(m => m.request?.subtype === 'apply_flag_settings').request.settings, { effortLevel: null }); assert.equal(f.chat.reasoningEffort, '');
});

test('Codex effort options come from model/list and Default explicitly resets to the published default', async t => {
  const f = await fixture(t, 'openai', (m, child, done) => {
    if (m.method === 'model/list') { child.respond(m, { data: [{ model: 'model-a', isDefault: true, supportedReasoningEfforts: [{ reasoningEffort: 'low' }, { reasoningEffort: 'ultra' }], defaultReasoningEffort: 'low' }] }); done(); return false; }
    if (m.method === 'turn/start') child.respond(m, { turn: { id: 'turn-a' } });
  });
  await f.session.start(); assert.equal(f.session.models[0].defaultReasoningEffort, 'low');
  await f.session.send({ text: 'Go', reasoningEffort: 'ultra' }); assert.equal(f.child.sent.at(-1).params.effort, 'ultra');
  f.child.emitJSON({ method: 'turn/completed', params: { turn: { id: 'turn-a', status: 'completed' } } });
  await f.session.send({ text: 'Default', reasoningEffort: '' }); assert.equal(f.child.sent.at(-1).params.effort, 'low');
});

test('Claude reads effective settings every turn and refuses clamped or unverifiable effort without submitting', async t => {
  let applied = 'high';
  const f = await fixture(t, 'claude', (m, child, done) => {
    if (m.request?.subtype === 'initialize') { child.respond(m, { models: [{ value: 'model-a', supportsEffort: true, supportedEffortLevels: ['high','xhigh'] }] }); done(); return false; }
    if (m.request?.subtype === 'get_settings') { child.respond(m, { applied: { effort: applied } }); done(); return false; }
  });
  await f.session.start();
  for (const actual of ['high', null, 15, undefined]) {
    applied = actual;
    await assert.rejects(f.session.send({ text: 'Keep this draft', reasoningEffort: 'xhigh' }), /instead of xhigh|could not confirm/);
    assert.equal(f.child.sent.filter(m => m.type === 'user').length, 0);
    assert.equal(f.chat.messages.length, 0);
  }
  applied = 'xhigh'; await f.session.send({ text: 'Now applied', reasoningEffort: 'xhigh' });
  f.chat.reasoningEffort = 'high';
  f.child.emitJSON({ type: 'result', subtype: 'success', result: 'Done' });
  assert.equal(f.chat.messages.at(-1).reasoningEffort, 'xhigh');
  assert.equal(f.chat.messages.at(-1).reasoningEffortVerified, true);
  applied = 'high';
  await assert.rejects(f.session.send({ text: 'Same requested level must be rechecked', reasoningEffort: 'xhigh' }), /applied high instead of xhigh/);
  assert.equal(f.child.sent.filter(m => m.type === 'user').length, 1);
});

test('Claude child results never complete the parent and restored success cannot replace the timed answer', async t => {
  const saved = { id: 'saved', role: 'assistant', text: 'Original final', completedAt: '2026-01-01T00:00:00.000Z', durationMs: 1234, completionStatus: 'completed' };
  const f = await fixture(t, 'claude', undefined, { conversationID: 'saved-session', messages: [structuredClone(saved)] });
  const completed = []; f.session.on('completed', event => completed.push(event)); await f.session.start();
  f.child.emitJSON({ type: 'result', subtype: 'success', uuid: 'restored', result: 'Replayed result' });
  assert.deepEqual(f.chat.messages, [saved]);
  await f.session.send({ text: 'New question' });
  f.child.emitJSON({ type: 'result', subtype: 'success', uuid: 'child', parent_tool_use_id: 'child-task', result: 'Subagent done' });
  assert.equal(f.session.isBusy, true); assert.equal(completed.length, 0);
  f.child.emitJSON({ type: 'result', subtype: 'success', uuid: 'parent', result: 'Parent done' }); assert.equal(completed.length, 1);
});

test('Codex does not silently keep explicit effort when switching to an unknown model default', async t => {
  const f = await fixture(t, 'openai', (m, child) => { if (m.method === 'turn/start') child.respond(m, { turn: { id: 'known-turn' } }); });
  await f.session.start(); f.session.models[0].reasoningEfforts = ['high'];
  await f.session.send({ text: 'Known', reasoningEffort: 'high' });
  f.child.emitJSON({ method: 'turn/completed', params: { turn: { id: 'known-turn', status: 'completed' } } });
  const count = f.chat.messages.length;
  await assert.rejects(f.session.send({ text: 'Keep unknown draft', model: 'unknown-model', reasoningEffort: '' }), /default thinking level.*unknown/);
  assert.equal(f.chat.messages.length, count); assert.equal(f.session.isBusy, false);
});

test('Codex actual effort remains distinct from desired Default across full process restart', async t => {
  const handler = (m, child) => { if (m.method === 'turn/start') child.respond(m, { turn: { id: 'known-turn' } }); };
  const first = await fixture(t, 'openai', handler); await first.session.start(); first.session.models[0].reasoningEfforts = ['high'];
  await first.session.send({ text: 'Known', reasoningEffort: 'high' });
  first.child.emitJSON({ method: 'turn/completed', params: { turn: { id: 'known-turn', status: 'completed' } } });
  first.chat.model = 'custom-without-default'; first.chat.reasoningEffort = ''; await first.session.close();
  assert.equal(first.chat.codexAppliedReasoningEffort, 'high');
  const restored = await fixture(t, 'openai', handler, structuredClone(first.chat)); await restored.session.start();
  await assert.rejects(restored.session.send({ text: 'Keep this draft', reasoningEffort: '' }), /default thinking level.*unknown/);
  assert.equal(restored.child.sent.filter(m => m.method === 'turn/start').length, 0);
});

test('files and images reach both CLI protocols while history keeps the original text and metadata only',async t=>{
 const {FileAttachments}=await import('../src/attachments.mjs');
 for(const provider of ['claude','openai']){
  const f=await fixture(t,provider,(m,child)=>{if(m.method==='turn/start')child.respond(m,{turn:{id:'files-turn'}});});
  const store=new FileAttachments(f.root),files=store.import([{name:'报告 "quoted".pdf',data:Buffer.from('file bytes').toString('base64')}]).files;
  const imagePath=path.join(f.root,'test.png');await writeFile(imagePath,'image bytes');
  await f.session.start();await f.session.send({text:'',files,images:[{id:'image',name:'p.png',path:imagePath,mimeType:'image/png'}]});
  const wire=f.child.sent.at(-1),content=provider==='claude'?wire.message.content:wire.params.input;
  const text=content.find(item=>item.type==='text').text;assert(text.includes(JSON.stringify(store.path(files[0]))));assert(text.includes('available file tools'));
  assert(content.some(item=>item.type===(provider==='claude'?'image':'localImage')));
  assert.equal(f.chat.messages[0].text,'');assert.deepEqual(f.chat.messages[0].files,files);assert(!JSON.stringify(f.chat.messages).includes(store.path(files[0])));
 }
});
test('file-only messages work and missing or modified files cannot silently become text-only requests',async t=>{
 const {FileAttachments}=await import('../src/attachments.mjs');
 for(const provider of ['claude','openai']){
  const f=await fixture(t,provider,(m,child)=>{if(m.method==='turn/start')child.respond(m,{turn:{id:'file-only'}});});
  const store=new FileAttachments(f.root),files=store.import([{name:'notes.txt',data:''}]).files;
  await f.session.start();const before=f.child.sent.length;
  await writeFile(store.path(files[0]),'modified');await assert.rejects(f.session.send({text:'must stay unsent',files}));
  assert.equal(f.child.sent.length,before);assert.equal(f.session.isBusy,false);
  await writeFile(store.path(files[0]),'');await f.session.send({text:'',files});assert.equal(f.chat.messages[0].files[0].byteCount,0);
 }
});

test('Codex steer targets the accepted running turn and retains timing, model, attachments and completion identity', async t => {
  let mono = 100, hold;
  const f = await fixture(t, 'openai', (m, child) => {
    if (m.method === 'turn/start') child.respond(m, { turn: { id: 'steered-turn' } });
    if (m.method === 'turn/steer') hold = m;
  }, {}, { elapsedNow: () => mono });
  const { FileAttachments } = await import('../src/attachments.mjs');
  const files = new FileAttachments(f.root).import([{ name: 'instructions.md', data: Buffer.from('supplement').toString('base64') }]).files;
  const imagePath = path.join(f.root, 'steer.png'); await writeFile(imagePath, 'image bytes');
  const images = [{ id: 'steer-image', name: 'example.png', path: imagePath, mimeType: 'image/png' }];
  const completed = []; f.session.on('completed', event => completed.push(event));
  await f.session.start(); assert.equal(f.session.canSteer, false);
  await f.session.send({ text: 'Original task' }); const original = f.chat.messages[0].id;
  assert.equal(f.session.canSteer, true); mono = 300;
  const steering = f.session.steer({ text: 'Keep the colors', files, images });
  await tick(); assert.equal(f.session.canSteer, false);
  await assert.rejects(f.session.steer({ text: 'Concurrent correction' }), /not ready/);
  while (!hold) await tick();
  assert.equal(hold.params.expectedTurnId, 'steered-turn'); assert.equal(hold.params.threadId, 'thread-1');
  assert.equal(hold.params.model, undefined); assert(hold.params.input[0].text.includes('Keep the colors'));
  assert.equal(hold.params.input[1].path, imagePath);
  f.child.emitJSON({ method: 'turn/completed', params: { turn: { id: 'steered-turn', status: 'completed', items: [{ id: 'final', type: 'agentMessage', text: 'Adjusted', phase: 'final_answer' }] } } });
  assert.equal(completed.length, 0); mono = 900;
  f.child.respond(hold, { turnId: 'steered-turn' }); await steering;
  assert.equal(f.chat.messages[1].text, 'Keep the colors'); assert.deepEqual(f.chat.messages[1].files, files);
  assert.equal(f.chat.messages.at(-1).text, 'Adjusted'); assert.equal(f.chat.messages.at(-1).durationMs, 800);
  assert.equal(completed.length, 1); assert.equal(completed[0].id, original); assert.equal(f.session.canSteer, false);
  assert.equal(f.child.sent.filter(m => m.method === 'turn/start').length, 1);
});

test('Codex rejected or invalid steer keeps the original task active and consumes deferred output', async t => {
  let hold;
  const f = await fixture(t, 'openai', (m, child) => {
    if (m.method === 'turn/start') child.respond(m, { turn: { id: 'current' } });
    if (m.method === 'turn/steer') hold = m;
  });
  await f.session.start(); await f.session.send({ text: 'Original task' });
  await assert.rejects(f.session.steer({ text: '', files: [{ id: 'bad' }] }));
  assert.equal(f.session.isBusy, true); assert.equal(f.session.canSteer, true);
  await assert.rejects(f.session.steer({ text: 'Revoked', stillAuthorized: () => false }), { code: 'authorization_revoked' });
  const steering = f.session.steer({ text: 'Rejected draft' }); await tick();
  f.child.emitJSON({ method: 'item/agentMessage/delta', params: { threadId: 'thread-1', itemId: 'progress', delta: 'Still running' } });
  f.child.reject(hold, 'Expected turn is no longer current');
  await assert.rejects(steering, { code: 'backend_rejected' });
  assert.equal(f.session.isBusy, true); assert.equal(f.session.canSteer, true); assert.equal(f.child.killed, false);
  assert.equal(f.chat.messages.at(-1).text, 'Still running'); assert.equal(f.chat.messages.filter(m => m.role === 'user').length, 1);
  f.child.emitJSON({ method: 'turn/completed', params: { turn: { id: 'current', status: 'completed' } } });
  await assert.rejects(f.session.steer({ text: 'Too late' }), /not ready/);
});

test('Codex unknown steer preserves the correction without retrying or terminating the running task', async t => {
  const f = await fixture(t, 'openai', (m, child) => { if (m.method === 'turn/start') child.respond(m, { turn: { id: 'current' } }); }, {}, { timeout: 50 });
  await f.session.start(); await f.session.send({ text: 'Original' });
  const steering = assert.rejects(f.session.steer({ text: 'Unknown correction' }), { code: 'submission_uncertain' });
  // Keep the test event loop alive because production timeout handles are unref'ed.
  await new Promise(resolve => setTimeout(resolve, 80)); await steering;
  assert.equal(f.session.isBusy, true); assert.equal(f.session.canSteer, false); assert.equal(f.child.killed, false);
  assert.equal(f.chat.messages.at(-1).text, 'Unknown correction');
  f.child.emitJSON({ method: 'turn/completed', params: { turn: { id: 'current', status: 'completed' } } });
  assert.equal(f.session.isBusy, false);
  assert.equal(f.child.sent.filter(m => m.method === 'turn/steer').length, 1);
});

for (const boundary of ['tool', 'final stream']) test(`Claude ${boundary} steer waits for UUID ACK and completes the whole logical task once`, async t => {
  let mono = 0, command;
  const f = await fixture(t, 'claude', (m, child) => {
    if (m.type === 'user') {
      if (!command) { command = m; child.emitJSON({ type: 'command_lifecycle', command_uuid: m.uuid, state: 'queued' }); }
    }
  }, {}, { elapsedNow: () => mono });
  await f.session.start(); assert(f.launch().args.includes('--replay-user-messages'));
  const completed = []; f.session.on('completed', event => completed.push(event));
  await f.session.send({ text: 'Original task' }); const token = f.session.steerToken;
  assert.equal(f.session.canSteer, true); mono = 200;
  const steering = f.session.steer({ text: 'Use the new requirement' }); await tick();
  const correction = f.child.sent.at(-1); assert.equal(correction.type, 'user'); assert(correction.uuid); assert.equal(correction.priority, undefined);
  assert.equal(f.chat.messages.length, 1); assert.equal(f.session.canSteer, false);
  f.child.emitJSON({ type: 'command_lifecycle', command_uuid: correction.uuid, state: 'queued' }); await steering;
  assert.equal(f.chat.messages[1].text, 'Use the new requirement'); assert.equal(f.session.steerToken, token);
  const emit = (uuid, ids, text) => f.child.emitJSON({ type: 'result', uuid, subtype: 'success', result: text, user_message_uuids: ids, queued_turn_count: 0 });
  if (boundary === 'final stream') {
    emit('original-result', [command.uuid], 'Old answer');
    assert.equal(f.session.isBusy, true); assert.equal(completed.length, 0);
    f.child.emitJSON({ type: 'user', uuid: correction.uuid, isReplay: true, message: { content: 'Use the new requirement' } });
  }
  mono = 900; emit('final-result', boundary === 'tool' ? [command.uuid, correction.uuid] : [correction.uuid], 'Adjusted answer');
  assert.equal(completed.length, 1); assert.equal(completed[0].id, token); assert.equal(f.session.isBusy, false);
  assert.equal(f.chat.messages.at(-1).text, 'Adjusted answer'); assert.equal(f.chat.messages.at(-1).durationMs, 900);
  assert.equal(f.chat.messages.filter(m => m.role === 'user').length, 2);
  emit('final-result', [correction.uuid], 'Adjusted answer'); assert.equal(completed.length, 1);
});

test('Claude refused steer leaves task active and rejected drafts out of history', async t => {
  const f = await fixture(t, 'claude', (m, child) => {
    if (m.type === 'user' && m.message.content === 'Original') child.emitJSON({ type: 'command_lifecycle', command_uuid: m.uuid, state: 'queued' });
  });
  await f.session.start(); await f.session.send({ text: 'Original' });
  const steering = f.session.steer({ text: 'Refuse this correction' }); await tick();
  f.child.emitJSON({ type: 'command_lifecycle', command_uuid: f.child.sent.at(-1).uuid, state: 'refused' });
  await assert.rejects(steering, { code: 'backend_rejected' });
  assert.equal(f.session.isBusy, true); assert.equal(f.session.canSteer, true);
  assert.equal(f.chat.messages.length, 1); assert.equal(f.child.killed, false);
});

test('Claude Stop cancels accepted queued corrections and releases a held completion without notifying', async t => {
  let initial;
  const f = await fixture(t, 'claude', (m, child) => {
    if (m.type === 'user') { initial ||= m.uuid; child.emitJSON({ type: 'command_lifecycle', command_uuid: m.uuid, state: 'queued' }); }
    if (m.request?.subtype === 'interrupt') {
      assert.equal(m.request.cancel_queued, true);
      child.respond(m, { cancelled: [child.sent.filter(m => m.type === 'user').at(-1).uuid], still_queued: [] });
    }
  });
  const completed = []; f.session.on('completed', e => completed.push(e));
  await f.session.start(); await f.session.send({ text: 'Original' }); await f.session.steer({ text: 'Queued' });
  f.child.emitJSON({ type: 'result', uuid: 'first-result', subtype: 'success', result: 'Partial answer', user_message_uuid: initial });
  assert.equal(f.session.isBusy, true);
  await f.session.interrupt(); assert.equal(f.session.isBusy, false); assert.equal(completed.length, 0);
  assert.equal(f.chat.messages.find(m => m.text === 'Queued').isError, true);
});

for (const state of ['cancelled', 'refused', 'discarded']) test(`Claude accepted steer later ${state} is visibly not applied and releases held result`, async t => {
  let initial;
  const f = await fixture(t, 'claude', (m, child) => {
    if (m.type === 'user') { initial ||= m.uuid; child.emitJSON({ type: 'command_lifecycle', command_uuid: m.uuid, state: 'queued' }); }
  });
  await f.session.start(); await f.session.send({ text: 'Original' });
  await f.session.steer({ text: 'Correction not applied' });
  const correction = f.chat.messages.at(-1);
  assert.equal(correction.isSteering, true); assert.equal(correction.isError, false);
  f.child.emitJSON({ type: 'result', uuid: 'original-result', subtype: 'success', result: 'Original answer', user_message_uuids: [initial] });
  assert.equal(f.session.isBusy, true);
  f.child.emitJSON({ type: 'command_lifecycle', command_uuid: correction.id, state });
  assert.equal(correction.text, 'Correction not applied'); assert.equal(correction.isError, true);
  assert.equal(f.session.isBusy, false); assert.equal(f.session.claudeSteers.size, 0);
  assert.match(f.session.error, /could not apply/);
});

test('Claude Stop lifecycle cancellation marks accepted steer without a generic failure', async t => {
  let initial;
  const f = await fixture(t, 'claude', (m, child) => {
    if (m.type === 'user') { initial ||= m.uuid; child.emitJSON({ type: 'command_lifecycle', command_uuid: m.uuid, state: 'queued' }); }
    if (m.request?.subtype === 'interrupt') {
      const id = child.sent.filter(m => m.type === 'user').at(-1).uuid;
      child.emitJSON({ type: 'command_lifecycle', command_uuid: id, state: 'cancelled' });
      child.respond(m, { cancelled: [id], still_queued: [] });
    }
  });
  await f.session.start(); await f.session.send({ text: 'Original' }); await f.session.steer({ text: 'Cancelled correction' });
  const correction = f.chat.messages.at(-1);
  f.child.emitJSON({ type: 'result', uuid: 'original-result', subtype: 'success', result: 'Original answer', user_message_uuid: initial });
  await f.session.interrupt();
  assert.equal(correction.isError, true); assert.equal(f.session.isBusy, false); assert.equal(f.session.error, null);
});

test('Claude queued ACK and cancellation in the same output batch cannot create a falsely applied steer row', async t => {
  const f = await fixture(t, 'claude', (m, child) => {
    if (m.type === 'user') {
      child.emitJSON({ type: 'command_lifecycle', command_uuid: m.uuid, state: 'queued' });
      if (m.message.content === 'Cancelled in same batch') child.emitJSON({ type: 'command_lifecycle', command_uuid: m.uuid, state: 'cancelled' });
    }
  });
  await f.session.start(); await f.session.send({ text: 'Original' });
  await f.session.steer({ text: 'Cancelled in same batch' });
  const correction = f.chat.messages.at(-1);
  assert.equal(correction.isSteering, true); assert.equal(correction.isError, true);
  assert.match(f.session.error, /could not apply/); assert.equal(f.session.claudeSteers.size, 0);
  f.child.emitJSON({ type: 'result', uuid: 'original-result', subtype: 'success', result: 'Original answer', user_message_uuid: f.session.claudeInitialUUID });
  assert.equal(f.session.isBusy, false);
});
