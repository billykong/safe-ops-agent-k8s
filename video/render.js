// Renders the video's frames in the style of the capstone thumbnail, and the
// ffmpeg concat list that times them to the narration.
//   node render.js OUT_DIR    (needs OUT_DIR/timings.json from tts.py)
// Frames are SVG rendered with resvg; text is DejaVu (see the thumbnails'
// note: resvg-js ignores weights in variable fonts).
const fs = require('fs');
const path = require('path');
const { Resvg } = require(require.resolve('@resvg/resvg-js', { paths: [process.cwd(), __dirname] }));
const { scenes, LAYERS } = require('./scenes');

const W = 1920, H = 1080, X = 128;
const C = { bg: '#0f172a', grid: '#1e293b', fg: '#f8fafc', muted: '#cbd5e1', dim: '#94a3b8', teal: '#2dd4bf', amber: '#fbbf24', box: '#1e293b', edge: '#334155', term: '#0b1220' };
const sans = 'DejaVu Sans', mono = 'DejaVu Sans Mono';

const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const t = (x, y, s, size, fill, font = sans, weight = 400, extra = '') =>
  `<text x="${x}" y="${y}" font-family="${font}" font-size="${size}" font-weight="${weight}" fill="${fill}" ${extra}>${esc(s)}</text>`;
const frame = inner => `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
<defs><pattern id="g" width="64" height="64" patternUnits="userSpaceOnUse"><path d="M64 0H0V64" fill="none" stroke="${C.grid}" stroke-width="1.5"/></pattern>
<marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0L10 5L0 10Z" fill="${C.dim}"/></marker></defs>
<rect width="${W}" height="${H}" fill="${C.bg}"/><rect width="${W}" height="${H}" fill="url(#g)" opacity="0.6"/>
<rect x="0" y="0" width="16" height="${H}" fill="${C.teal}"/>${inner}</svg>`;
const label = s => t(X, 150, s, 36, C.teal, mono, 700, 'letter-spacing="5"');
const footer = s => t(X, 1010, s, 28, C.dim, mono);

// Greedy wrap by estimated width: DejaVu Sans averages ~0.55em a character,
// bold ~0.62em, mono exactly 0.602em.
function wrap(s, px, size, factor = 0.55) {
  const max = Math.floor(px / (size * factor)), out = [];
  let line = '';
  for (const w of s.split(' ')) {
    if (line && (line + ' ' + w).length > max) { out.push(line); line = w; } else line = line ? line + ' ' + w : w;
  }
  if (line) out.push(line);
  return out;
}

// The thumbnail's motif: eight nested squares around the agent, layer 1
// innermost. `hl` lights one layer in amber.
function rings(cx, cy, size, hl = 0) {
  let s = '';
  const step = (size - size * 0.3) / 7;
  for (let i = 0; i < 8; i++) {
    const n = 8 - i, d = size - i * step, on = n === hl;
    s += `<rect x="${cx - d / 2}" y="${cy - d / 2}" width="${d}" height="${d}" rx="${22 - i * 2}" fill="${i % 2 ? C.bg : C.box}" stroke="${on ? C.amber : C.teal}" stroke-width="${on ? 7 : 3}" opacity="${on ? 1 : hl ? 0.35 : 0.45 + i * 0.07}"/>`;
  }
  const a = size * 0.3 - step * 0.6;
  s += `<rect x="${cx - a / 2}" y="${cy - a / 2}" width="${a}" height="${a}" rx="12" fill="${C.amber}"/>`
    + t(cx, cy + a * 0.1, 'agent', a * 0.26, C.bg, mono, 700, 'text-anchor="middle"');
  return s;
}

const V = {
  title() {
    return frame(label('SAFE-OPS-AGENT-K8S · CAPSTONE')
      + t(X, 330, 'Defence in depth', 88, C.fg, sans, 700)
      + t(X, 450, 'for autonomous', 88, C.fg, sans, 700)
      + t(X, 570, 'infrastructure agents', 88, C.fg, sans, 700)
      + t(X, 690, 'One task traced through eight layers:', 44, C.muted)
      + t(X, 752, 'what each stops, and what it doesn’t.', 44, C.muted)
      + footer('github.com/billykong/safe-ops-agent-k8s')
      + rings(1610, 500, 440));
  },

  statement(v, b) {
    let s = label(v.label), y = 300;
    v.lines.forEach((l, i) => {
      const on = i < b.show, last = i === b.show - 1;
      for (const w of wrap(l, 1640, 56, 0.6)) { s += t(X, y, w, 56, on ? (last ? C.fg : C.muted) : C.grid, sans, 700); y += 78; }
      y += 34;
    });
    if (v.question && b.show > v.lines.length) {
      y += 20;
      s += `<rect x="${X}" y="${y - 50}" width="10" height="${wrap(v.question, 1600, 44).length * 62}" fill="${C.amber}"/>`;
      for (const w of wrap(v.question, 1600, 44)) { s += t(X + 40, y, w, 44, C.amber, sans, 700); y += 62; }
    }
    return frame(s);
  },

  cards(v, b) {
    let s = label(v.label) + t(X, 250, v.title, 64, C.fg, sans, 700);
    v.cards.forEach(([n, head, body], i) => {
      const x = X + (i % 2) * 840, y = 320 + Math.floor(i / 2) * 330, on = i < b.show, col = n === '!' ? C.amber : C.teal;
      s += `<rect x="${x}" y="${y}" width="800" height="290" rx="20" fill="${C.box}" stroke="${on ? col : C.edge}" stroke-width="${on ? 4 : 2}" opacity="${on ? 1 : 0.4}"/>`;
      if (!on) return;
      s += t(x + 44, y + 92, n, 64, col, mono, 700) + t(x + 120, y + 84, head, 34, C.fg, sans, 700);
      wrap(body, 700, 32).forEach((w, j) => { s += t(x + 44, y + 160 + j * 46, w, 32, C.muted); });
    });
    return frame(s);
  },

  arch(v, b) {
    const N = {
      op: [190, 540, 220, 'Operator', 'gives a task'],
      agent: [560, 540, 300, 'Agent worker', 'no keys, no writes'],
      sandbox: [1000, 250, 300, 'Sandbox pod', 'gVisor, no network'],
      llm: [1000, 410, 300, 'LLM gateway', 'API key, budgets'],
      mcp: [1000, 570, 300, 'MCP gateway', 'tool secrets, rules'],
      cr: [1000, 760, 300, 'ChangeRequest', 'a proposal'],
      model: [1440, 410, 300, 'AI model', ''],
      tools: [1440, 570, 300, 'Incident tracker', ''],
      ctl: [1440, 760, 300, 'Controller', 'no AI, writes'],
      wl: [1770, 760, 200, 'Workload', ''],
      human: [1440, 930, 300, 'Approver', 'hash-bound'],
      kill: [560, 760, 300, 'Kill switch', 'stops the agent'],
      obs: [560, 930, 300, 'Traces, audit', 'agent can’t write'],
    };
    const hl = new Set(b.hl || []), BH = 112;
    const side = (k, dir) => { const [x, y, w] = N[k]; return dir === 'r' ? [x + w / 2, y] : dir === 'l' ? [x - w / 2, y] : dir === 'u' ? [x, y - BH / 2] : [x, y + BH / 2]; };
    const edge = (a, ad, z, zd, dash = false) => {
      const [x1, y1] = side(a, ad), [x2, y2] = side(z, zd);
      const d = ad === 'r' || ad === 'l' ? (y1 === y2 ? `M${x1} ${y1}H${x2}` : `M${x1} ${y1}H${(x1 + x2) / 2}V${y2}H${x2}`) : `M${x1} ${y1}V${y2}`;
      return `<path d="${d}" fill="none" stroke="${C.dim}" stroke-width="3" ${dash ? 'stroke-dasharray="10 8"' : ''} marker-end="url(#ah)"/>`;
    };
    let s = label('THE ARCHITECTURE')
      + edge('op', 'r', 'agent', 'l') + edge('agent', 'r', 'sandbox', 'l') + edge('agent', 'r', 'llm', 'l') + edge('agent', 'r', 'mcp', 'l') + edge('agent', 'r', 'cr', 'l')
      + edge('llm', 'r', 'model', 'l') + edge('mcp', 'r', 'tools', 'l') + edge('ctl', 'l', 'cr', 'r') + edge('ctl', 'r', 'wl', 'l') + edge('human', 'u', 'ctl', 'd')
      + edge('kill', 'u', 'agent', 'd', true);
    for (const [k, [x, y, w, a, sub]] of Object.entries(N)) {
      const on = hl.has(k), col = on ? C.amber : k === 'agent' ? C.amber : C.teal, op = hl.size && !on ? 0.4 : 1;
      s += `<g opacity="${op}"><rect x="${x - w / 2}" y="${y - BH / 2}" width="${w}" height="${BH}" rx="16" fill="${C.box}" stroke="${col}" stroke-width="${on ? 5 : 3}"/>`
        + t(x, sub ? y - 4 : y + 10, a, 28, C.fg, mono, 700, 'text-anchor="middle"')
        + (sub ? t(x, y + 34, sub, 23, C.dim, sans, 400, 'text-anchor="middle"') : '') + '</g>';
    }
    return frame(s);
  },

  layer(v, b) {
    let s = label(`LAYER ${v.n} OF 8`);
    const title = wrap(v.title, 1120, 66, 0.62);
    title.forEach((w, i) => { s += t(X, 250 + i * 80, w, 66, C.fg, sans, 700); });
    let size = 34, items;
    // Shrink until the items fit above the footer.
    for (; size >= 26; size -= 2) {
      items = v.items.map(it => ({ ...it, lines: wrap(it.t, 1060, size) }));
      const h = items.reduce((a, it) => a + it.lines.length * size * 1.4 + (it.kind ? 44 : 0) + 30, 0);
      if (290 + title.length * 80 + h < 990) break;
    }
    let y = 290 + title.length * 80 + 20;
    items.forEach((it, i) => {
      if (i >= (b.show ?? items.length)) return;
      const cur = i === b.show - 1;
      if (it.kind) {
        const col = it.kind === 'stop' ? C.amber : C.teal;
        s += t(X, y, it.kind === 'stop' ? 'DOESN’T STOP' : 'HOW I KNOW', 24, col, mono, 700, 'letter-spacing="3"');
        y += 44;
      } else s += `<rect x="${X}" y="${y - size * 0.62}" width="14" height="14" rx="3" fill="${C.teal}"/>`;
      it.lines.forEach(w => { s += t(it.kind ? X : X + 36, y, w, size, cur ? C.fg : C.muted); y += size * 1.4; });
      y += 30;
    });
    return frame(s + rings(1580, 560, 480, v.n) + footer(LAYERS.map((_, i) => i + 1 === v.n ? '■' : '□').join(' ')));
  },

  terminal(v, b, cap, upto) {
    const lines = cap.slice(0, upto), rows = 22, shown = lines.slice(-rows);
    let s = label(v.label);
    s += `<rect x="${X}" y="200" width="${W - 2 * X}" height="800" rx="18" fill="${C.term}" stroke="${C.edge}" stroke-width="2"/>`
      + `<rect x="${X}" y="200" width="${W - 2 * X}" height="56" rx="18" fill="${C.box}"/><rect x="${X}" y="236" width="${W - 2 * X}" height="20" fill="${C.box}"/>`
      + [0, 1, 2].map(i => `<circle cx="${X + 36 + i * 30}" cy="228" r="9" fill="${[C.amber, C.dim, C.teal][i]}"/>`).join('')
      + t(W / 2, 237, `${cap.title} · recorded on the cluster`, 24, C.dim, mono, 400, 'text-anchor="middle"');
    shown.forEach((l, i) => {
      const col = /^\$ /.test(l) ? C.fg : /^(PASS|ok|✓)/.test(l) ? C.teal : /^(FAIL|OPEN|open)/.test(l) ? C.amber : /^(---|===)/.test(l) ? C.fg : C.muted;
      const bold = /^(\$ |---|===)/.test(l) ? 700 : 400;
      s += t(X + 36, 300 + i * 32, l.length > 104 ? l.slice(0, 103) + '…' : l, 24, col, mono, bold, 'xml:space="preserve"');
    });
    return frame(s);
  },

  table(v, b) {
    let s = label(v.label) + t(X, 250, 'Where each attack stops', 64, C.fg, sans, 700);
    s += t(X, 330, 'ATTACK', 24, C.dim, mono, 700, 'letter-spacing="3"') + t(1140, 330, 'STOPPED BY', 24, C.dim, mono, 700, 'letter-spacing="3"');
    v.rows.forEach(([a, by], i) => {
      if (i >= b.show) return;
      const y = 390 + i * 62, open = /^Nothing/.test(by);
      s += `<rect x="${X}" y="${y - 40}" width="${W - 2 * X}" height="54" rx="8" fill="${open ? '#3b2f12' : i % 2 ? C.bg : C.box}"/>`
        + t(X + 24, y, a, 30, C.fg) + t(1140, y, by, 30, open ? C.amber : C.teal, sans, 700);
    });
    return frame(s);
  },

  list(v, b) {
    let s = label(v.label) + t(X, 250, 'If you put an agent near infrastructure', 60, C.fg, sans, 700);
    v.items.forEach((it, i) => {
      if (i >= b.show) return;
      const y = 350 + i * 72, cur = i >= b.show - 3;
      s += `<rect x="${X}" y="${y - 40}" width="56" height="54" rx="10" fill="${cur ? C.amber : C.box}"/>`
        + t(X + 28, y - 2, i + 1, 32, cur ? C.bg : C.teal, mono, 700, 'text-anchor="middle"')
        + t(X + 88, y, it, 36, cur ? C.fg : C.muted);
    });
    return frame(s);
  },

  end() {
    const card = (y, k, v) => `<rect x="${X}" y="${y}" width="1100" height="130" rx="18" fill="${C.box}" stroke="${C.teal}" stroke-width="3"/>`
      + t(X + 40, y + 52, k, 26, C.teal, mono, 700, 'letter-spacing="3"') + t(X + 40, y + 100, v, 38, C.fg, mono, 700);
    return frame(label('THANKS FOR WATCHING')
      + t(X, 260, 'The code, the tests, the gaps', 72, C.fg, sans, 700)
      + card(340, 'CODE · MIT', 'github.com/billykong/safe-ops-agent-k8s')
      + card(510, 'WRITE-UP', 'billykong.github.io')
      + t(X, 760, 'Scripted from the write-up with AI and narrated with an AI voice.', 32, C.muted)
      + t(X, 808, 'All terminal output is from real runs on the cluster.', 32, C.muted)
      + rings(1600, 560, 400));
  },
};

// A capture is the real output of a run, trimmed: `#@ name` lines mark
// reveal points and aren't shown; `#title` names the window.
function loadCapture(name) {
  const raw = fs.readFileSync(path.join(__dirname, 'captures', `${name}.txt`), 'utf8').split('\n');
  const lines = [], marks = {};
  let title = name;
  for (const l of raw) {
    if (l.startsWith('#@ ')) marks[l.slice(3).trim()] = lines.length;
    else if (l.startsWith('#title ')) title = l.slice(7);
    else lines.push(l.replace(/\s+$/, ''));
  }
  while (lines.length && !lines[lines.length - 1]) lines.pop();
  marks.end = lines.length;
  lines.title = title;
  return { lines, marks };
}

function main() {
  const out = process.argv[2];
  const timings = JSON.parse(fs.readFileSync(path.join(out, 'timings.json'), 'utf8'));
  fs.mkdirSync(path.join(out, 'frames'), { recursive: true });
  const list = [];
  const png = (name, svg) => {
    const f = path.join(out, 'frames', `${name}.png`);
    fs.writeFileSync(f, new Resvg(svg, { font: { loadSystemFonts: true, defaultFontFamily: sans }, fitTo: { mode: 'width', value: W } }).render().asPng());
    return f;
  };
  for (const sc of scenes) {
    const cap = sc.visual.type === 'terminal' ? loadCapture(sc.visual.capture) : null;
    let from = 0;
    sc.beats.forEach((b, i) => {
      const id = `${sc.id}-${i}`, dur = timings[id];
      if (dur === undefined) throw new Error(`no timing for ${id}: run tts.py first`);
      if (!cap) { list.push([png(id, V[sc.visual.type](sc.visual, b)), dur]); return; }
      // Reveal the capture line by line across the beat, the last line
      // landing ~70% through so it can be read while the voice finishes.
      const to = cap.marks[b.show];
      if (to === undefined) throw new Error(`capture ${sc.visual.capture} has no mark ${b.show}`);
      const steps = Math.max(1, to - from), span = dur * 0.7;
      for (let k = 1; k <= steps; k++) {
        const upto = from + k, d = k < steps ? span / steps : dur - span * (steps - 1) / steps;
        list.push([png(`${id}-${String(k).padStart(3, '0')}`, V.terminal(sc.visual, b, Object.assign(cap.lines, { title: cap.lines.title }), upto)), d]);
      }
      from = to;
    });
  }
  // The concat demuxer needs the last file repeated to honour its duration.
  const txt = list.map(([f, d]) => `file '${f}'\nduration ${d.toFixed(3)}`).join('\n') + `\nfile '${list[list.length - 1][0]}'\n`;
  fs.writeFileSync(path.join(out, 'frames.txt'), txt);
  // YouTube's thumbnail: the title frame at 1280x720.
  fs.writeFileSync(path.join(out, 'thumbnail.png'), new Resvg(V.title(), { font: { loadSystemFonts: true, defaultFontFamily: sans }, fitTo: { mode: 'width', value: 1280 } }).render().asPng());
  console.log(`${list.length} frames, ${list.reduce((a, [, d]) => a + d, 0).toFixed(1)} s`);
}

if (require.main === module) main();
module.exports = { V, loadCapture };
