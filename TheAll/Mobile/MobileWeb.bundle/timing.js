// UTC completion timestamps are displayed in the reader's local time zone.
// Old transcripts have no timing metadata and must never invent a finish time.
export function turnTiming(message, locale) {
  if (message?.role !== 'assistant' || message.isIntermediate ||
      typeof message.completedAt !== 'string' || !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z$/.test(message.completedAt) ||
      typeof message.durationMs !== 'number' || !Number.isFinite(message.durationMs) || message.durationMs < 0) return null;
  const date = new Date(message.completedAt);
  if (!Number.isFinite(date.getTime()) || date.toISOString().slice(0, 19) !== message.completedAt.slice(0, 19)) return null;
  const seconds = Math.round(message.durationMs / 100) / 10;
  const hours = Math.floor(seconds / 3600), minutes = Math.floor((seconds % 3600) / 60);
  const remaining = hours || minutes ? Math.round((seconds % 60) * 10) / 10 : message.durationMs / 1000;
  const unit = (value, name, digits = 0) => new Intl.NumberFormat(locale, {
    style: 'unit', unit: name, unitDisplay: 'short', maximumFractionDigits: digits
  }).format(value);
  const parts = [];
  if (hours) parts.push(unit(hours, 'hour'));
  if (minutes) parts.push(unit(minutes, 'minute'));
  if (remaining || !parts.length) parts.push(unit(remaining, 'second', message.durationMs < 1000 ? 3 : 1));
  return { time: new Intl.DateTimeFormat(locale, { dateStyle: 'short', timeStyle: 'medium' }).format(date),
    duration: parts.join(' '), iso: date.toISOString(), status: ['completed', 'failed', 'interrupted'].includes(message.completionStatus) ? message.completionStatus : message.isError ? 'failed' : 'completed' };
}
