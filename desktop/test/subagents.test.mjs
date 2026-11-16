import test from 'node:test';
import assert from 'node:assert/strict';
import {SubagentTracker} from '../src/subagents.mjs';
const start=(id,extra={})=>({type:'system',subtype:'task_started',task_id:id,task_type:'local_agent',description:'Review '+id,...extra});
test('Claude tracks real agents only and ignores duplicate/stale completion after resume',()=>{
 const tracker=new SubagentTracker();
 tracker.claude(start('a',{run_id:'01'}),true);tracker.claude(start('b'),true);
 assert.equal(tracker.items.length,2);
 tracker.claude(start('shell',{task_type:'local_bash'}),true);
 tracker.claude(start('ambient',{ambient:true}),true);assert.equal(tracker.items.length,2);
 tracker.claude({type:'system',subtype:'task_notification',task_id:'a',run_id:'01',status:'completed'},true);
 tracker.claude(start('a',{run_id:'01'}),true);assert.equal(tracker.items[0].status,'done');
 tracker.claude(start('a',{run_id:'02'}),true);assert.equal(tracker.items[0].status,'running');
 tracker.claude({type:'system',subtype:'task_notification',task_id:'a',run_id:'01',status:'completed'},true);
 assert.equal(tracker.items[0].status,'running');
 tracker.claude({type:'system',subtype:'task_updated',task_id:'a',run_id:'02',patch:{status:'failed'}},true);
 assert.equal(tracker.items[0].status,'failed');
});
test('confirmed background agents survive parent completion and reconcile idle snapshots',()=>{
 const tracker=new SubagentTracker();tracker.claude(start('foreground'),true);
 tracker.claude(start('background',{is_backgrounded:true,run_id:'01'}),true);
 tracker.finish();assert.deepEqual(tracker.items.map(i=>i.id),['background']);
 tracker.claude({type:'system',subtype:'background_tasks_changed',tasks:[{task_id:'background',run_id:'01',task_type:'local_agent',description:'Background'},{task_id:'new',run_id:'02',task_type:'local_agent',description:'Next'}]},false);
 assert.equal(tracker.items.length,2);
 tracker.claude({type:'system',subtype:'background_tasks_changed',tasks:[]},false);
 assert.equal(tracker.items.filter(i=>i.status==='running').length,0);
 tracker.clear();assert.deepEqual(tracker.items,[]);
});
test('Codex child statuses are separate from tool completion and root/turn scoped',()=>{
 const tracker=new SubagentTracker();
 const event=(id,tool,states,extra={})=>({method:'item/completed',params:{threadId:'root',turnId:'turn',item:{id,type:'collabAgentToolCall',senderThreadId:'root',tool,status:'completed',receiverThreadIds:Object.keys(states),agentsStates:states,...extra}}});
 tracker.codex(event('spawn','spawnAgent',{a:{status:'running'},b:{status:'pendingInit'}}),'root','turn');
 assert.equal(tracker.items.filter(i=>i.status==='running').length,2);
 tracker.codex(event('wait','wait',{a:{status:'completed'},b:{status:'running'}}),'root','turn');
 tracker.codex(event('spawn','spawnAgent',{a:{status:'running'},b:{status:'pendingInit'}}),'root','turn');
 assert.equal(tracker.items[0].status,'done');
 const bad=event('foreign','spawnAgent',{c:{status:'running'}});bad.params.turnId='old';tracker.codex(bad,'root','turn');assert.equal(tracker.items.length,2);
 tracker.codex(event('resume','resumeAgent',{a:{status:'running'}}),'root','turn');assert.equal(tracker.items[0].status,'running');
});
test('Codex background completion uses the originating parent turn while resume rejects the old turn',()=>{
 const tracker=new SubagentTracker();
 const activity=(id,kind,turnId)=>({method:'item/completed',params:{threadId:'root',turnId,item:{id,type:'subAgentActivity',agentThreadId:'child',agentPath:'Research',kind}}});
 tracker.codex(activity('start','started','first'),'root','first');tracker.finish();
 assert.equal(tracker.items[0].status,'running');
 tracker.codex(activity('complete','completed','first'),'root',null);assert.equal(tracker.items[0].status,'done');
 tracker.codex(activity('restart','started','next'),'root','next');
 tracker.codex(activity('late','completed','first'),'root','next');assert.equal(tracker.items[0].status,'running');
});
test('Claude foreground workers promoted to background survive parent completion',()=>{
 const tracker=new SubagentTracker();tracker.claude(start('a'),true);
 tracker.claude({type:'system',subtype:'task_updated',task_id:'a',patch:{is_backgrounded:true}},true);
 tracker.finish();assert.equal(tracker.items[0].status,'running');
});
test('Codex excludes parent and unknown receivers, and duplicate started cannot revive a completed child',()=>{
 const tracker=new SubagentTracker();
 const activity=(method,id,kind)=>({method,params:{threadId:'root',turnId:'turn',item:{id,type:'subAgentActivity',agentThreadId:'child',agentPath:'Tests',kind}}});
 tracker.codex(activity('item/completed','start','started'),'root','turn');
 tracker.codex(activity('item/completed','done','completed'),'root','turn');
 tracker.codex(activity('item/started','start','started'),'root','turn');assert.equal(tracker.items[0].status,'done');
 tracker.codex(activity('item/completed','prototype','constructor'),'root','turn');assert.equal(tracker.items[0].status,'done');
 tracker.codex({method:'item/completed',params:{threadId:'root',turnId:'turn',item:{id:'scope',type:'collabAgentToolCall',senderThreadId:'root',tool:'wait',status:'completed',receiverThreadIds:['child','root'],agentsStates:{child:{status:'completed'},root:{status:'running'},foreign:{status:'running'}}}}},'root','turn');
 assert.equal(tracker.items.length,1);
});

test('agent descriptions redact complete secrets before bounding display length',()=>{
 const secret='subagent-fixture-secret-value';
 const tracker=new SubagentTracker(value=>value.replaceAll(secret,'[redacted]'));
 tracker.claude(start('a',{description:'a'.repeat(490)+secret}),true);
 assert.equal(tracker.items[0].title.includes('subagent-'),false);
 assert.ok(tracker.items[0].title.length<=500);
});
