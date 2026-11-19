// SVG drawing, station glyphs and palettes adapted from https://github.com/alexeyw/lot-map (hooks/{draw,setup,palette,classify}.ts)
// Revision e3a93ec01f72803483767154564de9f1fa8d4ca4. Copyright (c) 2026 Aleksei Volodin. MIT, see lot-map-LICENSE.txt.
(() => {
const DARK = {
  ground: '#0a0c11',
  raised: '#12151c',
  line: '#272c36',
  spoke: '#1a1e27',
  bone: '#ebe6dc',
  ash: '#9ba1ab',
  dim: '#6b7280',
  accent: '#e1ac6e',
  hot: '#f0c595',
  red: '#e8654f',
  mem: '#62c7ba',
  memHot: '#a5e6dc',
  // One step away from `bone`, so that the light rules can give the route a color of its own.
  trail: '#ebe6dd',
}

const LIGHT = {
  ground: '#f5f2ea',
  raised: '#ffffff',
  line: '#cfc9bc',
  spoke: '#e3ded2',
  bone: '#1f2228',
  ash: '#5f6570',
  dim: '#8b909a',
  accent: '#b8762a',
  hot: '#8f560f',
  red: '#c5402b',
  mem: '#1c8c81',
  memHot: '#136a62',
  trail: '#9c978b',
}

const STATIONS = [
  { id: 'you', icon: `${ring(0, -3.6, 3.4)}M-6.5 8c0-4 3-6.2 6.5-6.2s6.5 2.2 6.5 6.2` },
  { id: 'model', icon: 'M-5 -5h10v10h-10zM-2 -8.5v3.5M2 -8.5v3.5M-2 5v3.5M2 5v3.5M-8.5 -2h3.5M-8.5 2h3.5M5 -2h3.5M5 2h3.5' },
  { id: 'memory', icon: `M-5 4.5L0 -5L6 3.5M-5 4.5L6 3.5${ring(-5, 4.5, 2.1)}${ring(0, -5, 2.1)}${ring(6, 3.5, 2.1)}` },
  { id: 'files', icon: 'M-5.5 -8h7.5l3.5 3.5v12.5h-11zM2 -8v3.5h3.5' },
  { id: 'shell', icon: 'M-7.5 -5l5 5l-5 5M0 6h7.5' },
  { id: 'web', icon: `${ring(0, 0, 7.8)}M-7.8 0h15.6M0 -7.8c-4.2 4.2 -4.2 11.4 0 15.6M0 -7.8c4.2 4.2 4.2 11.4 0 15.6` },
  { id: 'browser', icon: 'M-8.5 -6.5h17v13h-17zM-8.5 -2.8h17M-6.3 -4.7h.1M-3.8 -4.7h.1' },
  { id: 'agents', icon: `M0 -4v3.5M0 -.5L-6 4M0 -.5L6 4${ring(0, -6, 2.1)}${ring(-6.5, 5.5, 2.1)}${ring(6.5, 5.5, 2.1)}` },
  { id: 'skills', icon: 'M1.5 -8.5L-5.5 1h4.5l-1.5 7.5l7.5 -9.8h-4.5z' },
  { id: 'hooks', icon: `M2.5 -5.5v8a4.2 4.2 0 1 1 -8.4 0v-1.5${ring(2.5, -7.3, 1.8)}` },
]

function ring(x, y, r) {
  return `M${x - r} ${y}a${r} ${r} 0 1 0 ${2 * r} 0a${r} ${r} 0 1 0 ${-2 * r} 0`
}

function shortModel(model) {
  const m = /claude-([a-z]+)-(\d+)(?:-(\d+))?/.exec(model)
  return m === null ? model : `${m[1]} ${m[2]}${m[3] !== undefined ? `.${m[3]}` : ''}`
}
function formatTokens(tokens) {
  const n = Math.max(0, Math.round(tokens))
  if (n < 1000) return String(n)
  const k = Math.round(n / 1000)
  return k < 1000 ? `${k}k` : `${Math.round(n / 1_000_000)}M`
}
// How the board is drawn: one SVG, the agent in the centre and a station for each kind of work.
// Nothing here touches the engine.

const W = 460
const H = 430
/** Height over width of the drawing, for a surface that sizes it itself. */
const MAP_ASPECT = H / W
const CX = 230
const CY = 212
const RX = 176
const RY = 164
const NODE = 22
const CORE = 40
/** Where spokes and pulses meet the core: outside the context ring. */
const HUB = CORE + 8

const FONT = 'font-family="SF Mono, ui-monospace, Menlo, monospace"'

// The braille map keeps these times too, so that the two drawings of one board light and fade together.
const PULSE_MS = 800
const RIPPLE_MS = 450
const GLOW_MS = 3200
const ALARM_MS = 6000
const SWITCH_MS = 8000
const DONE_MS = 1100
const TRAIL_STOPS = 7
/** A leg of the route stays for a while after it was drawn, then fades: the route shows where the work is going, and the spokes keep where it went. */
const TRAIL_HOLD_MS = 40_000
const TRAIL_FADE_MS = 20_000

/** The angle of place `i` on a ring turned `shift` places. */
const turn = (i, shift) => ((i + shift) * 2 * Math.PI) / STATIONS.length
const at = (a, f = 1) => ({ x: CX + RX * f * Math.sin(a), y: CY - RY * f * Math.cos(a) })
const place = (i, shift) => at(turn(i, shift))
const indexOf = (id) => STATIONS.findIndex(s => s.id === id)

const n1 = (v) => (Math.round(v * 10) / 10).toString()
/** A moment on the drawing's own clock, which starts at zero each time it is drawn; a past moment is negative. */
const clock = (ms) => `${(ms / 1000).toFixed(3)}s`

/** Where a straight line from `from` to `to` meets the circle of radius `r` around `from`. */
function edge(from, to, r) {
  const d = Math.hypot(to.x - from.x, to.y - from.y) || 1
  return { x: from.x + ((to.x - from.x) * r) / d, y: from.y + ((to.y - from.y) * r) / d }
}

/** The same line moved sideways, so that several pulses on one spoke fly side by side. */
function aside(a, b, off) {
  const d = Math.hypot(b.x - a.x, b.y - a.y) || 1
  const dx = (-(b.y - a.y) * off) / d
  const dy = ((b.x - a.x) * off) / d
  return [{ x: a.x + dx, y: a.y + dy }, { x: b.x + dx, y: b.y + dy }]
}

/** A pulse with a short tail behind it. A hollow one is a signal nobody asked for. */
function pulse(a, b, color, age, radius, isHollow = false) {
  // A negative begin carries on where the last drawing left off, so a redraw never restarts a flight.
  const path = `M${n1(a.x)} ${n1(a.y)}L${n1(b.x)} ${n1(b.y)}`
  let out = ''
  for (let k = isHollow ? 0 : 2; k >= 0; k--) {
    const timing = `begin="${clock(k * 45 - age)}" dur="${clock(PULSE_MS)}" fill="freeze"`
    const peak = n1(1 - 0.36 * k)
    const paint = isHollow ? `fill="none" stroke="${color}" stroke-width="1.4"` : `fill="${color}"`
    out +=
      `<circle r="${n1(radius * (1 - 0.27 * k))}" ${paint} opacity="0">` +
      `<animateMotion path="${path}" ${timing}/>` +
      `<animate attributeName="opacity" values="${peak};${peak};0" keyTimes="0;.82;1" ${timing}/>` +
      `</circle>`
  }
  return out
}

/** A ring that spreads from where a pulse lands, at the moment it lands. */
function ripple(p, r, color, age) {
  const timing = `begin="${clock(PULSE_MS - age)}" dur="${clock(RIPPLE_MS)}" fill="freeze"`
  return (
    `<circle cx="${n1(p.x)}" cy="${n1(p.y)}" r="${r}" fill="none" stroke="${color}" stroke-width="1.2" opacity="0">` +
    `<animate attributeName="r" values="${r};${r + 11}" ${timing}/>` +
    `<animate attributeName="opacity" values=".7;0" ${timing}/></circle>`
  )
}

function beam(a, b, color, age, isDashed) {
  return (
    `<line x1="${n1(a.x)}" y1="${n1(a.y)}" x2="${n1(b.x)}" y2="${n1(b.y)}" stroke="${color}" stroke-width="1.4"${isDashed ? ' stroke-dasharray="3 4"' : ''} opacity="0">` +
    `<animate attributeName="opacity" values=".75;0" begin="${clock(-age)}" dur="${clock(GLOW_MS / 2)}" fill="freeze"/></line>`
  )
}

/** How far from the core a leg bends, by how many stations apart its ends are: far enough in to clear the labels under the nodes, far enough out to clear the core. */
const BEND = [0.5, 0.5, 0.4, 0.45, 0.55, 0.75]

/** The way from one station to another: a curve through the room between the core and the ring. */
function leg(i, j, shift) {
  const n = STATIONS.length
  let steps = (((j - i) % n) + n) % n
  if (steps > n / 2) steps -= n
  const bend = at(turn(i + steps / 2, shift), BEND[Math.abs(steps)] ?? 0.5)
  const a = edge(place(i, shift), bend, NODE + 4)
  const b = edge(place(j, shift), bend, NODE + 4)
  return { path: `M${n1(a.x)} ${n1(a.y)}Q${n1(bend.x)} ${n1(bend.y)} ${n1(b.x)} ${n1(b.y)}`, end: b }
}

/** The stations the main loop went through, oldest first, a station visited twice in a row counted once. */
function routeOf(entries, max = TRAIL_STOPS) {
  const stops = []
  for (const e of entries) {
    if (e.from === 'agents' || e.station === 'model') continue
    const last = stops[stops.length - 1]
    if (last !== undefined && last.station === e.station) last.at = e.startedAt
    else stops.push({ station: e.station, at: e.startedAt })
  }
  return stops.slice(-max)
}

function trail(entries, now, c, isStill, shift) {
  const stops = routeOf(entries)
  let out = ''
  for (let k = 1; k < stops.length; k++) {
    const from = stops[k - 1]
    const to = stops[k]
    if (from === undefined || to === undefined) continue
    const { path, end } = leg(indexOf(from.station), indexOf(to.station), shift)
    const isHead = k === stops.length - 1
    const age = now - to.at
    if (age >= TRAIL_HOLD_MS + TRAIL_FADE_MS) continue
    const opacity = n1(0.12 + (0.5 * k) / (stops.length - 1))
    // The fading is written into the drawing, so a leg goes out on time even when nothing redraws the map.
    const fade = `<animate attributeName="opacity" values="${opacity};0" begin="${clock(TRAIL_HOLD_MS - age)}" dur="${clock(TRAIL_FADE_MS)}" fill="freeze"/>`
    // The newest leg draws itself; the rest are already there.
    const drawing = isHead && !isStill
      ? ` pathLength="1" stroke-dasharray="1 1" stroke-dashoffset="1"><animate attributeName="stroke-dashoffset" values="1;0" begin="${clock(to.at - now)}" dur=".5s" fill="freeze"/>`
      : '>'
    out += `<path d="${path}" fill="none" stroke="${c.trail}" stroke-width="${isHead ? 1.5 : 1.1}" stroke-linecap="round" opacity="${opacity}"${drawing}${fade}</path>`
    if (isHead) {
      out +=
        `<circle cx="${n1(end.x)}" cy="${n1(end.y)}" r="2.4" fill="${c.trail}" opacity="${isStill ? '.85' : '0'}">` +
        (isStill ? '' : `<animate attributeName="opacity" values="0;.85" begin="${clock(to.at - now + 400)}" dur=".15s" fill="freeze"/>`) +
        `<animate attributeName="opacity" values=".85;0" begin="${clock(TRAIL_HOLD_MS - age)}" dur="${clock(TRAIL_FADE_MS)}" fill="freeze"/></circle>`
    }
  }
  return out
}

function station(s, i, { entries, board, now, c, names, isStill, shift, spent }) {
  const p = place(i, shift)
  const x = n1(p.x)
  const y = n1(p.y)
  const count = board.counts[s.id] ?? 0
  const own = entries.filter(e => e.station === s.id)
  const running = own.filter(e => e.status === 'run')
  const latest = own.length > 0 ? own[own.length - 1] : undefined
  const since = latest === undefined ? Infinity : now - (latest.endedAt ?? latest.startedAt)
  const alarm = own.filter(e => e.status === 'block' || e.status === 'err').pop()
  const alarmAge = alarm === undefined ? Infinity : now - (alarm.endedAt ?? alarm.startedAt)
  const isAlarm = alarmAge < ALARM_MS
  const isLit = running.length > 0 || since < GLOW_MS
  const [main, hot] = s.id === 'memory' ? [c.mem, c.memHot] : [c.accent, c.hot]
  const color = isAlarm ? c.red : main
  const fade = isAlarm ? alarmAge : since
  const span = isAlarm ? ALARM_MS : GLOW_MS

  let under = ''
  if (isLit || isAlarm) {
    under +=
      running.length > 0 && !isAlarm
        ? `<circle cx="${x}" cy="${y}" r="${NODE + 10}" fill="${color}" opacity=".16"/>`
        : `<circle cx="${x}" cy="${y}" r="${NODE + 10}" fill="${color}" opacity="0">` +
          `<animate attributeName="opacity" values=".3;0" begin="${clock(-fade)}" dur="${clock(span)}" fill="freeze"/></circle>`
  }
  if (running.length > 0) {
    const elapsed = now - Math.min(...running.map(e => e.startedAt))
    const beat = `begin="${clock(-(elapsed % 1400))}" dur="1.4s" repeatCount="indefinite"`
    // The beat is a ring that spreads: with reduced motion the steady halo and the clock hands say the same.
    if (!isStill) {
      under +=
        `<circle cx="${x}" cy="${y}" r="${NODE}" fill="none" stroke="${color}" stroke-width="1.3">` +
        `<animate attributeName="r" values="${NODE};${NODE + 15}" ${beat}/>` +
        `<animate attributeName="opacity" values=".9;0" ${beat}/></circle>`
    }
    // Two hands of a clock around the node: the inner one goes round in a minute, the outer one in ten.
    const hand = (r, width, lapMs, isOnce) =>
      `<circle cx="${x}" cy="${y}" r="${r}" fill="none" stroke="${hot}" stroke-width="${width}" pathLength="1" stroke-dasharray="1 1" stroke-dashoffset="1" transform="rotate(-90 ${x} ${y})">` +
      `<animate attributeName="stroke-dashoffset" values="1;0" begin="${clock(-(isOnce ? Math.min(elapsed, lapMs) : elapsed % lapMs))}" dur="${clock(lapMs)}" ${isOnce ? 'fill="freeze"' : 'repeatCount="indefinite"'}/></circle>`
    under += hand(NODE + 4, 2.2, 60_000, false) + hand(NODE + 8, 1.2, 600_000, true)
  }

  // A lit node wears a ring of its color while something runs; afterwards the ring fades back to the resting line.
  const lit = `<circle cx="${x}" cy="${y}" r="${NODE}" fill="none" stroke="${color}" stroke-width="1.2"`
  const cooling =
    running.length > 0
      ? `${lit}/>`
      : isLit || isAlarm
        ? `${lit} opacity="0"><animate attributeName="opacity" values="1;0" begin="${clock(-fade)}" dur="${clock(span)}" fill="freeze"/></circle>`
        : ''
  const glyphColor = isAlarm ? c.red : isLit ? hot : s.id === 'memory' && count > 0 ? main : c.ash
  // The words stand on a rim of the ground's own color, so a line that passes behind them never strikes them through.
  const rim = `paint-order="stroke" stroke="${c.ground}" stroke-width="3.5" stroke-linejoin="round"`
  let over =
    `<circle cx="${x}" cy="${y}" r="${NODE}" fill="${c.raised}" stroke="${c.line}" stroke-width="1.2"/>${cooling}` +
    `<path transform="translate(${x} ${y})" d="${s.icon}" fill="none" stroke="${glyphColor}" stroke-width="1.25" stroke-linecap="round" stroke-linejoin="round"/>` +
    `<text x="${x}" y="${n1(p.y + NODE + 15)}" text-anchor="middle" ${FONT} font-size="11.5" ${rim} fill="${isLit || isAlarm ? c.bone : c.ash}">${names[s.id]}</text>`

  if (count > 0) {
    // Memory keeps two counts: what was asked for, and what a hook brought down unasked.
    const pushed = s.id === 'memory' ? Math.min(count, board.pushed ?? 0) : 0
    const asked = count - pushed
    const figures =
      pushed === 0 ? String(count) : `${asked > 0 ? `${asked} ` : ''}<tspan fill="${main}">↓${pushed}</tspan>`
    // With `contextCost`, after the counts, about how much the station's calls added to the context: in the counts' own colour.
    const tokens = spent?.[s.id] ?? 0
    const cost = tokens > 0 ? ` · ${formatTokens(tokens)}` : ''
    over += `<text x="${x}" y="${n1(p.y + NODE + 28)}" text-anchor="middle" ${FONT} font-size="9.5" ${rim} fill="${c.dim}">${figures}${cost}</text>`
  }

  // Top right: how many run at once. Top left: what went wrong since the last message, until the next one.
  const corner = NODE * 0.74
  if (board.rows[s.id === "web" ? "network" : s.id].active > 1) {
    over +=
      `<circle cx="${n1(p.x + corner)}" cy="${n1(p.y - corner)}" r="8" fill="${c.raised}" stroke="${color}" stroke-width="1"/>` +
      `<text x="${n1(p.x + corner)}" y="${n1(p.y - corner + 3)}" text-anchor="middle" ${FONT} font-size="8.5" fill="${hot}">×${board.rows[s.id === "web" ? "network" : s.id].active}</text>`
  }
  const faults = board.faults?.[s.id] ?? 0
  if (faults > 0) {
    over +=
      `<circle cx="${n1(p.x - corner)}" cy="${n1(p.y - corner)}" r="7.5" fill="${c.red}"/>` +
      `<text x="${n1(p.x - corner)}" y="${n1(p.y - corner + 3.1)}" text-anchor="middle" ${FONT} font-size="9" font-weight="700" fill="${c.ground}">${faults > 99 ? '99+' : faults}</text>`
  }
  const key = s.id === "web" ? "network" : s.id
  const row = board.rows[key]
  return { under, over: `<g data-station="${key}" data-active="${row.active}" data-completed="${row.completed}" data-failed="${row.failed}">${over}</g>` }
}

/** The board as one SVG. With `contextCost` on, each station's count line also says how much of the context its calls added. */
function drawMap(board, now, setup) {
  const c = { ...(setup.theme === 'light' ? LIGHT : DARK), ...setup.colors }
  // How many places the ring is turned. The stations keep their order, so the far side of the person is always the network.
  const shift = setup.layout === 'you-bottom' ? STATIONS.length / 2 : 0
  const core = { x: CX, y: CY }
  const recent = board.entries
  // With reduced motion nothing flies, spreads or spins. A call still shows: its spoke flashes and fades, its station
  // lights and cools, the route gets its leg; those only change their opacity. The clock hands stay, as slow as a clock's.
  const isStill = setup.motion === 'reduced'
  const flights = isStill ? [] : recent.filter(e => now - e.startedAt < PULSE_MS + RIPPLE_MS).slice(-14)
  const returns = isStill ? [] : recent.filter(e => e.endedAt !== undefined && e.from !== 'inbound' && now - e.endedAt < PULSE_MS + RIPPLE_MS).slice(-14)
  const beams = recent.filter(e => now - e.startedAt < GLOW_MS / 2).slice(-10)
  const anyRunning = recent.some(e => e.status === 'run')
  const agentsAt = place(indexOf('agents'), shift)
  const isBad = (e) => e.status === 'block' || e.status === 'err'
  const tone = (e) => (e.station === 'memory' ? [c.mem, c.memHot] : [c.accent, c.hot])

  // Without its ground the map keeps the rim around its words, in the ground's color: a faint halo on a surface of another shade.
  let body = setup.background === 'transparent' ? '' : `<rect width="${W}" height="${H}" rx="12" fill="${c.ground}"/>`

  // Contours around the core.
  for (const [rx, ry] of [[66, 62], [104, 97], [142, 132]]) {
    body += `<ellipse cx="${CX}" cy="${CY}" rx="${rx}" ry="${ry}" fill="none" stroke="${c.line}" stroke-width=".7" opacity=".45" stroke-dasharray="2 5"/>`
  }

  // Spokes first, then whatever flies along them, then the nodes on top.
  // A spoke wears in with use: by the end of a session the map shows where the work went.
  STATIONS.forEach((s, i) => {
    const p = place(i, shift)
    const a = edge(core, p, HUB)
    const b = edge(p, core, NODE)
    const worn = Math.min(1, Math.log2(1 + (board.counts[s.id] ?? 0)) / 7)
    const line = `<line x1="${n1(a.x)}" y1="${n1(a.y)}" x2="${n1(b.x)}" y2="${n1(b.y)}" stroke-width="${n1(1 + 2.6 * worn)}" stroke-linecap="round"`
    body += `${line} stroke="${c.spoke}"/>`
    if (worn > 0) body += `${line} stroke="${s.id === 'memory' ? c.mem : c.accent}" opacity="${n1(worn * 0.55)}"/>`
  })

  const scene = { entries: recent, board, now, c, names: setup.t.stations, isStill, shift, spent: setup.contextCost ? board.spent : undefined }
  const drawn = STATIONS.map((s, i) => station(s, i, scene))
  body += drawn.map(d => d.under).join('')
  body += trail(recent, now, c, isStill, shift)

  /** The two ends of an entry's spoke: where it starts (the core or the agents station) and its own station. */
  const ends = (e) => {
    const p = place(indexOf(e.station), shift)
    const start = e.from === 'agents' ? agentsAt : core
    return [edge(start, p, e.from === 'agents' ? NODE : HUB), edge(p, start, NODE)]
  }
  /** Pulses that share a spoke and a moment fly in lanes, five apart. */
  const lane = (list, e) => {
    const peers = list.filter(x => x.station === e.station && x.from === e.from)
    return (peers.indexOf(e) - (peers.length - 1) / 2) * 5
  }

  for (const e of beams) {
    const [a, b] = ends(e)
    body += beam(a, b, isBad(e) ? c.red : tone(e)[0], now - e.startedAt, e.from === 'inbound')
  }
  for (const e of flights) {
    const [a, b] = aside(...ends(e), lane(flights, e))
    const age = now - e.startedAt
    const color = e.status === 'block' ? c.red : tone(e)[1]
    if (e.from === 'inbound') {
      body += pulse(b, a, color, age, 3.8, true) + ripple(core, HUB - 2, color, age)
    } else {
      body += pulse(a, b, color, age, 3.8) + ripple(place(indexOf(e.station), shift), NODE, color, age)
    }
  }
  for (const e of returns) {
    const [a, b] = aside(...ends(e), lane(returns, e))
    body += pulse(b, a, e.status === 'ok' ? c.ash : c.red, now - (e.endedAt), 2.6)
  }

  body += drawn.map(d => d.over).join('')

  // Each subagent still at work circles the agents station.
  const crew = (board.agents ?? []).slice(0, 6)
  crew.forEach((_, k) => {
    const lap = 7000
    const spin = `${n1(agentsAt.x)} ${n1(agentsAt.y)}`
    // Standing still, each keeps its own place on the circle.
    if (isStill) {
      body += `<g transform="rotate(${n1((360 * k) / crew.length)} ${spin})"><circle cx="${n1(agentsAt.x)}" cy="${n1(agentsAt.y - NODE - 6)}" r="3" fill="${c.hot}"/></g>`
      return
    }
    body +=
      `<g><animateTransform attributeName="transform" type="rotate" from="0 ${spin}" to="360 ${spin}" begin="${clock(-((now + (k * lap) / crew.length) % lap))}" dur="${clock(lap)}" repeatCount="indefinite"/>` +
      `<circle cx="${n1(agentsAt.x)}" cy="${n1(agentsAt.y - NODE - 6)}" r="3" fill="${c.hot}"/></g>`
  })

  // A name longer than three letters shrinks to stay inside the circle.
  const coreSize = Math.min(17, 62 / (0.75 * setup.core.length))

  // The core breathes at rest and quickens while something runs.
  const period = anyRunning ? 1600 : 4800
  const breath = `begin="${clock(-(now % period))}" dur="${clock(period)}" repeatCount="indefinite"`
  body +=
    (isStill
      ? `<circle cx="${CX}" cy="${CY}" r="${CORE + 8}" fill="${c.accent}" opacity="${anyRunning ? '.16' : '.08'}"/>`
      : `<circle cx="${CX}" cy="${CY}" r="${CORE + 6}" fill="${c.accent}" opacity=".08">` +
        `<animate attributeName="r" values="${CORE + 3};${CORE + 13};${CORE + 3}" ${breath}/>` +
        `<animate attributeName="opacity" values=".05;${anyRunning ? '.24' : '.12'};.05" ${breath}/></circle>`) +
    `<circle cx="${CX}" cy="${CY}" r="${CORE}" fill="${c.raised}" stroke="${anyRunning ? c.accent : c.line}" stroke-width="1.3"/>`

  // The context window as a ring around the core: it fills as the session goes and empties at a compaction.
  if (board.context !== undefined) {
    const full = Math.max(0, Math.min(100, Math.round(board.context)))
    const ring = `cx="${CX}" cy="${CY}" r="${CORE + 5}" fill="none" stroke-width="2.2"`
    body +=
      `<circle ${ring} stroke="${c.line}" opacity=".7"/>` +
      `<circle ${ring} stroke="${full >= 90 ? c.red : full >= 70 ? c.accent : c.ash}" pathLength="100" stroke-dasharray="${full} 100" transform="rotate(-90 ${CX} ${CY})"/>` +
      `<text x="${CX}" y="${CY - 19}" text-anchor="middle" ${FONT} font-size="8" fill="${c.dim}">${full}%</text>`
  }

  const switchAge = board.switchedAt === undefined ? Infinity : now - board.switchedAt
  const isSwitching = switchAge >= 0 && switchAge < SWITCH_MS
  body += `<text x="${CX}" y="${CY + (board.model === undefined ? 6 : 1)}" text-anchor="middle" ${FONT} font-size="${n1(coreSize)}" letter-spacing="${n1(coreSize * 0.147)}" fill="${c.bone}">${escapeXml(setup.core)}</text>`
  if (board.model !== undefined) {
    body += `<text x="${CX}" y="${CY + 17}" text-anchor="middle" ${FONT} font-size="9" fill="${isSwitching ? c.hot : c.ash}">${escapeXml(shortModel(board.model))}</text>`
  }

  // A changed model rings at the core and at its station for a few seconds.
  if (isSwitching && !isStill) {
    const model = place(indexOf('model'), shift)
    const laps = Math.ceil((SWITCH_MS - switchAge) / 1600)
    for (const [p, r] of [[core, CORE], [model, NODE]]) {
      const ringing = `begin="${clock(-(switchAge % 1600))}" dur="1.6s" repeatCount="${laps}" fill="freeze"`
      body +=
        `<circle cx="${n1(p.x)}" cy="${n1(p.y)}" r="${r}" fill="none" stroke="${c.bone}" stroke-width="1.4" opacity="0">` +
        `<animate attributeName="r" values="${r};${r + 26}" ${ringing}/>` +
        `<animate attributeName="opacity" values=".7;0" ${ringing}/></circle>`
    }
  }

  // The answer leaves the core as one wide ring.
  const done = recent.filter(e => e.mark === 'done').pop()
  if (done !== undefined && now - done.startedAt < DONE_MS && !isStill) {
    const leaving = `begin="${clock(done.startedAt - now)}" dur="${clock(DONE_MS)}" fill="freeze"`
    body +=
      `<circle cx="${CX}" cy="${CY}" r="${CORE}" fill="none" stroke="${c.bone}" stroke-width="1.6" opacity="0">` +
      `<animate attributeName="r" values="${CORE};${CORE + 38}" ${leaving}/>` +
      `<animate attributeName="opacity" values=".6;0" ${leaving}/></circle>`
  }

  // Twice the viewBox, so the picture fills whatever room the pane gives it.
  return `<svg class="theall-lot-board" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" width="${W * 2}" height="${H * 2}">${body}</svg>`
}

function escapeXml(text) {
  return text.replace(/[<>&"]/g, c => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;' })[c])
}

// TheAll receives station counters from either CLI. Keep just enough history
// to finish flights already on screen, without reading conversation content.
const countOf = n => Number.isSafeInteger(n) && n >= 0 ? n : 0;
const emptyRow = { active: 0, completed: 0, failed: 0 };
const stationKey = id => id === 'web' ? 'network' : id;

function synchronize(board, rows, now) {
  const input = new Map(rows.map(row => [row.station, row]));
  for (const {id} of STATIONS) {
    const key = stationKey(id);
    const previous = board.rows[key] || emptyRow;
    const raw = input.get(key) || emptyRow;
    const row = {active: countOf(raw.active), completed: countOf(raw.completed), failed: countOf(raw.failed)};
    board.rows[key] = row;
    board.counts[id] = row.active + row.completed + row.failed;
    board.faults[id] = row.failed;

    const live = board.entries.filter(entry => entry.station === id && entry.status === 'run');
    // A host can coalesce a start and its end in the same snapshot.
    // Cap visual flights at the original renderer's maximum, retaining the true counter above.
    for (const [field, status] of [['failed', 'err'], ['completed', 'ok']]) {
      const finishes = Math.min(14, row[field] - previous[field]);
      for (let n = 0; n < finishes; n++) {
        const entry = live.shift();
        if (entry) Object.assign(entry, { status, endedAt: now });
        else board.entries.push({station: id, startedAt: now, endedAt: now, status});
      }
    }
    const needed = Math.min(14, row.active);
    for (const entry of live.slice(needed)) {
      // A busy-model indicator may go idle without a separate completion.
      entry.status = 'ok';
      entry.endedAt = now;
    }
    for (let n = live.length; n < needed; n++) {
      board.entries.push({station: id, startedAt: now, status: 'run'});
    }
  }
  const recent = new Set(board.entries.filter(e => e.status !== 'run').slice(-40));
  board.entries = board.entries.filter(e => e.status === 'run' || recent.has(e));
  board.agents = Array(Math.min(6, board.rows.agents.active)).fill(true);
}

// Percentages describe a provider-reported usage window. A missing reading stays blank.
function quotaText(rows, locale, now) {
  if (!Array.isArray(rows)) return '';
  const parts = [];
  for (const row of rows) {
    if (!row || !Number.isSafeInteger(row.windowMinutes) || row.windowMinutes <= 0
        || !Number.isSafeInteger(row.remainingPercent) || row.remainingPercent < 0 || row.remainingPercent > 100
        || (row.resetsAt != null && (!Number.isFinite(row.resetsAt) || row.resetsAt <= now))) continue;
    const units = [[10080, 'week'], [1440, 'day'], [60, 'hour'], [1, 'minute']];
    const [scale, unit] = units.find(([minutes]) => row.windowMinutes % minutes === 0);
    const duration = new Intl.NumberFormat(locale, {style:'unit', unit, unitDisplay:'short'}).format(row.windowMinutes / scale);
    const remaining = new Intl.NumberFormat(locale, {style:'percent'}).format(row.remainingPercent / 100);
    parts.push(duration + ' ' + remaining);
  }
  return parts.join(' · ');
}

function mount(element, footer) {
  const board = { entries: [], rows: {}, counts: {}, faults: {} };
  const dark = matchMedia('(prefers-color-scheme: dark)');
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  let signature, state, expiryTimer;
  function updateFooter() {
    if (!footer) return;
    clearTimeout(expiryTimer);
    const now = Date.now() / 1000;
    const summary = quotaText(state.quota, state.locale, now);
    footer.hidden = !summary;
    footer.textContent = summary ? state.quotaLabel + ' · ' + summary : '';
    if (summary) {
      const deadlines = state.quota.map(row => row?.resetsAt).filter(t => Number.isFinite(t) && t > now);
      if (deadlines.length) expiryTimer = setTimeout(updateFooter, Math.min(2147483647, Math.ceil((Math.min(...deadlines) - now) * 1000)));
    }
  }
  function update(payload) {
    const {provider, rows = [], labels = {}, reduceMotion, theme} = payload;
    const isDark = theme === 'dark' || (theme !== 'light' && dark.matches);
    const still = Boolean(reduceMotion || reduced.matches);
    const next = JSON.stringify([provider, rows, labels, still, isDark]);
    state = payload;
    updateFooter();
    if (next === signature) return;
    signature = next;
    const now = performance.now();
    synchronize(board, rows, now);
    const names = {};
    for (const {id} of STATIONS) {
      const key = stationKey(id);
      names[id] = escapeXml(String(labels[key] ?? key[0].toUpperCase() + key.slice(1)));
    }
    element.innerHTML = drawMap(board, now, {
      core: String(provider || 'AI'), theme: isDark ? 'dark' : 'light',
      motion: still ? 'reduced' : 'full', t: {stations: names}
    });
    element.firstElementChild?.setCurrentTime?.(0);
  }
  function repaint() { if (state) update(state); }
  dark.addEventListener('change', repaint);
  reduced.addEventListener('change', repaint);
  return { update, destroy() {
    if (footer) { clearTimeout(expiryTimer); footer.hidden = true; footer.textContent = ''; }
    dark.removeEventListener('change', repaint);
    reduced.removeEventListener('change', repaint);
    element.replaceChildren();
  }};
}

window.TheAllLotMap = {mount, quotaText};
const standalone = document.getElementById('lot-map-window');
if (standalone) window.updateLotMap = mount(standalone, document.querySelector('.lot-quota')).update;
})();
