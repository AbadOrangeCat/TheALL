import test from 'node:test';
import assert from 'node:assert/strict';
import { isTrustedDesktopSender } from '../src/desktop-ipc.mjs';

const origin = 'http://127.0.0.1:54321';
function fixture() {
  const main = { processId: 12, frameToken: 'frame-token', parent: null, detached: false,
    origin, url: origin + '/desktop/index.html' };
  const contents = { id: 3, mainFrame: main, isDestroyed: () => false };
  return { main, contents, event: { sender: contents, senderFrame: { ...main } } };
}
test('accepts a live desktop main frame even when Electron returns another wrapper', () => {
  const { event, contents, main } = fixture();
  assert.notEqual(event.senderFrame, main);
  assert.equal(isTrustedDesktopSender(event, contents, origin), true);
  event.sender = { ...contents };
  assert.equal(isTrustedDesktopSender(event, contents, origin), true);
});
test('rejects another window, renderer process, or frame token', () => {
  for (const field of ['window', 'process', 'token']) {
    const { event, contents } = fixture();
    if (field === 'window') event.sender = { ...contents, id: contents.id + 1 };
    if (field === 'process') event.senderFrame.processId++;
    if (field === 'token') event.senderFrame.frameToken = 'other-frame';
    assert.equal(isTrustedDesktopSender(event, contents, origin), false, field);
  }
});
test('rejects same-origin child frames, detached frames, and missing frames', () => {
  for (const patch of [{ parent: {} }, { detached: true }, { frameToken: '' }, { processId: undefined }]) {
    const { event, contents } = fixture(); Object.assign(event.senderFrame, patch);
    assert.equal(isTrustedDesktopSender(event, contents, origin), false);
  }
  const { event, contents } = fixture(); event.senderFrame = null;
  assert.equal(isTrustedDesktopSender(event, contents, origin), false);
});
test('requires the actual origin and exact desktop document on both frame wrappers', () => {
  for (const side of ['sender', 'main']) for (const patch of [
    { origin: 'null' }, { origin: 'http://127.0.0.1:54322' },
    { url: origin + '/chat.html' }, { url: origin + '/desktop/index.html?other' },
    { url: 'about:blank' }, { url: 'https://example.com/desktop/index.html' }
  ]) {
    const { event, contents, main } = fixture(); Object.assign(side === 'main' ? main : event.senderFrame, patch);
    assert.equal(isTrustedDesktopSender(event, contents, origin), false);
  }
});
test('destroyed objects and throwing native frame accessors fail closed', () => {
  const { event, contents } = fixture();
  assert.equal(isTrustedDesktopSender(event, { ...contents, isDestroyed: () => true }, origin), false);
  event.sender = { ...contents, isDestroyed: () => true };
  assert.equal(isTrustedDesktopSender(event, contents, origin), false);
  event.sender = contents;
  Object.defineProperty(event, 'senderFrame', { get() { throw new Error('frame was destroyed'); } });
  assert.equal(isTrustedDesktopSender(event, contents, origin), false);
});
