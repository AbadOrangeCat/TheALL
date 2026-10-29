import { desktopChat as chat, desktopHooks as hooks } from '/app.js';
import { t, setLocale } from './localization.mjs';
import { applyTheme } from './theme.mjs';
import { PromptHistory } from './history.mjs';
import { icon, iconMask } from './icons.mjs';
import { setLanguage, t as chatText } from '/i18n.js';
const shell=window.parent!==window&&window.parent.location.origin===location.origin?window.parent.theallDesktop:null;
if(!shell)throw new Error('The chat pane requires the desktop host');
const $=id=>document.getElementById(id);
const id=new URL(location.href).searchParams.get('id');
const css=document.createElement('link');css.rel='stylesheet';css.href='/desktop/pane.css';document.head.append(css);
// Icons for controls whose text the shared chat client rewrites on translation.
const iconStyle=document.createElement('style');iconStyle.textContent=[['.composer .attachment-add::before','paperclip'],['.composer #stop::before','stop.fill'],['.jump-bottom::before','arrow.down.to.line'],['.composer .directory::before','folder']].map(([selector,name])=>`${selector}{-webkit-mask-image:${iconMask(name)};mask-image:${iconMask(name)}}`).join('');document.head.append(iconStyle);
let loaded=false,restoreCounter=0,saveTimer,lastSaved='',lastFilesSaved='',saveTail=Promise.resolve(),setupProvider=null,setupDirectory='';
const history=new PromptHistory();
function node(tag,cls,text){const el=document.createElement(tag);if(cls)el.className=cls;if(text!==undefined)el.textContent=text;return el;}
function report(error){shell.reportError(error);}
function snapshot(){return{id:chat.selected,text:$('draft').value,images:(chat.imageDrafts.get(chat.selected)||[]).map(({id,name,data})=>({id,name,data,mimeType:'image/jpeg'})),files:(chat.fileDrafts.get(chat.selected)||[]).map(({id,name,data,byteCount,mimeType,sha256,unavailable})=>({id,name,data,byteCount,mimeType,sha256,...(unavailable?{unavailable:true}:{})})),model:chat.models.get(chat.selected)??chat.selectedChat?.model??'',reasoningEffort:chat.efforts.get(chat.selected)??chat.selectedChat?.reasoningEffort??''};}
function fileSignature(files) { return JSON.stringify(files.map(({id,name,byteCount,unavailable})=>({id,name,byteCount,unavailable}))); }
async function saveDraft(){
 clearTimeout(saveTimer);if(!loaded||!chat.selected)return;
 await chat.flushAttachments();
 const payload=snapshot(),fileState=fileSignature(payload.files);
 const encoded=JSON.stringify({...payload,files:fileState});if(encoded===lastSaved)return saveTail;
 const fileValues=payload.files;delete payload.files;lastSaved=encoded;
 saveTail=saveTail.catch(()=>{}).then(async()=>{
   if(fileState!==lastFilesSaved)payload.files=fileValues;
   await shell.invoke('draft.save',payload);lastFilesSaved=fileState;
 }).catch(e=>{lastSaved='';report(e);throw e;});return saveTail;
}
window.theallFlushDrafts=saveDraft;
hooks.beforeSelect=async target=>{const generation=++restoreCounter;await saveDraft();loaded=false;const saved=await shell.invoke('draft.get',{id:target});if(generation!==restoreCounter)return false;chat.setDraft(target,saved);loaded=true;history.reset();lastSaved='';lastFilesSaved=fileSignature(chat.fileDrafts.get(target)||[]);};
function updateComposerHint(){const hint=$('composer-hint');if(hint)hint.textContent=`Ctrl+↵ ${chatText(chat.selectedChat?.isBusy?'steer':'send')}`;}
hooks.onComposer=()=>{updateComposerHint();if(!loaded)return;clearTimeout(saveTimer);saveTimer=setTimeout(()=>saveDraft().catch(()=>{}),200);showSetupIfNeeded();};
function applySettings(){const settings=shell.settings;setLocale(shell.locale);setLanguage(shell.locale);applyTheme(document,settings);document.documentElement.lang=shell.locale;chat.translate?.();updateComposerHint();showSetupIfNeeded(true);}
window.addEventListener('theall:settings',applySettings);window.addEventListener('theall:connection',()=>{showSetupIfNeeded(true);chat.refresh();});
const hint=node('p','composer-hint');hint.id='composer-hint';$('composer').append(hint);
$('directory').role='button';$('directory').tabIndex=0;
async function chooseFolder(){if(chat.selectedChat?.isBusy||chat.pending)return;const result=await shell.invoke('folder.select',{directory:chat.selectedChat?.directory});if(result.directory){await shell.invoke('chat.update',{id,directory:result.directory});await chat.refresh();}}
$('directory').onclick=()=>chooseFolder().catch(report);$('directory').onkeydown=e=>{if(e.key==='Enter'){e.preventDefault();chooseFolder().catch(report);}};
document.addEventListener('pointerdown',()=>shell.active(id));window.addEventListener('focus',()=>shell.active(id));
let lastSetupSignature='',returnedToChooser=false;
const providerInfo={claude:{title:'Claude',tool:'Claude Code',icon:'sparkle',url:'https://api.anthropic.com'},openai:{title:'OpenAI',tool:'Codex',icon:'command',url:'https://api.openai.com/v1'}};
// Chat header (AIChatView.swift): the tool name and its connection settings, once a chat can run.
const header=node('header','desktop-chat-header'),headerTitle=node('span','desktop-chat-title'),headerSettings=node('button','desktop-chat-settings');
header.hidden=true;headerSettings.type='button';headerSettings.onclick=()=>shell.openSettings('agents');header.append(icon('sparkles'),headerTitle,headerSettings);$('chat-area').before(header);
function updateHeader(current,ready){header.hidden=!ready;headerTitle.textContent=providerInfo[current?.provider]?.tool||'AI';const label=t('ai.settings');if(headerSettings.textContent!==label)headerSettings.replaceChildren(icon('slider.horizontal.3'),node('span','',label));}
function heading(title,detail){const box=node('div','setup-heading');box.append(node('h2','',title),node('p','',detail));return box;}
// Provider chooser and connection form, laid out like AITerminalPaneView.swift.
function showSetupIfNeeded(force=false){
 const current=chat.selectedChat;let section=$('native-setup');if(!current)return;
 const ready=!!(current.provider&&shell.settings.connections?.[current.provider]?.configured);updateHeader(current,ready);
 if(ready){section?.remove();shell.ensureModels(current.provider);return;}
 if(current.provider&&!setupProvider&&!returnedToChooser)setupProvider=current.provider;
 const signature=JSON.stringify([shell.locale,shell.settings.connections,current.directory,setupProvider]);if(!force&&signature===lastSetupSignature&&section)return;lastSetupSignature=signature;section?.remove();
 section=node('section','native-setup');section.id='native-setup';const inner=node('div','setup-inner'),error=node('p','setup-error');
 setupDirectory||=current.directory||shell.settings.defaultDirectory||'';
 const directory=node('div','setup-directory'),choose=node('button'),folderPath=node('span','',setupDirectory);choose.type='button';choose.title=t('ai.directory.choose');choose.append(icon('folder'),folderPath);directory.append(choose);
 choose.onclick=async()=>{try{const r=await shell.invoke('folder.select',{directory:setupDirectory});if(r.directory){setupDirectory=r.directory;folderPath.textContent=r.directory;}}catch(e){error.textContent=e.message;}};
 if(setupProvider&&!shell.settings.connections?.[setupProvider]?.configured){
  const back=node('button','setup-back');back.type='button';back.append(icon('chevron.left'),node('span','',t('ai.back')));back.onclick=()=>{setupProvider=null;returnedToChooser=true;showSetupIfNeeded(true);};
  const form=node('form','setup-form'),keyField=node('label','setup-field'),key=node('input'),baseField=node('label','setup-field'),base=node('input'),actions=node('div','setup-actions'),submit=node('button','primary',t('ai.saveOpen'));
  key.type='password';key.autocomplete='off';key.required=true;keyField.append(node('span','',t('apiKey')),key);
  base.type='url';base.value=providerInfo[setupProvider].url;baseField.append(node('span','',t('ai.url')),base);
  submit.type='submit';actions.append(submit);form.append(keyField,baseField,actions);
  form.onsubmit=async e=>{e.preventDefault();submit.disabled=true;try{await shell.invoke('connection.save',{provider:setupProvider,apiKey:key.value,baseURL:base.value,model:'',useBearerToken:false,executable:''});key.value='';await activate();}catch(e){error.textContent=e.message;}finally{submit.disabled=false;}};
  inner.append(back,heading(providerInfo[setupProvider].tool,t('ai.configure')),directory,form);
 }else{
  const brand=node('div','setup-brand'),logo=node('img');logo.src='/icons/icon-192.png';logo.alt='';logo.width=logo.height=24;brand.append(logo,node('span','','TheAll'));
  const choices=node('div','provider-options');
  for(const provider of ['claude','openai']){
   const info=providerInfo[provider],card=node('div','provider-card'+(setupProvider===provider?' active':'')),main=node('button','provider-main'),copy=node('span','provider-copy'),settings=node('button','provider-settings');
   copy.append(node('strong','',info.title),node('small','',info.tool));main.type='button';main.append(icon(info.icon,'icon provider-icon'),copy,icon('arrow.right','icon provider-arrow'));
   settings.type='button';settings.title=t('ai.settings');settings.setAttribute('aria-label',`${info.tool} · ${settings.title}`);settings.append(icon('slider.horizontal.3'));settings.onclick=()=>shell.openSettings('agents');
   main.onclick=async()=>{setupProvider=provider;returnedToChooser=false;if(shell.settings.connections?.[provider]?.configured){main.disabled=true;try{await activate();}catch(e){error.textContent=e.message;main.disabled=false;}}else showSetupIfNeeded(true);};
   card.append(main,settings);choices.append(card);
  }
  const note=node('p','setup-note');note.append(icon('lock.shield'),node('span','',t('storageNote')));
  inner.append(brand,directory,heading(t('ai.choose.title'),t('ai.choose.detail')),choices,note);
 }
 inner.append(error);section.append(inner);document.body.append(section);
 async function activate(){await shell.invoke('chat.update',{id,provider:setupProvider,directory:setupDirectory,model:shell.settings.connections?.[setupProvider]?.model||''});await chat.refresh();await shell.changed();shell.ensureModels(setupProvider);section.remove();}
}
function atBoundary(key){const input=$('draft'),start=input.selectionStart;if(key==='ArrowUp'){const before=input.value.slice(0,start);return !before.includes('\n')&&visualWidth(before)<=input.clientWidth-24;}const after=input.value.slice(start);return !after.includes('\n')&&visualWidth(after)<=input.clientWidth-24;}
function visualWidth(text){const canvas=document.createElement('canvas'),context=canvas.getContext('2d'),style=getComputedStyle($('draft'));context.font=`${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;return context.measureText(text).width;}
$('draft').addEventListener('keydown',event=>{
 if(shell.keyboard(event))return;
 if(['z','y'].includes(event.key.toLowerCase())&&(event.ctrlKey||event.metaKey)){history.reset();return;}
 if(!['ArrowUp','ArrowDown'].includes(event.key))return;
 const input=$('draft'),result=history.step(event.key==='ArrowUp'?-1:1,{text:input.value,start:input.selectionStart,end:input.selectionEnd,history:(chat.selectedChat?.messages||[]).filter(m=>m.role==='user').map(m=>m.text).filter(Boolean),atBoundary:atBoundary(event.key),composing:event.isComposing,modified:event.ctrlKey||event.metaKey||event.shiftKey||event.altKey});
 if(result){event.preventDefault();input.value=result.text;input.setSelectionRange(result.start,result.end);input.dispatchEvent(new Event('input',{bubbles:true}));}
});
document.addEventListener('keydown',event=>{if(event.target!==$('draft'))shell.keyboard(event);});
applySettings();
for(let attempt=0;attempt<100&&!chat.authenticated;attempt++)await new Promise(resolve=>setTimeout(resolve,100));
if(chat.authenticated)await chat.select(id);else throw new Error('The local chat service could not be reached');

// Native composer options also apply to the structured chat input on Windows.
const caret=node('span','native-caret');caret.hidden=true;document.body.append(caret);
let composing=false;
function drawCaret(){
 const input=$('draft'),settings=shell.settings,style=getComputedStyle(input),rect=input.getBoundingClientRect();
 if(document.activeElement!==input||input.selectionStart!==input.selectionEnd||composing||!rect.width){caret.hidden=true;input.style.caretColor=composing?'var(--text)':'transparent';return;}
 input.style.caretColor='transparent';
 const mirror=node('div');Object.assign(mirror.style,{position:'fixed',left:rect.left+'px',top:rect.top+'px',width:rect.width+'px',visibility:'hidden',pointerEvents:'none',whiteSpace:'pre-wrap',overflowWrap:'break-word',boxSizing:'border-box',padding:style.padding,border:style.border,font:style.font,letterSpacing:style.letterSpacing,lineHeight:style.lineHeight});
 mirror.append(document.createTextNode(input.value.slice(0,input.selectionStart)));const marker=node('span','','\u200b');mirror.append(marker,document.createTextNode(input.value.slice(input.selectionStart)||' '));document.body.append(mirror);const position=marker.getBoundingClientRect();mirror.remove();
 const size=parseFloat(style.fontSize),height=parseFloat(style.lineHeight)||size*1.4,type=settings.cursorStyle||'bar';
 const left=position.left-input.scrollLeft,top=position.top-input.scrollTop+(type==='underline'?height-2:0);
 if(left<rect.left+2||left>rect.right-2||top<rect.top+2||top>rect.bottom-2){caret.hidden=true;return;}
 caret.hidden=false;caret.classList.toggle('blink',!!settings.cursorBlink);Object.assign(caret.style,{left:left+'px',top:top+'px',width:(type==='bar'?1:Math.max(7,visualWidth(input.value[input.selectionStart]||'M')))+'px',height:(type==='underline'?2:height)+'px'});
}
for(const event of ['input','keyup','click','select','scroll','focus','blur'])$('draft').addEventListener(event,()=>requestAnimationFrame(drawCaret));
$('draft').addEventListener('compositionstart',()=>{composing=true;drawCaret();});$('draft').addEventListener('compositionend',()=>{composing=false;drawCaret();});
$('draft').addEventListener('keydown',()=>{if(shell.settings.hideMouseWhileTyping)document.body.classList.add('hide-mouse');});
document.addEventListener('pointermove',()=>document.body.classList.remove('hide-mouse'));
document.addEventListener('mouseup',()=>{if(!['true','clipboard'].includes(shell.settings.copyOnSelect))return;const input=$('draft');const value=document.activeElement===input?input.value.slice(input.selectionStart,input.selectionEnd):String(window.getSelection()||'');if(value)shell.invoke('clipboard.writeText',{text:value}).catch(report);});
window.addEventListener('resize',drawCaret);window.addEventListener('theall:settings',drawCaret);
