import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { extractAll } from '@electron/asar';

// Resolve inside the artifact only. In particular, never use the checkout's
// node_modules to satisfy a missing production dependency or required peer.
export async function verifyDependencies(root) {
  root = path.resolve(root);
  const visited = new Set();
  async function resolve(from, name) {
    for (let directory = from; ; directory = path.dirname(directory)) {
      if (directory !== root && path.basename(directory) === 'node_modules') continue;
      const candidate = path.join(directory, 'node_modules', name);
      try { await fs.access(path.join(candidate, 'package.json')); return candidate; }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
      if (directory === root) break;
    }
    return null;
  }
  async function visit(directory) {
    if (visited.has(directory)) return;
    visited.add(directory);
    const pkg = JSON.parse(await fs.readFile(path.join(directory, 'package.json'), 'utf8'));
    const required = new Set(Object.keys(pkg.dependencies || {}).filter(name => !(name in (pkg.optionalDependencies || {}))));
    for (const name of Object.keys(pkg.peerDependencies || {})) {
      if (!pkg.peerDependenciesMeta?.[name]?.optional) required.add(name);
    }
    for (const name of new Set([...required, ...Object.keys(pkg.optionalDependencies || {})])) {
      const found = await resolve(directory, name);
      assert(found || !required.has(name), `Packaged ${pkg.name} requires missing ${name}`);
      if (found) await visit(found);
    }
  }
  await visit(root);
  return visited.size - 1;
}

export async function verifyArchive(archive) {
  const temporary = await fs.mkdtemp(path.join(os.tmpdir(), 'TheAll package verification '));
  try {
    extractAll(path.resolve(archive), temporary);
    const count = await verifyDependencies(temporary);
    const env = { ...process.env };
    delete env.NODE_PATH; delete env.NODE_OPTIONS; delete env.ELECTRON_RUN_AS_NODE;
    const probe = `
      import assert from 'node:assert/strict';
      import {pathToFileURL} from 'node:url';
      const {loadLANIdentity}=await import(pathToFileURL(process.argv[1]));
      let saved=null;
      const store={readSecret:async()=>saved,writeSecret:async(_,value)=>{saved=value;}};
      const first=await loadLANIdentity({store,address:'192.168.1.20'});
      const second=await loadLANIdentity({store,address:'192.168.1.20'});
      assert(saved?.ca?.cert.includes('BEGIN CERTIFICATE'));
      assert.deepEqual(second,first);
    `;
    const result = spawnSync(process.execPath, ['--input-type=module', '--eval', probe, path.join(temporary, 'src/tls.mjs')], {
      cwd: temporary, env, encoding: 'utf8', timeout: 30000,
    });
    assert.equal(result.status, 0, `Packaged TLS import/certificate probe failed: ${result.error?.message || result.stderr}`);
    console.log(`PASS: packaged production dependency closure (${count} packages), required peers and real TLS certificate round-trip`);
  } finally { await fs.rm(temporary, { recursive: true, force: true }); }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  assert.equal(process.argv.length, 3, 'Usage: node scripts/verify-package.mjs APP_ASAR');
  await verifyArchive(process.argv[2]);
}
