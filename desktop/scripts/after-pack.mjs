import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { Arch } from 'builder-util';
import { verifyArchive } from './verify-package.mjs';

// Runs for every packaging command, including both existing Windows CI jobs.
// Failure blocks creation/upload of installers without relying on source tests.
export default async function afterPack(context) {
  if (context.electronPlatformName !== 'win32') return;
  await verifyArchive(path.join(context.appOutDir, 'resources', 'app.asar'));
  const script = fileURLToPath(new URL('desktop-smoke.mjs', import.meta.url));
  await new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [script, '--package-dir', context.appOutDir, '--arch', Arch[context.arch]], {
      stdio: 'inherit', shell: false,
    });
    child.once('error', reject);
    child.once('exit', (code, signal) => code === 0 ? resolve() : reject(new Error(`Packaged desktop smoke failed (${code ?? signal})`)));
  });
}
