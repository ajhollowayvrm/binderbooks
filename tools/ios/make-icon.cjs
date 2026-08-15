#!/usr/bin/env node
/* Generate the iOS app icon: a 1024x1024 PNG written by hand (zlib is the only dependency, and it
   ships with node) so the repo needs no image toolchain.

   The mark is what the app is, in two ideas at once: three card sleeves standing side by side, and
   their ascending heights reading as a P&L bar chart. The tallest is --pos green, because the point
   of the ledger is the profit line. It has to read at 60px on a home screen, so the shapes are
   thick, the gaps are wide and there is no type.

   iOS app icons must NOT carry an alpha channel, hence PNG colour type 2 (truecolour, no alpha).

   The .cjs extension is load-bearing: package.json declares "type": "module", so a .js file here
   would be treated as ESM and the requires below would throw.

     node tools/ios/make-icon.cjs     (or: npm run ios:icon)
*/
const fs = require('fs'), path = require('path'), zlib = require('zlib');

const SIZE = 1024;
const BG    = [0x0c, 0x0e, 0x13];   // --bg
const SURF  = [0x2a, 0x31, 0x40];   // --line, the quiet sleeve
const VIOLET= [0xa7, 0x8b, 0xfa];   // the tab accent
const GREEN = [0x3f, 0xd6, 0x8c];   // --pos, the profit line

const OUT = path.join(__dirname, '..', '..', 'ios', 'Resources', 'Assets.xcassets',
                      'AppIcon.appiconset', 'icon-1024.png');

// ---- the image ----------------------------------------------------------------
const px = Buffer.alloc(SIZE * SIZE * 3);
const set = (x, y, c) => { const i = (y * SIZE + x) * 3; px[i] = c[0]; px[i + 1] = c[1]; px[i + 2] = c[2]; };

for (let y = 0; y < SIZE; y++) for (let x = 0; x < SIZE; x++) set(x, y, BG);

/* A rounded rectangle, filled. The corner test is a plain distance check against the centre of each
   corner's radius circle — no anti-aliasing beyond a 2px soft edge, which is all the icon needs at
   the sizes iOS actually draws it. */
const roundRect = (x0, y0, w, h, r, c) => {
  for (let y = y0; y < y0 + h; y++) {
    for (let x = x0; x < x0 + w; x++) {
      const dx = x < x0 + r ? x0 + r - x : x > x0 + w - 1 - r ? x - (x0 + w - 1 - r) : 0;
      const dy = y < y0 + r ? y0 + r - y : y > y0 + h - 1 - r ? y - (y0 + h - 1 - r) : 0;
      if (dx === 0 || dy === 0) { set(x, y, c); continue; }
      const d = Math.sqrt(dx * dx + dy * dy);
      if (d <= r - 1) { set(x, y, c); continue; }
      if (d <= r) {                                  // one-pixel feathered edge
        const t = r - d;
        set(x, y, c.map((ch, i) => Math.round(BG[i] + (ch - BG[i]) * t)));
      }
    }
  }
};

/* Three sleeves, bottom-aligned, ascending. Kept well inboard of the edges: iOS masks the icon to a
   squircle, and a shape hugging the side gets clipped diagonally at the corners, which reads as a
   mistake rather than as a design. */
const BASE = 812;                 // shared bottom edge
const W = 176, GAP = 52, R = 34;
const HEIGHTS = [332, 456, 596];
const COLORS  = [SURF, VIOLET, GREEN];
const left = Math.round((SIZE - (W * 3 + GAP * 2)) / 2);

HEIGHTS.forEach((h, i) => {
  roundRect(left + i * (W + GAP), BASE - h, W, h, R, COLORS[i]);
});

// ---- PNG container ------------------------------------------------------------
const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();
const crc32 = buf => {
  let c = -1;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
};
const chunk = (type, data) => {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
};

const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(SIZE, 0); ihdr.writeUInt32BE(SIZE, 4);
ihdr[8] = 8;    // bit depth
ihdr[9] = 2;    // colour type 2 = truecolour, NO alpha (iOS requirement)
ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;   // deflate / adaptive filtering / no interlace

// Each scanline is prefixed with its filter byte; 0 = None, which compresses fine on flat colour.
const raw = Buffer.alloc(SIZE * (SIZE * 3 + 1));
for (let y = 0; y < SIZE; y++) {
  raw[y * (SIZE * 3 + 1)] = 0;
  px.copy(raw, y * (SIZE * 3 + 1) + 1, y * SIZE * 3, (y + 1) * SIZE * 3);
}

const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  chunk('IHDR', ihdr),
  chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
  chunk('IEND', Buffer.alloc(0)),
]);

fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, png);
console.log(`${path.relative(path.join(__dirname, '..', '..'), OUT)} — ${SIZE}x${SIZE}, ${(png.length / 1024).toFixed(1)}KB`);
