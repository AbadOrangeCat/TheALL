import test from 'node:test';
import assert from 'node:assert/strict';
import https from 'node:https';
import tls from 'node:tls';
import { X509Certificate, createPrivateKey } from 'node:crypto';
import { loadLANIdentity } from '../src/tls.mjs';

const address = '192.168.12.34';
const DAY = 86400000;
function memoryStore(initial = null) {
  let record = structuredClone(initial);
  return { reads: 0, writes: 0,
    async readSecret(name) { assert.equal(name, 'lan-tls'); this.reads++; return structuredClone(record); },
    async writeSecret(name, value) { assert.equal(name, 'lan-tls'); this.writes++; record = structuredClone(value); },
    snapshot() { return structuredClone(record); }
  };
}
async function request(port, ca, expectedAddress) {
  return new Promise((resolve, reject) => {
    // Loopback carries the fixture; certificate verification still checks the
    // private LAN IP the production browser uses, without altering system trust.
    const req = https.get({ hostname: '127.0.0.1', port, ca,
      checkServerIdentity: (_hostname, cert) => tls.checkServerIdentity(expectedAddress, cert) }, res => {
      const authorized = res.socket.authorized; let text = ''; res.setEncoding('utf8'); res.on('data', chunk => { text += chunk; });
      res.on('end', () => resolve({ status: res.statusCode, text, authorized }));
    }); req.on('error', reject);
  });
}

test('creates constrained P-256 CA and server-only IP leaf, returns only the public root', async () => {
  const store = memoryStore(), result = await loadLANIdentity({ store, address });
  assert.deepEqual(Object.keys(result).sort(), ['ca', 'cert', 'fingerprint', 'key']);
  const root = new X509Certificate(result.ca), leaf = new X509Certificate(result.cert);
  assert.equal(root.ca, true); assert.equal(leaf.ca, false); assert.ok(root.verify(root.publicKey)); assert.ok(leaf.verify(root.publicKey));
  assert.equal(leaf.checkIP(address), address); assert.equal(leaf.checkIP('192.168.12.35'), undefined);
  assert.deepEqual(leaf.keyUsage, ['1.3.6.1.5.5.7.3.1']);
  assert.ok(leaf.checkPrivateKey(createPrivateKey(result.key)));
  assert.equal(root.publicKey.asymmetricKeyDetails.namedCurve, 'prime256v1');
  assert.equal(result.fingerprint, root.fingerprint256);
  assert.equal(store.writes, 1); assert.notEqual(result.key, store.snapshot().ca.key);
  assert.ok(!result.ca.includes('PRIVATE KEY'));
});

test('real HTTPS trusts exported CA and rejects a wrong CA or LAN IP', async t => {
  const result = await loadLANIdentity({ store: memoryStore(), address });
  const other = await loadLANIdentity({ store: memoryStore(), address });
  const server = https.createServer({ key: result.key, cert: result.cert, minVersion: 'TLSv1.2' }, (_req, res) => res.end('TheAll HTTPS'));
  server.on('tlsClientError', () => {});
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); }));
  const port = server.address().port;
  const response = await request(port, result.ca, address);
  assert.deepEqual(response, { status: 200, text: 'TheAll HTTPS', authorized: true });
  await assert.rejects(request(port, other.ca, address), error => ['UNABLE_TO_VERIFY_LEAF_SIGNATURE', 'UNABLE_TO_GET_ISSUER_CERT_LOCALLY'].includes(error.code));
  await assert.rejects(request(port, result.ca, '192.168.12.35'), { code: 'ERR_TLS_CERT_ALTNAME_INVALID' });
});

test('saved identity reloads byte-for-byte unchanged, including after store recreation', async () => {
  const store = memoryStore(), original = await loadLANIdentity({ store, address });
  assert.deepEqual(await loadLANIdentity({ store, address }), original); assert.equal(store.writes, 1);
  const restarted = memoryStore(store.snapshot());
  assert.deepEqual(await loadLANIdentity({ store: restarted, address }), original); assert.equal(restarted.writes, 0);
});

test('address change rotates the leaf while retaining the exact installed CA', async () => {
  const store = memoryStore(), before = await loadLANIdentity({ store, address });
  const after = await loadLANIdentity({ store, address: '10.20.30.40' });
  assert.equal(after.ca, before.ca); assert.equal(after.fingerprint, before.fingerprint); assert.notEqual(after.cert, before.cert); assert.notEqual(after.key, before.key);
  assert.equal(new X509Certificate(after.cert).checkIP('10.20.30.40'), '10.20.30.40'); assert.equal(store.writes, 2);
});

test('expiring leaf renews under stable root and an expired root is preserved without replacement', async () => {
  const now = Date.now(), store = memoryStore(), before = await loadLANIdentity({ store, address, now: () => now });
  const after = await loadLANIdentity({ store, address, now: () => now + 365 * DAY });
  assert.equal(after.ca, before.ca); assert.notEqual(after.cert, before.cert); assert.equal(store.writes, 2);
  const saved = store.snapshot();
  await assert.rejects(loadLANIdentity({ store, address, now: () => now + 3651 * DAY }), /preserved/);
  assert.deepEqual(store.snapshot(), saved); assert.equal(store.writes, 2);
});

test('concurrent first-use and address changes never replace or export conflicting roots', async () => {
  const store = memoryStore();
  const results = await Promise.all(Array.from({ length: 5 }, () => loadLANIdentity({ store, address })));
  assert.equal(new Set(results.map(r => r.ca)).size, 1); assert.equal(new Set(results.map(r => r.key)).size, 1); assert.equal(store.writes, 1);
  const rotate = await Promise.all(['10.1.2.3','172.16.2.3','192.168.2.3'].map(address => loadLANIdentity({ store, address })));
  assert.equal(new Set([...results, ...rotate].map(r => r.ca)).size, 1); assert.equal(store.writes, 4);
});

test('public, ambiguous, loopback and non-IP addresses fail before reading or creating any secret', async () => {
  const store = memoryStore();
  for (const invalid of ['127.0.0.1','8.8.8.8','0.0.0.0','169.254.1.2','192.168.01.2','10.0.0.999','localhost','::1','172.32.0.1','10.1.2.3\n']) {
    await assert.rejects(loadLANIdentity({ store, address: invalid }), /private IPv4/);
  }
  assert.equal(store.reads, 0); assert.equal(store.writes, 0);
});

test('damaged certificate, wrong key, wrong root, mismatched SAN and unsupported record version never overwrite stored identity', async () => {
  const originalStore = memoryStore(); await loadLANIdentity({ store: originalStore, address });
  const original = originalStore.snapshot();
  const otherStore = memoryStore(); await loadLANIdentity({ store: otherStore, address }); const other = otherStore.snapshot();
  const mutations = [
    value => { value.version = 99; },
    value => { value.ca.cert = 'broken'; },
    value => { value.ca.key = other.ca.key; },
    value => { value.leaf.key = other.leaf.key; },
    value => { value.ca = other.ca; },
    value => { value.leaf.address = '10.4.5.6'; },
    value => { value.leaf.cert += original.ca.cert; },
  ];
  for (const mutate of mutations) {
    const saved = structuredClone(original); mutate(saved); const store = memoryStore(saved);
    await assert.rejects(loadLANIdentity({ store, address }), /preserved/);
    assert.deepEqual(store.snapshot(), saved); assert.equal(store.writes, 0);
  }
});

test('failed credential reads and writes fail closed without returning an unpersisted root', async () => {
  let writes = 0;
  await assert.rejects(loadLANIdentity({ address, store: { readSecret: async () => { throw new Error('DPAPI unavailable'); }, writeSecret: async () => { writes++; } } }), /DPAPI/);
  assert.equal(writes, 0);
  await assert.rejects(loadLANIdentity({ address, store: { readSecret: async () => null, writeSecret: async () => { throw new Error('Disk unavailable'); } } }), /Disk unavailable/);
});
