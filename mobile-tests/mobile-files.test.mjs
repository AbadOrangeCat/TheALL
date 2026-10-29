import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
const bundle = new URL('../TheAll/Mobile/MobileWeb.bundle/', import.meta.url);
const dataURL = text => `data:text/javascript;base64,${Buffer.from(text).toString('base64')}`;
const source = (await readFile(new URL('files.js', bundle), 'utf8')).replace("'./core.js'", JSON.stringify(dataURL(await readFile(new URL('core.js', bundle), 'utf8'))));
const { FILE_LIMITS, FileError, safeFileName, validateFileSelection, splitAttachments, prepareFile, filePath, fileSize, freezeFileSubmission, removeSubmittedFiles } = await import(dataURL(source));
test('file size boundaries include empty files and bound cumulative selections', () => {
  assert.doesNotThrow(() => validateFileSelection([{size:0},{size:FILE_LIMITS.bytes}], [{byteCount:FILE_LIMITS.bytes}]));
  assert.throws(() => validateFileSelection([{size:FILE_LIMITS.bytes+1}]), /filesTooLarge/);
  assert.throws(() => validateFileSelection([{size:1}], [{byteCount:FILE_LIMITS.totalBytes}]), /filesTotalTooLarge/);
  assert.throws(() => validateFileSelection(Array.from({length:6},()=>({size:0}))), /filesTooMany/);
  for(const size of [NaN,-1,Infinity,1.5])assert.throws(()=>validateFileSelection([{size}]),FileError);
});
test('names are bounded by UTF8 bytes and cannot preserve path/control/bidi characters',()=>{
  assert.equal(safeFileName('C:\\private\\report\u202e\r\n.txt'),'report.txt');
  assert.equal(safeFileName('../.'),'attachment');
  assert(Buffer.byteLength(safeFileName('文'.repeat(100)))<=255);
  assert.equal(safeFileName('résumé.pdf'),'résumé.pdf');
});
test('mixed selection routes raster photos but treats active documents as opaque files',()=>{
  const values=[new File(['pdf'],'report.pdf',{type:'application/pdf'}),new File(['png'],'photo.png'),new File(['svg'],'script.svg',{type:'image/svg+xml'}),new File(['html'],'image.png',{type:'text/html'})];
  const {images,documents}=splitAttachments(values);
  assert.equal(images.length,1);assert.equal(images[0].type,'image/png');assert.deepEqual(documents.map(f=>f.name),['report.pdf','script.svg','image.png']);
});
test('file preparation retains exact bytes including an empty file without preview or script evaluation',async()=>{
  const bytes=Uint8Array.of(0,1,255,128,37,60);
  const file=await prepareFile(new File([bytes],'中文.pdf',{type:'application/pdf'}));
  assert.equal(file.byteCount,bytes.length);assert.deepEqual(Buffer.from(file.data,'base64'),Buffer.from(bytes));assert.equal(file.preview,undefined);assert(Object.isFrozen(file));
  assert.equal((await prepareFile(new File([],'empty.txt'))).data,'');
  await assert.rejects(prepareFile({size:1,arrayBuffer:async()=>new ArrayBuffer(2)}),/filesUnavailable/);
});
test('immutable file submissions retain retry bytes and success only removes submitted IDs',()=>{
  const first={id:'one',name:'a.txt',data:'YQ==',byteCount:1},wire=freezeFileSubmission([first]);first.data='changed';
  assert.deepEqual(wire,[{name:'a.txt',data:'YQ=='}]);assert.throws(()=>{wire[0].data='x';},TypeError);
  const second={id:'two',name:'b.txt',data:''};assert.deepEqual(removeSubmittedFiles([first,second],['one']),[second]);
  assert.throws(()=>freezeFileSubmission([{name:'lost',unavailable:true}]),/filesUnavailable/);
});
test('download addresses remain on authenticated chat routes, with no inline active-content URLs',()=>{
  const id='12345678-1234-1234-1234-123456789012';assert.equal(filePath('chat',id),`/api/chats/chat/files/${id}`);
  for(const value of ['../../private','data:text/html,test','javascript:alert(1)',id+'?key=x'])assert.equal(filePath('chat',value),null);
  assert.equal(fileSize(0),'0 B');assert.equal(fileSize(1024),'1 KB');assert.equal(fileSize(-1),'');
});
test('max file, photo and text payload fits both JSON HTTP and base64 relay envelope',()=>{
  const files=Array.from({length:2},()=>({name:'x'.repeat(255),data:Buffer.alloc(FILE_LIMITS.bytes).toString('base64')}));
  const images=Array.from({length:4},()=>({name:'photo.jpg',data:Buffer.alloc(512*1024).toString('base64')}));
  const body=JSON.stringify({files,images,text:'x'.repeat(128*1024),bootID:'b'.repeat(36),requestID:'r'.repeat(36)});
  assert(Buffer.byteLength(body)<32*1024*1024);assert(Buffer.byteLength(Buffer.from(body).toString('base64'))<48*1024*1024);
});
test('file download data is never cached by the service worker',async()=>{
  const handlers=new Map();vm.runInNewContext(await readFile(new URL('sw.js',bundle),'utf8'),{self:{location:{origin:'https://mac.example'},addEventListener:(name,fn)=>handlers.set(name,fn)},URL,fetch:async()=>({ok:false}),caches:{match:async()=>({})}});
  let cached=false,module=false;handlers.get('fetch')({request:{method:'GET',url:'https://mac.example/api/chats/chat/files/12345678-1234-1234-1234-123456789012'},respondWith(){cached=true;}});
  handlers.get('fetch')({request:{method:'GET',url:'https://mac.example/files.js'},respondWith(){module=true;}});assert.equal(cached,false);assert.equal(module,true);
});
test('all attachment controls and failures are available in five languages',async()=>{
  const {catalog}=await import(dataURL(await readFile(new URL('i18n.js',bundle),'utf8')));
  for(const code of ['en','zh-Hans','fr','ja','ko'])for(const key of ['filesAdd','filesRemove','filesDownload','filesPreparing','filesTooMany','filesTooLarge','filesTotalTooLarge','filesUnavailable','filesMissing','filesDrop','filesFolders'])assert(catalog[code][key],code+'.'+key);
});
