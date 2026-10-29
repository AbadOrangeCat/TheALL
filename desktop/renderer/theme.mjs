import { themes } from './themes.mjs';
const mix=(a,b,f)=>a.map((v,i)=>v*(1-f)+b[i]*f);
const css=value=>'rgb('+value.map(v=>Math.round(v*255)).join(' ')+')';
const hex=value=>value?.match(/^#[a-f0-9]{6}$/i)?[1,3,5].map(i=>parseInt(value.slice(i,i+2),16)/255):null;
export function themeTokens(mode='system',systemDark=true){
 const configured=themes[mode]||{};
 const defaultDark=mode==='system'?systemDark:mode!=='light';
 const bg=hex(configured.background)||(defaultDark?[.07,.07,.075]:[.985,.982,.978]);
 const fg=hex(configured.foreground)||(defaultDark?[.92,.92,.93]:[.10,.10,.105]);
 const dark=Math.max(...bg)<.5;
 const accent=hex(configured.palette3||configured.palette11||configured.palette6||configured.palette14)||(dark?[.953,.659,.196]:[.850,.450,.050]);
 return {'--canvas':css(bg),'--surface':css(bg),'--sidebar':css(mix(bg,fg,dark?.04:.05)),'--border':css(mix(bg,fg,.12)),'--border-strong':css(mix(bg,fg,.22)),'--text':css(fg),'--muted':css(mix(fg,bg,.4)),'--tertiary':css(mix(fg,bg,.65)),'--accent':css(accent),'--accent-muted':css(accent).replace(')', ' / 0.1)'),'--danger':css(dark?[.973,.318,.286]:[.827,.184,.184]),'--success':css(dark?[.247,.729,.314]:[.180,.600,.235]),'color-scheme':dark?'dark':'light'};
}
export function applyTheme(document,settings={}){
 const root=document.documentElement;
 for(const [key,value] of Object.entries(themeTokens(settings.theme,matchMedia('(prefers-color-scheme:dark)').matches))){if(key==='color-scheme')root.style.colorScheme=value;else root.style.setProperty(key,value);}
 // Like the Mac chat, the default is the system UI font; the settings page shows the same default.
 const family=String(settings.fontFamily||'Segoe UI').replace(/[;{}"\\]/g,'');
 root.style.setProperty('--chat-font',`"${family}", "Segoe UI Variable Text", "Segoe UI", system-ui, sans-serif`);
 applyEffects(document,settings);
 root.style.setProperty('--chat-size',`${Math.max(6,Math.min(72,Number(settings.fontSize)||13))}px`);
}

export function applyEffects(document,settings={}){
 const root=document.documentElement;
 const values={backgroundOpacity:1,contentOpacity:1,contentShadow:0,paddingX:4,paddingY:4,unfocusedPaneOpacity:.7,backgroundBlur:0};
 for(const[key,fallback]of Object.entries(values)){const value=Number.isFinite(settings[key])?settings[key]:fallback;root.style.setProperty('--'+key.replace(/[A-Z]/g,m=>'-'+m.toLowerCase()),String(value));}
 root.style.setProperty('--chat-weight',settings.fontThicken?'500':'400');
 root.dataset.cursorStyle=settings.cursorStyle||'bar';root.dataset.cursorBlink=String(!!settings.cursorBlink);
}
