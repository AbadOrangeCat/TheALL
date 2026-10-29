// Line icons drawn after the SF Symbols used by the macOS app, on a 16px grid.
function gear() {
  const points = [];
  for (let tooth = 0; tooth < 8; tooth++) {
    const angle = tooth * Math.PI / 4;
    for (const [offset, radius] of [[-.25, 4.9], [-.15, 6.6], [.15, 6.6], [.25, 4.9]]) {
      points.push([8 + radius * Math.cos(angle + offset), 8 + radius * Math.sin(angle + offset)].map(v => v.toFixed(2)).join(' '));
    }
  }
  return `<path d="M${points.join('L')}Z"/><circle cx="8" cy="8" r="2"/>`;
}
const star = (x, y, r) => `<path fill="currentColor" stroke="none" d="M${x} ${y - r}C${x + r * .18} ${y - r * .18} ${x + r * .18} ${y - r * .18} ${x + r} ${y}C${x + r * .18} ${y + r * .18} ${x + r * .18} ${y + r * .18} ${x} ${y + r}C${x - r * .18} ${y + r * .18} ${x - r * .18} ${y + r * .18} ${x - r} ${y}C${x - r * .18} ${y - r * .18} ${x - r * .18} ${y - r * .18} ${x} ${y - r}Z"/>`;
const shapes = {
  'sidebar.left': '<rect x="1.75" y="2.75" width="12.5" height="10.5" rx="2.25"/><path d="M6.25 2.75v10.5"/>',
  plus: '<path d="M8 3v10M3 8h10"/>',
  gearshape: gear(),
  'qrcode.viewfinder': '<path d="M1.75 5V3.5a1.75 1.75 0 0 1 1.75-1.75H5M11 1.75h1.5a1.75 1.75 0 0 1 1.75 1.75V5M14.25 11v1.5a1.75 1.75 0 0 1-1.75 1.75H11M5 14.25H3.5a1.75 1.75 0 0 1-1.75-1.75V11"/><path fill="currentColor" stroke="none" d="M4.5 4.5h3v3h-3zM8.5 4.5h3v3h-3zM4.5 8.5h3v3h-3zM8.5 8.5h1.4v1.4H8.5zM10.1 10.1h1.4v1.4h-1.4z"/>',
  terminal: '<rect x="1.75" y="2.75" width="12.5" height="10.5" rx="2.25"/><path d="m4.75 6.25 2 1.75-2 1.75M8.5 10H11"/>',
  'arrow.down.circle': '<circle cx="8" cy="8" r="6.25"/><path d="M8 4.75v6M5.5 8.5 8 11l2.5-2.5"/>',
  sparkle: star(8, 8, 6.5),
  sparkles: star(6.5, 9, 5.25) + star(12.5, 3.75, 2.25),
  command: '<path d="M10 4v8a2 2 0 1 0 2-2H4a2 2 0 1 0 2 2V4a2 2 0 1 0-2 2h8a2 2 0 1 0-2-2"/>',
  'arrow.right': '<path d="M3 8h10M9 4l4 4-4 4"/>',
  'slider.horizontal.3': '<path d="M2 4h6.5M11.5 4H14M2 8h2M7 8h7M2 12h5.5M10.5 12H14"/><circle cx="10" cy="4" r="1.5"/><circle cx="5.5" cy="8" r="1.5"/><circle cx="9" cy="12" r="1.5"/>',
  'lock.shield': '<path d="M8 1.75 13.25 3.6v3.9c0 3.1-2.2 5.65-5.25 6.75-3.05-1.1-5.25-3.65-5.25-6.75V3.6Z"/><rect x="5.9" y="7.6" width="4.2" height="3.15" rx=".7"/><path d="M6.75 7.6v-1a1.25 1.25 0 0 1 2.5 0v1"/>',
  folder: '<path d="M1.75 4.5A1.75 1.75 0 0 1 3.5 2.75h2.6l1.6 1.75h4.8a1.75 1.75 0 0 1 1.75 1.75v5.5a1.75 1.75 0 0 1-1.75 1.75h-9A1.75 1.75 0 0 1 1.75 11.75Z"/>',
  'chevron.left': '<path d="M10 3.5 5.5 8l4.5 4.5"/>',
  paperclip: '<path d="M13.25 7.25 8.4 12.1a3.1 3.1 0 0 1-4.4-4.4l5.05-5.05a2.05 2.05 0 0 1 2.9 2.9L6.9 10.6a1 1 0 0 1-1.42-1.42l4.6-4.6"/>',
  'stop.fill': '<rect x="3.75" y="3.75" width="8.5" height="8.5" rx="1.75" fill="currentColor" stroke="none"/>',
  'arrow.down.to.line': '<path d="M8 2.5v8M4.5 7 8 10.5 11.5 7M3 13.5h10"/>',
  xmark: '<path d="m4 4 8 8M12 4l-8 8"/>',
  'arrow.up': '<path d="M8 13V3M4 7l4-4 4 4"/>'
};

export function iconMarkup(name) {
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">${shapes[name]}</svg>`;
}

export function icon(name, className = 'icon') {
  const span = document.createElement('span');
  span.className = className;
  span.innerHTML = iconMarkup(name);
  return span;
}

// CSS mask for controls whose text the shared chat client rewrites when translating.
export function iconMask(name) {
  return `url("data:image/svg+xml,${encodeURIComponent(iconMarkup(name).replaceAll('currentColor', '#000'))}")`;
}
