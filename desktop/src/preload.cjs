const { contextBridge, ipcRenderer } = require('electron');
const methods = new Set([
  'app.info', 'clipboard.writeText', 'mobile.exportCertificate', 'settings.get', 'connection.save', 'connection.remove', 'models.list',
  'folder.select', 'chat.update', 'workspace.rename', 'workspace.delete',
  'mobile.enable', 'mobile.disable', 'mobile.pair', 'mobile.devices', 'mobile.revoke',
  'draft.get', 'draft.save', 'workspace.create', 'workspace.select', 'workspace.reorder',
  'tab.create', 'tab.select', 'tab.rename', 'tab.close', 'tab.reorder', 'pane.split', 'pane.close', 'pane.resize',
  'settings.save', 'mobile.relay.status', 'mobile.relay.configure', 'mobile.info', 'mobile.certificate', 'workspace.metadata'
]);
contextBridge.exposeInMainWorld('theall', Object.freeze({
  invoke(method, payload = {}) {
    if (!methods.has(method)) return Promise.reject(new Error('Unsupported desktop operation'));
    return ipcRenderer.invoke('theall:desktop', method, payload);
  }
}));
