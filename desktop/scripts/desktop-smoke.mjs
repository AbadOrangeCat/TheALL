// Runs an isolated Electron instance and an offline fake CLI. No user app,
// provider account, API key, or network AI endpoint is used.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { _electron } from 'playwright';
import electronPath from 'electron';
import { APP_VERSION } from '../src/version.mjs';

const root=fileURLToPath(new URL('..',import.meta.url));
const args=process.argv.slice(2);
assert(args.length===0 || (args.length===4 && args[0]==='--package-dir' && args[2]==='--arch' && ['x64','arm64'].includes(args[3])), 'Use --package-dir DIR --arch x64|arm64');
const packageDir=args.length?path.resolve(args[1]):null;
const nativePackage=!!packageDir && process.platform==='win32' && process.arch===args[3];
const temporary=await fs.mkdtemp(path.join(os.tmpdir(),'TheAll isolated desktop '));
// A package under desktop/dist could accidentally resolve missing modules from
// desktop/node_modules. Copy outside the checkout before launching any artifact.
let archive,packagedExecutable;
if(packageDir){
 const isolated=path.join(temporary,'application');
 if(nativePackage){
  await fs.cp(packageDir,isolated,{recursive:true});
  packagedExecutable=path.join(isolated,'TheAll.exe');
 }else{
  await fs.mkdir(path.join(isolated,'resources'),{recursive:true});
  await fs.copyFile(path.join(packageDir,'resources/app.asar'),path.join(isolated,'resources/app.asar'));
  const unpacked=path.join(packageDir,'resources/app.asar.unpacked');
  try{await fs.cp(unpacked,path.join(isolated,'resources/app.asar.unpacked'),{recursive:true});}catch(error){if(error.code!=='ENOENT')throw error;}
 }
 archive=path.join(isolated,'resources/app.asar');
}
const dataDir=path.join(temporary,'profile'),working=path.join(temporary,'project');
await fs.mkdir(working);
const cli=path.join(temporary,'fake-claude.mjs');
await fs.writeFile(cli,`import readline from 'node:readline';import{randomUUID}from'node:crypto';
let effort='medium',waitingForSteer=null;
const send=m=>process.stdout.write(JSON.stringify(m)+'\\n');
const resume=process.argv.indexOf('--resume'),session=resume<0?randomUUID():process.argv[resume+1];
readline.createInterface({input:process.stdin}).on('line',line=>{const m=JSON.parse(line);
 if(m.request?.subtype==='apply_flag_settings')effort=m.request.settings.effortLevel??'medium';
 if(m.type==='control_request'){send({type:'control_response',response:{subtype:'success',request_id:m.request_id,response:m.request?.subtype==='initialize'?{models:[{value:'default',displayName:'Default',supportsEffort:true,supportedEffortLevels:['low','medium','high']},{value:'sonnet',displayName:'Sonnet',supportsEffort:true,supportedEffortLevels:['low','medium','high']}]}:m.request?.subtype==='get_settings'?{applied:{effort}}:{}}});return;}
 if(m.type==='user'){send({type:'command_lifecycle',command_uuid:m.uuid,state:'queued'});send({type:'command_lifecycle',command_uuid:m.uuid,state:'started'});send({type:'system',subtype:'init',session_id:session,model:'sonnet'});
 send({type:'assistant',message:{id:randomUUID(),content:[{type:'thinking',thinking:'Checking the local project.'},{type:'text',text:'Reviewing files and preparing the result.'}],stop_reason:'tool_use'}});
 const text=typeof m.message.content==='string'?m.message.content:JSON.stringify(m.message.content);
 if(text.startsWith('Wait for steering')){waitingForSteer=m.uuid;return;}
 const covered=[m.uuid,...(waitingForSteer?[waitingForSteer]:[])];waitingForSteer=null;
 setTimeout(()=>{send({type:'assistant',message:{id:randomUUID(),content:[{type:'text',text:'The Windows desktop conversation is working. This response is from an offline test fixture.'}],stop_reason:'end_turn'}});send({type:'result',uuid:randomUUID(),user_message_uuids:covered,subtype:'success',session_id:session,result:'The Windows desktop conversation is working. This response is from an offline test fixture.',is_error:false});},120);}
});`);
await fs.chmod(cli,0o700);
// Exercise the documented case where IPC exposes a fresh wrapper for a live
// frame. The Proxy forwards real Electron frame properties; it does not forge
// origins, IDs or permissions. This instrumentation exists only in the test app.
const harness=path.join(temporary,'harness');await fs.mkdir(harness);
await fs.writeFile(path.join(harness,'package.json'),JSON.stringify({name:'theall-isolated-smoke',version:APP_VERSION,main:'main.cjs'}));
await fs.writeFile(path.join(harness,'main.cjs'),`
const {ipcMain}=require('electron');
const handle=ipcMain.handle.bind(ipcMain);
ipcMain.handle=(channel,listener)=>handle(channel,channel==='theall:desktop'?(event,...args)=>{
 const frame=event.senderFrame;
 const wrapper=frame?new Proxy(frame,{get(target,key){const value=Reflect.get(target,key,target);return typeof value==='function'?value.bind(target):value;}}):null;
 return listener({sender:event.sender,senderFrame:wrapper},...args);
}:listener);
import(${JSON.stringify(pathToFileURL(path.join(root,'src/updater.mjs')).href)}).then(({DesktopUpdater})=>{globalThis.theallUpdaterClass=DesktopUpdater;return import(${JSON.stringify(pathToFileURL(path.join(root,'src/main.mjs')).href)});});
`);
let application,page;const errors=[];
// A hidden window stops painting on Windows, so screenshot runs keep it visible.
const env={...process.env,THEALL_TEST_DATA_DIR:dataDir,...(process.env.THEALL_SMOKE_SCREENSHOTS?{}:{THEALL_TEST_HIDE_WINDOW:'1'})};delete env.ELECTRON_RUN_AS_NODE;delete env.NODE_PATH;delete env.NODE_OPTIONS;
async function launch(){
 application=await _electron.launch({executablePath:packagedExecutable||electronPath,args:packagedExecutable?[]:[archive||harness],cwd:temporary,env,timeout:45000});
 if(archive){
  const identity=await application.evaluate(({app})=>({path:app.getAppPath(),packaged:app.isPackaged}));
  assert.equal(path.resolve(identity.path),archive);
  assert.equal(identity.packaged,nativePackage);
 }
 page=await application.firstWindow();page.on('pageerror',e=>errors.push(e.message));
 page.setDefaultTimeout(20000);console.log('Opened isolated desktop');
 await page.waitForFunction(()=>!!window.theallDesktop?.settings.version,{timeout:30000});
 assert.equal(await page.locator('#desktop-error').isVisible(),false,'Startup must accept the real main frame through another wrapper');
 // Windows exercises real DPAPI. The Mac verification host uses a fixture
 // encryptor installed only in this test process, avoiding Keychain changes.
 if(process.platform!=='win32')await application.evaluate(({safeStorage})=>{
   safeStorage.isAsyncEncryptionAvailable=async()=>true;
   safeStorage.encryptStringAsync=async text=>Buffer.from([...Buffer.from(text)].map(v=>v^0x5a));
   safeStorage.decryptStringAsync=async bytes=>({result:Buffer.from([...bytes].map(v=>v^0x5a)).toString(),shouldReEncrypt:false});
 });
 return page;
}
async function ipc(method,payload={}){return page.evaluate(([m,p])=>window.theallDesktop.invoke(m,p),[method,payload]);}
// Optional UI review images. Windows CI uploads them so the native rendering can be checked.
async function shot(name){const directory=process.env.THEALL_SMOKE_SCREENSHOTS;if(!directory)return;try{await fs.mkdir(directory,{recursive:true});await page.waitForTimeout(400);await page.screenshot({path:path.join(directory,`${name}.png`),timeout:10000});}catch(e){console.warn(`Screenshot ${name} skipped: ${e.message}`);}}
async function paneFor(id){
 await page.waitForFunction(id=>[...document.querySelectorAll('iframe')].some(f=>f.src.includes(id)),id);
 const pane=page.frames().find(f=>f.url().includes(`/chat.html?id=${id}`));assert(pane);
 await pane.waitForFunction(()=>!!window.theallFlushDrafts,{timeout:30000});return pane;
}
async function close(){
 if(!application)return;
 console.log('Closing isolated desktop');const current=application;application=null;let timer;
 try{await Promise.race([current.close(),new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error('Desktop shutdown timed out')),20000);})]);}
 catch(e){current.process().kill('SIGKILL');throw e;}
 finally{clearTimeout(timer);}
}
try{
 await launch();
 assert.equal(await page.evaluate(()=>typeof window.require),'undefined');
 await assert.rejects(ipc('arbitrary.command',{command:'anything'}),/Unsupported/);
 await ipc('settings.save',{defaultDirectory:working,language:'en',theme:'dark'});
 const{ id:workspaceId}=await ipc('workspace.create',{name:'Smoke project'});
 const{ id:tabId,terminalId}=await ipc('tab.create',{workspaceId,directory:working});
 await page.evaluate(()=>window.theallDesktop.changed());
 let pane=await paneFor(terminalId);
 // Choose the provider and save the first connection through the actual pane UI.
 // Only the native folder dialog result is stubbed to avoid opening user UI.
 await application.evaluate(({dialog},directory)=>{dialog.showOpenDialog=async()=>({canceled:false,filePaths:[directory]});},working);
 await pane.locator('#native-setup').waitFor({state:'visible'});await shot('1-provider-chooser');
 await pane.locator('#native-setup .setup-directory button').click();
 await pane.locator('#native-setup .provider-options button').filter({hasText:'Claude Code'}).click();
 await pane.locator('#native-setup input[type=password]').waitFor({state:'visible'});await shot('2-connection-form');
 await pane.locator('#native-setup input[type=password]').fill('fake-desktop-smoke-key');
 await pane.locator('#native-setup input[type=url]').fill('http://127.0.0.1:9');
 await pane.locator('#native-setup button[type=submit]').click();
 await pane.locator('#native-setup').waitFor({state:'detached'});
 assert.equal(await page.locator('#desktop-error').isVisible(),false);
 await ipc('connection.save',{provider:'claude',apiKey:'fake-desktop-smoke-key',baseURL:'http://127.0.0.1:9',model:'sonnet',executable:cli});
 await pane.locator('#directory').click();
 await page.evaluate(()=>window.theallDesktop.changed());
 await pane.waitForFunction(()=>!document.getElementById('draft').disabled);
 await pane.locator('#photo-files').setInputFiles({name:'中文报告.pdf',mimeType:'application/pdf',buffer:Buffer.from('%PDF-desktop-fixture')});
 await pane.waitForFunction(()=>document.querySelectorAll('#file-previews .file-chip').length===1);
 await pane.locator('#draft').fill('List the files in the current folder.');
 await pane.locator('#draft').press('Control+Enter');
 await pane.waitForFunction(()=>document.getElementById('messages').textContent.includes('The Windows desktop conversation is working'),{timeout:30000});
 await pane.waitForFunction(()=>document.getElementById('draft').value==='');
 await pane.waitForFunction(()=>document.querySelectorAll('.file-download').length===1 && document.querySelectorAll('#file-previews .file-chip').length===0);
 assert.equal(await pane.locator('.file-download').getAttribute('download'),'中文报告.pdf');
 await pane.waitForFunction(()=>document.querySelector('.message-timing'));
 await shot('3-conversation');
 await pane.locator('#effort').waitFor({state:'visible'});
 await pane.locator('#effort').selectOption('high');
 assert(await pane.locator('details.progress').count()>0);
 assert.equal(await pane.locator('details.progress').first().getAttribute('open'),null);
 await pane.locator('details.progress summary').first().click();assert.notEqual(await pane.locator('details.progress').first().getAttribute('open'),null);
 await pane.locator('#draft').fill('Keep this unsent draft');
 await pane.locator('#draft').press('Home');await pane.locator('#draft').press('ArrowUp');
 assert.equal(await pane.locator('#draft').inputValue(),'List the files in the current folder.');
 await pane.locator('#draft').press('End');await pane.locator('#draft').press('ArrowDown');
 assert.equal(await pane.locator('#draft').inputValue(),'Keep this unsent draft');
 await pane.locator('#photo-files').setInputFiles({name:'empty-note.txt',mimeType:'text/plain',buffer:Buffer.alloc(0)});
 await pane.waitForFunction(()=>document.querySelectorAll('#file-previews .file-chip').length===1);
 await page.evaluate(()=>window.theallFlushDrafts());
 const before=JSON.parse(await fs.readFile(path.join(dataDir,'workspaces.json'),'utf8'));
 assert.equal(before.chats[terminalId].draft.files.length,1);assert.equal(before.chats[terminalId].draft.files[0].name,'empty-note.txt');assert.equal(before.chats[terminalId].draft.files[0].data,undefined);
 assert.equal(before.chats[terminalId].messages.find(m=>m.role==='user').files[0].name,'中文报告.pdf');
 assert(before.chats[terminalId].conversationID);assert.equal(before.chats[terminalId].draft.text,'Keep this unsent draft');assert.equal(before.chats[terminalId].draft.reasoningEffort,'high');
 const connectionBytes=await fs.readFile(path.join(dataDir,'Credentials/claude.bin'));assert(!connectionBytes.includes(Buffer.from('fake-desktop-smoke-key')));
 const split=await ipc('pane.split',{workspaceId,tabId,terminalId,direction:'horizontal'});
 await page.evaluate(()=>window.theallDesktop.changed());await paneFor(split.terminalId);pane=await paneFor(terminalId);await shot('4-split');
  assert.equal(await page.locator('.pane iframe:visible').count(),2);
 const screenshot=process.env.THEALL_SMOKE_SCREENSHOT;
 if(screenshot)await page.screenshot({path:screenshot});
 await pane.locator('#draft').fill('Draft saved while quitting through a recreated frame wrapper');
 await close();
 const withoutCapabilities=JSON.parse(await fs.readFile(path.join(dataDir,'workspaces.json'),'utf8'));
 delete withoutCapabilities.settings.modelCapabilities;
 await fs.writeFile(path.join(dataDir,'workspaces.json'),JSON.stringify(withoutCapabilities));
 await launch();await page.evaluate(()=>window.theallDesktop.changed());pane=await paneFor(terminalId);
 await pane.waitForFunction(()=>document.getElementById('messages').textContent.includes('The Windows desktop conversation is working'));
 await pane.waitForFunction(()=>document.getElementById('draft').value==='Draft saved while quitting through a recreated frame wrapper');
 await pane.waitForFunction(()=>document.querySelectorAll('#file-previews .file-chip').length===1);
 assert((await pane.locator('#file-previews').textContent()).includes('empty-note.txt'));
 assert.equal((await ipc('settings.get')).connections.claude.configured,true);
 const after=JSON.parse(await fs.readFile(path.join(dataDir,'workspaces.json'),'utf8'));
 assert.equal(after.chats[terminalId].conversationID,before.chats[terminalId].conversationID);
 assert.equal(after.chats[terminalId].draft.reasoningEffort,'high');
 assert.equal(after.chats[terminalId].messages.find(m=>m.completedAt)?.completedAt,before.chats[terminalId].messages.find(m=>m.completedAt)?.completedAt);
 assert.equal(after.workspaces.find(w=>w.id===workspaceId).tabs.find(t=>t.id===tabId).layout.type,'split');
 await pane.locator('#draft').fill('Continue after reopening.');await pane.locator('#draft').press('Control+Enter');
 await pane.waitForFunction(()=>document.querySelectorAll('.message.user').length>=2,{timeout:30000});
 await pane.waitForFunction(()=>document.querySelectorAll('.file-download').length===2);
 // A running task accepts a second prompt through the same composer, without stopping.
 await pane.waitForFunction(()=>document.getElementById('stop').hidden);
 await pane.locator('#draft').fill('Wait for steering before completing.');await pane.locator('#draft').press('Control+Enter');
 await pane.waitForFunction(()=>!document.getElementById('stop').hidden && document.getElementById('draft').value==='');
 const timingsBefore=await pane.locator('.message-timing').count();
 await pane.locator('#draft').fill('Use only source files.');
 await pane.waitForFunction(()=>!document.getElementById('send').disabled && document.getElementById('send').textContent==='Steer ↑');
 assert.equal(await pane.locator('#stop').getAttribute('aria-label'),'Stop ■');
 assert.equal(await pane.locator('#composer-hint').textContent(),'Ctrl+↵ Steer ↑');
 const apiBefore=await pane.evaluate(async id=>(await fetch('/api/chats/'+id)).json(),terminalId);
 assert(apiBefore.canSteer && apiBefore.steerToken);
 await pane.locator('#draft').press('Control+Enter');
 await pane.waitForFunction(()=>document.getElementById('draft').value==='' && document.getElementById('stop').hidden);
 assert.equal(await pane.locator('.message-timing').count(),timingsBefore+1,'one completion after steering');
 const apiAfter=await pane.evaluate(async id=>(await fetch('/api/chats/'+id)).json(),terminalId);
 assert.equal(apiAfter.steerToken,null);
 assert.equal(apiAfter.canSteer,false);
 assert(apiAfter.messages.some(m=>m.role==='user' && m.text==='Use only source files.' && m.isSteering));
 assert.equal(await pane.locator('#composer-hint').textContent(),'Ctrl+↵ Send ↑');
 await page.locator('#settings-button').click();assert.equal(await page.locator('#settings-tabs button').count(),8);await shot('5-settings');
 assert.equal((await ipc('update.status')).phase,'disabled');
 assert.equal(await page.locator('#update-shortcut').isVisible(),false);
 // Instrument the updater class in the isolated harness only. Production builds
 // have no test URL, fixture switch or renderer-controlled install destination.
 if(!packageDir){
 await application.evaluate(() => {
   const DesktopUpdater=globalThis.theallUpdaterClass;
   globalThis.theallUpdateFixture={phase:'available',version:'9.0.0',currentVersion:'0.1.6'};
   DesktopUpdater.prototype.status=function(){return {...globalThis.theallUpdateFixture};};
   DesktopUpdater.prototype.install=function(){globalThis.theallUpdateFixture.phase='downloading';globalThis.theallUpdateFixture.progress=.5;return this.status();};
 });
 await page.locator('#update-shortcut').waitFor({state:'visible'});await shot('6-update');
 assert(await page.evaluate(()=>!!(document.getElementById('update-shortcut').compareDocumentPosition(document.getElementById('phone-shortcut'))&Node.DOCUMENT_POSITION_FOLLOWING)));
 if(process.env.THEALL_TEST_UPDATE_SCREENSHOT){await page.locator('#close-settings').click();await page.screenshot({path:process.env.THEALL_TEST_UPDATE_SCREENSHOT});}
 await page.locator('#update-shortcut').click();await page.waitForFunction(()=>document.getElementById('update-detail').textContent.includes('50%'));
 assert(await page.locator('#update-shortcut').isDisabled());
 await application.evaluate(()=>{globalThis.theallUpdateFixture.phase='waiting';});
 await page.waitForFunction(()=>document.getElementById('update-detail').textContent.includes('Waiting'));
 for(const language of ['zh-Hans','fr','ja','ko','en']){await page.evaluate(()=>window.theallDesktop.openSettings('appearance'));await page.locator('#settings-content select:has(option[value="zh-Hans"])').selectOption(language);await page.waitForFunction(value=>document.documentElement.lang===value,language);await page.evaluate(()=>window.theallDesktop.openSettings('update'));assert(await page.locator('#update-settings').isVisible());}
 await application.evaluate(()=>{globalThis.theallUpdateFixture={phase:'upToDate',currentVersion:'0.1.6'};});
 await page.locator('#update-shortcut').waitFor({state:'hidden'});
 }
 assert.deepEqual(errors,[]);
 if(packageDir)console.log(`PASS: isolated ${nativePackage?'packaged Windows executable':'production ASAR on host Electron'} startup, UI, attachments, Steer, credentials and history after Quit/reopen`);
 else console.log('PASS: isolated Electron main-frame wrapper authorization, actual provider/key/folder UI, quit-time draft saving, sandbox/IPC, native-style desktop panes, CLI send, progress folding, prompt history, encrypted credentials, drafts/history/layout across restart, and resumed chat. '+(process.platform==='win32'?'Windows DPAPI verified.':'Host UI verified; Windows DPAPI requires the Windows CI job.'));
}catch(error){
 if(page)try{console.error('Desktop errors:',errors);console.error('Visible error:',await page.locator('#desktop-error').textContent());await page.screenshot({path:process.env.THEALL_SMOKE_SCREENSHOT||path.join(temporary,'failure.png')});}catch{}
 throw error;
}finally{try{await close();}finally{await fs.rm(temporary,{recursive:true,force:true});}}
