// Runs an isolated Electron instance and an offline fake CLI. No user app,
// provider account, API key, or network AI endpoint is used.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { _electron } from 'playwright';
import electronPath from 'electron';

const root=fileURLToPath(new URL('..',import.meta.url));
const temporary=await fs.mkdtemp(path.join(os.tmpdir(),'TheAll isolated desktop '));
const dataDir=path.join(temporary,'profile'),working=path.join(temporary,'project');
await fs.mkdir(working);
const cli=path.join(temporary,'fake-claude.mjs');
await fs.writeFile(cli,`import readline from 'node:readline';import{randomUUID}from'node:crypto';
let effort='medium';
const send=m=>process.stdout.write(JSON.stringify(m)+'\\n');
const resume=process.argv.indexOf('--resume'),session=resume<0?randomUUID():process.argv[resume+1];
readline.createInterface({input:process.stdin}).on('line',line=>{const m=JSON.parse(line);
 if(m.request?.subtype==='apply_flag_settings')effort=m.request.settings.effortLevel??'medium';
 if(m.type==='control_request'){send({type:'control_response',response:{subtype:'success',request_id:m.request_id,response:m.request?.subtype==='initialize'?{models:[{value:'default',displayName:'Default',supportsEffort:true,supportedEffortLevels:['low','medium','high']},{value:'sonnet',displayName:'Sonnet',supportsEffort:true,supportedEffortLevels:['low','medium','high']}]}:m.request?.subtype==='get_settings'?{applied:{effort}}:{}}});return;}
 if(m.type==='user'){send({type:'system',subtype:'init',session_id:session,model:'sonnet'});
 send({type:'assistant',message:{id:randomUUID(),content:[{type:'thinking',thinking:'Checking the local project.'},{type:'text',text:'Reviewing files and preparing the result.'}],stop_reason:'tool_use'}});
 setTimeout(()=>{send({type:'assistant',message:{id:randomUUID(),content:[{type:'text',text:'The Windows desktop conversation is working. This response is from an offline test fixture.'}],stop_reason:'end_turn'}});send({type:'result',subtype:'success',session_id:session,result:'The Windows desktop conversation is working. This response is from an offline test fixture.',is_error:false});},120);}
});`);
await fs.chmod(cli,0o700);
// Exercise the documented case where IPC exposes a fresh wrapper for a live
// frame. The Proxy forwards real Electron frame properties; it does not forge
// origins, IDs or permissions. This instrumentation exists only in the test app.
const harness=path.join(temporary,'harness');await fs.mkdir(harness);
await fs.writeFile(path.join(harness,'package.json'),JSON.stringify({name:'theall-isolated-smoke',version:'0.1.6',main:'main.cjs'}));
await fs.writeFile(path.join(harness,'main.cjs'),`
const {ipcMain}=require('electron');
const handle=ipcMain.handle.bind(ipcMain);
ipcMain.handle=(channel,listener)=>handle(channel,channel==='theall:desktop'?(event,...args)=>{
 const frame=event.senderFrame;
 const wrapper=frame?new Proxy(frame,{get(target,key){const value=Reflect.get(target,key,target);return typeof value==='function'?value.bind(target):value;}}):null;
 return listener({sender:event.sender,senderFrame:wrapper},...args);
}:listener);
import(${JSON.stringify(pathToFileURL(path.join(root,'src/main.mjs')).href)});
`);
let application,page;const errors=[];
const env={...process.env,THEALL_TEST_DATA_DIR:dataDir,THEALL_TEST_HIDE_WINDOW:'1'};delete env.ELECTRON_RUN_AS_NODE;
async function launch(){
 application=await _electron.launch({executablePath:electronPath,args:[harness],env,timeout:45000});
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
 await pane.locator('#native-setup .setup-directory button').click();
 await pane.locator('#native-setup .provider-options button').filter({hasText:'Claude Code'}).click();
 await pane.locator('#native-setup input[type=password]').fill('fake-desktop-smoke-key');
 await pane.locator('#native-setup input[type=url]').fill('http://127.0.0.1:9');
 await pane.locator('#native-setup button[type=submit]').click();
 await pane.locator('#native-setup').waitFor({state:'detached'});
 assert.equal(await page.locator('#desktop-error').isVisible(),false);
 await ipc('connection.save',{provider:'claude',apiKey:'fake-desktop-smoke-key',baseURL:'http://127.0.0.1:9',model:'sonnet',executable:cli});
 await pane.locator('#directory').click();
 await page.evaluate(()=>window.theallDesktop.changed());
 await pane.waitForFunction(()=>!document.getElementById('draft').disabled);
 await pane.locator('#draft').fill('List the files in the current folder.');
 await pane.locator('#draft').press('Control+Enter');
 await pane.waitForFunction(()=>document.getElementById('messages').textContent.includes('The Windows desktop conversation is working'),{timeout:30000});
 await pane.waitForFunction(()=>document.getElementById('draft').value==='');
 await pane.waitForFunction(()=>document.querySelector('.message-timing'));
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
 await page.evaluate(()=>window.theallFlushDrafts());
 const before=JSON.parse(await fs.readFile(path.join(dataDir,'workspaces.json'),'utf8'));
 assert(before.chats[terminalId].conversationID);assert.equal(before.chats[terminalId].draft.text,'Keep this unsent draft');assert.equal(before.chats[terminalId].draft.reasoningEffort,'high');
 const connectionBytes=await fs.readFile(path.join(dataDir,'Credentials/claude.bin'));assert(!connectionBytes.includes(Buffer.from('fake-desktop-smoke-key')));
 const split=await ipc('pane.split',{workspaceId,tabId,terminalId,direction:'horizontal'});
 await page.evaluate(()=>window.theallDesktop.changed());await paneFor(split.terminalId);pane=await paneFor(terminalId);
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
 assert.equal((await ipc('settings.get')).connections.claude.configured,true);
 const after=JSON.parse(await fs.readFile(path.join(dataDir,'workspaces.json'),'utf8'));
 assert.equal(after.chats[terminalId].conversationID,before.chats[terminalId].conversationID);
 assert.equal(after.chats[terminalId].draft.reasoningEffort,'high');
 assert.equal(after.chats[terminalId].messages.find(m=>m.completedAt)?.completedAt,before.chats[terminalId].messages.find(m=>m.completedAt)?.completedAt);
 assert.equal(after.workspaces.find(w=>w.id===workspaceId).tabs.find(t=>t.id===tabId).layout.type,'split');
 await pane.locator('#draft').fill('Continue after reopening.');await pane.locator('#draft').press('Control+Enter');
 await pane.waitForFunction(()=>document.querySelectorAll('.message.user').length>=2,{timeout:30000});
 await page.locator('#settings-button').click();assert.equal(await page.locator('#settings-tabs button').count(),8);
 assert.deepEqual(errors,[]);
 console.log('PASS: isolated Electron main-frame wrapper authorization, actual provider/key/folder UI, quit-time draft saving, sandbox/IPC, native-style desktop panes, CLI send, progress folding, prompt history, encrypted credentials, drafts/history/layout across restart, and resumed chat. '+(process.platform==='win32'?'Windows DPAPI verified.':'Host UI verified; Windows DPAPI requires the Windows CI job.'));
}catch(error){
 if(page)try{console.error('Desktop errors:',errors);console.error('Visible error:',await page.locator('#desktop-error').textContent());await page.screenshot({path:process.env.THEALL_SMOKE_SCREENSHOT||path.join(temporary,'failure.png')});}catch{}
 throw error;
}finally{await close();await fs.rm(temporary,{recursive:true,force:true});}
