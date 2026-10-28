import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import { adaptApp, adaptLanguage } from '../scripts/prepare-assets.mjs';
import { PromptHistory } from '../renderer/history.mjs';
import { themeTokens } from '../renderer/theme.mjs';
import { externalWebURL, validDesktopURL } from '../renderer/security.mjs';
import { imageDimensions } from '../renderer/image-headers.mjs';
import { themes } from '../renderer/themes.mjs';
const root=new URL('../../',import.meta.url);
test('desktop generated chat accepts native Windows paths and preserves POSIX development paths',async()=>{
 const source=await readFile(new URL('TheAll/Mobile/MobileWeb.bundle/app.js',root),'utf8');const adapted=adaptApp(source);
 const line=adapted.split('\n').find(v=>v.startsWith('const absoluteFolder ='));
 const accepts=vm.runInNewContext(line+'; absoluteFolder');
 for(const value of ['C:\\Users\\Casey\\Projects','D:/work space/中文','\\\\server\\share\\folder','/tmp/project'])assert.equal(accepts(value),true,value);
 for(const value of ['C:relative','relative\\folder','\\root-relative','~\\work',''])assert.equal(accepts(value),false,value);
 assert.match(adapted,/if \(!desktopHost && secure && 'serviceWorker'/);
 assert.match(adapted,/if \(!\(desktopHost \|\| navigator.onLine\)\)/);
 assert.match(adapted,/if \(desktopHost\) return; live.suspend/);
 assert.doesNotMatch(source,/desktopHost/);
});
test('adapter refuses stale mobile anchors instead of shipping broken integration',async()=>{
 const source=await readFile(new URL('TheAll/Mobile/MobileWeb.bundle/app.js',root),'utf8');
 assert.throws(()=>adaptApp(source.replace("if (!directory.startsWith('/'))",'if (invalidPath)')),/Shared mobile source changed/);
});
test('Windows mobile messages accept native path guidance in every language',async()=>{
 const source=await readFile(new URL('TheAll/Mobile/MobileWeb.bundle/i18n.js',root),'utf8');const adapted=adaptLanguage(source);
 const language=await import('data:text/javascript;base64,'+Buffer.from(adapted).toString('base64'));
 for(const values of Object.values(language.catalog)){assert.match(values.absoluteDirectory,/C:\\Users/);assert.doesNotMatch(values.absoluteDirectory,/starting with|以 \/ 开头/);assert.doesNotMatch(values.welcomeDetail,/Mac/);}
});
test('preload permits only named operations, does not expose ipcRenderer, and propagates payloads',async()=>{
 const calls=[],exposed={};const source=await readFile(new URL('../src/preload.cjs',import.meta.url),'utf8');
 const context={require(name){assert.equal(name,'electron');return{contextBridge:{exposeInMainWorld(name,api){exposed[name]=api;}},ipcRenderer:{invoke(...args){calls.push(args);return Promise.resolve({ok:true});}}};}};
 vm.runInNewContext(source,context);
 await assert.rejects(exposed.theall.invoke('fs.readFile',{path:'secret'}),/Unsupported/);assert.equal(calls.length,0);
 await exposed.theall.invoke('connection.save',{provider:'claude',apiKey:'fake-test-key'});
 await exposed.theall.invoke('pane.split',{terminalId:'test'});
 assert.equal(calls.length,2);assert.equal(calls[0][0],'theall:desktop');assert.equal(calls[0][1],'connection.save');assert.equal(Object.keys(exposed.theall).join(','),'invoke');assert.equal(Object.isFrozen(exposed.theall),true);
});
test('prompt history freezes messages, retains edited recalls and restores original caret/draft',()=>{
 const h=new PromptHistory(),history=['first','second'];
 let state={text:'unsent draft',start:3,end:3,history};
 let result=h.step(-1,state);assert.equal(result.text,'second');history.push('new message from phone');
 result=h.step(-1,{...state,text:'edited second',start:13,end:13});assert.equal(result.text,'first');
 result=h.step(1,{...state,text:'first',start:5,end:5});assert.equal(result.text,'edited second');
 result=h.step(1,{...state,text:'edited second',start:13,end:13});assert.deepEqual(result,{text:'unsent draft',start:3,end:3});assert.equal(h.index,null);
});
test('prompt history leaves selections, modifier keys, IME and inner visual lines alone',()=>{
 const h=new PromptHistory();const input={text:'draft',start:5,end:5,history:['prior']};
 for(const patch of [{end:2},{modified:true},{composing:true},{atBoundary:false}])assert.equal(h.step(-1,{...input,...patch}),null);
 assert.equal(h.step(1,input),null);assert.equal(h.step(-1,{...input,history:[]}),null);
});
test('desktop theme reproduces native AppTheme fallback colors and blend weights',()=>{
 const dark=themeTokens('dark'),light=themeTokens('light');
 assert.equal(dark['--canvas'],'rgb(18 18 19)');assert.equal(dark['--text'],'rgb(235 235 237)');assert.equal(dark['--accent'],'rgb(243 168 50)');assert.equal(dark['--sidebar'],'rgb(27 27 28)');
 assert.equal(light['--canvas'],'rgb(251 250 249)');assert.equal(light['--accent'],'rgb(217 115 13)');assert.deepEqual(themeTokens('system',false),light);
});

test('navigation blocks dangerous shell protocols and non-loopback desktop hosts',()=>{
 for(const value of ['javascript:alert(1)','file:///C:/Windows/system32/cmd.exe','ms-settings:privacy','https://user:password@example.com','not a URL'])assert.equal(externalWebURL(value),false,value);
 assert.equal(externalWebURL('https://github.com/AbadOrangeCat/TheALL'),true);
 for(const value of ['http://127.0.0.1.evil.com/','http://192.168.1.1/','https://127.0.0.1/','http://user@localhost/'])assert.equal(validDesktopURL(value),false,value);
 assert.equal(validDesktopURL('http://127.0.0.1:43210/desktop/index.html'),true);
 assert.equal(validDesktopURL('http://[::1]:43210/'),true);
});

test('photo headers reject decompression bombs and active/vector data before decoding',()=>{
 const png=Buffer.alloc(24);Buffer.from([137,80,78,71,13,10,26,10]).copy(png);png.write('IHDR',12);png.writeUInt32BE(2048,16);png.writeUInt32BE(1024,20);assert.deepEqual(imageDimensions(png),{width:2048,height:1024});
 png.writeUInt32BE(100000,16);assert.throws(()=>imageDimensions(png),/16 megapixels/);
 assert.throws(()=>imageDimensions(Buffer.from('<svg><script>bad()</script></svg>')),/JPEG or PNG/);
 const jpeg=Buffer.from([255,216,255,192,0,8,8,0,100,0,200,1]);assert.deepEqual(imageDimensions(jpeg),{width:200,height:100});
 jpeg.writeUInt16BE(65535,7);jpeg.writeUInt16BE(65535,9);assert.throws(()=>imageDimensions(jpeg),/16 megapixels/);
 assert.throws(()=>imageDimensions(Buffer.from([255,216,255,192,255,255,0,0])),/Invalid JPEG/);
});

test('all bundled Mac themes retain names and derive their actual palette',()=>{
 assert.equal(Object.keys(themes).length,502);const gruv=themeTokens('Gruvbox Dark');assert.equal(gruv['--canvas'],'rgb(40 40 40)');assert.equal(gruv['--text'],'rgb(235 219 178)');assert.equal(gruv['--accent'],'rgb(215 153 33)');
 for(const name of Object.keys(themes))assert.ok(themeTokens(name)['--canvas'].startsWith('rgb('),name);
});
