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
