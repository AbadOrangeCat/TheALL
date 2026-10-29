import { randomUUID } from './core.js';

export const FILE_LIMITS = Object.freeze({ count: 5, bytes: 10 * 1024 * 1024, totalBytes: 20 * 1024 * 1024 });
export class FileError extends Error { constructor(key) { super(key); this.key = key; } }
export function safeFileName(value) {
  const clean = String(value || '').split(/[\\/]/).pop().replace(/[\x00-\x1f\x7f-\x9f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, '').trim();
  let result = '';
  for (const character of clean) { if (new TextEncoder().encode(result + character).length > 255) break; result += character; }
  return result && result !== '.' && result !== '..' ? result : 'attachment';
}
export function validateFileSelection(files, existing = []) {
  if (files.length + existing.length > FILE_LIMITS.count) throw new FileError('filesTooMany');
  let total = existing.reduce((sum, file) => sum + file.byteCount, 0);
  for (const file of files) {
    if (!Number.isSafeInteger(file.size) || file.size < 0 || file.size > FILE_LIMITS.bytes) throw new FileError('filesTooLarge');
    total += file.size;
  }
  if (!Number.isSafeInteger(total) || total > FILE_LIMITS.totalBytes) throw new FileError('filesTotalTooLarge');
}
export function splitAttachments(files) {
  const images = [], documents = [];
  for (let file of files) {
    if (!file.type && typeof File === 'function' && file instanceof File) {
      const suffix = file.name.split('.').pop().toLowerCase(), type = { jpg:'jpeg', jpeg:'jpeg', png:'png', webp:'webp', gif:'gif', heic:'heic', heif:'heif', avif:'avif', bmp:'bmp', tif:'tiff', tiff:'tiff' }[suffix];
      if (type) file = new File([file], file.name, { type:'image/' + type });
    }
    (/^image\/(?:jpeg|png|webp|gif|heic|heif|avif|bmp|tiff)$/i.test(file.type || '') ? images : documents).push(file);
  }
  return { images, documents };
}
export async function prepareFile(file) {
  validateFileSelection([file]);
  let buffer;
  try { buffer = await file.arrayBuffer(); } catch { throw new FileError('filesUnavailable'); }
  if (buffer.byteLength !== file.size || buffer.byteLength > FILE_LIMITS.bytes) throw new FileError('filesUnavailable');
  const bytes = new Uint8Array(buffer); let binary = '';
  for (let i = 0; i < bytes.length; i += 32768) binary += String.fromCharCode(...bytes.subarray(i, i + 32768));
  return Object.freeze({ id: randomUUID(), name: safeFileName(file.name), data: btoa(binary), byteCount: bytes.length });
}
export const freezeFileSubmission = files => Object.freeze(files.map(({name, data, unavailable}) => { if (unavailable || typeof data !== 'string') throw new FileError('filesUnavailable'); return Object.freeze({name, data}); }));
export function removeSubmittedFiles(current, ids) { const submitted = new Set(ids); return current.filter(file => !submitted.has(file.id)); }
export function filePath(chatID, fileID) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(fileID)
    ? `/api/chats/${encodeURIComponent(chatID)}/files/${fileID}` : null;
}
export function fileSize(bytes, locale = 'en') {
  if (!Number.isSafeInteger(bytes) || bytes < 0) return '';
  const unit = bytes < 1024 ? 'B' : bytes < 1024 * 1024 ? 'KB' : 'MB';
  return `${new Intl.NumberFormat(locale, { maximumFractionDigits: 1 }).format(bytes / (unit === 'B' ? 1 : unit === 'KB' ? 1024 : 1024 * 1024))} ${unit}`;
}
