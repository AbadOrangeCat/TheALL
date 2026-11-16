import test from 'node:test';
import assert from 'node:assert/strict';
import {subagentState} from '../TheAll/Mobile/MobileWeb.bundle/core.js';
import {t,setLanguage,supportedLanguages} from '../TheAll/Mobile/MobileWeb.bundle/i18n.js';
test('only two or more running child agents expose the strip, including background agents',()=>{
 const a={id:'a',title:'Review',status:'running'},b={id:'b',title:'Tests',status:'running'};
 assert.equal(subagentState({subagents:[a]}).visible,false);
 assert.equal(subagentState({isBusy:false,subagents:[a,b]}).visible,true);
 assert.equal(subagentState({subagents:[a,{...b,status:'done'}]}).visible,false);
 assert.equal(subagentState({subagents:[a,a,null]}).visible,false);
 assert.equal(subagentState({}).visible,false);
});
test('all five locales include subagent status labels',()=>{
 for(const code of Object.keys(supportedLanguages)){setLanguage(code);for(const key of ['subagents','subagentRunning','subagentDone','subagentFailed','subagentStopped'])assert.notEqual(t(key),key);}
});
