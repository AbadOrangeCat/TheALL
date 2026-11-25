import test from 'node:test';
import assert from 'node:assert/strict';
import { nameFromPrompt } from '../src/naming.mjs';
import { parseConnectionPaste, parseClipboardConnection, describeConnectionPaste } from '../renderer/connection-paste.mjs';

// Every key below is a fixture, not a real credential.
const fakeKey = 'sk-test-0000000000000000000000000000000000000000';

test('tab names match the Mac WorkspaceName rules', () => {
  assert.equal(nameFromPrompt('请帮我修复登录页面的崩溃问题。另外看看日志'), '修复登录页面的崩溃问题');
  assert.equal(nameFromPrompt('Could you please refactor the tab bar layout?\nMore details'), 'refactor the tab bar layout');
  assert.equal(nameFromPrompt('## Release notes'), 'Release notes');
  assert.equal(nameFromPrompt('A very long english sentence that keeps going and going beyond the limit of forty eight chars'), 'A very long english sentence that keeps going…');
  assert.equal(nameFromPrompt('这是一个非常非常长的中文问题，用来确认标签页名称会被截断到二十四个字符以内并带省略号'), '这是一个非常非常长的中文问题，用来确认标签页名称…');
  assert.equal(nameFromPrompt('？？？'), '？？？');
  for (const empty of ['', '   \n  ', null]) assert.equal(nameFromPrompt(empty), '');
});

test('Claude Code settings.json fills key, Base URL and Bearer, and lists the skipped variables', () => {
  const text = JSON.stringify({ $schema: 'https://json.schemastore.org/claude-code-settings.json', env: {
    ANTHROPIC_BASE_URL: 'https://relay.example.test', ANTHROPIC_AUTH_TOKEN: fakeKey, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1' } }, null, 2);
  assert.deepEqual(parseConnectionPaste(text), { apiKey: fakeKey, baseURL: 'https://relay.example.test', useBearerToken: true,
    fields: ['apiKey', 'baseURL'], provider: 'claude', ignored: ['CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'] });
});

test('shell, PowerShell, cmd, collapsed lines, TOML and loose notes are recognized', () => {
  for (const text of [
    `export OPENAI_BASE_URL=https://gateway.example.test/v1\nexport OPENAI_API_KEY='${fakeKey}'`,
    `$env:OPENAI_API_KEY="${fakeKey}"\r\n$env:OPENAI_BASE_URL="https://gateway.example.test/v1"`,
    `set OPENAI_API_KEY=${fakeKey}\nset OPENAI_BASE_URL=https://gateway.example.test/v1`,
    `setx OPENAI_API_KEY "${fakeKey}"\nsetx OPENAI_BASE_URL https://gateway.example.test/v1`,
    `OPENAI_API_KEY=${fakeKey} OPENAI_BASE_URL=https://gateway.example.test/v1`,
  ]) {
    const parsed = parseConnectionPaste(text);
    assert.equal(parsed?.apiKey, fakeKey, text); assert.equal(parsed.baseURL, 'https://gateway.example.test/v1', text);
    assert.equal(parsed.provider, 'openai', text); assert.equal(parsed.useBearerToken, undefined, text);
  }
  const toml = parseConnectionPaste('model = "gpt-fixture"\nmodel_provider = "relay"\n[model_providers.relay]\nbase_url = "https://codex.example.test/v1"\nenv_key = "OPENAI_API_KEY"');
  assert.equal(toml.model, 'gpt-fixture'); assert.equal(toml.baseURL, 'https://codex.example.test/v1'); assert.equal(toml.apiKey, undefined);
  const notes = parseConnectionPaste(`Base URL: https://notes.example.test\nAPI Key: ${fakeKey}`);
  assert.equal(notes.apiKey, fakeKey); assert.equal(notes.baseURL, 'https://notes.example.test'); assert.equal(notes.provider, undefined);
  const fragment = parseConnectionPaste(`    "ANTHROPIC_API_KEY": "${fakeKey}",\n    "ANTHROPIC_MODEL": "claude-fixture-1",`);
  assert.equal(fragment.apiKey, fakeKey); assert.equal(fragment.model, 'claude-fixture-1'); assert.equal(fragment.useBearerToken, false);
  const ranked = parseConnectionPaste(`API_KEY=generic-fixture-key\nANTHROPIC_AUTH_TOKEN=${fakeKey}\nURL=https://generic.example.test\nANTHROPIC_BASE_URL=https://specific.example.test`);
  assert.equal(ranked.apiKey, fakeKey); assert.equal(ranked.baseURL, 'https://specific.example.test'); assert.equal(ranked.useBearerToken, true);
});

test('bare keys and placeholders are left for the field to handle', () => {
  for (const text of [fakeKey, 'c2stdGVzdC1maXh0dXJlLWtleQ==', 'sk-ant-api03-fixture', '', 'OPENAI_API_KEY=${OPENAI_API_KEY}\nANTHROPIC_API_KEY=<your key>',
    '{"env": {"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"}}']) assert.equal(parseConnectionPaste(text), null, text);
  assert.deepEqual(parseClipboardConnection(`  ${fakeKey}\n`), { apiKey: fakeKey, fields: ['apiKey'], ignored: [] });
  assert.deepEqual(parseClipboardConnection('https://relay.example.test'), { baseURL: 'https://relay.example.test', fields: ['baseURL'], ignored: [] });
  assert.equal(parseClipboardConnection('two words'), null);
});

test('the paste note names what was filled and warns about the other provider', () => {
  const strings = { 'ai.paste.applied': 'Filled: %@.', 'ai.paste.ignored': 'Skipped: %@.', 'ai.paste.otherProvider': 'For %@?',
    'ai.paste.field.url': 'Base URL', 'ai.paste.bearer': 'Bearer', 'ai.model': 'Model' };
  const t = key => strings[key] ?? key;
  const parsed = parseConnectionPaste(`{"env":{"ANTHROPIC_AUTH_TOKEN":"${fakeKey}","ANTHROPIC_BASE_URL":"https://relay.example.test","DISABLE_AUTOUPDATER":"1"}}`);
  assert.deepEqual(describeConnectionPaste(parsed, 'claude', t, 'en'), { summary: 'Filled: API Key, Base URL, and Bearer. Skipped: DISABLE_AUTOUPDATER.', warning: '' });
  assert.deepEqual(describeConnectionPaste(parsed, 'openai', t, 'en'), { summary: 'Filled: API Key and Base URL. Skipped: DISABLE_AUTOUPDATER.', warning: 'For Claude Code?' });
});
