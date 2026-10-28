import { createRequire } from 'node:module';

// package.json is the desktop's single version source; scripts/sync-version.py keeps it equal to project.yml.
export const APP_VERSION = createRequire(import.meta.url)('../package.json').version;
