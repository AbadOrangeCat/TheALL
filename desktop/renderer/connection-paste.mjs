// Connection fields recognized in a pasted block: Claude Code settings.json (`env`),
// shell `export` / `set` / PowerShell `$env:` lines, `.env` files, Codex TOML or loose
// "API key: …" notes. Only known names are applied; other environment variables are
// listed so the user can see what was skipped.
// Port of `AIConnectionPaste` in TheAll/AI/AIConnection.swift; keep both in sync.

const names = new Map([
  ['ANTHROPIC_AUTH_TOKEN', { field: 'apiKey', rank: 2, provider: 'claude', bearer: true }],
  ['ANTHROPIC_API_KEY', { field: 'apiKey', rank: 2, provider: 'claude', bearer: false }],
  ['OPENAI_API_KEY', { field: 'apiKey', rank: 2, provider: 'openai' }],
  ['CODEX_API_KEY', { field: 'apiKey', rank: 2, provider: 'openai' }],
  ['ANTHROPIC_BASE_URL', { field: 'baseURL', rank: 2, provider: 'claude' }],
  ['OPENAI_BASE_URL', { field: 'baseURL', rank: 2, provider: 'openai' }],
  ['OPENAI_API_BASE', { field: 'baseURL', rank: 2, provider: 'openai' }],
  ['ANTHROPIC_MODEL', { field: 'model', rank: 2, provider: 'claude' }],
  ['OPENAI_MODEL', { field: 'model', rank: 2, provider: 'openai' }],
  ['CODEX_MODEL', { field: 'model', rank: 2, provider: 'openai' }],
  ['MODEL', { field: 'model', rank: 1 }],
  ...['API_KEY', 'APIKEY', 'X_API_KEY', 'KEY', 'TOKEN', 'AUTH_TOKEN', 'ACCESS_TOKEN', 'BEARER_TOKEN', 'SECRET_KEY'].map(n => [n, { field: 'apiKey', rank: 1 }]),
  ...['BASE_URL', 'BASEURL', 'API_BASE', 'API_BASE_URL', 'API_URL', 'ENDPOINT', 'URL'].map(n => [n, { field: 'baseURL', rank: 1 }]),
]);
const FIELDS = ['apiKey', 'baseURL', 'model'];
const PAIR = /["']?([A-Za-z_][A-Za-z0-9_.-]*)["']?[ \t]*[=:][ \t]*("(?:[^"\\]|\\.)*"|'[^']*'|[^\s,;]+)/g;

const normalized = name => name.toUpperCase().replace(/[^A-Z0-9]+/g, '_').replace(/^_+|_+$/g, '');

function accept(value, field) {
  if (!value || value.length > 4096 || /[\s\x00-\x1f\x7f]/.test(value)) return null;
  if (field === 'apiKey') return value.length >= 8 && !/^[$<]/.test(value) && !/^https?:\/\//i.test(value) ? value : null;
  if (field === 'baseURL') {
    try { const url = new URL(value); return ['http:', 'https:'].includes(url.protocol) && url.hostname ? value : null; } catch { return null; }
  }
  return value.length <= 256 && !/^[$<]/.test(value) ? value : null;
}

function jsonPairs(text) {
  const trimmed = text.trim();
  if (!trimmed.startsWith('{')) return null;
  let root;
  try { root = JSON.parse(trimmed); } catch { return null; }
  const pairs = [];
  const walk = (value, depth) => {
    if (depth >= 8 || !value || typeof value !== 'object') return;
    if (Array.isArray(value)) { value.forEach(item => walk(item, depth + 1)); return; }
    for (const key of Object.keys(value).sort()) {
      const item = value[key];
      if (typeof item === 'string') pairs.push([key, item]);
      else if (typeof item === 'number') pairs.push([key, String(item)]);
      else walk(item, depth + 1);
    }
  };
  walk(root, 0);
  return pairs;
}

// `NAME=value`, `NAME: value`, `"NAME": "value"`, `export NAME=…`, `set NAME=…`,
// `setx NAME value` and `$env:NAME="…"`, even when line breaks became spaces.
function scannedPairs(text) {
  const source = text.replace(/\$env:/gi, '').replace(/\bsetx\s+([A-Za-z_][A-Za-z0-9_]*)\s+/gim, '$1=');
  return [...source.matchAll(PAIR)].map(([, name, raw]) => {
    let value = raw;
    const quote = value[0];
    if (value.length >= 2 && (quote === '"' || quote === "'") && value.at(-1) === quote) {
      value = value.slice(1, -1);
      if (quote === '"') value = value.replace(/\\(["\\/])/g, '$1');
    } else value = value.replace(/^["']+|["']+$/g, '');
    return [name, value];
  });
}

/** `null` unless the text names at least one connection field, so typing or pasting a bare key works as before. */
export function parseConnectionPaste(text) {
  if (typeof text !== 'string' || new TextEncoder().encode(text).length > 64 * 1024) return null;
  const result = {}, ranks = {}, providers = {}, ignored = new Set();
  for (const [rawName, rawValue] of jsonPairs(text) ?? scannedPairs(text)) {
    const name = names.get(normalized(rawName)), value = String(rawValue).trim();
    if (!name) { if (/^[A-Z][A-Z0-9]*(_[A-Z0-9]+)+$/.test(rawName)) ignored.add(rawName); continue; }
    const accepted = (ranks[name.field] || 0) < name.rank ? accept(value, name.field) : null;
    if (!accepted) continue;
    ranks[name.field] = name.rank;
    if (name.provider) providers[name.field] = name.provider; else delete providers[name.field];
    result[name.field] = accepted;
    if (name.field === 'apiKey') { if (name.bearer === undefined) delete result.useBearerToken; else result.useBearerToken = name.bearer; }
  }
  const fields = FIELDS.filter(field => result[field] !== undefined);
  if (!fields.length) return null;
  const provider = providers.apiKey || providers.baseURL || providers.model;
  return { ...result, fields, ...(provider ? { provider } : {}), ignored: [...ignored].sort().slice(0, 6) };
}

/** The "Paste settings" button also accepts a single bare key or URL. */
export function parseClipboardConnection(text) {
  const parsed = parseConnectionPaste(text);
  if (parsed) return parsed;
  const value = typeof text === 'string' ? text.trim() : '';
  const url = accept(value, 'baseURL');
  if (url) return { baseURL: url, fields: ['baseURL'], ignored: [] };
  const key = accept(value, 'apiKey');
  return key ? { apiKey: key, fields: ['apiKey'], ignored: [] } : null;
}

/** What was filled in, what was skipped, and a warning when the names belong to the other provider. `t` resolves the shared `ai.paste.*` strings. */
export function describeConnectionPaste(parsed, provider, t, locale = 'en') {
  const labels = parsed.fields.map(field => field === 'apiKey' ? 'API Key' : t(field === 'baseURL' ? 'ai.paste.field.url' : 'ai.model'));
  if (provider === 'claude' && parsed.useBearerToken === true) labels.push(t('ai.paste.bearer'));
  let list;
  try { list = new Intl.ListFormat(locale, { type: 'conjunction' }).format(labels); } catch { list = labels.join(', '); }
  let summary = t('ai.paste.applied').replace('%@', list);
  if (parsed.ignored.length) summary += ' ' + t('ai.paste.ignored').replace('%@', parsed.ignored.join(', '));
  const tool = { claude: 'Claude Code', openai: 'Codex' }[parsed.provider];
  return { summary, warning: tool && parsed.provider !== provider ? t('ai.paste.otherProvider').replace('%@', tool) : '' };
}
