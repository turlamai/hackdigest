// Generates the app icon (1024x1024 PNG) with a hand-rolled PNG encoder.
// Run: node scripts/gen-icon.mjs  → writes assets/icon-1024.png.

import { deflateSync } from 'node:zlib';
import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const SIZE = 1024;

// --- PNG encoding ---
const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (const b of buf) c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}

function encodePNG(rgba, w, h) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // RGBA
  const raw = Buffer.alloc(h * (1 + w * 4));
  for (let y = 0; y < h; y++) {
    raw[y * (1 + w * 4)] = 0; // filter: none
    rgba.copy(raw, y * (1 + w * 4) + 1, y * w * 4, (y + 1) * w * 4);
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

// --- Signed distance helpers (1px soft edges) ---
function roundedRectSDF(x, y, cx, cy, hw, hh, r) {
  const qx = Math.abs(x - cx) - (hw - r);
  const qy = Math.abs(y - cy) - (hh - r);
  const ax = Math.max(qx, 0);
  const ay = Math.max(qy, 0);
  return Math.min(Math.max(qx, qy), 0) + Math.hypot(ax, ay) - r;
}

function rectCover(x, y, cx, cy, hw, hh) {
  return Math.abs(x - cx) <= hw && Math.abs(y - cy) <= hh;
}

const soft = (sdf) => Math.min(1, Math.max(0, -sdf));

// --- Palette ---
const BG = [217, 83, 30]; // #D9531E HN-ish orange
const FG = [255, 255, 255];

const img = Buffer.alloc(SIZE * SIZE * 4);

for (let y = 0; y < SIZE; y++) {
  for (let x = 0; x < SIZE; x++) {
    const px = x + 0.5;
    const py = y + 0.5;
    let r = 0;
    let g = 0;
    let b = 0;
    let a = 0;

    const plate = soft(roundedRectSDF(px, py, 512, 512, 472, 472, 224));
    if (plate > 0) {
      // "H" glyph from three bars (with soft edges via small SDFs on rects):
      const bars = [
        [388, 510, 62, 236],
        [636, 510, 62, 236],
        [512, 510, 124, 40],
      ];
      let glyph = 0;
      for (const [cx, cy, hw, hh] of bars) {
        // 1px soft edge: distance to nearest rect edge
        const dx = Math.abs(px - cx) - hw;
        const dy = Math.abs(py - cy) - hh;
        const d = Math.max(dx, dy);
        glyph = Math.max(glyph, soft(d));
      }
      r = BG[0] * (1 - glyph) + FG[0] * glyph;
      g = BG[1] * (1 - glyph) + FG[1] * glyph;
      b = BG[2] * (1 - glyph) + FG[2] * glyph;
      a = plate * 255;
    }

    const i = (y * SIZE + x) * 4;
    img[i] = Math.round(r);
    img[i + 1] = Math.round(g);
    img[i + 2] = Math.round(b);
    img[i + 3] = Math.round(a);
  }
}

const out = join(dirname(fileURLToPath(import.meta.url)), '..', 'assets', 'icon-1024.png');
writeFileSync(out, encodePNG(img, SIZE, SIZE));
console.log('wrote', out);
