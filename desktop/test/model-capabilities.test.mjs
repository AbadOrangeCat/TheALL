import test from 'node:test';
import assert from 'node:assert/strict';
import { fetchModels, mergeModelCatalog, selectedReasoningEffort, modelCapabilities } from '../src/models.mjs';

test('Codex keeps all advertised effort levels, including ultra, without inventing unsupported levels', () => {
  const capabilities = modelCapabilities({ supportedReasoningEfforts: [
    'low', 'medium', 'high', 'xhigh', 'max', 'ultra', 'ultra', '', 'bad value', 'x'.repeat(33), null
  ].map(reasoningEffort => ({ reasoningEffort })), defaultReasoningEffort: 'ultra' }, 'openai');
  assert.deepEqual(capabilities.reasoningEfforts, ['low', 'medium', 'high', 'xhigh', 'max', 'ultra']);
  assert.equal(capabilities.defaultReasoningEffort, 'ultra');
  assert.equal(selectedReasoningEffort([{ id: 'fixture', ...capabilities }], 'fixture', 'ultra'), 'ultra');
  assert.deepEqual(modelCapabilities({ supportedReasoningEfforts: [{ reasoningEffort: 'high' }] }, 'openai').reasoningEfforts, ['high']);
});

test('Claude API capability flags are honored only for their exact model ID and only explicit supported levels', async () => {
  const models = await fetchModels('claude', { baseURL: 'https://api.fixture.invalid', apiKey: 'fake' }, async () => new Response(JSON.stringify({ data: [
    { id: 'claude-known', capabilities: { effort: { supported: true, low: { supported: true }, medium: { supported: false }, high: { supported: true }, max: true } } },
    { id: 'claude-unknown' }, { id: 'claude-disabled', capabilities: { effort: { supported: false, high: { supported: true } } } }
  ] })));
  const merged = mergeModelCatalog(models, [{ id: 'sonnet', title: 'Sonnet', reasoningEfforts: ['low', 'high', 'max'] }]);
  assert.deepEqual(merged.find(m => m.id === 'claude-known').reasoningEfforts, ['low', 'high']);
  assert.deepEqual(merged.find(m => m.id === 'claude-unknown').reasoningEfforts, []);
  assert.deepEqual(merged.find(m => m.id === 'claude-disabled').reasoningEfforts, []);
  assert.equal(selectedReasoningEffort(merged, 'claude-known', 'high'), 'high');
  assert.throws(() => selectedReasoningEffort(merged, 'claude-unknown', 'high'), /does not support/);
  assert.equal(selectedReasoningEffort(merged, 'claude-unknown', ''), '');
  assert.throws(() => selectedReasoningEffort(merged, 'unlisted-model', 'high', 'sonnet'), /does not support/);
  assert.equal(selectedReasoningEffort(merged, '', 'high', 'sonnet'), 'high');
});

test('Claude resolvedModel bridges exact API IDs while retaining constrained CLI levels and rejecting other versions', () => {
  const cli = [
    { id: '', title: 'Default', ...modelCapabilities({ resolvedModel: 'claude-opus-fixture', supportsEffort: true, supportedEffortLevels: ['low', 'high', 'max'] }, 'claude') },
    { id: 'opus', title: 'Opus', ...modelCapabilities({ resolvedModel: 'claude-opus-fixture', supportsEffort: true, supportedEffortLevels: ['low', 'high'] }, 'claude') }
  ];
  const merged = mergeModelCatalog([{ id: 'claude-opus-fixture', title: 'Claude Opus' }, { id: 'claude-opus-older', title: 'Older Opus' }], cli);
  assert.deepEqual(merged.find(m => m.id === 'claude-opus-fixture').reasoningEfforts, ['low', 'high']);
  assert.equal(merged.find(m => m.id === 'claude-opus-fixture').title, 'Claude Opus');
  assert.deepEqual(merged.find(m => m.id === 'claude-opus-older').reasoningEfforts, []);
  assert.equal(selectedReasoningEffort(merged, 'claude-opus-fixture', 'high'), 'high');
  assert.throws(() => selectedReasoningEffort(merged, 'claude-opus-older', 'high'), /does not support/);
});

test('Claude picker orders merged models by family and descending numeric version', () => {
  const options = ["claude-haiku-5-5", "claude-opus-4-8", "claude-fable-5", "claude-sonnet-5-5", "claude-opus-5", "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5-10", "claude-3-7-sonnet-20250219", "custom-model", ""].map(id => ({ id, title: id }));
  const sorted = mergeModelCatalog(options.slice(0, 3), options.slice(3));
  assert.deepEqual(sorted.map(m => m.id), ["", "claude-fable-5-1", "claude-fable-5", "claude-opus-5-10", "claude-opus-5-5", "claude-opus-5", "claude-opus-4-8", "claude-sonnet-5-5", "claude-3-7-sonnet-20250219", "claude-haiku-5-5", "custom-model"]);
  assert.deepEqual(mergeModelCatalog([...sorted].reverse()).map(m => m.id), sorted.map(m => m.id));
});

test('Codex picker orders merged models by family and descending numeric version', () => {
  const options = ["gpt-6-luna", "gpt-6.1-sol", "gpt-5.6-sol", "gpt-6-astra", "gpt-6.1-terra", "gpt-5-mini", "gpt-5.4", "gpt-5.4-pro", "gpt-5.4-nano", "gpt-4o-mini", "gpt-4", "gpt-4.1", "gpt-4o", "custom"].map(id => ({ id, title: id }));
  const sorted = mergeModelCatalog(options.slice(0, 3), options.slice(3));
  assert.deepEqual(sorted.map(m => m.id), ["gpt-6-astra", "gpt-6.1-sol", "gpt-5.6-sol", "gpt-6.1-terra", "gpt-6-luna", "gpt-5.4-pro", "gpt-5.4", "gpt-5.4-nano", "gpt-5-mini", "gpt-4.1", "gpt-4o", "gpt-4o-mini", "gpt-4", "custom"]);
  assert.deepEqual(mergeModelCatalog([...sorted].reverse()).map(m => m.id), sorted.map(m => m.id));
});

test('sorting retains gateway labels, explicit aliases and exact backend capabilities; dates are not versions', async () => {
  const api = await fetchModels('claude', { baseURL: 'https://fixture.invalid', apiKey: 'fake' }, async () => new Response(JSON.stringify({ data: [
    { id: 'claude-opus-4-20250514', display_name: 'Dated Opus' }, { id: 'claude-opus-4-6', display_name: 'Newer Opus' },
    { id: 'custom-alias', display_name: 'My chosen model' }, { id: 'opaque-id', display_name: 'Gateway flagship', line: 'fable' },
    { id: 'claude-opus-5', display_name: 'AAA' }, { id: 'custom-2', display_name: 'Custom 2' }, { id: 'custom-10', display_name: 'Custom 10' }
  ] })));
  const sorted = mergeModelCatalog(api, [{ id: 'custom-alias', title: 'Alias', reasoningEfforts: ['high'], defaultReasoningEffort: 'high', resolvedModel: 'claude-opus-5-5' }]);
  // JS merge also synthesizes the explicitly resolved ID for the CLI alias.
  assert.deepEqual(sorted.map(m => m.id), ['opaque-id', 'claude-opus-5-5', 'custom-alias', 'claude-opus-5', 'claude-opus-4-6', 'claude-opus-4-20250514', 'custom-2', 'custom-10']);
  assert.deepEqual(sorted.find(m => m.id === 'custom-alias'), { id: 'custom-alias', title: 'My chosen model', reasoningEfforts: ['high'], defaultReasoningEffort: 'high', resolvedModel: 'claude-opus-5-5' });
});

test('optional line metadata cannot reject a custom gateway catalog or reorder OpenAI as Claude', async () => {
  const payload = { data: [{ id: 'gpt-6-astra', line: 'opus' }, { id: 'number', line: 123 }, { id: 'object', line: {} }] };
  const fetcher = async () => new Response(JSON.stringify(payload));
  const models = await fetchModels('openai', { baseURL: 'https://fixture.invalid', apiKey: 'fake' }, fetcher);
  assert.equal(models.length, 3);
  assert.ok(models.every(model => model.line === undefined));
  const claude = await fetchModels('claude', { baseURL: 'https://fixture.invalid', apiKey: 'fake' }, fetcher);
  assert.equal(claude[0].line, 'opus');
  assert.ok(claude.slice(1).every(model => model.line === undefined));
});
