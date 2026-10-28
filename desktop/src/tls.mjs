import 'reflect-metadata';
import { webcrypto, createPrivateKey, randomBytes, X509Certificate as NativeCertificate } from 'node:crypto';
import { X509Certificate, X509CertificateGenerator, BasicConstraintsExtension, KeyUsagesExtension,
  KeyUsageFlags, ExtendedKeyUsageExtension, ExtendedKeyUsage, SubjectAlternativeNameExtension,
  SubjectKeyIdentifierExtension, AuthorityKeyIdentifierExtension } from '@peculiar/x509';

const DAY = 86400000;
const ALGORITHM = { name: 'ECDSA', namedCurve: 'P-256', hash: 'SHA-256' };
const SECRET = 'lan-tls';
const locks = new WeakMap();
const invalid = () => new Error('Saved HTTPS identity is invalid or expired. Existing certificates were preserved; repair the identity before enabling HTTPS.');

function privateAddress(value) {
  if (typeof value !== 'string' || !/^(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}$/.test(value)) return false;
  const parts = value.split('.').map(Number);
  return parts.every(part => part <= 255) && (parts[0] === 10 || (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) || (parts[0] === 192 && parts[1] === 168));
}
function pem(label, bytes) {
  return `-----BEGIN ${label}-----\n${Buffer.from(bytes).toString('base64').match(/.{1,64}/g).join('\n')}\n-----END ${label}-----\n`;
}
function serial() { const value = randomBytes(16); value[0] &= 0x7f; value[0] |= 1; return value.toString('hex'); }
async function keys() { return webcrypto.subtle.generateKey(ALGORITHM, true, ['sign', 'verify']); }
async function exportKey(key) { return pem('PRIVATE KEY', await webcrypto.subtle.exportKey('pkcs8', key)); }
async function signingKey(pemKey) {
  return webcrypto.subtle.importKey('pkcs8', createPrivateKey(pemKey).export({ type: 'pkcs8', format: 'der' }), ALGORITHM, false, ['sign']);
}
function parsePart(value) {
  if (!value || typeof value.key !== 'string' || typeof value.cert !== 'string' || value.key.length > 16384 || value.cert.length > 16384 ||
      !/^-----BEGIN PRIVATE KEY-----\s+[A-Za-z0-9+/=\s]+-----END PRIVATE KEY-----\s*$/.test(value.key) ||
      !/^-----BEGIN CERTIFICATE-----\s+[A-Za-z0-9+/=\s]+-----END CERTIFICATE-----\s*$/.test(value.cert)) throw invalid();
  const key = createPrivateKey(value.key), native = new NativeCertificate(value.cert), parsed = new X509Certificate(value.cert);
  if (key.asymmetricKeyType !== 'ec' || key.asymmetricKeyDetails?.namedCurve !== 'prime256v1' || !native.checkPrivateKey(key)) throw invalid();
  return { native, parsed };
}
function extension(cert, Type) {
  const result = cert.getExtensions(Type);
  if (result.length !== 1) throw invalid();
  return result[0];
}
function validateCA(value, now) {
  const ca = parsePart(value), constraints = extension(ca.parsed, BasicConstraintsExtension), usages = extension(ca.parsed, KeyUsagesExtension);
  if (!ca.native.ca || !constraints.ca || constraints.pathLength !== 0 || !constraints.critical || !usages.critical ||
      usages.usages !== (KeyUsageFlags.keyCertSign | KeyUsageFlags.cRLSign) || ca.native.issuer !== ca.native.subject ||
      !ca.native.verify(ca.native.publicKey) || ca.parsed.notBefore.getTime() > now || ca.parsed.notAfter.getTime() <= now + DAY) throw invalid();
  return ca;
}
function validateLeaf(value, ca, now) {
  if (!privateAddress(value?.address)) throw invalid();
  const leaf = parsePart(value), constraints = extension(leaf.parsed, BasicConstraintsExtension), usages = extension(leaf.parsed, KeyUsagesExtension);
  const extended = extension(leaf.parsed, ExtendedKeyUsageExtension), names = extension(leaf.parsed, SubjectAlternativeNameExtension).names.toJSON();
  if (leaf.native.ca || constraints.ca || !constraints.critical || !usages.critical || usages.usages !== KeyUsageFlags.digitalSignature ||
      extended.usages.length !== 1 || extended.usages[0] !== ExtendedKeyUsage.serverAuth ||
      names.length !== 1 || names[0].type !== 'ip' || names[0].value !== value.address ||
      leaf.native.checkIP(value.address) !== value.address || leaf.native.issuer !== ca.native.subject || !leaf.native.verify(ca.native.publicKey) ||
      leaf.parsed.notBefore.getTime() > now || leaf.parsed.notAfter.getTime() > ca.parsed.notAfter.getTime()) throw invalid();
  return leaf;
}
async function newCA(now) {
  const pair = await keys();
  const cert = await X509CertificateGenerator.createSelfSigned({ serialNumber: serial(), name: 'CN=TheAll Local CA',
    notBefore: new Date(now - 5 * 60000), notAfter: new Date(now + 3650 * DAY), keys: pair, signingAlgorithm: ALGORITHM,
    extensions: [new BasicConstraintsExtension(true, 0, true),
      new KeyUsagesExtension(KeyUsageFlags.keyCertSign | KeyUsageFlags.cRLSign, true),
      await SubjectKeyIdentifierExtension.create(pair.publicKey, false, webcrypto)] }, webcrypto);
  return { key: await exportKey(pair.privateKey), cert: cert.toString('pem') };
}
async function newLeaf(ca, address, now) {
  const pair = await keys(), issuer = new X509Certificate(ca.cert);
  const cert = await X509CertificateGenerator.create({ serialNumber: serial(), subject: `CN=${address}`, issuer: issuer.subject,
    notBefore: new Date(now - 5 * 60000), notAfter: new Date(Math.min(now + 365 * DAY, issuer.notAfter.getTime())),
    publicKey: pair.publicKey, signingKey: await signingKey(ca.key), signingAlgorithm: ALGORITHM,
    extensions: [new BasicConstraintsExtension(false, undefined, true), new KeyUsagesExtension(KeyUsageFlags.digitalSignature, true),
      new ExtendedKeyUsageExtension([ExtendedKeyUsage.serverAuth]), new SubjectAlternativeNameExtension([{ type: 'ip', value: address }]),
      await SubjectKeyIdentifierExtension.create(pair.publicKey, false, webcrypto),
      await AuthorityKeyIdentifierExtension.create(issuer, false, webcrypto)] }, webcrypto);
  return { address, key: await exportKey(pair.privateKey), cert: cert.toString('pem') };
}

/** Call only for encrypted LAN mode. No trust-store changes or external executables. */
export async function loadLANIdentity({ store, address, now = Date.now }) {
  if (!privateAddress(address)) throw new Error('HTTPS requires a private IPv4 address on this computer.');
  if (!store || typeof store.readSecret !== 'function' || typeof store.writeSecret !== 'function') throw new Error('Encrypted identity storage is unavailable.');
  // Concurrent settings/connection requests must never generate different roots.
  const previous = locks.get(store) || Promise.resolve();
  const operation = previous.catch(() => {}).then(async () => {
    const time = now();
    if (!Number.isFinite(time)) throw new Error('Invalid certificate clock.');
    let identity = await store.readSecret(SECRET);
    if (identity !== null && identity !== undefined) {
      let leaf;
      try {
        if (identity.version !== 1) throw invalid();
        const ca = validateCA(identity.ca, time); leaf = validateLeaf(identity.leaf, ca, time);
      } catch {
        // Never replace a corrupt/root-expired record silently: phones trust this exact root.
        throw invalid();
      }
      if (identity.leaf.address !== address || leaf.parsed.notAfter.getTime() <= time + DAY) {
        identity = { ...identity, leaf: await newLeaf(identity.ca, address, time) };
        await store.writeSecret(SECRET, identity);
      }
    } else {
      const ca = await newCA(time);
      identity = { version: 1, ca, leaf: await newLeaf(ca, address, time) };
      await store.writeSecret(SECRET, identity);
    }
    return { key: identity.leaf.key, cert: identity.leaf.cert, ca: identity.ca.cert,
      fingerprint: new NativeCertificate(identity.ca.cert).fingerprint256 };
  });
  locks.set(store, operation);
  try { return await operation; }
  finally { if (locks.get(store) === operation) locks.delete(store); }
}
