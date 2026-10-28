import https from 'node:https';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';

export const RELEASE_API = 'https://api.github.com/repos/AbadOrangeCat/TheALL/releases/latest';
export const CHECK_INTERVAL = 6 * 60 * 60 * 1000;
const MAX_PACKAGE = 1024 * 1024 * 1024;
const CDN = new Set(['release-assets.githubusercontent.com', 'objects.githubusercontent.com', 'github-releases.githubusercontent.com']);
export function versionParts(value) {
  const m = /^(?:v)?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.exec(value || '');
  return m && m.slice(1).every(n => Number.isSafeInteger(Number(n))) ? m.slice(1).map(Number) : null;
}
export function newerVersion(next, current) {
  const a = versionParts(next), b = versionParts(current);
  if (!a || !b) return false;
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] > b[i];
  return false;
}
export function trustedUpdateURL(value, { metadata = false, redirect = false } = {}) {
  try {
    const u = new URL(value);
    if (u.protocol !== 'https:' || u.username || u.password || u.port || u.hash) return false;
    if (metadata) return u.href === RELEASE_API;
    if (u.hostname === 'github.com') return /^\/AbadOrangeCat\/TheALL\/releases\/download\/v\d+\.\d+\.\d+\/TheAll-[A-Za-z0-9.\-]+$/.test(u.pathname) && !u.search;
    return redirect && CDN.has(u.hostname);
  } catch { return false; }
}
export function selectRelease(release, current, arch, kind) {
  if (!['x64', 'arm64'].includes(arch) || !['nsis','portable','zip'].includes(kind)) throw new Error('Unsupported Windows update package');
  if (!release || release.draft || release.prerelease || !versionParts(release.tag_name)) return null;
  if (!newerVersion(release.tag_name, current)) return null;
  const version = versionParts(release.tag_name).join('.');
  const name = `TheAll-${version}-windows-${arch}-${kind}.${kind === 'zip' ? 'zip' : 'exe'}`;
  const matches = (release.assets || []).filter(a => a.name === name);
  if (matches.length !== 1) throw new Error('The new release does not include a compatible Windows package');
  const asset = matches[0];
  const expected = `https://github.com/AbadOrangeCat/TheALL/releases/download/${release.tag_name}/${name}`;
  if (asset.browser_download_url !== expected || !trustedUpdateURL(expected) || !/^sha256:[a-f0-9]{64}$/.test(asset.digest || '') || !Number.isSafeInteger(asset.size) || asset.size < 1 || asset.size > MAX_PACKAGE) throw new Error('The update package has no valid integrity information');
  return { version, name, url: expected, size: asset.size, sha256: asset.digest.slice(7), kind };
}
// Every hop is checked before connecting. API requests cannot redirect to a CDN.
export function requestUpdate(url, { metadata = false, maxBytes, onChunk = () => {}, timeout = 30_000 } = {}) {
  return new Promise((resolve, reject) => {
    let active, timer, finished = false;
    const finish = (error, value) => { if (finished) return; finished = true; clearTimeout(timer); if (error) active?.destroy(); error ? reject(error) : resolve(value); };
    timer = setTimeout(() => finish(new Error('The update download timed out')), timeout);
    function hop(value, redirects = 0) {
      if (!trustedUpdateURL(value, { metadata, redirect: redirects > 0 }) || redirects > 5) return finish(new Error('Untrusted update address'));
      active = https.get(value, { headers: { 'User-Agent': 'TheAll-Updater', Accept: metadata ? 'application/vnd.github+json' : 'application/octet-stream', 'Accept-Encoding': 'identity' } }, response => {
        if ([301,302,303,307,308].includes(response.statusCode)) {
          const location = response.headers.location; response.destroy();
          if (!location) return finish(new Error('Invalid update redirect'));
          try { hop(new URL(location, value).href, redirects + 1); } catch (e) { finish(e); } return;
        }
        if (response.statusCode !== 200) { response.resume(); return finish(new Error(`Update service returned HTTP ${response.statusCode}`)); }
        const length = response.headers['content-length'];
        if (length && (!/^\d+$/.test(length) || Number(length) > maxBytes)) { response.destroy(); return finish(new Error('The update download is too large')); }
        let size = 0;
        response.on('data', chunk => {
          if (finished) return;
          size += chunk.length;
          if (size > maxBytes) { response.destroy(); return finish(new Error('The update download is too large')); }
          try { onChunk(chunk); } catch (e) { response.destroy(); finish(e); }
        });
        response.on('end', () => finish(null, size)); response.on('error', finish);
      });
      active.on('error', finish); active.setTimeout(20_000, () => finish(new Error('The update connection timed out')));
    }
    hop(url);
  });
}
export async function verifyPackage(file, asset) {
  const stat = await fsp.lstat(file);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size !== asset.size) throw new Error('The update package size changed');
  const digest = createHash('sha256');
  for await (const chunk of fs.createReadStream(file)) digest.update(chunk);
  if (digest.digest('hex') !== asset.sha256) throw new Error('The update package checksum does not match');
}
export class DesktopUpdater {
  constructor({ version, arch, kind, cacheDir, enabled, request = requestUpdate, prepare, beginInstall, onInstall, onFailure = () => {}, discard = async () => {}, interval = CHECK_INTERVAL, idleInterval = 1000 }) {
    Object.assign(this, { version, arch, kind, cacheDir, enabled, request, prepare, beginInstall, onInstall, onFailure, discard, interval, idleInterval });
    this.state = { phase: enabled ? 'idle' : 'disabled', currentVersion: version }; this.stopped = false;
  }
  status() { return { ...this.state }; }
  set(phase, extra = {}) { this.state = { currentVersion: this.version, ...(this.asset ? { version: this.asset.version } : {}), phase, ...extra }; }
  start() { if (!this.enabled) return; this.check(); this.timer = setInterval(() => this.check(), this.interval); this.timer.unref?.(); }
  stop() { this.stopped = true; clearInterval(this.timer); clearTimeout(this.waitTimer); }
  check() {
    if (!this.enabled || this.stopped || this.installTask) return Promise.resolve(this.status());
    if (this.checkTask) return this.checkTask;
    this.checkTask = (async () => {
      this.set('checking');
      try {
        const chunks = []; await this.request(RELEASE_API, { metadata: true, maxBytes: 2 * 1024 * 1024, onChunk: c => chunks.push(c) });
        const next = selectRelease(JSON.parse(Buffer.concat(chunks).toString('utf8')), this.version, this.arch, this.kind);
        this.asset = next; this.set(this.previousError ? 'error' : next ? 'available' : 'upToDate', this.previousError ? {error:this.previousError} : {});
      } catch (e) { this.set('error', { error: String(e.message).slice(0,300) }); }
      return this.status();
    })().finally(() => { this.checkTask = null; });
    return this.checkTask;
  }
  install() {
    if (!this.enabled || this.stopped) return this.status();
    if (this.installTask) return this.status();
    if (!this.asset) { this.check().then(() => { if (this.asset) this.install(); }); return this.status(); }
    this.installTask = (async () => {
      if (this.checkTask) await this.checkTask;
      if (!this.asset || this.stopped) return;
      const asset = this.asset; this.previousError = null;
      this.set('downloading', { progress: 0 });
      await fsp.mkdir(this.cacheDir, { recursive: true, mode: 0o700 });
      const folder = await fsp.mkdtemp(path.join(this.cacheDir, 'update-')); this.downloadFolder = folder;
      const file = path.join(folder, asset.name), handle = await fsp.open(file, 'wx', 0o600);
      try {
        let size = 0; const hash = createHash('sha256');
        await this.request(asset.url, { maxBytes: asset.size, timeout: 15 * 60 * 1000, onChunk: chunk => {
          fs.writeSync(handle.fd, chunk); size += chunk.length; hash.update(chunk); this.set('downloading', { progress: size / asset.size });
        } });
        await handle.sync();
        if (size !== asset.size || hash.digest('hex') !== asset.sha256) throw new Error('The update package checksum does not match');
      } finally { await handle.close(); }
      await verifyPackage(file, asset);
      const prepared = await this.prepare({ file, asset, folder }); this.prepared = prepared;
      if (this.stopped) return;
      this.set('waiting');
      const attempt = async () => {
        if (this.stopped) return;
        try {
          if (!this.beginInstall()) { this.waitTimer = setTimeout(attempt, this.idleInterval); this.waitTimer.unref?.(); return; }
          await verifyPackage(file, asset);
          this.set('installing'); await this.onInstall(prepared);
        } catch (e) { this.failed(e); }
      };
      await attempt();
    })().catch(e => this.failed(e)).finally(() => { if (this.state.phase !== 'waiting' && this.state.phase !== 'installing') this.installTask = null; });
    return this.status();
  }
  failed(error) { this.onFailure?.(); this.set('error', { error: String(error.message || error).slice(0,300) }); this.installTask = null;
    const prepared=this.prepared, folder=this.downloadFolder; this.prepared=null; this.downloadFolder=null;
    Promise.resolve(this.discard(prepared)).catch(()=>{}).then(()=>folder ? fsp.rm(folder,{recursive:true,force:true}) : null).catch(()=>{});
  }
}
