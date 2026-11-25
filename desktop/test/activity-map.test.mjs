import test from 'node:test';
import assert from 'node:assert/strict';
import { ActivityMap, fileStation, commandStation } from '../src/activity-map.mjs';

// Same cases as TheAllTests/AIActivityStationTests.swift.
test('memory includes TheAll’s own config directories and instruction files', () => {
  for (const path of ['/Users/u/Library/Application Support/com.mux0.app.dev/claude/projects/-Users-u-app/memory/MEMORY.md',
    '/home/u/.claude/projects/p/memory/notes.md', 'C:\\Users\\u\\AppData\\Roaming\\TheAll\\claude\\projects\\p\\memory\\a.md',
    'C:\\Users\\u\\AppData\\Roaming\\TheAll\\codex\\memories\\m.md', '/Users/u/.codex/memories/m.md',
    '/repo/CLAUDE.md', '/repo/CLAUDE.local.md', '/repo/AGENTS.md']) assert.equal(fileStation(path), 'memory', path);
  for (const path of ['/repo/src/memory/cache.swift', '/repo/docs/CLAUDE.md.bak', '/repo/projects/p/memory/x', undefined]) assert.equal(fileStation(path), 'files', String(path));
});

test('shell commands that go online or drive a browser light Network or Browser', () => {
  const cases = [
    ['cd app && git push origin main', 'network'], ['curl -s https://example.test', 'network'],
    ['GH_TOKEN=$(gh auth token) gh pr list', 'network'], ['npm install left-pad', 'network'],
    ['python3 -m pip install requests', 'network'], ['sudo apt-get update', 'network'],
    ['go mod download', 'network'], ['Invoke-WebRequest https://example.test', 'network'],
    ['open https://example.test', 'browser'], ['npx playwright test', 'browser'], ['start https://example.test', 'browser'],
    [`osascript -e 'tell application "Safari" to activate'`, 'browser'],
    ['npm test', 'shell'], ['git status && git diff', 'shell'], ['ls -la', 'shell'], ['open .', 'shell'], ['', 'shell'],
  ];
  for (const [command, station] of cases) assert.equal(commandStation(command), station, command);
  const map = new ActivityMap();
  map.claude({ type: 'stream_event', event: { type: 'content_block_start', content_block: { type: 'tool_use', id: 'fetch', name: 'Bash' } } });
  map.claude({ type: 'assistant', message: { content: [{ type: 'tool_use', id: 'fetch', name: 'Bash', input: { command: 'curl https://example.test' } }] } });
  map.claude({ type: 'assistant', message: { content: [{ type: 'tool_use', id: 'note', name: 'Write', input: { file_path: 'C:\\TheAll\\claude\\projects\\p\\memory\\a.md' } }] } });
  map.codex('item/started', { id: 'page', type: 'commandExecution', command: 'open https://example.test', commandActions: [{ type: 'unknown' }] });
  const rows = Object.fromEntries(map.snapshot(true, []).map(row => [row.station, row.active]));
  assert.deepEqual({ network: rows.network, memory: rows.memory, browser: rows.browser, shell: rows.shell }, { network: 1, memory: 1, browser: 1, shell: undefined });
});

test('browser and memory MCP servers are recognized by name', () => {
  const map = new ActivityMap();
  for (const [id, name] of [['a', 'mcp__puppeteer__navigate'], ['b', 'mcp__MyChrome__open'], ['c', 'mcp__team-memory__recall'], ['d', 'mcp__github__list_issues']]) {
    map.claude({ type: 'assistant', message: { content: [{ type: 'tool_use', id, name, input: {} }] } });
  }
  map.codex('item/started', { id: 'e', type: 'mcpToolCall', server: 'playwright-mcp', tool: 'click' });
  const rows = Object.fromEntries(map.snapshot(true, []).map(row => [row.station, row.active]));
  assert.deepEqual({ browser: rows.browser, memory: rows.memory, network: rows.network }, { browser: 3, memory: 1, network: 1 });
});
