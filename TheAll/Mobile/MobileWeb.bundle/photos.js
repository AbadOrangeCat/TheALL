// Photos remain in memory until the user sends them. The Mac validates and
// stores a separate copy; these browser limits also bound relay request size.
export const PHOTO_LIMITS = Object.freeze({ count: 4, inputBytes: 20 * 1024 * 1024,
  bytes: 512 * 1024, dimension: 2048, pixels: 100_000_000 });
export class PhotoError extends Error {
  constructor(key) { super(key); this.key = key; }
}
export function validatePhotoSelection(files, existingCount = 0) {
  if (existingCount + files.length > PHOTO_LIMITS.count) throw new PhotoError('photosTooMany');
  for (const file of files) {
    if (!file.size || file.size > PHOTO_LIMITS.inputBytes) throw new PhotoError('photosTooLarge');
    // Do not rasterize active/vector documents, even with a misleading suffix.
    if (!/^image\/(?:jpeg|png|webp|gif|heic|heif|avif|bmp|tiff)$/i.test(file.type || '')) throw new PhotoError('photosInvalid');
  }
}
export function imagePath(chatID, imageID) {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(imageID)) return null;
  return `/api/chats/${encodeURIComponent(chatID)}/images/${imageID}`;
}
export function freezePhotoSubmission(images) {
  return Object.freeze(images.map(({ name, data }) => Object.freeze({ name, data })));
}
export function removeSubmittedPhotos(current, submittedIDs) {
  const sent = new Set(submittedIDs);
  return current.filter(image => !sent.has(image.id));
}
function readFile(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(new PhotoError('photosInvalid'));
    reader.onabort = () => reject(new PhotoError('photosInvalid'));
    reader.onload = () => resolve(reader.result);
    reader.readAsDataURL(file);
  });
}
function loadImage(source) {
  return new Promise((resolve, reject) => {
    const image = new Image();
    const timer = setTimeout(() => { image.src = ''; reject(new PhotoError('photosInvalid')); }, 20000);
    image.onload = () => { clearTimeout(timer); resolve(image); };
    image.onerror = () => { clearTimeout(timer); reject(new PhotoError('photosInvalid')); };
    image.src = source;
  });
}
export async function preparePhoto(file) {
  validatePhotoSelection([file]);
  const image = await loadImage(await readFile(file));
  const canvas = document.createElement('canvas');
  try {
    if (!image.naturalWidth || !image.naturalHeight || image.naturalWidth * image.naturalHeight > PHOTO_LIMITS.pixels) {
      throw new PhotoError('photosTooLarge');
    }
    const scale = Math.min(1, PHOTO_LIMITS.dimension / Math.max(image.naturalWidth, image.naturalHeight));
    let width = Math.max(1, Math.round(image.naturalWidth * scale));
    let height = Math.max(1, Math.round(image.naturalHeight * scale));
    for (let resize = 0; resize < 7; resize++) {
      canvas.width = width; canvas.height = height;
      const context = canvas.getContext('2d');
      if (!context) throw new PhotoError('photosInvalid');
      context.fillStyle = '#ffffff'; context.fillRect(0, 0, width, height);
      context.drawImage(image, 0, 0, width, height);
      for (const quality of [0.86, 0.72, 0.56, 0.4, 0.25]) {
        const preview = canvas.toDataURL('image/jpeg', quality);
        if (!preview.startsWith('data:image/jpeg;base64,')) throw new PhotoError('photosInvalid');
        const data = preview.slice('data:image/jpeg;base64,'.length);
        const bytes = data.length * 3 / 4 - (data.endsWith('==') ? 2 : data.endsWith('=') ? 1 : 0);
        if (bytes <= PHOTO_LIMITS.bytes) {
          const stem = String(file.name || 'photo').split(/[\\/]/).pop().replace(/\.[^.]*$/, '').replace(/[\x00-\x1f\x7f]/g, '');
          return Object.freeze({ id: crypto.randomUUID(), name: `${Array.from(stem || 'photo').slice(0, 50).join('')}.jpg`, data, preview });
        }
      }
      width = Math.max(1, Math.round(width * 0.75)); height = Math.max(1, Math.round(height * 0.75));
    }
    throw new PhotoError('photosTooLarge');
  } finally { image.src = ''; canvas.width = 1; canvas.height = 1; }
}
