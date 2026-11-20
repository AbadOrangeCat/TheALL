// Turn-local counters. Tool inputs, outputs and transcript text never enter the map.
const stations = ['you', 'model', 'memory', 'files', 'shell', 'network', 'browser', 'agents', 'skills', 'hooks'];

function mcpStation(server, tool) {
  if (server === 'memory') return 'memory';
  if (['Claude_Browser', 'claude-in-chrome', 'playwright', 'browser', 'chrome-devtools'].includes(server) ||
      (server === 'remote-devices' && tool?.startsWith('Claude_Browser__'))) return 'browser';
  if (server === 'plugin-authoring') return 'skills';
  if (server === 'terminal') return 'shell';
  return 'network';
}

function fileStation(path) {
  const normalized = typeof path === 'string' ? path.replaceAll('\\', '/') : '';
  return /\/\.claude\/projects\/[^/]+\/memory\/|\/\.codex\/memories\//.test(normalized) ? 'memory' : 'files';
}

function claudeStation(name, input) {
  if (!name || name === 'Agent' || name === 'Task') return;
  switch (name) {
    case 'Read': case 'Write': case 'Edit': case 'MultiEdit': case 'NotebookEdit':
    case 'Glob': case 'Grep': case 'LS': case 'LSP':
      return fileStation(input?.file_path ?? input?.notebook_path ?? input?.path);
    case 'AskUserQuestion': case 'SendUserFile': case 'TaskCreate': case 'TaskUpdate':
    case 'TaskList': case 'TaskGet': case 'TodoWrite': case 'EnterPlanMode': case 'ExitPlanMode': return 'you';
    case 'Skill': case 'ToolSearch': case 'ListSkills': case 'SearchSkills': case 'SuggestSkills':
    case 'ListPlugins': case 'SearchPlugins': case 'SuggestPluginInstall':
    case 'ListConnectors': case 'SearchMcpRegistry': case 'SuggestConnectors': case 'WaitForMcpServers': return 'skills';
    case 'WebFetch': case 'WebSearch': case 'Artifact': return 'network';
    case 'ListMcpResourcesTool': case 'ReadMcpResourceTool': case 'ReadMcpResourceDirTool':
      return mcpStation(input?.server);
    default: {
      const mcp = /^mcp__(.+?)__(.+)$/.exec(name);
      return mcp ? mcpStation(mcp[1], mcp[2]) : 'shell';
    }
  }
}

function codexStation(item) {
  switch (item.type) {
    case 'commandExecution': {
      const actions = item.commandActions;
      if (actions?.length && actions.every(a => ['read', 'listFiles', 'search'].includes(a.type))) {
        return actions.every(a => fileStation(a.path) === 'memory') ? 'memory' : 'files';
      }
      return 'shell';
    }
    case 'fileChange': case 'imageView': return fileStation(item.path ?? item.changes?.[0]?.path);
    case 'webSearch': return 'network';
    case 'mcpToolCall': return mcpStation(item.server, item.tool);
    case 'dynamicToolCall': return claudeStation(item.tool, item.arguments);
    case 'plan': case 'enteredReviewMode': case 'exitedReviewMode': return 'you';
    case 'contextCompaction': return 'model';
    default: return;
  }
}

export class ActivityMap {
  constructor() { this.clear(); }

  clear() {
    this.running = new Map();
    this.finished = new Set();
    this.rows = new Map(stations.map(station => [station, { station, active: 0, completed: 0, failed: 0 }]));
  }

  start(id, station) {
    if (!station || typeof id !== 'string' || !id || id.length > 256 ||
        this.finished.has(id)) return;
    const previous = this.running.get(id);
    if (previous === station || (!previous && this.running.size >= 1024)) return;
    if (previous) this.rows.get(previous).active--;
    this.running.set(id, station);
    this.rows.get(station).active++;
  }

  finish(id, failed) {
    const station = this.running.get(id);
    if (!station) return;
    this.running.delete(id);
    this.finished.add(id);
    if (this.finished.size > 4096) this.finished.delete(this.finished.values().next().value);
    const row = this.rows.get(station);
    row.active--;
    if (failed) row.failed++; else row.completed++;
  }

  claude(message) {
    if (message.parent_tool_use_id != null || message.ambient === true) return;
    if (message.type === 'system' && typeof message.hook_id === 'string') {
      this.hook(message.hook_id, message.subtype, message.outcome);
      return;
    }
    const body = message.message?.content;
    if (message.type === 'stream_event' && message.event?.type === 'content_block_start') {
      const block = message.event.content_block;
      if (block?.type === 'tool_use') this.start(block.id, claudeStation(block.name, block.input));
    } else if (Array.isArray(body) && (message.type === 'assistant' || message.type === 'user')) {
      for (const block of body) {
        if (message.type === 'assistant' && block?.type === 'tool_use') this.start(block.id, claudeStation(block.name, block.input));
        if (message.type === 'user' && block?.type === 'tool_result') this.finish(block.tool_use_id, block.is_error === true);
      }
    }
  }

  hook(id, phase, outcome) {
    if (typeof id !== 'string' || !id) return;
    if (!['hook_started','hook_response','hook/started','hook/completed'].includes(phase)) return;
    const key = 'hook:' + id;
    this.start(key, 'hooks');
    if (phase === 'hook_response' || phase === 'hook/completed') {
      this.finish(key, ['error', 'failed', 'blocked', 'stopped', 'cancelled'].includes(outcome));
    }
  }

  submitted() { this.rows.get('you').completed++; }

  codex(method, item) {
    const station = codexStation(item);
    if (!station) return;
    // Some servers send only the completed item. Replayed starts/completions are idempotent.
    this.start(item.id, station);
    if (method === 'item/completed') {
      this.finish(item.id, item.status === 'failed' || item.status === 'declined' || item.status === 'cancelled' ||
        (item.exitCode != null && item.exitCode !== 0) || item.success === false || !!item.error || item.result?.isError === true);
    }
  }

  snapshot(busy, agents) {
    const workers = { station: 'agents', active: 0, completed: 0, failed: 0 };
    for (const agent of agents) {
      if (agent.status === 'running') workers.active++;
      else if (agent.status === 'done') workers.completed++;
      else if (agent.status === 'failed' || agent.status === 'stopped') workers.failed++;
    }
    if (!busy) return workers.active ? [workers] : [];
    const rows = [...this.rows.values()].map(row => row.station === 'agents' ? workers : { ...row });
    if (!this.running.size && !workers.active) rows.find(row => row.station === 'model').active = 1;
    return rows.filter(row => row.active || row.completed || row.failed);
  }
}
