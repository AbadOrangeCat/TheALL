import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { prepareInstaller, armInstaller } from '../src/update-installer.mjs';
const execute=promisify(execFile), windows=process.platform==='win32';
const ps=path.win32.join(process.env.SystemRoot||'C:\\Windows','System32\\WindowsPowerShell\\v1.0\\powershell.exe');
const quote=value=>"'"+value.replaceAll("'","''")+"'";
async function powershell(code){return execute(ps,['-NoProfile','-NonInteractive','-Command',code],{windowsHide:true,timeout:60000});}
async function fixture(t){
 const root=await fs.mkdtemp(path.join(os.tmpdir(),'TheAll updater 中文 '));t.after(()=>fs.rm(root,{recursive:true,force:true,maxRetries:20,retryDelay:200}));
 const userData=path.join(root,'profile'),folder=path.join(userData,'Updates','update-test');await fs.mkdir(folder,{recursive:true});
 return {root,userData,folder};
}
async function executable(destination,marker){
 const source=`using System.IO; public class Fixture { public static void Main() { File.WriteAllText(${JSON.stringify(marker)}, "started"); } }`;
 await powershell(`Add-Type -TypeDefinition ${quote(source)} -OutputAssembly ${quote(destination)} -OutputType ConsoleApplication`);
}
async function asset(file,kind){const bytes=await fs.readFile(file);return {kind,size:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex')};}
async function waitFile(file){for(let i=0;i<400;i++){try{return await fs.readFile(file,'utf8');}catch{}await new Promise(r=>setTimeout(r,50));}throw new Error('Helper result timed out');}
async function commit(prepared){
 // The actual launching Node process exits. This catches Windows job/console
 // bugs that a fake parent PID cannot detect while the test process stays alive.
 const code=`import fs from 'node:fs/promises';import {armInstaller} from ${JSON.stringify(new URL('../src/update-installer.mjs',import.meta.url).href)};const p=JSON.parse(await fs.readFile(process.argv[1],'utf8'));p.plan.pid=process.pid;await fs.writeFile(p.planFile,JSON.stringify(p.plan));const handoff=await armInstaller(p);await handoff.go();`;
 const input=path.join(path.dirname(prepared.planFile),'test-handoff.json');await fs.writeFile(input,JSON.stringify(prepared));
 await execute(process.execPath,['--input-type=module','-e',code,input],{cwd:prepared.plan.kind==='zip'?prepared.plan.target:undefined,windowsHide:true,timeout:30000});
 return JSON.parse(await waitFile(prepared.plan.result));
}
test('Windows NSIS helper waits for the saved application to exit and preserves the installation path',{skip:!windows,timeout:90000},async t=>{
 const f=await fixture(t),target=path.join(f.root,'Installed TheAll 中文'),file=path.join(f.folder,'setup.exe'),marker=path.join(f.root,'installer-command');
 await fs.mkdir(target);await fs.writeFile(path.join(f.userData,'history.json'),'preserved');
 const source=`using System; using System.IO; public class Fixture { public static void Main() { File.WriteAllText(${JSON.stringify(marker)}, Environment.CommandLine); } }`;
 await powershell(`Add-Type -TypeDefinition ${quote(source)} -OutputAssembly ${quote(file)} -OutputType ConsoleApplication`);
 const prepared=await prepareInstaller({file,asset:await asset(file,'nsis'),folder:f.folder},{kind:'nsis',target},{userData:f.userData});
 const child=spawn(process.execPath,['-e','process.stdin.resume()'],{stdio:['pipe','ignore','ignore'],windowsHide:true});t.after(()=>child.stdin.end());
 prepared.plan.pid=child.pid;await fs.writeFile(prepared.planFile,JSON.stringify(prepared.plan));
 const handoff=await armInstaller(prepared);await handoff.go();await new Promise(r=>setTimeout(r,150));
 await assert.rejects(fs.access(marker));child.stdin.end();
 const result=JSON.parse(await waitFile(prepared.plan.result));assert.equal(result.ok,true,result.error);
 const command=await waitFile(marker);assert(command.includes('/S --updated --force-run /D='+target));
 assert.equal(await fs.readFile(path.join(f.userData,'history.json'),'utf8'),'preserved');
});
test('Windows portable helper waits for exit, replaces the outer executable and preserves backup/profile',{skip:!windows,timeout:90000},async t=>{
 const f=await fixture(t),target=path.join(f.root,'TheAll portable.exe'),next=path.join(f.folder,'next.exe'),marker=path.join(f.root,'new-started');
 await executable(target,path.join(f.root,'old-started'));const original=await fs.readFile(target);await executable(next,marker);
 await fs.writeFile(path.join(f.userData,'history.json'),'preserved');
 const prepared=await prepareInstaller({file:next,asset:await asset(next,'portable'),folder:f.folder},{kind:'portable',target},{userData:f.userData});
 const result=await commit(prepared);assert.equal(result.ok,true,result.error);await waitFile(marker);
 assert.deepEqual(await fs.readFile(prepared.plan.backup),original);assert.equal(await fs.readFile(path.join(f.userData,'history.json'),'utf8'),'preserved');
});
test('Windows ZIP helper swaps a dedicated app directory and rejects unsafe archive paths',{skip:!windows,timeout:90000},async t=>{
 const f=await fixture(t),target=path.join(f.root,'TheAll app'),source=path.join(f.root,'package'),file=path.join(f.folder,'package.zip');
 for(const folder of [target,source]){await fs.mkdir(path.join(folder,'resources'),{recursive:true});await fs.writeFile(path.join(folder,'resources','app.asar'),'fixture');}
 await executable(path.join(target,'TheAll.exe'),path.join(f.root,'old-started'));await executable(path.join(source,'TheAll.exe'),path.join(f.root,'new-started'));
 await powershell(`Add-Type -AssemblyName System.IO.Compression.FileSystem; [IO.Compression.ZipFile]::CreateFromDirectory(${quote(source)},${quote(file)})`);
 const prepared=await prepareInstaller({file,asset:await asset(file,'zip'),folder:f.folder},{kind:'zip',target},{userData:f.userData});
 const result=await commit(prepared);assert.equal(result.ok,true,result.error);await waitFile(path.join(f.root,'new-started'));
 for(const name of ['../escape','/absolute','C:/drive','folder/../escape','file:stream','CON.txt','dir./file']){
   const another=await fs.mkdtemp(path.join(path.dirname(f.folder),'bad-')),bad=path.join(another,'bad.zip');
   await powershell(`Add-Type -AssemblyName System.IO.Compression.FileSystem; $z=[IO.Compression.ZipFile]::Open(${quote(bad)},[IO.Compression.ZipArchiveMode]::Create);$e=$z.CreateEntry(${quote(name)});$z.Dispose()`);
   await assert.rejects(prepareInstaller({file:bad,asset:await asset(bad,'zip'),folder:another},{kind:'zip',target},{userData:f.userData}));
 }
 assert.equal(await fs.readFile(path.join(target,'resources','app.asar'),'utf8'),'fixture');
});
test('Windows helper rejects a modified prepared package and rolls back a failed executable launch',{skip:!windows,timeout:90000},async t=>{
 const f=await fixture(t),target=path.join(f.root,'TheAll.exe'),file=path.join(f.folder,'not-an-executable.exe');
 await executable(target,path.join(f.root,'old-restarted'));const original=await fs.readFile(target);await fs.writeFile(file,'checksum-valid but not PE');
 const prepared=await prepareInstaller({file,asset:await asset(file,'portable'),folder:f.folder},{kind:'portable',target},{userData:f.userData});
 const result=await commit(prepared);assert.equal(result.ok,false);assert.deepEqual(await fs.readFile(target),original);await waitFile(path.join(f.root,'old-restarted'));
 await fs.writeFile(file,'tampered');await assert.rejects(armInstaller(prepared),/size changed|checksum/);
});
test('Windows cancelled update cannot replace or relaunch the app after cache cleanup and normal quit',{skip:!windows,timeout:90000},async t=>{
 const f=await fixture(t),target=path.join(f.root,'TheAll.exe'),file=path.join(f.folder,'next.exe');
 const oldMarker=path.join(f.root,'old-started'),newMarker=path.join(f.root,'new-started');
 await executable(target,oldMarker);const original=await fs.readFile(target);await executable(file,newMarker);
 const prepared=await prepareInstaller({file,asset:await asset(file,'portable'),folder:f.folder},{kind:'portable',target},{userData:f.userData});
 const child=spawn(process.execPath,['-e','process.stdin.resume()'],{stdio:['pipe','ignore','ignore'],windowsHide:true});t.after(()=>child.stdin.end());
 prepared.plan.pid=child.pid;await fs.writeFile(prepared.planFile,JSON.stringify(prepared.plan));
 const handoff=await armInstaller(prepared);await handoff.go();await new Promise(r=>setTimeout(r,150));
 await handoff.cancel();await fs.rm(f.folder,{recursive:true,force:true,maxRetries:20,retryDelay:100});
 const exited=new Promise(resolve=>child.once('exit',resolve));child.stdin.end();await exited;
 await new Promise(r=>setTimeout(r,2000));
 assert.deepEqual(await fs.readFile(target),original);
 for(const marker of [oldMarker,newMarker,prepared.plan.result])await assert.rejects(fs.access(marker));
});
