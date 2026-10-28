// Electron may expose different WebFrameMain wrappers for the same frame.
// Authorize the underlying live frame and its document, never wrapper identity.
export function isTrustedDesktopSender(event, contents, runtimeURL) {
  try {
    if (!contents || contents.isDestroyed() || !event?.sender || event.sender.isDestroyed()) return false;
    if (!Number.isInteger(contents.id) || contents.id < 1 || event.sender.id !== contents.id) return false;
    const frame = event.senderFrame, main = contents.mainFrame;
    if (!frame || !main || frame.detached || main.detached || frame.parent !== null || main.parent !== null) return false;
    if (!Number.isInteger(frame.processId) || frame.processId < 0 || frame.processId !== main.processId) return false;
    if (typeof frame.frameToken !== 'string' || !frame.frameToken || frame.frameToken !== main.frameToken) return false;
    const target = new URL('/desktop/index.html', runtimeURL);
    if (target.protocol !== 'http:' || !['127.0.0.1', '[::1]', 'localhost'].includes(target.hostname) || target.username || target.password) return false;
    return frame.origin === target.origin && main.origin === target.origin
      && frame.url === target.href && main.url === target.href;
  } catch {
    // Destroyed/detached native wrappers can throw from their property getters.
    return false;
  }
}
