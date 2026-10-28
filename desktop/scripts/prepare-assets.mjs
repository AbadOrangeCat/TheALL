import { mkdir, readFile, writeFile, copyFile, cp, readdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const desktop = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const root = path.resolve(desktop, '..');
export function replaceOnce(source, needle, replacement) {
  if (source.split(needle).length !== 2) throw new Error(`Shared mobile source changed; review the desktop adapter: ${needle.slice(0, 80)}`);
  return source.replace(needle, replacement);
}
export function adaptApp(source) {
  let result = replaceOnce(source, "const $ = id => document.getElementById(id);", "const $ = id => document.getElementById(id);\nexport const desktopHooks = {};\nconst desktopHost = window.theall || (window.parent !== window ? window.parent.theall : undefined);\nconst absoluteFolder = value => /^(?:[A-Za-z]:[\\\\/]|\\\\\\\\[^\\\\/]+[\\\\/][^\\\\/]+|\\/)/.test(value);");
  result = replaceOnce(result, "if (!directory.startsWith('/'))", 'if (!absoluteFolder(directory))');
  result = replaceOnce(result, 'async function selectChat(id) {', 'async function selectChat(id) {\n  if (await desktopHooks.beforeSelect?.(id) === false) return;');
  result = replaceOnce(result, 'function updateComposer() {', 'function updateComposer() {\n  if (desktopHost) queueMicrotask(() => desktopHooks.onComposer?.());');
  // A desktop renderer must never register a service worker that can intercept its privileged UI.
  result = replaceOnce(result, "if (secure && 'serviceWorker' in navigator)", "if (!desktopHost && secure && 'serviceWorker' in navigator)");
  const progressStart = result.indexOf('      if (turn.progress.length) {');
  const progressEnd = result.indexOf('      for (const message of turn.answers)', progressStart);
  if (progressStart < 0 || progressEnd < 0) throw new Error('Shared progress renderer changed; review desktop folding');
  result = result.slice(0, progressStart) + `      for (const message of turn.progress) {
        const key = data.id + ':' + message.id;
        const hasAnswer = turn.answers.some(m => m.role === 'assistant' && m.text?.trim());
        const saved = state.progress.get(key);
        const open = hasAnswer && !saved?.finished ? false : saved?.open ?? !hasAnswer;
        const details = el('details', 'progress'); details.open = open;
        state.progress.set(key, { open, finished: hasAnswer });
        details.append(el('summary', '', t('thinking')));
        details.append(messageNode(message, data.provider, data.id, previousNodes));
        details.addEventListener('toggle', () => { if (details.isConnected) state.progress.set(key, { open: details.open, finished: hasAnswer }); updateJump(); });
        section.append(details);
      }
` + result.slice(progressEnd);
  result = replaceOnce(result, 'for (const turn of turns(data.messages)) {', `for (const turn of turns(desktopHost ? desktopMessages(data.messages) : data.messages)) {`);
  result += `\nfunction desktopMessages(messages) {
    const limit = window.parent?.theallDesktop?.settings?.scrollbackLimit ?? 10000000;
    let bytes = 0, start = messages.length;
    const encoder = new TextEncoder();
    while (start > 0) { const next = encoder.encode(messages[start - 1].text || '').length; if (bytes + next > limit && start < messages.length) break; bytes += next; start--; }
    return messages.slice(start);
  }\n`;
  result = result.replaceAll('navigator.onLine', '(desktopHost || navigator.onLine)');
  result = replaceOnce(result, "window.addEventListener('offline', () => { live.suspend();", "window.addEventListener('offline', () => { if (desktopHost) return; live.suspend();");
  return result + `\n// Only the installed desktop's sandboxed preload enables these local controls.\nexport const desktopChat = {\n  get selected() { return state.selected; },\n  get selectedChat() { return state.chats.get(state.selected); },\n  get workspaces() { return state.workspaces; },\n  get pending() { return state.pending.has(state.selected); },\n  get drafts() { return state.drafts; },\n  get authenticated() { return state.authenticated; },\n  get imageDrafts() { return state.imageDrafts; },\n  get models() { return state.models; },\n  get efforts() { return state.efforts; },\n  setDraft(id, draft) {\n    state.drafts.set(id, draft.text || '');\n    state.imageDrafts.set(id, (draft.images || []).map(image => ({ ...image, id: image.id || crypto.randomUUID(), preview: image.preview || 'data:' + (image.mimeType || 'image/jpeg') + ';base64,' + image.data })));\n    if (draft.model !== undefined) state.models.set(id, draft.model);\n    if (draft.reasoningEffort !== undefined) state.efforts.set(id, draft.reasoningEffort);\n    if (state.selected === id) { $('draft').value = draft.text || ''; resizeDraft(); updateComposer(); }\n  },\n  refresh: poll, select: selectChat, newChat: openNewChat, update: updateComposer,\n  translate() { translatePage(); state.rendering = ''; state.questionRendering = ''; if (state.selected) renderChat(); }\n};\nif (desktopHost) import('/desktop/pane.mjs').catch(error => { showError('global-error', error.message); });\n`;
}
export function adaptLanguage(source) {
  // This build runs its agents on a PC; retain all five existing translations.
  return source.replace(/Mac/g, 'PC') + `\nconst absoluteFolders = ['Enter an absolute folder path (for example C:\\\\Users\\\\you\\\\Projects).', '请输入绝对文件夹路径，例如 C:\\\\Users\\\\you\\\\Projects。', 'Saisissez un chemin de dossier absolu, par exemple C:\\\\Users\\\\you\\\\Projects.', 'C:\\\\Users\\\\you\\\\Projects などの絶対パスを入力してください。', 'C:\\\\Users\\\\you\\\\Projects 같은 절대 폴더 경로를 입력하세요.'];\nObject.keys(supportedLanguages).forEach((code, index) => { catalog[code].absoluteDirectory = absoluteFolders[index]; });\n`;
}
export async function prepareAssets() {
  const web = path.join(desktop, 'web');
  await mkdir(web, { recursive: true });
  await cp(path.join(root, 'TheAll/Mobile/MobileWeb.bundle'), web, { recursive: true });
  await writeFile(path.join(web, 'app.js'), adaptApp(await readFile(path.join(web, 'app.js'), 'utf8')));
  await writeFile(path.join(web, 'i18n.js'), adaptLanguage(await readFile(path.join(web, 'i18n.js'), 'utf8')));
  const htmlPath = path.join(web, 'index.html');
  let html = await readFile(htmlPath, 'utf8');
  html = html.replace(/Mac/g, 'PC').replace('data-i18n="working"', 'data-i18n="thinking"').replace('placeholder="/Users/you/Projects"', 'placeholder="C:\\Users\\you\\Projects"');
  await writeFile(htmlPath, html);
  const strings = JSON.parse(await readFile(path.join(root, 'TheAll/Localization/Localizable.xcstrings'), 'utf8')).strings;
  const native = Object.fromEntries(['en', 'zh-Hans', 'fr', 'ja', 'ko'].map(language => [language, Object.fromEntries(Object.entries(strings).map(([key, value]) => [key, value.localizations?.[language]?.stringUnit?.value || value.localizations?.en?.stringUnit?.value || key]))]));
  await writeFile(path.join(desktop, 'renderer/native-strings.mjs'), 'export const catalog = ' + JSON.stringify(native) + ';\n');
  const themes = {};
  for (const name of (await readdir(path.join(desktop, 'assets/themes'))).sort()) {
    const text = await readFile(path.join(desktop, 'assets/themes', name), 'utf8');
    const colors = {};
    for (const line of text.split(/\r?\n/)) {
      const field = line.match(/^\s*(background|foreground|cursor-color|selection-background|selection-foreground)\s*=\s*#?([0-9a-f]{6})\s*$/i);
      if (field) colors[field[1]] = '#' + field[2];
      const palette = line.match(/^\s*palette\s*=\s*(\d+)\s*=\s*#?([0-9a-f]{6})\s*$/i);
      if (palette) colors['palette' + palette[1]] = '#' + palette[2];
    }
    themes[name] = colors;
  }
  await writeFile(path.join(desktop, 'renderer/themes.mjs'), 'export const themes = ' + JSON.stringify(themes) + ';\n');
  const icons = path.join(root, 'TheAll/Assets.xcassets/AppIcon.appiconset');
  await mkdir(path.join(desktop, 'assets'), { recursive: true });
  await copyFile(path.join(icons, 'icon_256x256.png'), path.join(desktop, 'assets/TheAll.png'));
  // ICO embeds original PNG representations, preserving the supplied logo exactly.
  const sizes = [16, 32, 128, 256];
  const images = await Promise.all(sizes.map(size => readFile(path.join(icons, `icon_${size}x${size}.png`))));
  const header = Buffer.alloc(6 + 16 * images.length); header.writeUInt16LE(1, 2); header.writeUInt16LE(images.length, 4);
  let offset = header.length;
  images.forEach((image, index) => {
    const slot = 6 + 16 * index, size = sizes[index];
    header[slot] = size === 256 ? 0 : size; header[slot + 1] = header[slot];
    header.writeUInt16LE(1, slot + 4); header.writeUInt16LE(32, slot + 6);
    header.writeUInt32LE(image.length, slot + 8); header.writeUInt32LE(offset, slot + 12); offset += image.length;
  });
  await writeFile(path.join(desktop, 'assets/TheAll.ico'), Buffer.concat([header, ...images]));
  await copyFile(path.join(root, 'LICENSE'), path.join(desktop, 'LICENSE'));
  const seen = new Set(); const notices = ['TheAll Desktop third-party notices\nElectron includes its own LICENSE and LICENSES.chromium.html in the installed application.\n'];
  async function dependency(name, from = desktop) {
    let location = path.join(from, 'node_modules', name);
    try { await readFile(path.join(location, 'package.json')); }
    catch { location = path.join(desktop, 'node_modules', name); }
    const pkg = JSON.parse(await readFile(path.join(location, 'package.json'), 'utf8'));
    const key = `${pkg.name}@${pkg.version}`; if (seen.has(key)) return; seen.add(key);
    notices.push(`\n--- ${key} (${pkg.license || 'see license'}) ---\n`);
    for (const name of await readdir(location)) {
      if (/^(?:licen[cs]e|copying|notice)(?:[.\-_]|$)/i.test(name)) {
        try { notices.push(await readFile(path.join(location, name), 'utf8')); } catch { /* Directories are not notices. */ }
      }
    }
    for (const child of new Set([...Object.keys(pkg.dependencies || {}), ...Object.keys(pkg.peerDependencies || {})])) {
      if (pkg.peerDependenciesMeta?.[child]?.optional) continue;
      await dependency(child, location);
    }
  }
  const pkg = JSON.parse(await readFile(path.join(desktop, 'package.json'), 'utf8'));
  for (const name of Object.keys(pkg.dependencies)) await dependency(name);
  await writeFile(path.join(desktop, 'THIRD-PARTY-NOTICES.txt'), notices.join('\n'));
  console.log('Prepared shared chat assets, Windows icon and third-party notices.');
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await prepareAssets();
