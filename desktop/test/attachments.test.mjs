import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { FileAttachments, FILE_LIMITS, cleanFileName } from '../src/attachments.mjs';
function fixture(t){const root=fs.mkdtempSync(path.join(os.tmpdir(),'theall-files-'));t.after(()=>fs.rmSync(root,{recursive:true,force:true}));return new FileAttachments(root);}
const payload=(name,contents='file contents')=>({name,data:Buffer.from(contents).toString('base64')});
test('private imports preserve exact empty/binary bytes, clean names, and retain only safe extensions',t=>{
 const store=fixture(t),binary=Buffer.from([0,255,128,1]);
 const {files}=store.import([payload('../资料\u202e.PDF',binary),payload('C:\\folder\\x\r\n.txt',''),payload('a.exe /..')]);
 assert.equal(files[0].name,'资料.PDF');assert(store.path(files[0]).endsWith('.pdf'));assert.deepEqual(store.read(files[0]),binary);
 assert.equal(files[1].byteCount,0);assert.deepEqual(store.read(files[1]),Buffer.alloc(0));assert.equal(files[2].name,'File');assert(store.path(files[2]).endsWith('.file'));
 assert.equal(cleanFileName('a\\b/c.txt'),'c.txt');
 assert.throws(()=>store.import([payload('a'.repeat(256))]),/name/);
 if(process.platform!=='win32'){assert.equal(fs.statSync(store.path(files[0])).mode&0o777,0o600);assert.equal(fs.statSync(store.directory).mode&0o777,0o700);}
});
test('selection limits and invalid base64 reject atomically before any files are saved',t=>{
 const store=fixture(t);
 for(const values of [Array.from({length:6},()=>payload('file')), [{name:'f',data:'????'}], [payload('f',Buffer.alloc(FILE_LIMITS.bytes+1))], Array.from({length:3},()=>payload('f',Buffer.alloc(FILE_LIMITS.bytes)))]){
   assert.throws(()=>store.import(values));assert.equal(fs.existsSync(store.directory),false);
 }
});
test('missing, changed, linked files and linked storage cannot be used as CLI inputs',t=>{
 const store=fixture(t),file=store.import([payload('readme.md')]).files[0],name=store.path(file);
 fs.writeFileSync(name,'file contentx');assert.throws(()=>store.prompt('question',[file]),/changed/);
 assert.equal(store.hydrate([file])[0].unavailable,true);assert(!('data' in store.hydrate([file])[0]));
 fs.unlinkSync(name);assert.throws(()=>store.read(file));
 const outside=path.join(path.dirname(store.directory),'outside');fs.writeFileSync(outside,'file contents');
 try{fs.symlinkSync(outside,name);}catch(e){if(process.platform==='win32'&&e.code==='EPERM'){t.diagnostic('Windows symlink fixture needs permission');return;}throw e;}
 assert.throws(()=>store.read(file),/unavailable/);
 fs.unlinkSync(name);fs.rmdirSync(store.directory);fs.mkdirSync(outside+'dir');fs.symlinkSync(outside+'dir',store.directory,process.platform==='win32'?'junction':'dir');
 assert.throws(()=>store.import([payload('f')]),/storage/);
});
test('unchanged saved drafts reuse verified file identities without writing duplicate copies',t=>{
 const store=fixture(t),input=[payload('same.txt')],first=store.import(input);
 const second=store.import(input,first.files);assert.deepEqual(second.files,first.files);assert.deepEqual(second.created,[]);
 assert.equal(fs.readdirSync(store.directory).length,1);
 fs.writeFileSync(store.path(first.files[0]),'changed');const repaired=store.import(input,first.files);assert.notEqual(repaired.files[0].id,first.files[0].id);assert.equal(store.read(repaired.files[0]).toString(),'file contents');
});
