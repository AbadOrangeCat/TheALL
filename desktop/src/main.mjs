import { app, BrowserWindow, dialog, ipcMain, safeStorage, nativeImage, shell, Menu, clipboard, nativeTheme } from 'electron';
import path from 'node:path';
import { writeFile } from 'node:fs/promises';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import QRCode from 'qrcode';
import { createRuntime } from './runtime.mjs';
import { externalWebURL, validDesktopURL } from '../renderer/security.mjs';
import { imageDimensions } from '../renderer/image-headers.mjs';
import { themeTokens } from '../renderer/theme.mjs';
import { isTrustedDesktopSender } from './desktop-ipc.mjs';
import { DesktopUpdater } from './updater.mjs';
import { installationTarget, prepareInstaller, armInstaller, discardPrepared } from './update-installer.mjs';
import { readFile, rm } from 'node:fs/promises';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const development = !app.isPackaged;
// Installed, development and explicitly isolated smoke-test stores never overlap.
const dataDir = process.env.THEALL_TEST_DATA_DIR
  ? path.resolve(process.env.THEALL_TEST_DATA_DIR)
  : path.join(app.getPath('appData'), development ? 'TheAll Development' : 'TheAll');
app.setName(development ? 'TheAll dev' : 'TheAll');
app.setPath('userData', dataDir);
app.setAppUserModelId('com.theall.app.windows');
const allowedMethods = new Set([
  'settings.get', 'connection.save', 'connection.remove', 'models.list', 'folder.select',
  'chat.update', 'workspace.rename', 'workspace.delete', 'mobile.enable', 'mobile.disable',
  'mobile.pair', 'mobile.devices', 'mobile.revoke', 'draft.get', 'draft.save',
  'workspace.create', 'workspace.select', 'workspace.reorder', 'tab.create', 'tab.select', 'tab.rename', 'tab.close', 'tab.reorder',
  'pane.split', 'pane.close', 'pane.resize', 'settings.save', 'mobile.relay.status', 'mobile.relay.configure', 'mobile.info', 'mobile.certificate', 'workspace.metadata'
]);
let runtime;
let window;
let quitting = false;
let shutdownTask;
let updater, pendingUpdate;

function trustedSender(event) {
  return !!window && !window.isDestroyed() && !!runtime
    && isTrustedDesktopSender(event, window.webContents, runtime.url);
}
async function openWindow() {
  if (window && !window.isDestroyed()) { window.restore(); window.focus(); return; }
  window = new BrowserWindow({
    width: 1280, height: 850, minWidth: 820, minHeight: 540,
    title: development ? 'TheAll dev' : 'TheAll', show: false,
    icon: path.join(root, 'assets', 'TheAll.png'), backgroundColor: '#121213', backgroundMaterial: process.platform === 'win32' ? 'auto' : undefined,
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(root, 'src', 'preload.cjs'), sandbox: true,
      contextIsolation: true, nodeIntegration: false, webSecurity: true,
      allowRunningInsecureContent: false, spellcheck: true,
      partition: 'persist:theall-desktop'
    }
  });
  const target = new URL('/desktop/index.html', runtime.url);
  if (!validDesktopURL(target.href)) {
    throw new Error('The desktop service must use local loopback HTTP');
  }
  await window.webContents.session.cookies.set({
    url: target.origin, name: 'TheAllDesktopSession', value: runtime.desktopToken,
    httpOnly: true, secure: false, sameSite: 'strict', path: '/'
  });
  window.webContents.session.setPermissionRequestHandler((contents, permission, callback, details) => callback(permission === 'local-fonts' && contents === window.webContents && String(details?.requestingUrl || '').startsWith(target.origin + '/')));
  window.webContents.session.setPermissionCheckHandler((contents, permission, origin) => permission === 'local-fonts' && contents === window.webContents && origin === target.origin);
  window.webContents.on('will-attach-webview', event => event.preventDefault());
  window.webContents.on('will-navigate', (event, value) => {
    if (value === target.href || value === `${target.origin}/`) return;
    event.preventDefault();
    if (externalWebURL(value) && new URL(value).origin !== target.origin) shell.openExternal(value).catch(() => {});
  });
  window.webContents.setWindowOpenHandler(({ url }) => {
    if (externalWebURL(url) && new URL(url).origin !== target.origin) shell.openExternal(url).catch(() => {});
    return { action: 'deny' };
  });
  window.webContents.on('will-prevent-unload', event => event.preventDefault());
  window.once('ready-to-show', () => { if (!process.env.THEALL_TEST_HIDE_WINDOW) window.show(); });
  window.on('close', event => {
    if (quitting) return;
    event.preventDefault();
    app.quit();
  });
  await updateWindowEffects();
  await window.loadURL(target.href);
}

async function updateWindowEffects() {
  if (!runtime || !window) return;
  const settings = await runtime.desktop('settings.get', {});
  const supportsGlass = process.platform === 'win32' && Number(os.release().split('.')[2]) >= 22621;
  if (supportsGlass) window.setBackgroundMaterial(settings.backgroundBlur > 0 ? 'acrylic' : 'none');
  window.setBackgroundColor(supportsGlass && settings.backgroundBlur > 0 ? '#00000000' : themeTokens(settings.theme, nativeTheme.shouldUseDarkColors)['--canvas']);
}

if (!app.requestSingleInstanceLock()) app.quit();
else {
  app.on('second-instance', () => { if (window) { if (window.isMinimized()) window.restore(); window.show(); window.focus(); } });
  app.on('activate', () => { if (runtime) openWindow().catch(fatal); });
  app.on('window-all-closed', () => app.quit());
  app.on('before-quit', event => {
    if (!runtime) return;
    event.preventDefault();
    if (shutdownTask) return;
    quitting = true;
    let handoff;
    shutdownTask = (async () => {
      if (pendingUpdate) handoff = await armInstaller(pendingUpdate);
      await Promise.race([
        window && !window.isDestroyed() ? window.webContents.executeJavaScript('window.theallFlushDrafts?.()') : Promise.resolve(),
        new Promise((_, reject) => setTimeout(() => reject(new Error('Saving your draft is taking longer than expected. Try closing again.')), 8000))
      ]);
      if (handoff) await handoff.go();
      await runtime.close();
      updater?.stop(); runtime = undefined; app.quit();
    })().catch(async error => {
      await handoff?.cancel().catch(() => {}); pendingUpdate = undefined; runtime?.abortUpdate(); updater?.failed(error);
      shutdownTask = undefined; quitting = false;
      dialog.showErrorBox('TheAll could not save its data', String(error.message || error));
    });
  });
  app.whenReady().then(async () => {
    Menu.setApplicationMenu(null);
    runtime = await createRuntime({
      dataDir, webRoot: path.join(root, 'web'), desktopRoot: path.join(root, 'renderer'),
      encrypt: async value => {
        if (!await safeStorage.isAsyncEncryptionAvailable()) throw new Error('Windows credential encryption is unavailable. Sign in to Windows and try again.');
        if (process.platform === 'linux' && safeStorage.getSelectedStorageBackend() === 'basic_text') throw new Error('An encrypted system credential store is required.');
        return safeStorage.encryptStringAsync(value);
      },
      decrypt: async value => {
        if (!await safeStorage.isAsyncEncryptionAvailable()) throw new Error('The saved connection cannot be decrypted by this operating-system account.');
        const decrypted = await safeStorage.decryptStringAsync(Buffer.from(value));
        return decrypted.result;
      },
      normalizeImage: async buffer => {
        imageDimensions(buffer);
        let image = nativeImage.createFromBuffer(buffer);
        if (image.isEmpty()) throw new Error('The image could not be decoded');
        const size = image.getSize();
        if (!size.width || !size.height || size.width * size.height > 16_000_000) throw new Error('The image is too large');
        const scale = Math.min(1, 2048 / Math.max(size.width, size.height));
        if (scale < 1) image = image.resize({ width: Math.round(size.width * scale), height: Math.round(size.height * scale), quality: 'best' });
        const output = image.getSize();
        return { data: image.toJPEG(88), mimeType: 'image/jpeg', ...output };
      },
      selectDirectory: async value => {
        const directory = typeof value === 'string' ? value : value?.directory;
        const result = await dialog.showOpenDialog(window, { defaultPath: directory || os.homedir(), properties: ['openDirectory'], title: 'TheAll — Choose working folder' });
        return result.canceled ? null : result.filePaths[0] || null;
      }
    });
    ipcMain.handle('theall:desktop', async (event, method, payload) => {
      if (!runtime || !trustedSender(event)) throw new Error('Unauthorized desktop request');
      if (method === 'update.status') return updater.status();
      if (method === 'update.check') return updater.check();
      if (method === 'update.install') return updater.install();
      if (method === 'app.info') return { version: app.getVersion(), platform: process.platform, development };
      if (method === 'clipboard.writeText') {
        if (typeof payload?.text !== 'string' || Buffer.byteLength(payload.text) > 128 * 1024) throw new Error('Selection is too large');
        clipboard.writeText(payload.text); return { ok: true };
      }
      if (method === 'mobile.exportCertificate') {
        const certificate = await runtime.desktop('mobile.certificate', {});
        const result = await dialog.showSaveDialog(window, { title: 'TheAll — Export phone certificate', defaultPath: 'TheAll-Phone-CA.crt', filters: [{ name: 'Public certificate', extensions: ['crt'] }] });
        if (result.canceled || !result.filePath) return { saved: false };
        await writeFile(result.filePath, certificate.pem, { mode: 0o600 }); return { saved: true, fingerprint: certificate.fingerprint };
      }
      if (!allowedMethods.has(method) || !payload || typeof payload !== 'object' || Array.isArray(payload)) throw new Error('Unsupported desktop operation');
      const result = await runtime.desktop(method, payload);
      if (method === 'settings.save') await updateWindowEffects();
      if (method === 'mobile.pair' && result?.url) {
        return { ...result, qrDataURL: await QRCode.toDataURL(result.url, { errorCorrectionLevel: 'M', width: 296, margin: 2 }) };
      }
      return result;
    });
    const updatesEnabled = !development && process.platform === 'win32' && !process.env.THEALL_TEST_DATA_DIR;
    let target;
    try { if (updatesEnabled) target = await installationTarget(process.execPath); } catch {}
    updater = new DesktopUpdater({ version: app.getVersion(), arch: process.arch, kind: target?.kind || 'nsis',
      enabled: updatesEnabled && !!target, cacheDir: path.join(dataDir, 'Updates'),
      prepare: download => prepareInstaller(download, target, { userData: dataDir }),
      discard: discardPrepared, beginInstall: () => runtime?.tryBeginUpdate(), onFailure: () => runtime?.abortUpdate(),
      onInstall: async prepared => { pendingUpdate = prepared; app.quit(); }
    });
    try {
      const resultFile = path.join(dataDir, 'Updates', 'last-result.json');
      const result = JSON.parse(await readFile(resultFile, 'utf8'));
      await rm(resultFile);
      if (!result.ok) updater.previousError = String(result.error || 'The previous update could not be installed').slice(0,300);
    } catch {}
    await openWindow();
    updater.start();
  }).catch(fatal);
}
function fatal(error) {
  // Startup failures never remove a store or silently replace it with empty data.
  dialog.showErrorBox('TheAll could not start', String(error?.message || error));
  app.quit();
}
