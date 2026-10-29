import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, createPublicKey, createHash, verify } from 'node:crypto';
import { mkdtemp, mkdir, writeFile, readFile, rm, chmod, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { prepareFeed, releaseConfig, signingKey } from './prepare-update-feed.mjs';

async function fixture(t) {
  const root = await mkdtemp(path.join(tmpdir(), 'theall-feed-test-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  const privateKey = generateKeyPairSync('ed25519').privateKey;
  const publicKey = Buffer.from(createPublicKey(privateKey).export({format:'jwk'}).x, 'base64url').toString('base64');
  const projectFile = path.join(root, 'project.yml'), keyFile = path.join(root, 'private.key');
  const releaseDir = path.join(root, 'release'), notesFile = path.join(root, 'notes.md');
  await mkdir(releaseDir);
  await writeFile(projectFile, `properties:\n  MARKETING_VERSION: "1.2.3"\n  CURRENT_PROJECT_VERSION: 7\n  SUPublicEDKey: "${publicKey}"\n`);
  await writeFile(keyFile, Buffer.from(privateKey.export({format:'jwk'}).d, 'base64url').toString('base64')+'\n', {mode:0o600});
  await writeFile(notesFile, 'Update <notes> & text ]]> end');
  const archive = path.join(releaseDir, 'TheAll-1.2.3-macos-arm64.dmg');
  await writeFile(archive, 'test archive, not an installer');
  return {root, projectFile, keyFile, releaseDir, notesFile, archive, publicKey, privateKey};
}

test('feed binds version, build, signed archive and checksums without including secrets', async t => {
  const f = await fixture(t);
  await writeFile(path.join(f.releaseDir, 'private-not-for-upload.key'), 'secret sentinel');
  const result = await prepareFeed(f);
  assert(verify(null, await readFile(f.archive), createPublicKey(f.privateKey), Buffer.from(result.signature, 'base64')));
  assert(!verify(null, Buffer.from('tampered'), createPublicKey(f.privateKey), Buffer.from(result.signature, 'base64')));
  const xml = await readFile(path.join(f.releaseDir, 'appcast.xml'), 'utf8');
  assert.match(xml, /sparkle:version="7" sparkle:shortVersionString="1\.2\.3"/);
  assert.match(xml, /releases\/download\/v1\.2\.3\/TheAll-1\.2\.3-macos-arm64\.dmg/);
  assert.match(xml, /<sparkle:hardwareRequirements>arm64<\/sparkle:hardwareRequirements>/);
  assert.match(xml, /\]\]\]\]><!\[CDATA\[>/);
  const sums = await readFile(path.join(f.releaseDir, 'SHA256SUMS.txt'), 'utf8');
  assert(!sums.includes('private'));
  for (const name of result.files) assert(sums.includes(`${createHash('sha256').update(await readFile(path.join(f.releaseDir, name))).digest('hex')}  ${name}`));
});

test('wrong key and malformed version cannot produce trusted update metadata', async t => {
  const f = await fixture(t);
  const wrong = generateKeyPairSync('ed25519').privateKey;
  assert.throws(() => signingKey(Buffer.from(wrong.export({format:'jwk'}).d, 'base64url').toString('base64'), f.publicKey), /does not match/);
  assert.throws(() => releaseConfig(`  MARKETING_VERSION: 1.2.3-beta\n  CURRENT_PROJECT_VERSION: 7\n  SUPublicEDKey: ${f.publicKey}\n`), /stable/);
  await writeFile(f.keyFile, 'invalid');
  await assert.rejects(prepareFeed(f), /private seed/);
});

test('private key must be outside release folder and private on POSIX', async t => {
  const f = await fixture(t);
  await assert.rejects(prepareFeed({...f, keyFile: path.join(f.releaseDir, 'sign.key')}), /outside/);
  if (process.platform !== 'win32') {
    await chmod(f.keyFile, 0o644);
    await assert.rejects(prepareFeed(f), /permissions/);
  }
});

test('rejects unsafe output symlinks and invalid XML notes', async t => {
  const f = await fixture(t);
  await writeFile(f.notesFile, 'bad\x01note');
  await assert.rejects(prepareFeed(f), /XML/);
  await writeFile(f.notesFile, 'good note');
  if (process.platform !== 'win32') {
    await symlink(f.keyFile, path.join(f.releaseDir, 'appcast.xml'));
    await assert.rejects(prepareFeed(f), /non-file/);
    assert((await readFile(f.keyFile, 'utf8')).length > 40);
  }
});
