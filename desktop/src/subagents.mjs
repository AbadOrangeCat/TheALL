// Ephemeral provider-reported workers. Never persist these as restored live work.
const statusMap = Object.assign(Object.create(null), {pendingInit:'running',running:'running',completed:'done',interrupted:'stopped',stopped:'stopped',killed:'stopped',shutdown:'stopped',errored:'failed',failed:'failed',notFound:'failed'});
const str = (value,limit=500) => typeof value==='string' ? value.trim().slice(0,limit) : '';
export class SubagentTracker {
  constructor(redact=String) { this.redact=redact; this.rows=new Map(); this.tools=new Map(); this.seen=new Set(); this.childTurns=new Map(); }
  get items() { return [...this.rows.values()].map(({id,title,detail,status})=>({id,title,detail,status})); }
  clear() { this.rows.clear();this.tools.clear();this.seen.clear();this.childTurns.clear(); }
  finish() { for(const [id,row] of this.rows) if(!row.background || row.status!=='running')this.rows.delete(id);this.tools.clear();this.childTurns.clear(); }
  text(value,limit=500) { return str(this.redact(typeof value==='string' ? value : ''),limit); }
  remember(block) { if(block && ['Agent','Task'].includes(block.name) && str(block.id,128) && this.tools.size<100)this.tools.set(block.id,this.text(block.input?.description)); }
  update(id,values,restart=false) {
    if(!str(id,128) || id.length>128)return;
    const old=this.rows.get(id);
    if(!old && this.rows.size>=100)return;
    if(old && old.status!=='running' && values.status==='running' && !restart)return;
    this.rows.set(id,{id,title:old?.title || id,detail:old?.detail || '',status:old?.status || 'running',...old,...values});
  }
  claude(message,busy) {
    if(message.type==='assistant' && message.parent_tool_use_id==null && busy)for(const block of message.message?.content || [])this.remember(block);
    if(message.type==='stream_event' && message.parent_tool_use_id==null && busy)this.remember(message.event?.content_block);
    if(message.type!=='system' || message.ambient)return;
    if(message.subtype==='background_tasks_changed') {
      if(!Array.isArray(message.tasks) || message.tasks.length>1000)return;
      const live=new Set();
      for(const task of message.tasks) {
        if(!task || task.ambient || !['local_agent','remote_agent'].includes(task.task_type))continue;
        const id=str(task.task_id,128);if(!id)continue;live.add(id);
        const old=this.rows.get(id),run=str(task.run_id,128);
        if(old?.run && run && run<old.run)continue;
        this.update(id,{title:this.text(task.description)||old?.title||id,status:'running',background:true,run:run||old?.run||''},!!run && run!==old?.run);
      }
      for(const [id,row] of this.rows)if(row.background && row.status==='running' && !live.has(id))this.update(id,{status:'stopped'});
      return;
    }
    const id=str(message.task_id,128);if(!id)return;
    const old=this.rows.get(id),run=str(message.run_id,128);
    if(message.subtype==='task_started') {
      if(!busy || (message.task_type && !['local_agent','remote_agent'].includes(message.task_type)))return;
      const tool=str(message.tool_use_id,128);
      if(!['local_agent','remote_agent'].includes(message.task_type) && !this.tools.has(tool))return;
      if(old?.run && run && run<old.run)return;
      this.update(id,{title:this.text(message.description)||this.tools.get(tool)||id,status:'running',run:run||old?.run||'',background:message.is_backgrounded===true||old?.background===true},!!run && run!==old?.run);
      return;
    }
    if(!old || (!busy && !old.background) || (run && old.run && run!==old.run))return;
    if(message.subtype==='task_updated' && message.patch?.is_backgrounded===true)this.update(id,{background:true});
    if(message.subtype==='task_progress') {
      if(old.status==='running')this.update(id,{detail:this.text(message.summary)||this.text(message.last_tool_name)||this.text(message.description)});
    } else if(['task_notification','task_updated'].includes(message.subtype)) {
      const state=message.subtype==='task_updated'?message.patch?.status:message.status;
      const status=statusMap[state];
      if(status && status!=='running')this.update(id,{status,detail:this.text(message.summary)||old.detail});
    }
  }
  codex(message,thread,turn) {
    const p=message.params || {},item=p.item;
    if(this.rows.has(p.threadId) && p.threadId!==thread) {
      if(message.method==='turn/started' && str(p.turn?.id))this.childTurns.set(p.threadId,p.turn.id);
      if(message.method==='turn/completed' && this.childTurns.get(p.threadId)===p.turn?.id) {
        const status=statusMap[p.turn.status];if(status)this.update(p.threadId,{status,detail:this.text(p.turn.error?.message)||this.rows.get(p.threadId).detail});
      }
      return;
    }
    if(p.threadId!==thread || !['item/started','item/completed'].includes(message.method) || !item || !str(item.id,128))return;
    const current=!!turn && p.turnId===turn;
    if(!current && item.type!=='subAgentActivity')return;
    if(!['collabAgentToolCall','subAgentActivity'].includes(item.type))return;
    const key=(item.type==='subAgentActivity'?'activity':message.method)+':'+item.id;if(this.seen.has(key) || this.seen.has('item/completed:'+item.id))return;
    if(this.seen.size>=512)this.seen.delete(this.seen.values().next().value);this.seen.add(key);
    if(item.type==='subAgentActivity') {
      const status=item.kind==='started'?'running':item.kind==='interrupted'?'stopped':item.kind==='completed'?'done':null;
      const old=this.rows.get(item.agentThreadId);
      if(!current && (!old || old.origin!==p.turnId || !['completed','interrupted'].includes(item.kind)))return;
      if(status)this.update(item.agentThreadId,{title:this.text(item.agentPath)||item.agentThreadId,status,background:true,origin:current && item.kind==='started'?p.turnId:old?.origin||p.turnId},item.kind==='started');
      return;
    }
    if(item.senderThreadId!==thread || !item.agentsStates || typeof item.agentsStates!=='object' || Array.isArray(item.agentsStates))return;
    if(!Array.isArray(item.receiverThreadIds) || item.receiverThreadIds.length>100)return;
    const receivers=new Set(item.receiverThreadIds.filter(id=>typeof id==='string' && id!==thread));
    const entries=Object.entries(item.agentsStates).filter(([id])=>receivers.has(id));if(entries.length>100)return;
    const restarting=['resumeAgent','followupTask'].includes(item.tool) && message.method==='item/completed' && item.status==='completed';
    for(const [id,state] of entries) {
      const status=statusMap[state?.status];if(!status)continue;
      this.update(id,{status,background:true,origin:restarting ? p.turnId : this.rows.get(id)?.origin || p.turnId,title:this.rows.get(id)?.title||this.text(item.prompt,160)||id,detail:this.text(state.message)||this.rows.get(id)?.detail||''},restarting);
    }
    if(item.tool==='spawnAgent' && message.method==='item/completed' && item.status==='completed' && Array.isArray(item.receiverThreadIds)) {
      for(const id of item.receiverThreadIds.slice(0,100))if(!this.rows.has(id) && id!==thread)this.update(id,{title:this.text(item.prompt,160)||id,status:'running',background:true,origin:p.turnId});
    }
  }
}
