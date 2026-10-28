import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const root = new URL('../TheAll/Mobile/MobileWeb.bundle/', import.meta.url);
async function load(name) { return import('data:text/javascript;base64,' + Buffer.from(await readFile(new URL(name, root), 'utf8')).toString('base64')); }
const { turnTiming } = await load('timing.js');
const { reasoningOptions, selectedReasoningEffort } = await load('effort.js');
const final = { role: 'assistant', text: 'Done', completedAt: '2026-10-28T00:01:02.123Z', durationMs: 65432 };

test('turn metadata uses localized reader time and elapsed units, including subsecond and long turns', () => {
  for (const locale of ['en', 'zh-Hans', 'fr', 'ja', 'ko']) {
    const result = turnTiming(final, locale);
    assert.equal(result.time, new Intl.DateTimeFormat(locale, { dateStyle: 'short', timeStyle: 'medium' }).format(new Date(final.completedAt)));
    assert.equal(result.iso, final.completedAt); assert.ok(result.duration); assert.equal(result.status, 'completed');
  }
  assert.equal(turnTiming({ ...final, durationMs: 125 }, 'en').duration, '0.125 sec');
  assert.equal(turnTiming({ ...final, durationMs: 0 }, 'en').duration, '0 sec');
  assert.equal(turnTiming({ ...final, durationMs: 59999 }, 'en').duration, '1 min');
  assert.equal(turnTiming({ ...final, durationMs: 3661200 }, 'en').duration, '1 hr 1 min 1.2 sec');
  assert.equal(turnTiming({ ...final, completionStatus: 'interrupted' }, 'en').status, 'interrupted');
  assert.equal(turnTiming({ ...final, isError: true }, 'en').status, 'failed');
});

test('old, intermediate, user or invalid timing metadata never fabricates a completion', () => {
  for (const changes of [{ completedAt: undefined }, { durationMs: undefined }, { durationMs: -1 }, { durationMs: Infinity }, { durationMs: '500' }, { completedAt: 'invalid' }, { completedAt: '2026-99-99T00:01:00Z' }, { completedAt: '2026-02-30T00:01:00Z' }, { completedAt: '2026-10-28T00:01:00+02:00' }, { role: 'user' }, { isIntermediate: true }]) assert.equal(turnTiming({ ...final, ...changes }, 'en'), null);
});

test('reasoning options come only from selected model metadata and resolved server default', () => {
  const chat = { model: 'one', defaultModel: 'one', models: [{ id: 'one', reasoningEfforts: ['low', 'high', 'high'] }, { id: 'two' }, { id: 'future', reasoningEfforts: ['ultra', 'adaptive', '<script>', null] }] };
  assert.deepEqual(reasoningOptions(chat, 'one'), ['low', 'high']);
  assert.deepEqual(reasoningOptions(chat, ''), ['low', 'high']);
  assert.deepEqual(reasoningOptions(chat, 'two'), []); assert.deepEqual(reasoningOptions(chat, 'unknown'), []);
  assert.deepEqual(reasoningOptions({ models: chat.models }, ''), []);
  assert.deepEqual(reasoningOptions(chat, 'future'), ['ultra', 'adaptive']);
  assert.equal(selectedReasoningEffort(chat, 'future', 'ultra'), 'ultra');
  assert.deepEqual(reasoningOptions({ models: [{ id: '', reasoningEfforts: ['medium'] }] }, ''), ['medium']);
});

test('explicit draft effort survives compatible model changes, resets when unsupported and never edits backend turn data', () => {
  const chat = { reasoningEffort: 'high', models: [{ id: 'one', reasoningEfforts: ['low', 'high'] }, { id: 'two', reasoningEfforts: ['low'] }] };
  assert.equal(selectedReasoningEffort(chat, 'one', undefined), 'high');
  assert.equal(selectedReasoningEffort(chat, 'one', ''), '');
  assert.equal(selectedReasoningEffort(chat, 'one', 'low'), 'low');
  assert.equal(selectedReasoningEffort(chat, 'two', 'high'), '');
  assert.equal(selectedReasoningEffort(chat, 'two', 'low'), 'low');
  assert.equal(chat.reasoningEffort, 'high');
});
