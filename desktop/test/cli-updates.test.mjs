import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, writeFile, rm} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {resolveCLI} from '../src/ai.mjs';
import { CLIUpdates, installation } from '../src/cli-updates.mjs';

test('recognizes the exact Windows npm entry and known native paths', async () => {
  const env={USERPROFILE:'C:\\User',LOCALAPPDATA:'C:\\User\\Local'};
  const cli={command:'C:\\node\\node.exe',prefix:['D:\\tools\\node_modules\\@openai\\codex\\bin\\codex.js']};
  assert.equal((await installation('openai',cli,env,async()=>true)).kind,'npm');
  cli.prefix=['D:\\tools\\unrelated.js'];
  assert.equal(await installation('openai',cli,env),null);
  assert.equal((await installation('claude',{command:'C:\\User\\.local\\bin\\claude.exe',prefix:[]},env)).kind,'native');
  assert.equal(await installation('openai',{command:'D:\\codex.exe',prefix:[]},env),null);
});

test('re-resolves before installation and verifies the new CLI version', async () => {
  let version='1.2.0', target='fixture', runs=0;
  const updates=new CLIUpdates({enabled:true,inspect:async()=>({version,target,manager:{kind:'native'}}),
    latest:async()=>'1.3.0',apply:async()=>{runs++;}});
  await updates.check();assert.equal(updates.status().claude.phase,'available');
  target='other';await updates.install('claude');assert.equal(runs,0);
  await updates.check();await updates.install('claude');assert.equal(runs,1);assert.equal(updates.status().claude.phase,'error');
  updates.apply=async()=>{version='1.3.0';};
  await updates.install('claude');assert.equal(updates.status().claude.phase,'current');
  await assert.rejects(updates.install('__proto__'));
});

test('modern npm Claude launches its packaged native entry and updates using npm', async t => {
  const root=await mkdtemp(path.join(os.tmpdir(),'claude-bin-'));
  t.after(()=>rm(root,{force:true,recursive:true}));
  const bin=path.join(root,'node_modules','@anthropic-ai','claude-code','bin','claude.exe');
  await mkdir(path.dirname(bin),{recursive:true});
  await writeFile(bin,'native fixture');
  const shim=path.join(root,'claude.cmd'); await writeFile(shim,'npm shim');
  const cli=await resolveCLI('claude',{platform:'win32',executable:shim,env:{Path:root}});
  assert.deepEqual(cli,{command:bin,prefix:[],runAsNode:false});
  const manager=await installation('claude',{...cli,command:'D:\\cli\\node_modules\\@anthropic-ai\\claude-code\\bin\\claude.exe'},{Path:'C:\\node'},async()=>true);
  assert.equal(manager.kind,'npm'); assert.equal(manager.node,'C:\\node\\node.exe');
});
