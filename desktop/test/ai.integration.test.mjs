import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { createHash, randomUUID } from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import { AISession, resolveCLI } from '../src/ai.mjs';

async function until(predicate, timeout = 40_000) {
  const deadline = Date.now() + timeout;
  while (!await predicate()) {
    if (Date.now() > deadline) throw new Error('Offline CLI fixture timed out.');
    await new Promise(resolve => setTimeout(resolve, 30));
  }
}

// Opt-in only: installed provider CLIs, fake key, temporary config/history, and
// the repository's loopback-only API fixture. No real AI endpoint is contacted.
for (const provider of ['claude', 'openai']) {
  test(`installed ${provider} CLI: model switch, photo, executable tool and process restart preserve context`, {
    skip: process.env.THEALL_TEST_INSTALLED_CLIS !== '1', timeout: 180_000
  }, async t => {
    const root = await mkdtemp(path.join(os.tmpdir(), 'TheAll Windows CLI '));
    const binary = await resolveCLI(provider);
    // Native executables and the official Windows npm JS entry both use the
    // production discovery path; no .cmd wrapper is evaluated by a shell.
    const executable = binary.prefix[0] || binary.command;
    const fixture = process.env.THEALL_GATEWAY_FIXTURE || fileURLToPath(new URL('../../TheAllTests/Fixtures/ai_gateway.py', import.meta.url));
    const python = process.env.PYTHON || (process.platform === 'win32' ? 'python' : 'python3');
    const server = spawn(python, [fixture, root], { stdio: 'ignore', windowsHide: true, shell: false });
    let serverError;
    server.on('error', error => { serverError = error; });
    let session;
    t.after(async () => { await session?.close(); server.kill(); await rm(root, { recursive: true, force: true }); });
    let port;
    await until(async () => {
      if (serverError) throw serverError;
      try { port = await readFile(path.join(root, 'port'), 'utf8'); return true; } catch { return false; }
    }, 5000);
    const firstModel = provider === 'claude' ? 'claude-opus-5-5' : 'fixture-one';
    const secondModel = provider === 'claude' ? 'claude-sonnet-5-5' : 'fixture-two';
    const chat = { id: randomUUID(), provider, directory: root, model: firstModel, messages: [], conversationID: null };
    const connection = { executable, apiKey: 'fake-local-integration-key', baseURL: `http://127.0.0.1:${port}${provider === 'openai' ? '/v1' : ''}` };
    // Keep provider feature/telemetry settings out of the real user's directories.
    const env = { ...process.env, HOME: root, USERPROFILE: root, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1', DISABLE_AUTOUPDATER: '1',
      CLAUDE_CODE_EFFORT_LEVEL: '40', CLAUDE_CODE_EXTRA_BODY: '{"output_config":{"effort":40}}' };
    let capEffort = false;
    const options = { chat, connection, dataDir: root, env, timeout: 40_000,
      spawnImpl(command, args, settings) {
        if (provider === 'claude' && capEffort) {
          args = [...args]; const index = args.indexOf('--settings');
          args[index + 1] = JSON.stringify({ ...JSON.parse(args[index + 1]), maxEffortLevel: 'high' });
        }
        return spawn(command, args, settings);
      } };
    session = new AISession(options);
    await session.start(); assert.equal(session.isReady, true);
    const send = async input => {
      await session.send(input);
      await until(() => !session.isBusy);
      assert.equal(session.error, null);
      assert.equal(session.questions.length, 0, 'Tool operations must remain automatic.');
    };
    await send({ text: 'First local fixture question' });
    const conversationID = chat.conversationID; assert.ok(conversationID);
    await send({ text: 'Continue the same conversation', model: secondModel });
    assert.equal(chat.conversationID, conversationID);
    const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC', 'base64');
    const photo = path.join(root, 'fixture.png'); await writeFile(photo, png);
    await send({ text: 'Inspect this fixture image', images: [{ id: randomUUID(), path: photo, name: 'fixture.png', mimeType: 'image/png', width: 1, height: 1 }] });
    let requests = (await readFile(path.join(root, 'requests.jsonl'), 'utf8')).trim().split('\n').map(JSON.parse);
    assert.equal(requests[0].model, firstModel); assert.equal(requests.at(-1).model, secondModel);
    assert.ok(requests.some(r => r.images.some(i => i.sha256 === createHash('sha256').update(png).digest('hex'))));
    const previousCount = requests.at(-1).count;
    await session.close(); session = new AISession({ ...options, chat: structuredClone(chat) });
    await session.start(); await send({ text: 'Continue after completely reopening the app' });
    assert.equal(session.chat.conversationID, conversationID);
    requests = (await readFile(path.join(root, 'requests.jsonl'), 'utf8')).trim().split('\n').map(JSON.parse);
    assert.ok(requests.at(-1).count > previousCount);
    await writeFile(path.join(root, 'tool-command.txt'), 'node -e "require(\'fs\').writeFileSync(\'fixture-result.txt\',\'passed\');console.log(\'fixture passed\')"');
    await send({ text: 'Run the local offline fixture tool' });
    assert.equal(await readFile(path.join(root, 'fixture-result.txt'), 'utf8'), 'passed');
    assert.equal(session.chat.messages.filter(m => m.role === 'user').length, 5);
    assert.equal(session.chat.messages.filter(m => m.role === 'assistant').length, 5);
    const effortModel = session.models.find(m => (provider !== 'claude' || m.id === firstModel) && m.reasoningEfforts?.includes('high') && m.reasoningEfforts?.includes('low') && m.defaultReasoningEffort !== 'high');
    assert(effortModel, 'Installed CLI must advertise an actual model with high/low effort');
    const recordedEffort = async () => (await readFile(path.join(root, 'requests.jsonl'), 'utf8')).trim().split('\n').map(JSON.parse).at(-1).effort;
    const transmittedEfforts = [];
    for (const reasoningEffort of [...effortModel.reasoningEfforts.filter(value => value !== 'low'), 'low']) {
      await send({ text: `Fixture ${reasoningEffort} effort`, model: effortModel.id, reasoningEffort });
      const actual = await recordedEffort();
      // Codex ultra is a client orchestration mode; this CLI uses xhigh for
      // its underlying model request. TheAll must still submit ultra to it.
      const expected = provider === 'openai' && reasoningEffort === 'ultra' ? 'xhigh' : reasoningEffort;
      assert.equal(actual, expected, `${provider} must apply the selected ${reasoningEffort} level`);
      const completed = session.chat.messages.at(-1);
      assert.equal(completed.reasoningEffort, reasoningEffort);
      assert.equal(completed.reasoningEffortVerified, provider === 'claude');
      transmittedEfforts.push({ selected: reasoningEffort, transmitted: actual });
    }
    await send({ text: 'Fixture default effort', model: effortModel.id, reasoningEffort: '' });
    const actualDefault = await recordedEffort();
    t.diagnostic(JSON.stringify({ provider, effortModel, transmittedEfforts, actualDefault }));
    if (provider === 'openai') assert.equal(actualDefault, effortModel.defaultReasoningEffort, 'Default must reset the previous explicit effort');
    else assert.notEqual(actualDefault, 'low', 'Default must clear the preceding low override');
    assert(session.chat.messages.at(-1).completedAt); assert(session.chat.messages.at(-1).durationMs >= 0);

    // Default selected but not yet sent must clear the previous override after
    // reopening the same conversation, on both backends.
    await send({ text: 'High before restart', model: effortModel.id, reasoningEffort: 'high' });
    session.chat.reasoningEffort = '';
    const restoredChat = structuredClone(session.chat);
    await session.close(); session = new AISession({ ...options, chat: restoredChat });
    await session.start(); await send({ text: 'Default after restart' });
    assert.equal(await recordedEffort(), actualDefault);

    if (provider === 'claude') {
      assert.equal(actualDefault, 'medium', 'Opus 5.5 Default must use its actual default');
      await session.close(); capEffort = true;
      session = new AISession({ ...options, chat: structuredClone(session.chat) });
      await session.start();
      const before = await readFile(path.join(root, 'requests.jsonl'), 'utf8');
      await assert.rejects(session.send({ text: 'Keep this draft', model: firstModel, reasoningEffort: 'xhigh' }), /applied high instead of xhigh/);
      assert.equal(await readFile(path.join(root, 'requests.jsonl'), 'utf8'), before, 'Clamped effort must reject before any user API request');
      await send({ text: 'Supported high after rejection', model: firstModel, reasoningEffort: 'high' });
      assert.equal(await recordedEffort(), 'high');
      t.diagnostic('Claude Opus 5.5: policy clamp rejected before submission; retry and Default after restart passed');
    }

  });
}
