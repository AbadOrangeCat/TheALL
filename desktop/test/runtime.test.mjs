import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { EventEmitter } from 'node:events';
import { randomUUID, randomBytes, createCipheriv, createDecipheriv } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { WebSocket } from 'ws';
import { createRuntime, isPrivateIPv4, isAbsoluteDirectory, lanAddresses } from '../src/runtime.mjs';
import { Store } from '../src/store.mjs';
import { validateConnection, fetchModels, selectedReasoningEffort } from '../src/models.mjs';

const root = fileURLToPath(new URL('../..', import.meta.url));
const key = randomBytes(32);
const encrypt = async text => { const nonce=randomBytes(12), cipher=createCipheriv('aes-256-gcm',key,nonce);return Buffer.concat([nonce,cipher.update(text),cipher.final(),cipher.getAuthTag()]); };
const decrypt = async buffer => { const cipher=createDecipheriv('aes-256-gcm',key,buffer.subarray(0,12));cipher.setAuthTag(buffer.subarray(-16));return Buffer.concat([cipher.update(buffer.subarray(12,-16)),cipher.final()]).toString(); };
const pixels = Buffer.from('89504e470d0a1a0a','hex');
class FakeSession extends EventEmitter {
  static sends=0; static starts=0; static delay=null; static uncertain=false;
  constructor({chat,connection}) {super();this.chat=chat;this.connection=connection;this.isReady=false;this.isBusy=false;this.canInterrupt=false;this.questions=[];this.models=[{id:'test-model',title:'Test model'}];}
  async start(){FakeSession.starts++;this.chat.conversationID||=randomUUID();if(FakeSession.delay)await FakeSession.delay;this.isReady=true;this.emit('change');}
  async send({text,images,files=[],model}){FakeSession.sends++;this.chat.model=model;this.chat.messages.push({id:randomUUID(),role:'user',text,images:images.map(({path,data,...i})=>i),files});this.chat.messages.push({id:randomUUID(),role:'assistant',text:'A preserved answer',images:[]});this.emit('change');if(FakeSession.uncertain){const e=new Error('Write outcome is unknown');e.code='submission_uncertain';throw e;}}
  async answer(value){this.answerValue=value;this.questions=[];this.emit('change');}
  async interrupt(){this.isBusy=false;this.canInterrupt=false;this.emit('change');}
  async close(){this.isReady=false;this.emit('change');}
}
async function fixture(t, extra={}) {
  const dataDir=fs.mkdtempSync(path.join(os.tmpdir(),'theall-windows-test-'));
  let runtime=await createRuntime({dataDir,webRoot:path.join(root,'TheAll/Mobile/MobileWeb.bundle'),desktopRoot:path.join(root,'desktop/renderer'),encrypt,decrypt,Session:FakeSession,
    normalizeImage:async()=>({data:pixels,mimeType:'image/png',width:1,height:1}),...extra});
  t.after(async()=>{await runtime.close();fs.rmSync(dataDir,{recursive:true,force:true});});
  FakeSession.sends=0;FakeSession.starts=0;FakeSession.delay=null;FakeSession.uncertain=false;
  const api=async(route,{body,cookie=`TheAllDesktopSession=${runtime.desktopToken}`,origin=runtime.url,headers={},url=runtime.url}={})=>{
    const res=await fetch(url+route,{method:body===undefined?'GET':'POST',headers:{cookie,...(body===undefined?{}:{origin,'content-type':'application/json','x-theall-client':'1'}),...headers},body:body===undefined?undefined:JSON.stringify(body)});
    return {status:res.status,headers:res.headers,body:await res.json()};
  };
  const config=()=>runtime.desktop('connection.save',{provider:'claude',apiKey:'fake-test-secret',baseURL:'http://127.0.0.1:9',model:'test-model'});
  const create=async()=>{await config();const r=await api('/api/chats',{body:{requestId:randomUUID(),bootID:runtime.bootID,provider:'claude',directory:dataDir}});assert.equal(r.status,201);return r.body.id;};
  return {get runtime(){return runtime;},dataDir,api,config,create,async restart(){await runtime.close();runtime=await createRuntime({dataDir,webRoot:path.join(root,'TheAll/Mobile/MobileWeb.bundle'),desktopRoot:path.join(root,'desktop/renderer'),encrypt,decrypt,Session:FakeSession,...extra});}};
}
function mutation(runtime, values={}) {return {requestId:randomUUID(),bootID:runtime.bootID,...values};}

test('native Windows absolute paths and RFC1918 selection exclude drive-relative/device/public addresses',()=>{
  for(const v of ['C:\\Projects\\AI','D:/Project with spaces','\\\\server\\share\\folder'])assert.equal(isAbsoluteDirectory(v,'win32'),true,v);
  for(const v of ['C:folder','\\folder','/folder','//?/C:/foo','\\\\?\\GLOBALROOT\\Device','relative','C:\\a\u0000b'])assert.equal(isAbsoluteDirectory(v,'win32'),false,v);
  for(const v of ['10.0.0.1','172.16.2.1','192.168.1.10'])assert.equal(isPrivateIPv4(v),true);
  for(const v of ['127.0.0.1','8.8.8.8','172.32.1.1','192.168.1.256','010.0.0.1','169.254.1.1'])assert.equal(isPrivateIPv4(v),false);
});
test('corrupt or newer stores fail closed and preserve their exact bytes',t=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'theall-store-'));t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
  const file=path.join(dir,'workspaces.json');
  for(const raw of ['broken json',JSON.stringify({version:999,workspaces:[],chats:{},devices:[],settings:{}})]){
    fs.writeFileSync(file,raw);assert.throws(()=>new Store(dir),/preserved/);assert.equal(fs.readFileSync(file,'utf8'),raw);
  }
});
test('advertised effort values persist up to the same boundary accepted by model metadata',t=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'theall-effort-store-'));t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
  const store=new Store(dir),{chat}=store.newWorkspace({provider:'openai'});
  for(const effort of ['ultra','x'.repeat(32)]){
    chat.reasoningEffort=effort;chat.codexAppliedReasoningEffort=effort;store.save();
    const restored=new Store(dir).chat(chat.id);
    assert.equal(restored.reasoningEffort,effort);assert.equal(restored.codexAppliedReasoningEffort,effort);
  }
  const bytes=fs.readFileSync(store.file);
  for(const field of ['reasoningEffort','codexAppliedReasoningEffort']){
    chat[field]='x'.repeat(33);assert.throws(()=>store.save(),/thinking level/);
    assert.deepEqual(fs.readFileSync(store.file),bytes);chat[field]='x'.repeat(32);
  }
});
test('active chats retain their own effort capabilities after another chat initializes',async t=>{
  class PerChatSession extends FakeSession {
    constructor(options){super(options);this.models=[{id:this.chat.model,title:this.chat.model,reasoningEfforts:[this.chat.model==='model-a'?'high':'low']}];}
    async send(input){selectedReasoningEffort(this.models,input.model,input.reasoningEffort);return super.send(input);}
  }
  const f=await fixture(t,{Session:PerChatSession});await f.config();
  const create=async model=>{
    const result=await f.api('/api/chats',{body:mutation(f.runtime,{provider:'claude',directory:f.dataDir,model})});
    assert.equal(result.status,201);return result.body.id;
  };
  const a=await create('model-a'),b=await create('model-b');
  const send=(id,model,reasoningEffort)=>f.api(`/api/chats/${id}/send`,{body:mutation(f.runtime,{text:'Fixture request',model,reasoningEffort})});
  assert.equal((await send(a,'model-a','high')).status,200);
  assert.equal((await send(b,'model-b','low')).status,200);
  assert.deepEqual((await f.api(`/api/chats/${a}`)).body.models.find(m=>m.id==='model-a').reasoningEfforts,['high']);
  assert.equal((await send(a,'model-a','high')).status,200);
});
test('unauthenticated, cross-origin and missing client marker cannot read or mutate desktop',async t=>{
  const f=await fixture(t);
  assert.equal((await f.api('/api/workspaces',{cookie:''})).status,401);
  assert.equal((await f.api('/api/workspaces',{headers:{origin:'https://evil.test'}})).status,403);
  assert.equal((await f.api('/api/chats',{body:{},origin:'https://evil.test'})).status,403);
  assert.equal((await f.api('/api/chats',{body:{},headers:{'x-theall-client':'0'}})).status,403);
  assert.equal((await f.api('/api/session')).body.deviceName,'TheAll');
});
test('connection is encrypted and readable after restart without exposing its key in settings',async t=>{
  const f=await fixture(t);await f.config();
  assert(!fs.readFileSync(path.join(f.dataDir,'Credentials/claude.bin')).includes(Buffer.from('fake-test-secret')));
  assert(!JSON.stringify(await f.runtime.desktop('settings.get')).includes('fake-test-secret'));
  assert(!fs.readFileSync(path.join(f.dataDir,'workspaces.json'),'utf8').includes('fake-test-secret'));
  await f.restart();assert.equal((await f.runtime.desktop('settings.get')).connections.claude.configured,true);
  await assert.rejects(f.runtime.desktop('connection.save',{provider:'claude',baseURL:'https://other.example.com'}),/key again/);
  const id=await f.create();assert(id);
});
test('transcript, IDs, drafts, model and layout survive restart; reading never starts CLI',async t=>{
  const f=await fixture(t),id=await f.create();
  const send=mutation(f.runtime,{text:'Which files are in this folder?',model:'test-model'});
  assert.equal((await f.api(`/api/chats/${id}/send`,{body:send})).status,200);
  await f.runtime.desktop('draft.save',{id,text:'Preserve this draft',model:'test-model',images:[]});
  const before=(await f.api(`/api/chats/${id}`)).body;
  const state=JSON.parse(fs.readFileSync(path.join(f.dataDir,'workspaces.json'),'utf8'));
  await f.restart();FakeSession.starts=0;
  const after=(await f.api(`/api/chats/${id}`)).body;
  assert.deepEqual(after.messages,before.messages);assert.equal(after.canResume,true);assert.equal(FakeSession.starts,0);
  assert.deepEqual(await f.runtime.desktop('draft.get',{id}),{text:'Preserve this draft',model:'test-model',images:[],reasoningEffort:''});
  assert.equal(JSON.parse(fs.readFileSync(path.join(f.dataDir,'workspaces.json'),'utf8')).chats[id].conversationID,state.chats[id].conversationID);
  assert.equal((await f.api('/api/workspaces')).body.workspaces[0].name,'Which files are in this folder?');
  assert.equal((await f.api(`/api/chats/${id}/send`,{body:send})).status,409);
});
test('retries execute once, conflicting request IDs are rejected and uncertain outcomes remain cached',async t=>{
  const f=await fixture(t),id=await f.create();const body=mutation(f.runtime,{text:'Run once'});
  for(let i=0;i<2;i++)assert.equal((await f.api(`/api/chats/${id}/send`,{body})).status,200);
  assert.equal(FakeSession.sends,1);
  assert.equal((await f.api(`/api/chats/${id}/send`,{body:{...body,text:'different'}})).status,409);
  FakeSession.uncertain=true;const uncertain=mutation(f.runtime,{text:'Unknown outcome'});
  for(let i=0;i<2;i++){const r=await f.api(`/api/chats/${id}/send`,{body:uncertain});assert.equal(r.status,503);assert.equal(r.body.code,'outcome_unknown');}
  assert.equal(FakeSession.sends,2);
});
test('workspace, tab, split, order and manual naming operations preserve ownership and restart layout',async t=>{
  const f=await fixture(t);const {id:w}=await f.runtime.desktop('workspace.create',{});
  const {id:tab,terminalId}=await f.runtime.desktop('tab.create',{workspaceId:w,directory:f.dataDir});
  const split=await f.runtime.desktop('pane.split',{workspaceId:w,tabId:tab,terminalId,direction:'horizontal'});
  await f.runtime.desktop('pane.resize',{workspaceId:w,tabId:tab,path:[],ratio:0.65});
  await f.runtime.desktop('workspace.rename',{id:w,name:'My project'});
  await f.runtime.desktop('tab.rename',{workspaceId:w,id:tab,title:'Build'});
  const before=(await f.api('/api/workspaces')).body.workspaces;
  await f.restart();assert.deepEqual((await f.api('/api/workspaces')).body.workspaces,before);
  await f.runtime.desktop('pane.close',{workspaceId:w,tabId:tab,terminalId:split.terminalId});
  const after=(await f.api('/api/workspaces')).body.workspaces[0];assert.equal(after.tabs.find(v=>v.id===tab).layout.type,'terminal');
  await f.runtime.desktop('tab.close',{workspaceId:w,id:tab});
  assert.equal((await f.api(`/api/chats/${terminalId}`)).status,404);
});
test('photos are normalized, persist with metadata only, and require a visible owning conversation',async t=>{
  const f=await fixture(t),id=await f.create();
  const body=mutation(f.runtime,{text:'',images:[{name:'photo.png',data:pixels.toString('base64')}]});
  assert.equal((await f.api(`/api/chats/${id}/send`,{body})).status,200);
  const chat=(await f.api(`/api/chats/${id}`)).body,image=chat.messages[0].images[0];
  assert(image.id);assert(!('path'in image));assert(!('data'in image));
  const res=await fetch(`${f.runtime.url}/api/chats/${id}/images/${image.id}`,{headers:{cookie:`TheAllDesktopSession=${f.runtime.desktopToken}`}});
  assert.equal(res.status,200);assert.deepEqual(Buffer.from(await res.arrayBuffer()),pixels);
  const other=await f.create();assert.equal((await f.api(`/api/chats/${other}/images/${image.id}`)).status,404);
  await f.restart();assert.equal((await f.api(`/api/chats/${id}`)).body.messages[0].images[0].id,image.id);
});
test('in-flight identical sends report pending without double submission',async t=>{
  const f=await fixture(t),id=await f.create();let release;FakeSession.delay=new Promise(r=>release=r);
  const body=mutation(f.runtime,{text:'single send'}),first=f.api(`/api/chats/${id}/send`,{body});
  await new Promise(r=>setTimeout(r,30));const next=await f.api(`/api/chats/${id}/send`,{body});assert.equal(next.status,409);assert.equal(next.body.code,'request_pending');
  release();assert.equal((await first).status,200);assert.equal(FakeSession.sends,1);
});
test('model catalog rejects redirects and connection rejects credential-bearing/unencrypted remote endpoints',async()=>{
  for(const baseURL of ['http://example.com','https://u:p@example.com','https://example.com/?secret=1','https://example.com/#x'])assert.throws(()=>validateConnection('openai',{apiKey:'fake',baseURL}));
  let options;const models=await fetchModels('openai',{apiKey:'fake',baseURL:'https://example.com/v1'},async(u,o)=>{options=o;assert.equal(String(u),'https://example.com/v1/models');return new Response(JSON.stringify({data:[{id:'gpt-test'}]}));});
  assert.equal(options.redirect,'error');assert.equal(models[0].id,'gpt-test');
});
test('real LAN pairing, scope, read-only, cookie isolation, WebSocket revoke and one-use invitation',async t=>{
  const address=lanAddresses()[0]?.address;if(!address){t.skip('No private network interface available');return;}
  const f=await fixture(t),id=await f.create(),w=(await f.api('/api/workspaces')).body.workspaces[0].id;
  const {url}=await f.runtime.enableLAN({address,port:0});
  const invitation=await f.runtime.desktop('mobile.pair',{workspaceId:w,writable:false});
  const pairBody={token:new URLSearchParams(new URL(invitation.url).hash.slice(1)).get('pair'),deviceName:'Test phone'};
  const pair=await f.api('/api/pair',{url,origin:url,cookie:'',body:pairBody});assert.equal(pair.status,200);
  const cookie=pair.headers.get('set-cookie').split(';')[0];assert(cookie.startsWith('TheAllLANSession='));assert(pair.headers.get('set-cookie').includes('HttpOnly'));
  assert.equal((await f.api('/api/pair',{url,origin:url,cookie:'',body:pairBody})).status,401);
  assert.equal((await f.api('/api/session',{url,cookie:`TheAllDesktopSession=${f.runtime.desktopToken}`})).status,401);
  assert.equal((await f.api('/api/session',{cookie})).status,401);
  assert.equal((await f.api('/api/session',{url,cookie:cookie+'; '+cookie})).status,401);
  assert.equal((await f.api(`/api/chats/${id}`,{url,cookie})).status,200);
  assert.equal((await f.api(`/api/chats/${id}/send`,{url,origin:url,cookie,body:mutation(f.runtime,{text:'Forbidden'})})).status,403);
  const second=await f.create();assert.equal((await f.api(`/api/chats/${second}`,{url,cookie})).status,404);
  const socket=new WebSocket(url.replace('http:','ws:')+'/api/events',{headers:{origin:url,cookie}});t.after(()=>socket.terminate());
  const messages=[];socket.on('message',b=>messages.push(JSON.parse(b.toString())));
  await new Promise((resolve,reject)=>{socket.on('open',resolve);socket.on('error',reject);});
  const closed=new Promise(resolve=>socket.on('close',resolve));const devices=await f.runtime.desktop('mobile.devices');
  assert(!JSON.stringify(devices).includes('tokenHash'));await f.runtime.desktop('mobile.revoke',{id:devices.devices[0].id});await closed;
  assert(messages.some(m=>m.type==='hello'));assert(messages.some(m=>m.type==='revoked'));
  assert.equal((await f.api('/api/session',{url,cookie})).status,401);
});

test('update handoff gates new desktop and phone tasks, permits draft flush and can recover',async t=>{
 const f=await fixture(t);const id=await f.create();assert.equal(f.runtime.tryBeginUpdate(),true);
 assert.equal(f.runtime.tryBeginUpdate(),false);
 await assert.rejects(f.runtime.desktop('workspace.create',{}),/installing an update/);
 await f.runtime.desktop('draft.save',{id,text:'Saved before update',model:'test-model'});
 const denied=await f.api(`/api/chats/${id}/send`,{body:mutation(f.runtime,{text:'Must not start',model:'test-model'})});assert.equal(denied.status,503);assert.equal(FakeSession.starts,0);
 await assert.rejects(f.runtime.desktop('update.install',{}),/installing an update/);
 f.runtime.abortUpdate();const sent=await f.api(`/api/chats/${id}/send`,{body:mutation(f.runtime,{text:'Retry after failed installation',model:'test-model'})});assert.equal(sent.status,200);
 const data=await f.api(`/api/chats/${id}`);assert(data.body.messages.some(m=>m.text==='Retry after failed installation'));
});
test('an initializing provider and an active AI turn prevent update handoff',async t=>{
 let instance;class BusySession extends FakeSession{constructor(o){super(o);instance=this;}async send(input){await super.send(input);this.isBusy=true;}}
 const f=await fixture(t,{Session:BusySession});const id=await f.create();let resolve;FakeSession.delay=new Promise(r=>resolve=r);
 const sending=f.api(`/api/chats/${id}/send`,{body:mutation(f.runtime,{text:'Running task',model:'test-model'})});
 for(let i=0;i<100&&!FakeSession.starts;i++)await new Promise(r=>setTimeout(r,5));
 assert.equal(f.runtime.tryBeginUpdate(),false);resolve();assert.equal((await sending).status,200);assert.equal(f.runtime.tryBeginUpdate(),false);
 instance.isBusy=false;instance.questions=[{id:'question'}];assert.equal(f.runtime.tryBeginUpdate(),false);instance.questions=[];assert.equal(f.runtime.tryBeginUpdate(),true);
});

test('final save failure cancels update shutdown without disabling the runtime or losing drafts',async t=>{
 let session;class RecoverableSession extends FakeSession{constructor(options){super(options);session=this;}}
 const f=await fixture(t,{Session:RecoverableSession});const id=await f.create();
 assert.equal((await f.api(`/api/chats/${id}/send`,{body:mutation(f.runtime,{text:'Before update',model:'test-model'})})).status,200);
 const conversationID=session.chat.conversationID;
 const socket=new WebSocket(f.runtime.url.replace('http:','ws:')+'/api/events',{headers:{origin:f.runtime.url,cookie:`TheAllDesktopSession=${f.runtime.desktopToken}`}});
 t.after(()=>socket.terminate());const events=[];socket.on('message',b=>events.push(JSON.parse(b.toString())));
 await new Promise((resolve,reject)=>{socket.once('open',resolve);socket.once('error',reject);});
 await f.runtime.desktop('draft.save',{id,text:'Keep me',model:'test-model'});
 events.length=0;session.emit('change'); // A coalesced event is pending when shutdown cancels it.
 assert(f.runtime.tryBeginUpdate());const original=Store.prototype.save;let calls=0;
 Store.prototype.save=function(){if(this.directory===f.dataDir&&++calls===2)throw new Error('Injected disk full');return original.call(this);};
 try{await assert.rejects(f.runtime.close(),/Injected disk full/);}finally{Store.prototype.save=original;}
 const response=await f.api(`/api/chats/${id}`);assert.equal(response.status,200);assert.equal((await f.runtime.desktop('draft.get',{id})).text,'Keep me');
 await f.runtime.desktop('draft.save',{id,text:'Recovered',model:'test-model'});
 assert.equal((await f.api(`/api/chats/${id}/send`,{body:mutation(f.runtime,{text:'After failed update',model:'test-model'})})).status,200);
 assert.equal(session.chat.conversationID,conversationID);
 for(let i=0;i<100&&!events.some(e=>e.type==='changed');i++)await new Promise(r=>setTimeout(r,10));
 assert(events.some(e=>e.type==='changed'),'Live phone/desktop events resume after a cancelled shutdown');
 assert.equal(f.runtime.tryBeginUpdate(),true);f.runtime.abortUpdate();
});

test('files persist as metadata, download only from their conversation, and identical requests execute once',async t=>{
 const f=await fixture(t),id=await f.create();
 const bytes=Buffer.from('Private file 资料\u0000'),body=mutation(f.runtime,{text:'',files:[{name:'../资料 "x".pdf',data:bytes.toString('base64')}]});
 assert.equal((await f.api(`/api/chats/${id}/send`,{body})).status,200);
 assert.equal((await f.api(`/api/chats/${id}/send`,{body})).status,200);assert.equal(FakeSession.sends,1);
 const file=(await f.api(`/api/chats/${id}`)).body.messages[0].files[0];assert.equal(file.name,'资料 "x".pdf');assert(!('data'in file));assert(!('path'in file));
 const route=`/api/chats/${id}/files/${file.id}`,download=()=>fetch(f.runtime.url+route,{headers:{cookie:`TheAllDesktopSession=${f.runtime.desktopToken}`}});
 let response=await download();assert.equal(response.status,200);assert.match(response.headers.get('content-disposition'),/^attachment;/);assert.equal(response.headers.get('x-content-type-options'),'nosniff');assert.deepEqual(Buffer.from(await response.arrayBuffer()),bytes);
 assert.equal((await fetch(f.runtime.url+route)).status,401);const other=await f.create();assert.equal((await f.api(`/api/chats/${other}/files/${file.id}`)).status,404);
 const saved=fs.readFileSync(path.join(f.dataDir,'workspaces.json'),'utf8');assert(!saved.includes(bytes.toString('base64')));assert.equal(JSON.parse(saved).version,2);
 await f.restart();response=await download();assert.equal(response.status,200);assert.deepEqual(Buffer.from(await response.arrayBuffer()),bytes);
 const {FileAttachments}=await import('../src/attachments.mjs');fs.writeFileSync(new FileAttachments(f.dataDir).path(file),'changed');assert.equal((await download()).status,404);
});
test('desktop file drafts survive restart without base64 in workspace JSON; missing files preserve the text draft',async t=>{
 const f=await fixture(t),id=await f.create(),data=Buffer.from('saved draft bytes').toString('base64');
 const payload={id,text:'Keep this text',images:[],files:[{id:randomUUID(),name:'draft.txt',data}],model:'test-model'};
 await f.runtime.desktop('draft.save',payload);const draft=await f.runtime.desktop('draft.get',{id});assert.equal(draft.files[0].data,data);
 await f.runtime.desktop('draft.save',payload);const next=await f.runtime.desktop('draft.get',{id});assert.equal(next.files[0].id,draft.files[0].id);
 const json=fs.readFileSync(path.join(f.dataDir,'workspaces.json'),'utf8');assert(!json.includes(data));assert.equal(JSON.parse(json).version,2);
 await f.restart();assert.deepEqual(await f.runtime.desktop('draft.get',{id}),next);
 const {FileAttachments}=await import('../src/attachments.mjs');fs.unlinkSync(new FileAttachments(f.dataDir).path(next.files[0]));
 const missing=await f.runtime.desktop('draft.get',{id});assert.equal(missing.text,payload.text);assert.equal(missing.files[0].unavailable,true);
 await f.runtime.desktop('draft.save',{...payload,files:[]});assert.deepEqual((await f.runtime.desktop('draft.get',{id})).files,[]);
});
test('rejected file submissions remove only new imports; unknown outcomes retain attached bytes and are never retried',async t=>{
 class Reject extends FakeSession{async send(){throw new Error('Rejected before write');}}
 const failed=await fixture(t,{Session:Reject}),id=await failed.create(),input={text:'',files:[{name:'a.txt',data:Buffer.from('bytes').toString('base64')}]};
 assert.equal((await failed.api(`/api/chats/${id}/send`,{body:mutation(failed.runtime,input)})).status,409);
 assert.deepEqual(fs.readdirSync(path.join(failed.dataDir,'FileAttachments')),[]);
 const f=await fixture(t),chat=await f.create();FakeSession.uncertain=true;const body=mutation(f.runtime,input);
 const response=await f.api(`/api/chats/${chat}/send`,{body});assert.equal(response.body.code,'outcome_unknown');assert.equal(fs.readdirSync(path.join(f.dataDir,'FileAttachments')).length,1);
 await f.api(`/api/chats/${chat}/send`,{body});assert.equal(FakeSession.sends,1);FakeSession.uncertain=false;
});

test('missing file drafts can retain owned references while edits save; foreign references and failed saves preserve previous data',async t=>{
 const f=await fixture(t),id=await f.create(),other=await f.create();
 const files=[{name:'first.txt',data:'YQ=='},{name:'second.txt',data:'Yg=='}];
 await f.runtime.desktop('draft.save',{id,text:'original',files});const draft=await f.runtime.desktop('draft.get',{id});
 const {FileAttachments}=await import('../src/attachments.mjs'),attachments=new FileAttachments(f.dataDir);
 fs.unlinkSync(attachments.path(draft.files[0]));fs.unlinkSync(attachments.path(draft.files[1]));
 const missing=await f.runtime.desktop('draft.get',{id});await f.runtime.desktop('draft.save',{id,text:'edited',files:[missing.files[1]]});
 const restored=await f.runtime.desktop('draft.get',{id});assert.equal(restored.text,'edited');assert.equal(restored.files[0].id,missing.files[1].id);assert.equal(restored.files[0].unavailable,true);
 await assert.rejects(f.runtime.desktop('draft.save',{id:other,text:'foreign',files:restored.files}),/unavailable/);
 await f.runtime.desktop('draft.save',{id,text:'fixed',files:[files[1]]});const fixed=await f.runtime.desktop('draft.get',{id});assert.equal(fixed.files[0].data,'Yg==');
 const originalSave=Store.prototype.save,before=fs.readFileSync(path.join(f.dataDir,'workspaces.json'));
 try{Store.prototype.save=function(){if(this.directory===f.dataDir)throw new Error('Injected storage failure');return originalSave.call(this);};
   await assert.rejects(f.runtime.desktop('draft.save',{id,text:'must not replace',files:[{name:'new.txt',data:'Yw=='}]}),/storage failure/);
 }finally{Store.prototype.save=originalSave;}
 assert.deepEqual(fs.readFileSync(path.join(f.dataDir,'workspaces.json')),before);assert.deepEqual(await f.runtime.desktop('draft.get',{id}),fixed);
 assert.deepEqual(fs.readdirSync(attachments.directory),[path.basename(attachments.path(fixed.files[0]))]);
});
test('paired read-only phone can download an authorized file, but other workspaces and revoked devices cannot',async t=>{
 const address=lanAddresses()[0]?.address;if(!address){t.skip('No private network interface available');return;}
 const f=await fixture(t),id=await f.create(),other=await f.create();
 for(const chat of [id,other])assert.equal((await f.api(`/api/chats/${chat}/send`,{body:mutation(f.runtime,{text:'',files:[{name:'document.txt',data:'cHJpdmF0ZQ=='}]})})).status,200);
 const file=(await f.api(`/api/chats/${id}`)).body.messages[0].files[0],foreign=(await f.api(`/api/chats/${other}`)).body.messages[0].files[0];
 const w=(await f.api('/api/workspaces')).body.workspaces.find(w=>w.conversations.some(c=>c.id===id)).id;
 const {url}=await f.runtime.enableLAN({address,port:0}),invitation=await f.runtime.desktop('mobile.pair',{workspaceId:w,writable:false});
 const pair=await f.api('/api/pair',{url,origin:url,cookie:'',body:{token:new URLSearchParams(new URL(invitation.url).hash.slice(1)).get('pair'),deviceName:'File phone'}});
 const cookie=pair.headers.get('set-cookie').split(';')[0];
 const get=(chat,file)=>fetch(`${url}/api/chats/${chat}/files/${file}`,{headers:{cookie}});
 const allowed=await get(id,file.id);assert.equal(allowed.status,200);assert.equal(await allowed.text(),'private');
 assert.equal((await get(other,foreign.id)).status,404);
 const devices=await f.runtime.desktop('mobile.devices');await f.runtime.desktop('mobile.revoke',{id:devices.devices[0].id});assert.equal((await get(id,file.id)).status,401);
});
test('file uploads above the former photo request limit work and mixed invalid imports leave no orphan files',async t=>{
 const f=await fixture(t),id=await f.create(),bytes=Buffer.alloc(4*1024*1024,65);
 assert.equal((await f.api(`/api/chats/${id}/send`,{body:mutation(f.runtime,{text:'',files:[{name:'large.bin',data:bytes.toString('base64')}]})})).status,200);
 const before=fs.readdirSync(path.join(f.dataDir,'FileAttachments'));
 const result=await f.api(`/api/chats/${id}/send`,{body:mutation(f.runtime,{text:'invalid',images:[{name:'p.png',data:pixels.toString('base64')}],files:[{name:'bad',data:'not-base64'}]})});
 assert.equal(result.status,409);assert.deepEqual(fs.readdirSync(path.join(f.dataDir,'FileAttachments')),before);assert.deepEqual(fs.readdirSync(path.join(f.dataDir,'Attachments')),[]);
});

test('steer API requires a live matching task, is idempotent, preserves drafts and never starts a CLI', async t => {
  let active, steers = 0;
  class SteeringSession extends FakeSession {
    constructor(options) { super(options); active = this; this.steerToken = null; this.canSteer = false; }
    async send(input) { await super.send(input); this.isBusy = true; this.canInterrupt = true; this.canSteer = true; this.steerToken = randomUUID(); }
    async steer({ text, images, files, steerToken, stillAuthorized }) {
      if (!this.canSteer || steerToken !== this.steerToken || !stillAuthorized()) throw new Error('Task changed');
      steers++;
      this.chat.messages.push({ id: randomUUID(), role: 'user', text, images: images.map(({ path, data, ...i }) => i), files });
      this.emit('change');
    }
  }
  const f = await fixture(t, { Session: SteeringSession }), id = await f.create();
  const request = values => f.api(`/api/chats/${id}/steer`, { body: mutation(f.runtime, values) });
  assert.equal((await request({ text: 'Before starting', steerToken: randomUUID() })).status, 409); assert.equal(FakeSession.starts, 0);
  assert.equal((await f.api(`/api/chats/${id}/send`, { body: mutation(f.runtime, { text: 'Original' }) })).status, 200);
  const snapshot = (await f.api(`/api/chats/${id}`)).body;
  assert.equal(snapshot.canSteer, true); assert.equal(snapshot.steerToken, active.steerToken);
  await f.runtime.desktop('draft.save', { id, text: 'Desktop draft', images: [] });
  assert.equal((await request({ text: 'No token' })).status, 409);
  assert.equal((await request({ text: 'Old token', steerToken: randomUUID() })).status, 409);
  assert.equal((await request({ text: 'Change model', steerToken: snapshot.steerToken, model: 'different' })).status, 400);
  const body = mutation(f.runtime, { text: 'Keep the colors', steerToken: snapshot.steerToken, files: [{ name: 'notes.txt', data: Buffer.from('File body').toString('base64') }] });
  for (let i = 0; i < 2; i++) assert.equal((await f.api(`/api/chats/${id}/steer`, { body })).status, 200);
  assert.equal(steers, 1); assert.equal(FakeSession.sends, 1); assert.equal(FakeSession.starts, 1);
  assert.equal((await f.runtime.desktop('draft.get', { id })).text, 'Desktop draft');
  const history = (await f.api(`/api/chats/${id}`)).body.messages;
  assert.equal(history.at(-1).text, 'Keep the colors'); assert.equal(history.at(-1).files[0].name, 'notes.txt');
  active.steerToken = randomUUID();
  assert.equal((await request({ text: 'Old task', steerToken: snapshot.steerToken })).status, 409);
});

test('steer completion race during image import rejects and removes unowned attachments', async t => {
  let active;
  class SteeringSession extends FakeSession {
    constructor(options) { super(options); active = this; }
    async send(input) { await super.send(input); this.isBusy = true; this.canSteer = true; this.steerToken = randomUUID(); }
    async steer({ steerToken }) { if (steerToken !== this.steerToken) throw new Error('Task changed'); throw new Error('Must not reach CLI'); }
  }
  const f = await fixture(t, { Session: SteeringSession, normalizeImage: async () => {
    active.steerToken = randomUUID();
    return { data: pixels, mimeType: 'image/png', width: 1, height: 1 };
  } }), id = await f.create();
  await f.api(`/api/chats/${id}/send`, { body: mutation(f.runtime, { text: 'Original' }) });
  const body = mutation(f.runtime, { text: 'Stale after import', steerToken: active.steerToken, images: [{ name: 'photo.png', data: pixels.toString('base64') }], files: [{ name: 'file.txt', data: '' }] });
  const response = await f.api(`/api/chats/${id}/steer`, { body }); assert.equal(response.status, 409);
  assert.equal(active.chat.messages.filter(m => m.role === 'user').length, 1);
  assert.equal(fs.readdirSync(path.join(f.dataDir, 'FileAttachments')).length, 0);
});
