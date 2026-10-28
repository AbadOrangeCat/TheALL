import { providers } from './store.mjs';

export function validateConnection(provider, input) {
  if (!providers.has(provider)) throw new Error('Unknown AI provider');
  const apiKey = String(input.apiKey ?? '').trim();
  if (!apiKey || apiKey.length > 16384 || /[\x00-\x1f\x7f]/.test(apiKey)) throw new Error('Enter a valid API key');
  const raw = String(input.baseURL || (provider === 'claude' ? 'https://api.anthropic.com' : 'https://api.openai.com/v1')).trim();
  const url = new URL(raw);
  if (url.username || url.password || url.search || url.hash || /\s/.test(raw)
      || (url.protocol !== 'https:' && !(url.protocol === 'http:' && ['localhost','127.0.0.1','[::1]'].includes(url.hostname)))) {
    throw new Error('Base URL must use HTTPS (HTTP is allowed only for localhost)');
  }
  const model = String(input.model || '').trim(), executable = String(input.executable || '').trim();
  if (model.length > 256 || executable.length > 4096 || /[\x00-\x1f\x7f]/.test(model + executable)) throw new Error('Invalid model or CLI path');
  return { apiKey, baseURL: url.href.replace(/\/+$/, ''), model, executable, useBearerToken: input.useBearerToken === true };
}

export async function fetchModels(provider, connection, fetcher = fetch) {
  const base = connection.baseURL.replace(/\/+$/, '');
  let url = new URL(provider === 'claude' && !base.endsWith('/v1') ? `${base}/v1/models` : `${base}/models`);
  const origin = url.origin, models = [], seen = new Set();
  const headers = provider === 'claude' ? { 'anthropic-version': '2023-06-01', ...(connection.useBearerToken
    ? { authorization: `Bearer ${connection.apiKey}` } : { 'x-api-key': connection.apiKey }) } : { authorization: `Bearer ${connection.apiKey}` };
  for (let page = 0; page < 20; page++) {
    const response = await fetcher(url, { headers, redirect: 'error', signal: AbortSignal.timeout(10000) });
    if (!response.ok) throw new Error(`Model listing failed (HTTP ${response.status})`);
    const reader = response.body.getReader(); let total = 0; const chunks = [];
    try {
      while (true) { const { done, value } = await reader.read(); if (done) break; total += value.length;
        if (total > 2 * 1024 * 1024) throw new Error('Model response is too large'); chunks.push(value); }
    } finally { await reader.cancel().catch(() => {}); }
    const payload = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    if (!Array.isArray(payload.data)) throw new Error('Invalid model catalog');
    for (const item of payload.data) if (typeof item.id === 'string' && item.id.length <= 256 && !seen.has(item.id)) {
      seen.add(item.id); models.push({ id: item.id, title: String(item.display_name || item.id).slice(0,256), ...(provider === 'claude' ? apiModelCapabilities(item) : {}) });
    }
    if (provider !== 'claude' || !payload.has_more || typeof payload.last_id !== 'string') break;
    const next = new URL(url); next.searchParams.set('after_id', payload.last_id);
    if (next.href === url.href || next.origin !== origin) break; url = next;
  }
  return models;
}

const EFFORTS = new Set(['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max']);
export function modelCapabilities(item, provider) {
  const values = provider === 'claude' ? (item.supportsEffort === true ? item.supportedEffortLevels : [])
    : item.supportedReasoningEfforts?.map(value => value.reasoningEffort);
  // The CLI owns its supported levels, including newly advertised values.
  // Match the native client's bounded identifier validation instead of
  // silently dropping levels that are newer than this client.
  const reasoningEfforts = [...new Set((Array.isArray(values) ? values : []).filter(value => typeof value === 'string' && /^[a-z]{1,32}$/.test(value)))];
  const defaultReasoningEffort = item.defaultReasoningEffort;
  const resolvedModel = provider === 'claude' && typeof item.resolvedModel === 'string' && item.resolvedModel.length > 0 && item.resolvedModel.length <= 256 && !/[\x00-\x1f\x7f]/.test(item.resolvedModel) ? item.resolvedModel : undefined;
  return { reasoningEfforts, ...(resolvedModel ? { resolvedModel } : {}), ...(reasoningEfforts.includes(defaultReasoningEffort) ? { defaultReasoningEffort } : {}) };
}
export function apiModelCapabilities(item) {
  const effort = item.capabilities?.effort;
  if (!effort || typeof effort.supported !== 'boolean') return {};
  return { reasoningEfforts: effort.supported ? [...EFFORTS].filter(level => effort[level]?.supported === true) : [] };
}
export function mergeModelCatalog(apiModels = [], cliModels = []) {
  const byID = new Map(cliModels.map(model => [model.id, model]));
  for (const resolved of new Set(cliModels.map(model => model.resolvedModel).filter(Boolean))) {
    if (byID.has(resolved)) continue;
    const matching = cliModels.filter(model => model.resolvedModel === resolved);
    const reasoningEfforts = (matching[0]?.reasoningEfforts || []).filter(level => matching.every(model => model.reasoningEfforts?.includes(level)));
    byID.set(resolved, { id: resolved, title: resolved, resolvedModel: resolved, reasoningEfforts });
  }
  return [...new Map([...byID.values(), ...apiModels.map(model => {
    const backend = byID.get(model.id);
    return { id: model.id, title: model.title, reasoningEfforts: backend?.reasoningEfforts ?? model.reasoningEfforts ?? [],
      ...(backend?.defaultReasoningEffort ? { defaultReasoningEffort: backend.defaultReasoningEffort } : {}) };
  })].map(model => [model.id, { ...model, reasoningEfforts: model.reasoningEfforts || [] }])).values()];
}
export function selectedReasoningEffort(models, model, value = '', defaultModel) {
  if (typeof value !== 'string' || (value && !(models.find(item => item.id === model) || (!model && models.find(item => item.id === defaultModel)))?.reasoningEfforts?.includes(value))) {
    throw Object.assign(new Error('This model does not support the selected thinking level. Choose Default or a supported level.'), { status: 400 });
  }
  return value;
}
