import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { DesktopUpdater, newerVersion, selectRelease, trustedUpdateURL, RELEASE_API, verifyPackage } from '../src/updater.mjs';
import { validateInstallPath } from '../src/update-installer.mjs';
const bytes = Buffer.from('fake update package');
const hash = createHash('sha256').update(bytes).digest('hex');
function release(version='0.2.0',kind='nsis',arch='x64') { const name=`TheAll-${version}-windows-${arch}-${kind}.${kind==='zip'?'zip':'exe'}`;return {tag_name:`v${version}`,draft:false,prerelease:false,assets:[{name,size:bytes.length,digest:`sha256:${hash}`,browser_download_url:`https://github.com/AbadOrangeCat/TheALL/releases/download/v${version}/${name}`}]}; }
const until=async fn=>{for(let i=0;i<300;i++){if(fn())return;await new Promise(r=>setTimeout(r,5));}throw new Error('Timed out');};
async function fixture(t, options={}) {
 const directory=await fs.mkdtemp(path.join(os.tmpdir(),'theall-update-test-'));t.after(()=>fs.rm(directory,{recursive:true,force:true}));
 let fetched=0,installed=0,busy=false,gate=false;
 const updater=new DesktopUpdater({version:'0.1.6',arch:'x64',kind:'nsis',cacheDir:directory,enabled:true,idleInterval:5,
 request:async(url,{onChunk})=>{fetched++;onChunk(url===RELEASE_API?Buffer.from(JSON.stringify(release())):bytes);return bytes.length;},
 prepare:async value=>value,beginInstall:()=>{if(busy)return false;gate=true;return true;},onInstall:async()=>{installed++;},...options});t.after(()=>updater.stop());
 return {updater,directory,get fetched(){return fetched;},get installed(){return installed;},get gate(){return gate;},set busy(v){busy=v;}};
}
test('release selection compares numeric stable versions and exact architecture/package',()=>{
 for(const [next,current,want]of [['0.10.0','0.9.0',true],['0.1.6','0.1.6',false],['0.1.5','0.1.6',false],['0.2.0-rc.1','0.1.6',false],['01.2.0','0.1.6',false],['1.0.0','0.99.9',true]])assert.equal(newerVersion(next,current),want);
 for(const kind of ['nsis','portable','zip'])for(const arch of ['x64','arm64'])assert.equal(selectRelease(release('0.2.0',kind,arch),'0.1.6',arch,kind).kind,kind);
 assert.equal(selectRelease({...release(),prerelease:true},'0.1.6','x64','nsis'),null);
 assert.throws(()=>selectRelease(release(),'0.1.6','arm64','nsis'));
 const bad=release();delete bad.assets[0].digest;assert.throws(()=>selectRelease(bad,'0.1.6','x64','nsis'));
 bad.assets[0].digest=`sha256:${hash}`;bad.assets[0].browser_download_url='https://evil.test/update.exe';assert.throws(()=>selectRelease(bad,'0.1.6','x64','nsis'));
});
test('only fixed API/repository and explicit CDN redirects are trusted',()=>{
 assert(trustedUpdateURL(RELEASE_API,{metadata:true}));assert(!trustedUpdateURL(RELEASE_API+'?token=x',{metadata:true}));
 assert(trustedUpdateURL(release().assets[0].browser_download_url));
 for(const bad of ['http://github.com/AbadOrangeCat/TheALL/releases/download/v0.2.0/app.exe','https://github.com.evil.test/file','https://user@github.com/file','https://release-assets.githubusercontent.com/file','https://github.com/other/TheALL/releases/download/v0.2.0/app.exe','https://localhost/file'])assert(!trustedUpdateURL(bad));
 assert(trustedUpdateURL('https://release-assets.githubusercontent.com/github-production-release-asset/file?sig=123',{redirect:true}));
 assert(!trustedUpdateURL('https://release-assets.githubusercontent.com:444/file',{redirect:true}));
});
test('application paths reject injection, device, root and traversal paths',()=>{
 assert.equal(validateInstallPath('C:\\Users\\Test User\\TheAll\\TheAll.exe'),'C:\\Users\\Test User\\TheAll\\TheAll.exe');
 for(const bad of ['C:\\','C:\\Users\\..\\TheAll','\\\\server\\share\\TheAll.exe','C:\\TheAll\nwhoami','C:\\TheAll" /bad','C:\\TheAll:bad','C:\\TheAll.'])assert.throws(()=>validateInstallPath(bad));
});
test('disabled development updater never calls network or installer',async t=>{const f=await fixture(t,{enabled:false});f.updater.start();await f.updater.check();f.updater.install();await new Promise(r=>setTimeout(r,20));assert.equal(f.fetched,0);assert.equal(f.installed,0);assert.equal(f.updater.status().phase,'disabled');});
test('download is explicit, duplicate clicks share one download, tasks finish before handoff',async t=>{
 const f=await fixture(t);await f.updater.check();assert.equal(f.fetched,1);assert.equal(f.updater.status().phase,'available');f.busy=true;
 f.updater.install();f.updater.install();await until(()=>f.updater.status().phase==='waiting');assert.equal(f.fetched,2);assert.equal(f.installed,0);assert(!f.gate);
 f.busy=false;await until(()=>f.installed===1);assert(f.gate);assert.equal(f.updater.status().phase,'installing');
});
test('corrupted/truncated downloads never reach installer and can retry',async t=>{
 let corrupt=true;const f=await fixture(t,{request:async(url,{onChunk})=>{onChunk(url===RELEASE_API?Buffer.from(JSON.stringify(release())):corrupt?Buffer.from('bad'):bytes);}});
 await f.updater.check();f.updater.install();await until(()=>f.updater.status().phase==='error');assert.equal(f.installed,0);assert(!f.gate);
 corrupt=false;f.updater.install();await until(()=>f.installed===1);
});
test('post-download modification is detected before installation',async t=>{
 const f=await fixture(t,{prepare:async value=>{await fs.writeFile(value.file,Buffer.alloc(bytes.length));return value;}});await f.updater.check();f.updater.install();await until(()=>f.updater.status().phase==='error');assert.equal(f.installed,0);
});
test('verification rejects symlinks and modified files',async t=>{
 const f=await fixture(t),file=path.join(f.directory,'test.exe'),asset=selectRelease(release(),'0.1.6','x64','nsis');await fs.writeFile(file,bytes);await verifyPackage(file,asset);await fs.writeFile(file,'short');await assert.rejects(verifyPackage(file,asset));
});
test('a failed handoff releases the task gate and cleans only its update cache',async t=>{
 let unlocked=false;const f=await fixture(t,{onInstall:async()=>{throw new Error('Saving failed');},onFailure:()=>{unlocked=true;}});
 const unrelated=path.join(f.directory,'keep.json');await fs.writeFile(unrelated,'keep');await f.updater.check();f.updater.install();await until(()=>f.updater.status().phase==='error');assert(unlocked);await until(()=>!f.updater.downloadFolder);
 assert.equal(await fs.readFile(unrelated,'utf8'),'keep');
});
test('automatic checks preserve an earlier installation failure until explicit retry',async t=>{
 const f=await fixture(t);f.updater.previousError='Installer failed';await f.updater.check();assert.equal(f.updater.status().phase,'error');assert.equal(f.updater.status().error,'Installer failed');assert.equal(f.updater.status().version,'0.2.0');
 f.updater.install();await until(()=>f.installed===1);assert.equal(f.updater.previousError,null);
});
