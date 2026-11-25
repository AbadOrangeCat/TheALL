// Short tab names from a conversation's first question.
// Port of the Mac `WorkspaceName.from(prompt:)` (TheAll/Models/Workspace.swift); keep both in sync.

const PUNCTUATION = new Set([...'#*`> -—:：，,。.!！?？"“”‘’']);
const PREFIXES = ['请帮我', '请你', '帮我', '我想要', '我希望', '我想', '我怎么', '请', '你好，', '你好,',
  'Could you please ', 'Can you please ', 'Could you ', 'Can you ', 'Please '];
const CJK = /[㐀-鿿぀-ヿ가-힯]/u;

function trimSet(value, set) {
  const chars = [...value];
  let start = 0, end = chars.length;
  while (start < end && set.has(chars[start])) start++;
  while (end > start && set.has(chars[end - 1])) end--;
  return chars.slice(start, end).join('');
}

/** A short title, or '' when the text has nothing usable. */
export function nameFromPrompt(prompt) {
  if (typeof prompt !== 'string') return '';
  const lines = prompt.split(/\r\n|\r|\n/).map(line => line.trim());
  // Keep a punctuation-only first question usable as a title as well.
  let title = lines.map(line => trimSet(line, PUNCTUATION)).find(Boolean) || lines.find(Boolean);
  if (!title) return '';
  // Strip a request's introductory words, preserving the actual topic.
  for (const prefix of PREFIXES) {
    if (!title.toLowerCase().startsWith(prefix.toLowerCase())) continue;
    const candidate = title.slice(prefix.length).trim();
    if (candidate) title = candidate;
  }
  title = title.split(/\s+/).filter(Boolean).join(' ');
  const boundary = title.search(/[。！？]/u);
  if (boundary > 0) title = title.slice(0, boundary);
  const hasCJK = CJK.test(title), limit = hasCJK ? 24 : 48, chars = [...title];
  if (chars.length > limit) {
    let shortened = chars.slice(0, limit).join('');
    const space = shortened.lastIndexOf(' ');
    if (!hasCJK && space >= 20) shortened = shortened.slice(0, space);
    title = trimSet(shortened, PUNCTUATION) + '…';
  }
  return trimSet(title, PUNCTUATION) || title;
}
