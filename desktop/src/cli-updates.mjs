import { execFile } from 'node:child_process';
import { stat, realpath } from 'node:fs/promises';
import { win32 as path } from 'node:path';
import { promisify } from 'node:util';
import { resolveCLI } from './ai.mjs';
import { CHECK_INTERVAL, newerVersion, versionParts } from './updater.mjs';

const execute = promisify(execFile);
const packages = { claude: '@anthropic-ai/claude-code', openai: '@openai/codex' };
const ids = { claude: 'Anthropic.ClaudeCode', openai: 'OpenAI.Codex' };
const registry = 'https://registry.npmjs.org';
const exists = async file => (await stat(file).catch(() => null))?.isFile();
const same = (a,b) => path.normalize(a).toLowerCase() === path.normalize(b).toLowerCase();

export async function installation(provider, cli, env, fileExists = exists) {
  const script = cli.prefix[0];
  const entry = path.normalize(script || cli.command);
  const names = provider === 'claude' ? ['cli.js','bin/claude.exe'] : ['bin/codex.js'];
  const suffix = names.map(name=>path.join('node_modules',packages[provider],name)).find(end=>entry.toLowerCase().endsWith(path.sep+end.toLowerCase()));
  if (suffix) {
    const prefix = entry.slice(0,-suffix.length);
    const envPath = Object.entries(env).find(([key]) => key.toLowerCase() === 'path')?.[1] || '';
    const nodes = script ? [cli.command] : envPath.split(';').filter(Boolean).map(dir=>path.join(dir,'node.exe'));
    for (const node of nodes) {
      const npm = path.join(path.dirname(node),'node_modules','npm','bin','npm-cli.js');
      if (await fileExists(node) && await fileExists(npm)) return {kind:'npm',node,npm,prefix};
    }
    return null;
  }
  if (script) return null;
  const local = env.LOCALAPPDATA;
  if (local) {
    const id = ids[provider];
    const target = await realpath(cli.command).catch(() => cli.command);
    const directory = path.relative(path.join(local,'Microsoft','WinGet','Packages'),target).split(path.sep)[0];
    if (directory.toLowerCase().startsWith(id.toLowerCase() + '_microsoft.winget.source_')) {
      const winget = path.join(local,'Microsoft','WindowsApps','winget.exe');
      if (await fileExists(winget)) return {kind:'winget',winget,id};
    }
    const codexDir = env.CODEX_INSTALL_DIR || path.join(local,'Programs','OpenAI','Codex','bin');
    if (provider === 'openai' && same(cli.command,path.join(codexDir,'codex.exe'))) return {kind:'native'};
  }
  if (provider === 'claude' && env.USERPROFILE && same(cli.command,path.join(env.USERPROFILE,'.local','bin','claude.exe'))) return {kind:'native'};
  return null;
}

async function run(command,args,cli,timeout = 15000) {
  const env = {...process.env};
  delete env.NODE_OPTIONS;
  delete env.ELECTRON_RUN_AS_NODE;
  if (cli?.runAsNode) env.ELECTRON_RUN_AS_NODE = '1';
  const child = execute(command,args,{env,windowsHide:true,timeout,maxBuffer:1024*1024});
  child.child.stdin?.end();
  return (await child).stdout;
}

export async function inspectCLI(provider, executable) {
  let cli;
  try { cli = await resolveCLI(provider,{executable}); }
  catch(error) { if (!executable && error.message.includes('CLI was not found')) return null; throw error; }
  const raw = await run(cli.command,[...cli.prefix,'--version'],cli);
  const version = raw.trim().match(/^(?:codex-cli\s+)?(\d+\.\d+\.\d+)(?:\s|$)/)?.[1];
  if (!versionParts(version)) throw new Error('Unrecognized CLI version.');
  const manager = await installation(provider,cli,process.env);
  // npm releases may migrate from a JS entry to a native executable under the same prefix.
  const target = manager?.kind === 'npm' ? path.join(manager.prefix,'node_modules',packages[provider]) : cli.prefix[0] || cli.command;
  return {cli, version, target, manager};
}

async function latestCLI(provider, installed) {
  if (installed.manager?.kind === 'winget') {
    const {winget,id} = installed.manager;
    const output = await run(winget,['show','--id',id,'--exact','--source','winget','--versions','--disable-interactivity','--accept-source-agreements']);
    const versions = output.split(/\r?\n/).map(line=>line.trim()).filter(v=>versionParts(v));
    if (!versions.length) throw new Error('WinGet did not report a version.');
    return versions.reduce((a,b)=>newerVersion(b,a)?b:a);
  }
  const response = await fetch(registry+'/'+packages[provider]+'/latest',{signal:AbortSignal.timeout(12000),redirect:'error'});
  if (!response.ok) throw new Error('Could not check the package registry.');
  const release = await response.json();
  if (release.name !== packages[provider] || !versionParts(release.version)) throw new Error('Invalid CLI release.');
  return release.version;
}

async function applyCLI(provider,{cli,manager},version) {
  if (manager.kind === 'npm') {
    await run(manager.node,[manager.npm,'install','--global','--prefix',manager.prefix,'--registry',registry,packages[provider]+'@'+version],{runAsNode:manager.node===process.execPath},300000);
  } else if (manager.kind === 'winget') {
    await run(manager.winget,['upgrade','--id',manager.id,'--exact','--source','winget','--version',version,'--disable-interactivity','--accept-package-agreements','--accept-source-agreements'],null,300000);
  } else {
    await run(cli.command,['update'],cli,300000);
  }
}

export class CLIUpdates {
  constructor({enabled,inspect,latest=latestCLI,apply=applyCLI,withIdle=(_provider, op) => op()}) {
    Object.assign(this,{enabled,inspect,latest,apply,withIdle});
    this.rows = {}; this.offers = new Map(); this.busy = new Set();
  }
  start() {
    if (!this.enabled || this.timer) return;
    this.check();
    this.timer = setInterval(()=>this.check(),CHECK_INTERVAL); this.timer.unref();
  }
  stop() { clearInterval(this.timer); }
  status() { return structuredClone(this.rows); }
  async check() {
    if (this.enabled) await Promise.all(Object.keys(packages).map(provider=>this.checkProvider(provider)));
    return this.status();
  }
  async checkProvider(provider) {
    if (this.busy.has(provider)) return;
    this.busy.add(provider);
    this.rows[provider]={phase:'checking'};
    this.offers.delete(provider);
    try {
      const current=await this.inspect(provider);
      if (!current) {this.rows[provider]={phase:'missing'};return;}
      const version=await this.latest(provider,current);
      const available=newerVersion(version,current.version);
      const phase = !available ? 'current' : current.manager ? 'available' : 'manual';
      this.rows[provider]={phase,current:current.version,version};
      if (phase==='available') this.offers.set(provider,current);
    } catch { this.rows[provider]={phase:'checkError'}; }
    finally {this.busy.delete(provider);}
  }
  async install(provider) {
    if (!Object.hasOwn(packages,provider)) throw new Error('Unknown CLI.');
    const offer=this.offers.get(provider);
    if (!this.enabled || !offer || this.busy.has(provider)) return this.status();
    this.busy.add(provider);
    const row=this.rows[provider]; row.phase='installing';
    try {
      const current=await this.inspect(provider);
      if (!current || current.target!==offer.target || JSON.stringify(current.manager)!==JSON.stringify(offer.manager)) {
        this.offers.delete(provider); row.phase='checkError'; return this.status();
      }
      if (newerVersion(row.version,current.version)) await this.withIdle(provider, () => this.apply(provider,current,row.version));
      const installed=await this.inspect(provider);
      if (!installed || installed.target!==offer.target || newerVersion(row.version,installed.version)) throw new Error('Version verification failed.');
      this.offers.delete(provider); this.rows[provider]={phase:'current',current:installed.version,version:installed.version};
    } catch {row.phase='error';}
    finally {this.busy.delete(provider);}
    return this.status();
  }
}
