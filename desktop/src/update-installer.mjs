import fs from 'node:fs/promises';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { verifyPackage } from './updater.mjs';
const execute = promisify(execFile);
const helper = fileURLToPath(new URL('./windows-update.ps1', import.meta.url));
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
export function validateInstallPath(value) {
  if (typeof value !== 'string' || !/^[a-z]:\\[^\r\n"<>|?*]+$/i.test(value) || /(?:^|\\)\.\.?(?:\\|$)/.test(value) || /[:\x00-\x1f]/.test(value.slice(2)) || value.endsWith('\\') || /[. ]$/.test(value)) throw new Error('Unsupported application location');
  return value;
}
export async function installationTarget(exe, env = process.env) {
  validateInstallPath(exe);
  // Other portable launchers can leave these variables in child environments.
  // Only electron-builder's TheAll launcher may select an outer executable.
  const portable = env.PORTABLE_EXECUTABLE_APP_FILENAME === 'TheAll' ? env.PORTABLE_EXECUTABLE_FILE : null;
  if (portable) {
    validateInstallPath(portable);
    const stat = await fs.lstat(portable);
    if (!stat.isFile() || stat.isSymbolicLink() || !portable.toLowerCase().endsWith('.exe')) throw new Error('Invalid portable application location');
    return { kind: 'portable', target: await fs.realpath(portable) };
  }
  const folder = await fs.realpath(path.win32.dirname(exe));
  try { const stat = await fs.lstat(path.win32.join(folder, 'Uninstall TheAll.exe')); if (stat.isFile() && !stat.isSymbolicLink()) return { kind: 'nsis', target: folder }; } catch {}
  return { kind: 'zip', target: folder };
}
export async function prepareInstaller({ file, asset, folder }, target, { userData, powershell = path.win32.join(process.env.SystemRoot || 'C:\\Windows', 'System32\\WindowsPowerShell\\v1.0\\powershell.exe') }) {
  validateInstallPath(target.target);
  const root = target.target.toLowerCase(), data = userData.toLowerCase();
  if (data === root || data.startsWith(root + '\\') || root.startsWith(data + '\\')) throw new Error('The application and data folders must be separate');
  await verifyPackage(file, asset);
  const parentPath = path.dirname(target.target);
  const probe = path.join(parentPath, `.TheAll-write-check-${randomUUID()}`);
  const writable = await fs.open(probe, 'wx', 0o600);
  await writable.close(); await fs.unlink(probe);
  const id = randomUUID(), parent = path.dirname(target.target);
  const plan = { ...target, file, sha256: asset.sha256, size: asset.size, pid: process.pid,
    stage: path.join(parent, `.TheAll-update-${id}${target.kind === 'portable' ? '.exe' : ''}`), backup: path.join(parent, `.TheAll-backup-${id}`),
    manifest: path.join(folder, 'manifest.json'), ready: path.join(folder, 'ready'), go: path.join(folder, 'go'), cancel: path.join(folder, 'cancel'), result: path.join(userData, 'Updates', 'last-result.json'),
    stdoutLog: path.join(folder,'installer.stdout.log'), stderrLog: path.join(folder,'installer.stderr.log') };
  const scriptFile = path.join(folder, 'install.ps1');
  await fs.writeFile(scriptFile, await fs.readFile(helper), { flag: 'wx', mode: 0o600 });
  const planFile = path.join(folder, 'plan.json');
  await fs.writeFile(planFile, JSON.stringify(plan), { flag: 'wx', mode: 0o600 });
  try { await execute(powershell, ['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',scriptFile,'-Plan',planFile,'-Prepare'], { cwd: path.dirname(plan.result), windowsHide: true, timeout: 180_000, maxBuffer: 1024 * 1024 }); }
  catch(error) { await fs.rm(plan.stage,{recursive:true,force:true}).catch(()=>{}); throw error; }
  if (target.kind === 'zip') {
    plan.manifestHash = createHash('sha256').update(await fs.readFile(plan.manifest)).digest('hex');
    await fs.writeFile(planFile, JSON.stringify(plan), { mode: 0o600 });
  }
  return { plan, planFile, powershell, scriptFile };
}
export async function armInstaller({ plan, planFile, powershell, scriptFile }) {
  await verifyPackage(plan.file, plan);
  // A helper must not hold the installation directory open as its working
  // directory, or Windows cannot rename a ZIP installation after app exit.
  await execute(powershell, ['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',scriptFile,'-Plan',planFile,'-Launch'], { cwd:path.dirname(plan.result), windowsHide:true, timeout:15_000, maxBuffer:1024*1024 });
  for (let i = 0; i < 150; i++) {
    try { await fs.access(plan.ready); return { go: () => fs.writeFile(plan.go, 'install', { flag: 'wx' }), cancel: () => fs.writeFile(plan.cancel, 'cancel') }; } catch {}
    await delay(100);
  }
  await fs.writeFile(plan.cancel, 'cancel');
  const detail=await fs.readFile(plan.stderrLog,'utf8').catch(()=>'');
  throw new Error('The update installer did not become ready'+(detail?'\n'+detail.slice(-4000):''));
}

export async function discardPrepared(prepared) { if (prepared?.plan) await fs.rm(prepared.plan.stage,{recursive:true,force:true}); }
