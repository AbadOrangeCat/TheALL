import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const source = readFileSync(new URL('../TheAll/Mobile/MobileWeb.bundle/lot-map.js', import.meta.url), 'utf8');

test('live board renders ten stations, parallel flights, a crew and a reduced-motion state', () => {
  const window = {};
  const query = { matches: false, addEventListener() {}, removeEventListener() {} };
  runInNewContext(source, { window, document: { getElementById() {} }, matchMedia: () => query, performance });
  const element = {innerHTML: '', replaceChildren() { this.innerHTML = ''; }};
  const map = window.TheAllLotMap.mount(element);
  const state = { provider: 'Codex', rows: [{ station: 'agents', active: 2 }], labels: { network: '<unsafe>' } };
  map.update(state);
  assert.equal([...element.innerHTML.matchAll(/data-station="/g)].length, 10);
  assert.match(element.innerHTML, /×2/);
  assert.match(element.innerHTML, /animateMotion/);
  assert.match(element.innerHTML, /animateTransform/);
  assert.doesNotMatch(element.innerHTML, /<unsafe>/);
  map.update({...state, reduceMotion: true, rows: [{ station: 'agents', active: 1, failed: 1 }]});
  assert.doesNotMatch(element.innerHTML, /animateMotion|animateTransform/);
  assert.match(element.innerHTML, /data-station="agents" data-active="1" data-completed="0" data-failed="1"/);
  assert.match(element.innerHTML, />Codex<\/text>/);
  map.destroy();
  assert.equal(element.innerHTML, '');
});

test('quota footer shows measured windows, including zero, and omits unknown or expired limits', () => {
  const window = {};
  runInNewContext(source, {window, document: {getElementById() {}}});
  const now = 1_800_000_000;
  const rows = [
    {windowMinutes: 300, remainingPercent: 78, resetsAt: now + 15},
    {windowMinutes: 10080, remainingPercent: 0},
    {windowMinutes: 60, remainingPercent: 88, resetsAt: now},
    {windowMinutes: 1, remainingPercent: null}
  ];
  const {quotaText} = window.TheAllLotMap;
  assert.equal(quotaText(rows, 'en-US', now), '5 hr 78% · 1 wk 0%');
  assert.equal(quotaText([], 'en-US', now), '');
});
