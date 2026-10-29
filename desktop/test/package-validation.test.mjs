import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { verifyDependencies } from '../scripts/verify-package.mjs';

async function fixture(t, packages) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'theall-dependency-test-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  for (const [directory, pkg] of Object.entries(packages)) {
    await fs.mkdir(path.join(root, directory), { recursive: true });
    await fs.writeFile(path.join(root, directory, 'package.json'), JSON.stringify(pkg));
  }
  return root;
}

test('rejects missing transitive required peers, including the second ASN.1 peer', async t => {
  const root = await fixture(t, {
    '.': { name: 'app', dependencies: { '@peculiar/x509': '3.1.0' } },
    'node_modules/@peculiar/x509': { name: '@peculiar/x509', peerDependencies: { '@peculiar/asn1-schema': '^3.0.0' } },
  });
  await assert.rejects(verifyDependencies(root), /requires missing @peculiar\/asn1-schema/);
  const schema = path.join(root, 'node_modules/@peculiar/asn1-schema');
  await fs.mkdir(schema);
  await fs.writeFile(path.join(schema, 'package.json'), JSON.stringify({ name: '@peculiar/asn1-schema', peerDependencies: { asn1js: '^4.0.0' } }));
  await assert.rejects(verifyDependencies(root), /requires missing asn1js/);
});

test('allows absent optional dependencies and optional peers', async t => {
  const root = await fixture(t, {
    '.': { name: 'app', dependencies: { ws: '*' }, optionalDependencies: { missing: '*' } },
    'node_modules/ws': { name: 'ws', peerDependencies: { bufferutil: '*' }, peerDependenciesMeta: { bufferutil: { optional: true } } },
  });
  assert.equal(await verifyDependencies(root), 1);
});

test('resolves nested and hoisted dependencies and terminates dependency cycles', async t => {
  const root = await fixture(t, {
    '.': { name: 'app', dependencies: { a: '*' } },
    'node_modules/a': { name: 'a', dependencies: { b: '*' } },
    'node_modules/a/node_modules/b': { name: 'b', peerDependencies: { a: '*' } },
  });
  assert.equal(await verifyDependencies(root), 2);
});

test('never satisfies an artifact dependency from its parent development node_modules', async t => {
  const parent = await fixture(t, {
    'artifact': { name: 'app', dependencies: { external: '*' } },
    'node_modules/external': { name: 'external' },
  });
  await assert.rejects(verifyDependencies(path.join(parent, 'artifact')), /requires missing external/);
});
