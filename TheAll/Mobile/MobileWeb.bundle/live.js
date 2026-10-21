// Notifications contain no transcript or credentials. All snapshots still use authenticated HTTP.
export class LiveUpdates {
  constructor({ url, onHello, onChanged, onState, onRevoked, socket = url => new WebSocket(url),
    setTimer = (fn, ms) => setTimeout(fn, ms), clearTimer = id => clearTimeout(id) }) {
    Object.assign(this, { url, onHello, onChanged, onState, onRevoked, socket, setTimer, clearTimer });
    this.generation = 0; this.delay = 500; this.active = false; this.ready = false;
    this.timers = new Set(); this.ws = null;
  }
  later(callback, delay) {
    const timer = this.setTimer(() => { this.timers.delete(timer); callback(); }, delay);
    this.timers.add(timer); return timer;
  }
  clear(timer) { this.clearTimer(timer); this.timers.delete(timer); }
  start() { if (this.active) return; this.active = true; this.connect(); }
  resume() {
    if (!this.active) return;
    this.disconnect(); this.connect();
  }
  suspend() { this.disconnect(); }
  stop() { this.active = false; this.disconnect(); }
  disconnect() {
    this.generation++;
    for (const timer of this.timers) this.clearTimer(timer);
    this.timers.clear(); this.changeTimer = null;
    const ws = this.ws; this.ws = null;
    if (ws) { ws.onopen = ws.onmessage = ws.onerror = ws.onclose = null; ws.close(); }
    if (this.ready) { this.ready = false; this.onState(false); }
  }
  connect() {
    if (!this.active) return;
    const generation = ++this.generation;
    const current = () => this.active && generation === this.generation;
    let ws;
    const failed = () => {
      if (!current()) return;
      this.disconnect(); this.onState(false);
      const delay = this.delay; this.delay = Math.min(10000, this.delay * 2);
      this.later(() => this.connect(), delay);
    };
    try { this.ws = ws = this.socket(this.url); } catch { failed(); return; }
    const handshake = this.later(failed, 10000);
    let awaitingPong = false; let pongTimeout;
    const heartbeat = () => {
      if (!current() || !this.ready) return;
      awaitingPong = true;
      try { ws.send(JSON.stringify({ type: 'ping' })); } catch { failed(); return; }
      pongTimeout = this.later(() => { if (awaitingPong) failed(); }, 10000);
      this.later(heartbeat, 20000);
    };
    ws.onmessage = event => {
      if (!current()) return;
      let message;
      try { message = JSON.parse(event.data); } catch { failed(); return; }
      if (message.type === 'revoked') { this.stop(); this.onRevoked?.(); return; }
      if (message.type === 'hello' && !this.ready) {
        this.clear(handshake); this.ready = true; this.delay = 500;
        this.onHello(message); this.onState(true); this.onChanged();
        this.later(heartbeat, 20000);
      } else if (message.type === 'changed' && this.ready) {
        // Bound refresh frequency during streaming; preserve one trailing refresh.
        if (!this.changeTimer) this.changeTimer = this.later(() => {
          this.changeTimer = null; if (current()) this.onChanged();
        }, 200);
      } else if (message.type === 'pong' && this.ready) {
        awaitingPong = false; this.clear(pongTimeout);
      }
    };
    ws.onerror = failed; ws.onclose = failed;
  }
}
