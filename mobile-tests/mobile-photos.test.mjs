import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
const bundle = new URL('../TheAll/Mobile/MobileWeb.bundle/', import.meta.url);
const source = await readFile(new URL('photos.js', bundle), 'utf8');
const { PHOTO_LIMITS, PhotoError, validatePhotoSelection, imagePath, freezePhotoSubmission, removeSubmittedPhotos, preparePhoto } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
const jpeg = { size: 100, type: 'image/jpeg' };

test('photo selection permits phone formats but bounds count, input size and active documents', () => {
  assert.doesNotThrow(() => validatePhotoSelection([jpeg, { size: 20, type: 'image/heic' }], 2));
  for (const [files, current, key] of [
    [[jpeg, jpeg], 3, 'photosTooMany'],
    [[{ ...jpeg, size: PHOTO_LIMITS.inputBytes + 1 }], 0, 'photosTooLarge'],
    [[{ ...jpeg, size: 0 }], 0, 'photosTooLarge'],
    [[{ ...jpeg, type: 'image/svg+xml' }], 0, 'photosInvalid'],
    [[{ ...jpeg, type: 'text/html' }], 0, 'photosInvalid']
  ]) assert.throws(() => validatePhotoSelection(files, current), error => error instanceof PhotoError && error.key === key);
});
test('history photos can only generate a same-origin chat URL with a UUID image ID', () => {
  const id = '12345678-1234-1234-1234-123456789012';
  assert.equal(imagePath('../private', id), `/api/chats/..%2Fprivate/images/${id}`);
  for (const invalid of ['../secret', 'data:image/png;base64,x', 'https://outside.example', id + '?token=secret']) assert.equal(imagePath('chat', invalid), null);
});
test('photo submissions are independent immutable copies; successful sends preserve newer draft photos', () => {
  const first = { id: 'one', name: 'photo.jpg', data: 'Zg==', preview: 'data:image/jpeg;base64,Zg==' };
  const drafts = [first]; const wire = freezePhotoSubmission(drafts); first.data = 'changed'; drafts.length = 0;
  assert.deepEqual(wire, [{ name: 'photo.jpg', data: 'Zg==' }]);
  assert.throws(() => { wire[0].data = 'another'; }, TypeError);
  assert.throws(() => wire.push({}), TypeError);
  const newer = { id: 'two', data: 'new' };
  assert.deepEqual(removeSubmittedPhotos([first, newer], ['one']), [newer]);
});
test('four normalized photos plus a maximum text message fit the HTTP and relay request budget', () => {
  const photos = Array.from({ length: PHOTO_LIMITS.count }, () => ({ name: 'x'.repeat(200), data: Buffer.alloc(PHOTO_LIMITS.bytes).toString('base64') }));
  const body = JSON.stringify({ text: 'x'.repeat(128 * 1024), images: photos, requestId: 'x'.repeat(36), bootID: 'x'.repeat(36), model: 'x'.repeat(256) });
  assert.ok(Buffer.byteLength(body) < 3 * 1024 * 1024);
});
test('service worker excludes authenticated image paths and caches only photo code', async () => {
  const handlers = new Map();
  vm.runInNewContext(await readFile(new URL('sw.js', bundle), 'utf8'), {
    self: { location: { origin: 'https://mac.example' }, addEventListener: (name, callback) => handlers.set(name, callback) },
    URL, fetch: async () => ({ ok: false }), caches: { match: async () => ({}) }
  });
  let imageCached = false, moduleCached = false;
  handlers.get('fetch')({ request: { method: 'GET', url: 'https://mac.example/api/chats/chat/images/12345678-1234-1234-1234-123456789012' }, respondWith() { imageCached = true; } });
  handlers.get('fetch')({ request: { method: 'GET', url: 'https://mac.example/photos.js' }, respondWith() { moduleCached = true; } });
  assert.equal(imageCached, false); assert.equal(moduleCached, true);
});
test('photo errors and controls are translated in all five mobile languages', async () => {
  const text = await readFile(new URL('i18n.js', bundle), 'utf8');
  const { catalog } = await import(`data:text/javascript;base64,${Buffer.from(text).toString('base64')}`);
  for (const code of ['en', 'zh-Hans', 'fr', 'ja', 'ko']) {
    for (const key of ['photosAdd', 'photosRemove', 'photosPreview', 'photosPreparing', 'photosTooMany', 'photosTooLarge', 'photosInvalid', 'photosUnavailable']) assert.ok(catalog[code][key], `${code}.${key}`);
  }
});
