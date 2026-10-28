// Only advertise options supplied by the selected model's capability metadata.
export function reasoningOptions(chat, selectedModel) {
  const models = chat?.models || [];
  const model = models.find(item => item.id === selectedModel) ||
    (!selectedModel && chat?.defaultModel ? models.find(item => item.id === chat.defaultModel) : undefined);
  return Array.isArray(model?.reasoningEfforts)
    ? [...new Set(model.reasoningEfforts.filter(value => typeof value === 'string' && /^[a-z][a-z0-9_-]{0,31}$/.test(value)))] : [];
}
export function selectedReasoningEffort(chat, model, draft) {
  const value = draft === undefined ? chat?.reasoningEffort || '' : draft;
  return reasoningOptions(chat, model).includes(value) ? value : '';
}
