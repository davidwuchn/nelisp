// dtw.js — the minimal browser shim for the P4a skeleton (Doc 164 §5.4).
// All game logic lives in dtw.wasm; JS only (a) forwards key LEVELS, (b) supplies
// performance.now, (c) drains the draw-op ring buffer to a Canvas2D each frame.
// Draw-op record ABI == p4-helpers.mjs: 96-byte records [op:u64, a0..a9:u64,
// textOff:u64(absolute)] + a NUL-terminated UTF-8 string blob in the same memory.
const RECORD_BYTES = 96;
const OP = { LOAD_IMAGE: 1, FILL_RECT: 2, SET_COLOR: 3, DRAW_IMAGE: 4, DRAW_TEXT: 5, SET_ALPHA: 6, SELECT_BUFFER: 7, PRESENT: 8 };
const canvas = document.getElementById('screen');
const ctx = canvas.getContext('2d');
ctx.imageSmoothingEnabled = false;
const dec = new TextDecoder('utf-8');
const keys = new Set();
const rgba = (n) => `rgba(${(n >>> 24) & 255},${(n >>> 16) & 255},${(n >>> 8) & 255},${(n & 255) / 255})`;

// ---- placeholder assets (P4b swaps these for real PNGs via the manifest) ------
function tile(id) {                                     // offscreen "image" per buffer id
  const c = document.createElement('canvas');
  const g = c.getContext('2d');
  if (id === 5) { c.width = c.height = 340; for (let y = 0; y < 340; y += 20) for (let x = 0; x < 340; x += 20) { g.fillStyle = ((x + y) / 20) % 2 ? '#1f6f43' : '#2a8a55'; g.fillRect(x, y, 20, 20); } }
  else { c.width = 160; c.height = 40; const cols = ['#e23', '#f52', '#e23', '#c41']; for (let i = 0; i < 4; i++) { g.fillStyle = cols[i]; g.fillRect(i * 40 + 6, 4, 28, 32); g.fillStyle = '#fff'; g.fillRect(i * 40 + 14, 12, 5, 5); g.fillRect(i * 40 + 22, 12, 5, 5); } }
  return c;
}
const images = { 3: tile(3), 5: tile(5) };
const KEYMAP = { ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39, ArrowDown: 40 };
addEventListener('keydown', (e) => { if (KEYMAP[e.key] !== undefined) { keys.add(KEYMAP[e.key]); e.preventDefault(); } });
addEventListener('keyup', (e) => { if (KEYMAP[e.key] !== undefined) { keys.delete(KEYMAP[e.key]); e.preventDefault(); } });

let mem, cstr;
function drain(ptr, count) {
  const dv = new DataView(mem.buffer);
  const u8 = new Uint8Array(mem.buffer);
  const rd = (b, l) => dv.getUint32(b + l * 8, true);
  cstr = (o) => { if (!o) return ''; let e = o; while (u8[e]) e++; return dec.decode(u8.subarray(o, e)); };
  for (let i = 0; i < count; i++) {
    const b = ptr + i * RECORD_BYTES, op = rd(b, 0), a = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].map((l) => rd(b, l)), t = cstr(rd(b, 11));
    if (op === OP.FILL_RECT) { ctx.fillStyle = rgba(a[4]); ctx.fillRect(a[0], a[1], a[2], a[3]); }
    else if (op === OP.DRAW_IMAGE) { const img = images[a[0]]; if (img) ctx.drawImage(img, a[5], a[6], a[7], a[8], a[1], a[2], a[3], a[4]); }
    else if (op === OP.DRAW_TEXT) { ctx.fillStyle = rgba(a[2]); ctx.font = '16px monospace'; ctx.textBaseline = 'top'; ctx.fillText(t, a[0], a[1]); }
    // LOAD_IMAGE / PRESENT / SELECT_BUFFER are no-ops for this single-buffer skeleton
  }
}
const imports = { env: { key_state: (c) => (keys.has(c) ? 1 : 0), now_ms: () => performance.now(), frame_out: (p, n) => drain(p, n) } };

WebAssembly.instantiateStreaming(fetch('dtw.wasm'), imports).then(({ instance }) => {
  mem = instance.exports.memory;
  instance.exports.init();
  const loop = () => { instance.exports.step(); requestAnimationFrame(loop); };
  requestAnimationFrame(loop);
});
