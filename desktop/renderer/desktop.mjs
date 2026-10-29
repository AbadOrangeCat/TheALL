import { t, setLocale, getLocale, languageNames } from './localization.mjs';
import { applyTheme } from './theme.mjs';
import { themes } from './themes.mjs';
import { icon, iconMarkup } from './icons.mjs';
const $=id=>document.getElementById(id);
const bridge=window.theall;
if(!bridge)throw new Error('The desktop window is not connected to TheAll');
let updateState={phase:'idle'}, updateSignature='';
const state={workspaces:[],selected:null,settings:{},activePane:null,section:'appearance',polling:false,viewSignatures:new Map(),views:new Map(),drag:null,metadata:new Map(),modelLoads:new Map()};
const invoke=async(method,payload={})=>{const result=await bridge.invoke(method,payload);if(['connection.save','connection.remove'].includes(method)){state.settings=await bridge.invoke('settings.get');state.modelLoads.delete(payload.provider);}return result;};
function node(tag,cls,text){const value=document.createElement(tag);if(cls)value.className=cls;if(text!==undefined)value.textContent=text;return value;}
function button(text,action,cls=''){const b=node('button',cls,text);b.type='button';b.onclick=()=>run(action);return b;}
function error(error){$('desktop-error').textContent=error?.message||String(error);$('desktop-error').hidden=false;}
async function run(action){try{$('desktop-error').hidden=true;return await action();}catch(e){error(e);}}
const selectedWorkspace=()=>state.workspaces.find(w=>w.id===state.selected);
const selectedTab=()=>{const w=selectedWorkspace();return w?.tabs?.find(tab=>tab.id===w.selectedTabId)||w?.tabs?.[0];};
function terminals(layout){return !layout?[]:layout.type==='terminal'?[layout.terminalId]:[...terminals(layout.first),...terminals(layout.second)];}
function topology(layout){return !layout?null:layout.type==='terminal'?{type:'terminal',terminalId:layout.terminalId}:{type:'split',direction:layout.direction,first:topology(layout.first),second:topology(layout.second)};}
async function flush(){await Promise.all([...document.querySelectorAll('.pane iframe')].map(frame=>frame.contentWindow?.theallFlushDrafts?.()));}
window.theallFlushDrafts=flush;
window.theallDesktop={
  invoke, get settings(){return state.settings;},get locale(){return getLocale();},
  active(id){state.activePane=id;document.querySelectorAll('.pane').forEach(p=>p.classList.toggle('active',p.dataset.id===id));},
  changed:()=>refresh(), ensureModels(provider){if(!state.modelLoads.has(provider)){state.modelLoads.set(provider,invoke('models.list',{provider}).then(()=>refresh()).catch(()=>{}));}return state.modelLoads.get(provider);}, openSettings(section='agents'){showSettings(section);},
  keyboard:event=>shortcuts(event), reportError:error
};
async function refresh(){
 if(state.polling)return;state.polling=true;
 try{
  const response=await fetch('/api/workspaces',{credentials:'same-origin',cache:'no-store'});if(!response.ok)throw new Error('Unable to read saved workspaces');
  const data=await response.json();state.workspaces=data.workspaces;
  state.selected=data.selectedWorkspaceId||state.selected||state.workspaces[0]?.id;
  if(!state.workspaces.some(w=>w.id===state.selected))state.selected=state.workspaces[0]?.id;
  renderWorkspaces();renderTabs();renderPanes();
 }finally{state.polling=false;}
}
async function mutate(method,payload){await flush();const result=await invoke(method,payload);await refresh();return result;}
async function createWorkspace(){const r=await mutate('workspace.create',{});state.selected=r.id;await refresh();hideSettings();}
async function createTab(provider){const w=selectedWorkspace();if(!w)return createWorkspace();await mutate('tab.create',{workspaceId:w.id,...(provider?{provider}:{}),directory:state.settings.defaultDirectory});hideSettings();}
async function chooseWorkspace(id){await mutate('workspace.select',{id});state.selected=id;hideSettings();await refresh();}
async function chooseTab(id){const w=selectedWorkspace();if(w)await mutate('tab.select',{workspaceId:w.id,id});}
async function split(direction,id=state.activePane){const w=selectedWorkspace(),tab=selectedTab();id||=terminals(tab?.layout)[0];if(!w||!tab||!id)return;const result=await mutate('pane.split',{workspaceId:w.id,tabId:tab.id,terminalId:id,direction});state.activePane=result.terminalId;}
async function closePane(id=state.activePane){const w=selectedWorkspace(),tab=selectedTab();id||=terminals(tab?.layout)[0];if(!w||!tab||!id)return;if(state.settings.confirmClose==='false'||await confirm(t('closePane'),t('closeDetail')))await mutate('pane.close',{workspaceId:w.id,tabId:tab.id,terminalId:id});}
async function closeTab(id){const w=selectedWorkspace();if(w&&(state.settings.confirmClose==='false'||await confirm(t('closeTab'),t('closeDetail'))))await mutate('tab.close',{workspaceId:w.id,id});}
function context(event,entries){event.preventDefault();const menu=$('context-menu');menu.replaceChildren(...entries.map(entry=>{if(!entry)return node('hr');const[title,action,danger,shortcut]=entry;const item=button(title,()=>{menu.hidden=true;return action();},danger?'danger':'');if(shortcut)item.append(node('kbd','',shortcut));return item;}));menu.hidden=false;menu.style.left=`${Math.min(event.clientX,innerWidth-menu.offsetWidth-8)}px`;menu.style.top=`${Math.min(event.clientY,innerHeight-menu.offsetHeight-8)}px`;}
document.addEventListener('pointerdown',e=>{if(!$('context-menu').contains(e.target))$('context-menu').hidden=true;});
function edit(title,value,action){const dialog=$('edit-dialog');$('edit-title').textContent=title;$('edit-label').textContent=t('name');$('edit-value').value=value;dialog.showModal();$('edit-value').select();$('edit-form').onsubmit=event=>{event.preventDefault();const value=$('edit-value').value.trim();if(!value)return;dialog.close();run(()=>action(value));};}
$('edit-cancel').onclick=()=>$('edit-dialog').close();
function confirm(title,description){const dialog=$('confirm-dialog');$('confirm-title').textContent=title;$('confirm-description').textContent=description;dialog.returnValue='cancel';dialog.showModal();return new Promise(resolve=>dialog.addEventListener('close',()=>resolve(dialog.returnValue==='confirm'),{once:true}));}
async function renameWorkspace(w){edit(t('rename'),w.name,name=>mutate('workspace.rename',{id:w.id,name}));}
async function deleteWorkspace(w){if(await confirm(t('delete'),t('deleteDetail')))await mutate('workspace.delete',{id:w.id});}
const conversationStatus=list=>['needsInput','running','idle'].find(status=>list.some(c=>c.status===status))||'';
// Matches the Mac TerminalStatusIconView: spinning arc, filled dot or hollow ring.
function statusIcon(status){const value=node('span','status-icon '+status);value.hidden=!status;value.setAttribute('aria-hidden','true');return value;}
function renderWorkspaces(){
 const signature=JSON.stringify([state.selected,getLocale(),state.workspaces.map(w=>[w.id,w.name,w.conversations.map(c=>[c.directory,c.status]),state.metadata.get(w.id)])]);
 if(state.viewSignatures.get('workspaces')===signature)return;state.viewSignatures.set('workspaces',signature);
 const items=state.workspaces.map(w=>{
  const row=node('div','workspace-row'+(w.id===state.selected?' selected':''));row.tabIndex=0;row.draggable=true;row.title=t('dragHint');row.setAttribute('role','button');row.setAttribute('aria-current',String(w.id===state.selected));
  const heading=node('div','workspace-heading');heading.append(node('span','workspace-title',w.name),statusIcon(conversationStatus(w.conversations)));
  const copy=node('div','workspace-copy');copy.append(heading,node('div','workspace-detail',w.conversations[0]?.directory||''));row.append(copy);const metadata=state.metadata.get(w.id);if(metadata?.isGit){const detail=copy.querySelector('.workspace-detail');detail.textContent=`⎇ ${metadata.branch||'HEAD'}${metadata.changed?' · '+metadata.changed+' Δ':''}${metadata.ahead?' ↑'+metadata.ahead:''}${metadata.behind?' ↓'+metadata.behind:''}`;detail.title=metadata.directory||'';}
  row.onclick=()=>run(()=>chooseWorkspace(w.id));row.onkeydown=e=>{if(e.key==='Enter')run(()=>chooseWorkspace(w.id));};row.ondblclick=()=>renameWorkspace(w);
  const entries=[[t('rename'),()=>renameWorkspace(w)],null,[t('delete'),()=>deleteWorkspace(w),true]];
  row.oncontextmenu=e=>context(e,entries);
  row.ondragstart=e=>{state.drag={type:'workspace',id:w.id};e.dataTransfer.effectAllowed='move';e.dataTransfer.setData('text/plain',w.id);};
  row.ondragover=e=>{if(state.drag?.type==='workspace')e.preventDefault();};row.ondrop=e=>{if(state.drag?.type!=='workspace')return;e.preventDefault();const ids=state.workspaces.map(v=>v.id).filter(id=>id!==state.drag.id);ids.splice(ids.indexOf(w.id),0,state.drag.id);state.drag=null;run(()=>mutate('workspace.reorder',{ids}));};return row;
 });$('desktop-workspaces').replaceChildren(...items);
}
function renderTabs(){
 const w=selectedWorkspace(),tab=selectedTab();const tabStatus=item=>conversationStatus((w?.conversations||[]).filter(c=>terminals(item.layout).includes(c.id)));const signature=JSON.stringify([getLocale(),w?.id,w?.tabs?.map(v=>[v.id,v.title,tabStatus(v)]),tab?.id]);if(state.viewSignatures.get('tabs')===signature)return;state.viewSignatures.set('tabs',signature);
 $('desktop-tabs').replaceChildren(...(w?.tabs||[]).map(item=>{
  const pill=node('div','tab-pill'+(item.id===tab?.id?' selected':''));pill.tabIndex=0;pill.draggable=true;pill.setAttribute('role','tab');pill.setAttribute('aria-selected',String(item.id===tab?.id));pill.title=item.title||t('newTab');
  // Like the Mac tab strip: kind icon, title and status, no close button. Middle-click closes.
  pill.append(icon('terminal','tab-kind'),node('span','tab-name',item.title||t('newTab')),statusIcon(tabStatus(item)));
  pill.onmousedown=e=>{if(e.button===1)e.preventDefault();};pill.onauxclick=e=>{if(e.button===1){e.preventDefault();run(()=>closeTab(item.id));}};
  pill.onclick=()=>run(()=>chooseTab(item.id));pill.onkeydown=e=>{if(e.key==='Enter')run(()=>chooseTab(item.id));};pill.ondblclick=()=>edit(t('rename'),item.title,title=>mutate('tab.rename',{workspaceId:w.id,id:item.id,title}));
  const paneEntries=item.id===tab?.id?[[t('splitRight'),()=>split('horizontal'),false,'Ctrl+D'],[t('splitDown'),()=>split('vertical'),false,'Ctrl+Shift+D'],[t('closePane'),()=>closePane(),false,'Ctrl+W'],null]:[];
  pill.oncontextmenu=e=>context(e,[[t('rename'),()=>edit(t('rename'),item.title,title=>mutate('tab.rename',{workspaceId:w.id,id:item.id,title}))],null,...paneEntries,[t('closeTab'),()=>closeTab(item.id),true]]);
  pill.ondragstart=e=>{state.drag={type:'tab',id:item.id,workspaceId:w.id};e.dataTransfer.effectAllowed='move';e.dataTransfer.setData('text/plain',item.id);};pill.ondragover=e=>{if(state.drag?.type==='tab'&&state.drag.workspaceId===w.id)e.preventDefault();};pill.ondrop=e=>{if(state.drag?.type!=='tab'||state.drag.workspaceId!==w.id)return;e.preventDefault();const ids=w.tabs.map(v=>v.id).filter(id=>id!==state.drag.id);ids.splice(ids.indexOf(item.id),0,state.drag.id);state.drag=null;run(()=>mutate('tab.reorder',{workspaceId:w.id,ids}));};return pill;
 }));
}
function makeLayout(layout,w,tab,path=[]){
 if(layout.type==='terminal'){
  const id=layout.terminalId,summary=w.conversations.find(c=>c.id===id),pane=node('section','pane');pane.dataset.id=id;
  // Mac panes have no toolbar: split and close live in the tab menu and Ctrl+D / Ctrl+Shift+D / Ctrl+W.
  const frame=node('iframe');frame.src=`/chat.html?id=${encodeURIComponent(id)}`;frame.title=summary?.title||'AI conversation';frame.setAttribute('sandbox','allow-same-origin allow-scripts allow-forms allow-modals allow-downloads');pane.append(frame);pane.addEventListener('pointerdown',()=>window.theallDesktop.active(id));return pane;
 }
 const splitNode=node('div','split-node '+(layout.direction==='vertical'?'vertical':'horizontal'));splitNode.dataset.splitPath=JSON.stringify(path);
 const a=node('div','split-child'),b=node('div','split-child'),handle=node('div','split-handle');a.append(makeLayout(layout.first,w,tab,[...path,0]));b.append(makeLayout(layout.second,w,tab,[...path,1]));a.style.flex=`${layout.ratio||.5} 1 0`;b.style.flex=`${1-(layout.ratio||.5)} 1 0`;
 handle.setAttribute('role','separator');handle.tabIndex=0;handle.setAttribute('aria-orientation',layout.direction==='vertical'?'horizontal':'vertical');
 handle.onpointerdown=event=>{event.preventDefault();handle.setPointerCapture(event.pointerId);document.querySelectorAll('iframe').forEach(f=>f.style.pointerEvents='none');let ratio=layout.ratio||.5;const move=e=>{const rect=splitNode.getBoundingClientRect();ratio=Math.max(.15,Math.min(.85,layout.direction==='vertical'?(e.clientY-rect.top)/rect.height:(e.clientX-rect.left)/rect.width));a.style.flex=`${ratio} 1 0`;b.style.flex=`${1-ratio} 1 0`;};const end=()=>{handle.removeEventListener('pointermove',move);document.querySelectorAll('iframe').forEach(f=>f.style.pointerEvents='');run(()=>invoke('pane.resize',{workspaceId:w.id,tabId:tab.id,path,ratio}));};handle.addEventListener('pointermove',move);handle.addEventListener('pointerup',end,{once:true});handle.addEventListener('pointercancel',end,{once:true});};
 handle.onkeydown=e=>{if(!['ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(e.key))return;e.preventDefault();const ratio=Math.max(.15,Math.min(.85,(layout.ratio||.5)+(['ArrowLeft','ArrowUp'].includes(e.key)?-.05:.05)));run(()=>mutate('pane.resize',{workspaceId:w.id,tabId:tab.id,path,ratio}));};splitNode.append(a,handle,b);return splitNode;
}
function updateRatios(view,layout,path=[]){if(layout?.type!=='split')return;const el=[...view.querySelectorAll('[data-split-path]')].find(v=>v.dataset.splitPath===JSON.stringify(path));if(el){el.children[0].style.flex=`${layout.ratio} 1 0`;el.children[2].style.flex=`${1-layout.ratio} 1 0`;}updateRatios(view,layout.first,[...path,0]);updateRatios(view,layout.second,[...path,1]);}
function renderPanes(){
 const w=selectedWorkspace(),tab=selectedTab();const valid=new Set(state.workspaces.flatMap(v=>v.tabs||[]).map(v=>v.id));
 for(const[id,view]of state.views){if(!valid.has(id)){view.remove();state.views.delete(id);state.viewSignatures.delete(id);}else view.hidden=id!==tab?.id;}
 $('empty-workspace').hidden=!!tab;$('pane-container').hidden=!tab;if(!tab)return;
 const signature=JSON.stringify(topology(tab.layout));let view=state.views.get(tab.id);
 if(!view||state.viewSignatures.get(tab.id)!==signature){view?.remove();view=node('div','tab-content');view.style.height='100%';view.append(makeLayout(tab.layout,w,tab));state.views.set(tab.id,view);state.viewSignatures.set(tab.id,signature);$('pane-container').append(view);}else updateRatios(view,tab.layout);
 view.hidden=false;const ids=terminals(tab.layout);if(!ids.includes(state.activePane))state.activePane=ids[0];window.theallDesktop.active(state.activePane);
}
function field(label,type='text',value=''){const wrap=node('div','field');const name=node('label','',label);const input=node('input');input.type=type;input.value=value??'';input.autocomplete='off';name.append(input);wrap.append(name);return{wrap,input};}
function selectField(label,options,value){const wrap=node('div','field'),name=node('label','',label),select=node('select');for(const[id,title]of options){const option=node('option','',title);option.value=id;select.append(option);}select.value=value;name.append(select);wrap.append(name);return{wrap,input:select};}
async function saveSettings(patch){await invoke('settings.save',patch);state.settings={...state.settings,...patch};applySettings();}
function applySettings(){setLocale(state.settings.language==='system'||!state.settings.language?resolveLocale(navigator.language):state.settings.language);document.documentElement.lang=getLocale();applyTheme(document,state.settings);document.querySelectorAll('[data-text]').forEach(el=>el.textContent=t(el.dataset.text));document.querySelectorAll('[data-title]').forEach(el=>{el.title=t(el.dataset.title);el.setAttribute('aria-label',el.title);});updateSidebarToggle();for(const f of document.querySelectorAll('iframe'))f.contentWindow?.dispatchEvent(new Event('theall:settings'));state.viewSignatures.delete('workspaces');state.viewSignatures.delete('tabs');renderWorkspaces();renderTabs();}
function resolveLocale(value){const raw=String(value||'').toLowerCase();return raw.startsWith('zh')?'zh-Hans':['fr','ja','ko'].find(v=>raw.startsWith(v))||'en';}
function rangeSetting(key,label,min,max,step,fallback){const row=node('div','setting-row');row.append(node('div','',t(label)));const control=node('div','setting-range'),input=node('input'),output=node('output');input.type='range';input.min=min;input.max=max;input.step=step;input.value=state.settings[key]??fallback;output.textContent=input.value;input.oninput=()=>output.textContent=input.value;input.onchange=()=>run(()=>saveSettings({[key]:Number(input.value)}));control.append(input,output);row.append(control);return row;}
function toggleSetting(key,label){const row=node('label','setting-row');row.append(node('span','',t(label)));const input=node('input');input.type='checkbox';input.checked=!!state.settings[key];input.onchange=()=>run(()=>saveSettings({[key]:input.checked}));row.append(input);return row;}
function resetSettings(values){const row=node('div','reset-row');row.append(button(t('settings.reset.button'),async()=>{await saveSettings(values);renderSettings();}));return row;}
function showSettings(section=state.section){state.section=section;$('workspace-content').hidden=true;$('settings-panel').hidden=false;renderSettings();}
function hideSettings(){$('settings-panel').hidden=true;$('workspace-content').hidden=false;}
function renderSettings(){
 const sections=['appearance','quickActions','agents','mobile','font','terminal','shell','update'];$('settings-tabs').replaceChildren(...sections.map(key=>{const b=button(t(key),()=>showSettings(key),'tab-pill'+(key===state.section?' selected':''));b.setAttribute('role','tab');return b;}));
 const content=node('section','settings-section');content.append(node('h2','',t(state.section)));$('settings-content').replaceChildren(content);
 if(state.section==='appearance'){
  const theme=field(t('settings.appearance.theme'),'text',state.settings.theme||'system');theme.wrap.classList.add('theme-field');theme.input.setAttribute('list','theme-list');const presets=node('datalist');presets.id='theme-list';for(const name of ['system','dark','light',...Object.keys(themes)]){const option=node('option','',['system','dark','light'].includes(name)?t(name):name);option.value=name;presets.append(option);}theme.wrap.append(presets);theme.input.onchange=()=>run(()=>saveSettings({theme:theme.input.value}));content.append(theme.wrap);
  for(const[key,label,min,max,step,fallback]of [
   ['backgroundOpacity','backgroundOpacity',0,1,.05,1],['backgroundBlur','backgroundBlur',0,100,1,0],['contentOpacity','contentOpacity',0,1,.05,1],['contentShadow','contentShadow',0,1,.05,0],['paddingX','windowPaddingX',0,100,1,4],['paddingY','windowPaddingY',0,100,1,4],['unfocusedPaneOpacity','unfocusedPaneOpacity',0,1,.05,.7]
  ])content.append(rangeSetting(key,'settings.appearance.'+label,min,max,step,fallback));
  const cursor=selectField(t('settings.appearance.cursorStyle'),[['block','▮'],['bar','│'],['underline','_']],state.settings.cursorStyle||'bar');cursor.input.onchange=()=>run(()=>saveSettings({cursorStyle:cursor.input.value}));content.append(cursor.wrap,toggleSetting('cursorBlink','settings.appearance.cursorBlink'));
  const language=selectField(t('language'),[['system',t('system')],...Object.entries(languageNames)],state.settings.language||'system');language.input.onchange=()=>run(async()=>{await saveSettings({language:language.input.value});renderSettings();});content.append(language.wrap);
  content.append(resetSettings({theme:'system',backgroundOpacity:1,backgroundBlur:0,contentOpacity:1,contentShadow:0,paddingX:4,paddingY:4,cursorStyle:'bar',cursorBlink:false,unfocusedPaneOpacity:.7}));
 }else if(state.section==='font'){
  const font=field(t('settings.font.family'),'text',state.settings.fontFamily||'Segoe UI');font.input.setAttribute('list','font-list');const list=node('datalist');list.id='font-list';for(const name of ['Segoe UI','Cascadia Code','Consolas','Arial','Courier New']){const option=node('option');option.value=name;list.append(option);}font.wrap.append(list);font.input.onchange=()=>run(()=>saveSettings({fontFamily:font.input.value}));content.append(font.wrap);
  if(window.queryLocalFonts)content.append(button(t('settings.font.listButton'),async()=>{const fonts=await window.queryLocalFonts();const names=[...new Set(fonts.map(f=>f.family))].sort();list.replaceChildren(...names.map(name=>{const opt=node('option');opt.value=name;return opt;}));font.input.focus();}));
  content.append(rangeSetting('fontSize','settings.font.size',6,72,1,13),toggleSetting('fontThicken','settings.font.thicken'),resetSettings({fontFamily:'Segoe UI',fontSize:13,fontThicken:false}));
 }else if(state.section==='agents'){
  content.append(node('p','help',t('cliHelp')));for(const provider of ['claude','openai'])content.append(connectionForm(provider));
  const links=node('div','cli-links');for(const[text,url]of [['Claude Code','https://code.claude.com/docs/en/setup'],['Codex','https://developers.openai.com/codex/windows/']]){const a=node('a','',text);a.href=url;a.target='_blank';a.rel='noreferrer';links.append(a);}content.append(links);
 }else if(state.section==='quickActions'){
  content.append(node('p','help',t('quickHelp')));for(const provider of ['claude','openai']){const row=node('div','setting-row');row.append(node('span','',provider==='claude'?'Claude Code':'Codex'),button(t('newTab'),()=>createTab(provider),'primary'));content.append(row);}
 }else if(state.section==='mobile'){
  content.append(button(t('connectPhone'),()=>openPhone(),'primary'),node('p','help',t('phoneDetail')));renderRelay(content);renderDevices(content);
 }else if(state.section==='shell'){
  const folder=field(t('defaultDirectory'),'text',state.settings.defaultDirectory||'');const actions=node('div','row-actions');actions.append(button(t('chooseFolder'),async()=>{const r=await invoke('folder.select',{directory:folder.input.value});if(r.directory){folder.input.value=r.directory;await saveSettings({defaultDirectory:r.directory});}}),button(t('save'),()=>saveSettings({defaultDirectory:folder.input.value}),'primary'));content.append(folder.wrap,actions,node('p','help',t('toolsAutomatic')));
 }else if(state.section==='terminal'){
  content.append(rangeSetting('scrollbackLimit','settings.terminal.scrollbackLimit',0,100000000,100000,10000000));
  const copy=selectField(t('settings.terminal.copyOnSelect'),[['false','false'],['true','true'],['clipboard','clipboard']],state.settings.copyOnSelect||'false');copy.input.onchange=()=>run(()=>saveSettings({copyOnSelect:copy.input.value}));content.append(copy.wrap,toggleSetting('hideMouseWhileTyping','settings.terminal.hideMouseWhileTyping'));
  const close=selectField(t('settings.terminal.confirmClose'),[['true','true'],['false','false'],['always','always']],state.settings.confirmClose||'true');close.input.onchange=()=>run(()=>saveSettings({confirmClose:close.input.value}));content.append(close.wrap,resetSettings({scrollbackLimit:10000000,copyOnSelect:'false',hideMouseWhileTyping:false,confirmClose:'true'}));
  content.append(node('h3','',t('shortcuts')));for(const[label,key]of [[t('newWorkspace'),'Ctrl+N'],[t('newTab'),'Ctrl+T'],[t('closePane'),'Ctrl+W'],[t('splitRight'),'Ctrl+D'],[t('splitDown'),'Ctrl+Shift+D'],[t('send'),'Ctrl+Enter'],[t('history'),'↑ / ↓']]){const row=node('div','setting-row');row.append(node('span','',label),node('kbd','',key));content.append(row);}content.append(node('p','help',t('toolsAutomatic')));
 }else if(state.section==='update'){
  content.append(node('p','',`${t('version')}: ${state.settings.version||''}`),node('p','help',t('updateAutomatic')));const updateBox=node('div');updateBox.id='update-settings';content.append(updateBox);renderUpdateSettings();const a=node('a','',t('openReleases'));a.href='https://github.com/AbadOrangeCat/TheALL/releases/latest';a.target='_blank';a.rel='noreferrer';a.style.display='inline-block';a.style.marginTop='20px';content.append(a);
 }
}
function connectionForm(provider){
 const saved=state.settings.connections?.[provider]||{},box=node('form','setting-group');box.append(node('h3','',provider==='claude'?'Claude Code':'Codex'),node('p','help',t(saved.configured?'configured':'notConfigured')));
 const key=field(t('apiKey'),'password');key.input.placeholder=saved.configured?t('keepKey'):t('apiKey');key.input.spellcheck=false;
 const base=field(t('baseURL'),'url',saved.baseURL||(provider==='claude'?'https://api.anthropic.com':'https://api.openai.com/v1'));
 const model=field(t('model'),'text',saved.model||'');model.input.placeholder=t('defaultModel');model.input.setAttribute('list',`models-${provider}`);const list=node('datalist');list.id=`models-${provider}`;box.append(list);
 const executable=field(t('executable'),'text',saved.executable||'');const bearer=node('label','help'),check=node('input');check.type='checkbox';check.checked=!!saved.useBearerToken;bearer.append(check,document.createTextNode(' '+t('bearer')));
 box.append(key.wrap,base.wrap,model.wrap,executable.wrap);if(provider==='claude')box.append(bearer);
 const feedback=node('p','save-state'),actions=node('div','row-actions');const save=button(t('save'),()=>{},'primary');save.type='submit';save.onclick=null;
 const load=button(t('loadModels'),async()=>{feedback.textContent='';load.disabled=true;try{const result=await invoke('models.list',{provider});list.replaceChildren(...result.models.map(m=>{const opt=node('option','',m.title||m.id);opt.value=m.id;return opt;}));model.input.focus();}catch(e){feedback.className='error-text';feedback.textContent=e.message;}finally{load.disabled=false;}});
 const forget=button(t('forget'),async()=>{if(await confirm(t('forget'),t('forget'))){await invoke('connection.remove',{provider});state.settings=await invoke('settings.get');renderSettings();}},'danger');actions.append(save,load,forget);box.append(actions,feedback);
 box.onsubmit=async event=>{event.preventDefault();save.disabled=true;feedback.textContent='';try{await invoke('connection.save',{provider,apiKey:key.input.value,baseURL:base.input.value,model:model.input.value,useBearerToken:check.checked,executable:executable.input.value});key.input.value='';state.settings=await invoke('settings.get');feedback.className='save-state';feedback.textContent=t('saved');window.theallDesktop.ensureModels(provider);for(const f of document.querySelectorAll('iframe'))f.contentWindow?.dispatchEvent(new Event('theall:connection'));}catch(e){feedback.className='error-text';feedback.textContent=e.message;}finally{save.disabled=false;}};return box;
}
async function renderDevices(parent){const box=node('div');parent.append(box);try{const{devices}=await invoke('mobile.devices');box.append(node('h3','',t('devices')));if(!devices.length)box.append(node('p','help',t('noDevices')));for(const device of devices){const row=node('div','device-row');const text=node('div');text.append(node('span','',device.name||device.deviceName||'Phone'),node('small','',` · ${t(device.access?.writable?'writable':'readOnly')}`));row.append(text,button(t('revoke'),async()=>{await invoke('mobile.revoke',{id:device.id});box.remove();renderDevices(parent);},'danger'));box.append(row);}}catch(e){box.append(node('p','error-text',e.message));}}
async function renderRelay(parent){const box=node('div','setting-group');box.append(node('h3','',t('relayTitle')));parent.append(box);try{const current=await invoke('mobile.relay.status');const url=field(t('relayURL'),'url',current.url||'');url.input.placeholder='wss://relay.example.com';const key=node('pre','help',current.publicKey||'');key.style.whiteSpace='pre-wrap';key.style.wordBreak='break-all';const status=node('p','help',current.error||current.state||'');box.append(url.wrap,button(t('save'),async()=>{const result=await invoke('mobile.relay.configure',{url:url.input.value});key.textContent=result.publicKey||'';status.textContent=result.error||result.state||'';} ,'primary'),node('p','help',t('relayKey')+' (THEALL_MAC_PUBLIC_KEY)'),key,status,button(t('connectPhone'),()=>openPhone('relay')));}catch(e){box.append(node('p','error-text',e.message));}}
async function openPhone(mode='lan'){
 const dialog=$('phone-dialog');if(!dialog.open)dialog.showModal();const content=$('phone-content');content.replaceChildren(node('p','help',t(mode==='relay'?'relayHelp':'phoneDetail')));
 const info=await invoke('mobile.info');
 const connection=selectField('',[['quick',t('quickMode')],['encrypted',t('encryptedMode')]],info.mode||'quick');
 const addresses=(info.addresses||[]).map(item=>typeof item==='string'?[item,item]:[item.address,`${item.name||item.interface||''} ${item.address}`.trim()]);
 const address=selectField(t('networkAddress'),[['','Automatic'],...addresses],info.address||'');
 if(mode==='lan'){const networking=node('div','field-row');networking.append(connection.wrap,address.wrap);content.append(networking);}
 const scope=selectField(t('allWorkspaces'),[['',t('allWorkspaces')],...state.workspaces.map(w=>[w.id,w.name])],'');const permission=selectField('',[['write',t('writable')],['read',t('readOnly')]],'write');const controls=node('div','field-row');controls.append(scope.wrap,permission.wrap);content.append(controls);
 const qr=node('div','qr-card'),message=node('p','error-text'),notice=node('p','help'),certificate=button(t('certificate'),()=>invoke('mobile.exportCertificate'));content.append(qr,message,notice,certificate);const actions=node('div','row-actions');const generate=button(t('regenerate'),pair,'primary');actions.append(generate,button(t('stopSharing'),async()=>{await invoke('mobile.disable');dialog.close();}));content.append(actions);renderDevices(content);
 async function pair(){generate.disabled=true;qr.replaceChildren();message.textContent='';const encrypted=mode==='lan'&&connection.input.value==='encrypted';notice.textContent=t(mode==='relay'?'relayHelp':encrypted?'tlsHelp':'phoneHTTP');certificate.hidden=!encrypted;try{if(mode==='lan')await invoke('mobile.enable',{mode:connection.input.value,...(address.input.value?{address:address.input.value}:{})});const result=await invoke('mobile.pair',{mode,workspaceId:scope.input.value||null,writable:permission.input.value==='write'});const img=node('img');img.src=result.qrDataURL;img.alt=t('connectPhone');qr.append(img,node('p','qr-url',result.url));}catch(e){message.textContent=e.message;}finally{generate.disabled=false;}}
 scope.input.onchange=()=>run(pair);permission.input.onchange=()=>run(pair);connection.input.onchange=()=>run(pair);address.input.onchange=()=>run(pair);await pair();
}
function shortcuts(e){if(e.isComposing||!(e.ctrlKey||e.metaKey))return;let action;const key=e.key.toLowerCase();if(key===',')action=()=>showSettings();else if(key==='n')action=createWorkspace;else if(key==='t')action=()=>createTab();else if(key==='w')action=()=>closePane();else if(key==='d')action=()=>split(e.shiftKey?'vertical':'horizontal');else if(/^[1-9]$/.test(key)){const index=Number(key)-1;if(e.altKey){const tab=selectedWorkspace()?.tabs?.[index];if(tab)action=()=>chooseTab(tab.id);}else{const w=state.workspaces[index];if(w)action=()=>chooseWorkspace(w.id);}}else if(e.altKey&&['arrowleft','arrowright'].includes(key)){const ids=terminals(selectedTab()?.layout),index=ids.indexOf(state.activePane),id=ids[(index+(key==='arrowright'?1:ids.length-1))%ids.length];if(id)action=()=>{window.theallDesktop.active(id);document.querySelector(`.pane[data-id="${CSS.escape(id)}"] iframe`)?.contentWindow?.focus();};}else if(e.shiftKey&&['[',']'].includes(key)){const tabs=selectedWorkspace()?.tabs||[],index=tabs.findIndex(v=>v.id===selectedTab()?.id),tab=tabs[(index+(key===']'?1:tabs.length-1))%tabs.length];if(tab)action=()=>chooseTab(tab.id);}if(action){e.preventDefault();run(action);return true;}return false;}
function updateSidebarToggle(){const button=$('toggle-sidebar');button.title=t(document.body.classList.contains('collapsed-sidebar')?'sidebar.show':'sidebar.hide');button.setAttribute('aria-label',button.title);}
document.addEventListener('keydown',shortcuts);$('toggle-sidebar').onclick=()=>{document.body.classList.toggle('collapsed-sidebar');updateSidebarToggle();};$('collapsed-brand').onclick=()=>showSettings('update');$('collapsed-settings').onclick=()=>showSettings();$('new-workspace').onclick=()=>run(createWorkspace);$('empty-new').onclick=()=>run(createWorkspace);$('new-tab').onclick=()=>run(()=>createTab());$('settings-button').onclick=()=>showSettings();$('version-button').onclick=()=>showSettings('update');$('close-settings').onclick=hideSettings;$('update-shortcut').onclick=()=>run(async()=>{updateState=await invoke('update.install');renderUpdate();});$('phone-shortcut').onclick=()=>run(()=>openPhone());$('close-phone').onclick=()=>$('phone-dialog').close();
function updateText(){return t(({available:'updateInstall',downloading:'updateDownloading',waiting:'updateWaiting',installing:'updateInstalling',error:'updateFailed',checking:'updateChecking',upToDate:'updateCurrent',disabled:'updateDevelopment'})[updateState.phase]||'updateCheck');}
function renderUpdate(){
 const busy=['downloading','waiting','installing','checking'].includes(updateState.phase);
 const card=$('update-shortcut');card.hidden=!updateState.version;card.disabled=busy;
 $('update-title').textContent=updateState.phase==='error'?t('updateFailed'):`${t('updateAvailable')} ${updateState.version||''}`;
 $('update-detail').textContent=updateText()+(updateState.phase==='downloading'?` ${Math.floor((updateState.progress||0)*100)}%`:'');
 card.title=updateState.error||'';renderUpdateSettings();
}
function renderUpdateSettings(){
 const box=$('update-settings');if(!box)return;box.replaceChildren(node('p','help',updateText()));
 if(updateState.error)box.append(node('p','error-text',updateState.error));
 const busy=['downloading','waiting','installing','checking'].includes(updateState.phase);
 const actions=node('div','row-actions');const check=button(t('updateCheck'),async()=>{updateState=await invoke('update.check');renderUpdate();});check.disabled=busy||updateState.phase==='disabled';actions.append(check);
 if(updateState.version){const install=button(t('updateInstall')+' '+updateState.version,async()=>{updateState=await invoke('update.install');renderUpdate();},'primary');install.disabled=busy;actions.append(install);}box.append(actions);
}
async function pollUpdate(){try{const next=await invoke('update.status'),signature=JSON.stringify([getLocale(),next]);if(signature!==updateSignature){updateSignature=signature;updateState=next;renderUpdate();}}catch{}}
matchMedia('(prefers-color-scheme:dark)').addEventListener('change',()=>applySettings());
document.documentElement.classList.toggle('mac',/Mac/.test(navigator.platform));
document.querySelectorAll('[data-icon]').forEach(el=>el.insertAdjacentHTML('afterbegin',iconMarkup(el.dataset.icon)));
try{state.settings=await invoke('settings.get');const info=await invoke('app.info');state.settings.version=info.version;$('app-version').textContent='v'+info.version;applySettings();await pollUpdate();setInterval(pollUpdate,1000);await refresh();if(!state.workspaces.length)await createWorkspace();setInterval(()=>refresh().catch(error),1500);async function metadata(){for(const w of state.workspaces){try{state.metadata.set(w.id,await invoke('workspace.metadata',{id:w.id}));}catch{}}renderWorkspaces();}metadata();setInterval(metadata,7000);}catch(e){error(e);}
