#!/usr/bin/env node
// Prepare signed macOS update metadata locally. This never uploads a release.
import { createHash, createPrivateKey, createPublicKey, sign, verify } from 'node:crypto';
import { lstat, readFile, readdir, rename, writeFile, unlink } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = 'https://github.com/AbadOrangeCat/TheALL';
const seedPrefix = Buffer.from('302e020100300506032b657004220420', 'hex');
const escapeXML = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&apos;'}[c]));

export function releaseConfig(project) {
  const value = key => project.match(new RegExp(`^\\s+${key}:\\s*["']?([^\\s"'#]+)`, 'm'))?.[1];
  const version = value('MARKETING_VERSION'), build = value('CURRENT_PROJECT_VERSION');
  const publicKey = value('SUPublicEDKey');
  if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(version ?? '')) throw Error('Expected a stable release version in project.yml');
  if (!/^[1-9]\d*$/.test(build ?? '')) throw Error('Expected a positive build number');
  if (!/^[A-Za-z0-9+/]{43}=$/.test(publicKey ?? '')) throw Error('Missing or invalid SUPublicEDKey');
  return {version, build, publicKey};
}

export function signingKey(seedText, publicKey) {
  const seed = Buffer.from(seedText.trim(), 'base64');
  if (seed.length !== 32 || seed.toString('base64') !== seedText.trim()) throw Error('Expected a base64 Ed25519 32-byte private seed');
  const key = createPrivateKey({key: Buffer.concat([seedPrefix, seed]), format: 'der', type: 'pkcs8'});
  const actual = Buffer.from(createPublicKey(key).export({format: 'jwk'}).x, 'base64url').toString('base64');
  if (actual !== publicKey) throw Error('Signing key does not match the public key embedded in the app');
  return key;
}

export function renderFeed({version, build, archiveName, size, signature, notes, now = new Date()}) {
  if (archiveName !== `TheAll-${version}-macos-arm64.dmg`) throw Error('Unexpected macOS update archive name');
  return `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>TheAll</title>
    <link>${repo}</link>
    <item>
      <title>TheAll ${escapeXML(version)}</title>
      <pubDate>${now.toUTCString()}</pubDate>
      <description><![CDATA[${notes.replaceAll(']]>', ']]]]><![CDATA[>')}]]></description>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <enclosure url="${repo}/releases/download/v${escapeXML(version)}/${escapeXML(archiveName)}"
        sparkle:version="${escapeXML(build)}" sparkle:shortVersionString="${escapeXML(version)}"
        sparkle:edSignature="${escapeXML(signature)}" length="${size}" type="application/octet-stream" />
    </item>
  </channel>
</rss>
`;
}

async function regularFile(file, maxBytes) {
  const info = await lstat(file);
  if (!info.isFile() || info.size < 1 || info.size > maxBytes) throw Error(`Not a bounded regular file: ${path.basename(file)}`);
  return info;
}

async function atomicWrite(file, data) {
  try { if (!(await lstat(file)).isFile()) throw Error(`Refusing to replace a non-file: ${path.basename(file)}`); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  const temp = `${file}.${process.pid}.tmp`;
  try {
    await writeFile(temp, data, {flag: 'wx', mode: 0o644});
    await rename(temp, file);
  } finally { await unlink(temp).catch(() => {}); }
}

export async function prepareFeed({projectFile, releaseDir, keyFile, notesFile}) {
  const config = releaseConfig(await readFile(projectFile, 'utf8'));
  const release = path.resolve(releaseDir), keyPath = path.resolve(keyFile);
  const relativeKey = path.relative(release, keyPath);
  if (!relativeKey.startsWith(`..${path.sep}`) && relativeKey !== '..' && !path.isAbsolute(relativeKey)) throw Error('Keep the signing private key outside the release directory');
  const keyInfo = await regularFile(keyPath, 128);
  if (process.platform !== 'win32' && (keyInfo.mode & 0o077) !== 0) throw Error('Private key permissions must be 0600');
  const key = signingKey(await readFile(keyPath, 'utf8'), config.publicKey);
  await regularFile(notesFile, 256 * 1024);
  const notes = await readFile(notesFile, 'utf8');
  if (/[\x00-\x08\x0b\x0c\x0e-\x1f]/.test(notes)) throw Error('Release notes contain invalid XML characters');
  const archiveName = `TheAll-${config.version}-macos-arm64.dmg`;
  const archive = path.join(release, archiveName);
  await regularFile(archive, 512 * 1024 * 1024);
  const bytes = await readFile(archive);
  const signature = sign(null, bytes, key);
  if (!verify(null, bytes, createPublicKey(key), signature)) throw Error('Signature self-check failed');
  const feed = renderFeed({...config, archiveName, size: bytes.length, signature: signature.toString('base64'), notes});
  await atomicWrite(path.join(release, 'appcast.xml'), feed);

  // Only distribution artifacts enter the public checksum list; no keys/config.
  const prefix = `TheAll-${config.version}-`;
  const files = (await readdir(release)).filter(name => name === 'appcast.xml' || name === 'BUILD-INFO.txt' ||
    (name.startsWith(prefix) && /\.(dmg|zip|tar\.gz|exe)$/.test(name))).sort();
  const checksums = [];
  for (const name of files) {
    const file = path.join(release, name);
    await regularFile(file, 2 * 1024 * 1024 * 1024);
    // Use a stream for large Windows artifacts.
    const { createReadStream } = await import('node:fs');
    const hash = createHash('sha256');
    for await (const chunk of createReadStream(file)) hash.update(chunk);
    checksums.push(`${hash.digest('hex')}  ${name}`);
  }
  await atomicWrite(path.join(release, 'SHA256SUMS.txt'), checksums.join('\n') + '\n');
  return {version: config.version, build: config.build, archiveName, signature: signature.toString('base64'), files};
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = process.argv.slice(2), values = {};
    for (let i = 0; i < args.length; i += 2) {
      if (!['--release-dir', '--key-file', '--notes-file'].includes(args[i]) || !args[i + 1] || values[args[i]]) throw Error('Usage: node scripts/prepare-update-feed.mjs --release-dir DIR --key-file PRIVATE_SEED_FILE --notes-file NOTES');
      values[args[i]] = args[i + 1];
    }
    if (Object.keys(values).length !== 3) throw Error('Required: --release-dir, --key-file, --notes-file');
    const result = await prepareFeed({projectFile: fileURLToPath(new URL('../project.yml', import.meta.url)), releaseDir: values['--release-dir'], keyFile: values['--key-file'], notesFile: values['--notes-file']});
    console.log(`Prepared signed appcast for TheAll ${result.version} (build ${result.build}) and checksums for ${result.files.length} assets. No files uploaded.`);
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
