import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const source = await readFile(new URL('../TheAll/Mobile/MobileWeb.bundle/markdown.js', import.meta.url), 'utf8');
const { parseMarkdown, splitTableRow, safeMarkdownLink, safeMarkdownImage } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);

test('comparison table retains cells, emphasis and alignment across blank-separated rows', () => {
  const blocks = parseMarkdown('## 耗时和调用次数\n\n| 场景 | Titan 调用（旧 → 新） | 耗时 |\n\n|---|---:|:---:|\n\n| S1 建 KB | 49,191 → 13,864（**−71.8%**） | 52.2 → 12.9 分钟 |\n\n| **合计** | **74,087 → 17,113** | |\n\n后续正文');
  assert.equal(blocks[0].type, 'heading');
  assert.equal(blocks[1].type, 'table');
  assert.deepEqual(blocks[1].alignments, ['left', 'right', 'center']);
  assert.deepEqual(blocks[1].rows[1], ['**合计**', '**74,087 → 17,113**', '']);
  assert.equal(blocks[2].text, '后续正文');
});
test('table parser respects escaped pipes and code pipes, pads missing cells without losing extra data', () => {
  assert.deepEqual(splitTableRow('| a\\|b | `a|b` |'), ['a\\|b', '`a|b`']);
  assert.deepEqual(parseMarkdown('| A | B |\n|---|---|\n| one |')[0].rows, [['one', '']]);
  const blocks = parseMarkdown('| A | B |\n|---|---|\n| one | two | three |');
  assert.equal(blocks[1].text, '| one | two | three |');
});
test('incomplete fenced code preserves exact indentation, blank lines and special text', () => {
  const content = '  <script>x()</script>\n\n\tprint("| **data** |")\n';
  assert.deepEqual(parseMarkdown('```python\n' + content)[0], {type:'code', language:'python', text:content});
  assert.deepEqual(parseMarkdown('~~~sh\necho "```"\n~~~\nafter'), [{type:'code', language:'sh', text:'echo "```"\n'}, {type:'paragraph', text:'after'}]);
});
test('literal escapes, ordinary pipe text and malformed tables remain readable', () => {
  for (const text of ['echo a | head', '\\| A | B |\n\\|---|---|', '| A | B |\n|---|no|', '\\## Literal']) {
    assert.ok(parseMarkdown(text).every(block => block.type === 'paragraph'));
  }
});
test('link validation rejects scripts, credentials, controls and unsafe schemes', () => {
  for (const url of ['javascript:alert(1)', 'data:text/html,<script>x</script>', 'file:///private/a', '//example.com', 'https://user:pass@example.com', 'https://exa\nmple.com']) assert.equal(safeMarkdownLink(url), null);
  assert.equal(safeMarkdownLink('https://example.com/a?q=x#b'), 'https://example.com/a?q=x#b');
});
test('image embedding is limited to raster data and authorized current-chat photo paths', () => {
  const photo = '/api/chats/c/images/00000000-0000-4000-8000-000000000001';
  assert.equal(safeMarkdownImage(photo, 'c'), photo);
  assert.equal(safeMarkdownImage(photo, 'd'), null);
  for (const url of ['https://example.com/a.png', 'file:///tmp/a.png', '/api/session', photo + '?private=1', 'data:image/svg+xml;base64,AAAA']) assert.equal(safeMarkdownImage(url, 'c'), null);
  assert.equal(safeMarkdownImage('data:image/png;base64,AAAA', 'c'), 'data:image/png;base64,AAAA');
});

test('adjacent blank-separated tables stay separate and indented pipe text is not a table', () => {
  const source = '| First | Value |\n|---|---|\n| A | 1 |\n\n| Second | Cost |\n|---|---:|\n| B | 2 |';
  const blocks = parseMarkdown(source + '\n\n');
  assert.equal(blocks.length, 2);
  assert.deepEqual(blocks.map(block => block.headers[0]), ['First', 'Second']);
  assert.deepEqual(blocks.map(block => block.rows), [[['A', '1']], [['B', '2']]]);
  for (const indent of ['    ', '\t']) {
    assert.equal(splitTableRow(indent + '| A | B |'), null);
    assert.ok(parseMarkdown(indent + '| A | B |\n' + indent + '|---|---|').every(block => block.type !== 'table'));
  }
});
