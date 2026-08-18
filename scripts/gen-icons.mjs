// Procedurally renders the BinderBooks app icon (a tilted holo-gradient
// trading card with a sparkle and ledger bars) and writes the two PNGs that
// survive: the browser favicon and the iOS app icon. Rerun after design tweaks:
//   node scripts/gen-icons.mjs
//
// It used to emit icon-192, icon-512 and apple-touch-icon as well. Those existed
// for the web app manifest and the home-screen install it enabled. GitHub Pages
// is back, but that install path is not: the hosted build is the desk half of
// the app, and the phone runs the real iOS app. Add them back here if the web
// build is ever meant to be installed to a home screen again.
import { deflateSync } from "node:zlib";
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const OUT = join(ROOT, "public");

/* ---------- tiny PNG encoder (8-bit RGBA, no filtering) ---------- */
const CRC_TABLE = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
const crc32 = (buf) => {
  let c = 0xffffffff;
  for (const b of buf) c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
};
const chunk = (type, data) => {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
};
function encodePNG(size, rgba) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0); ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; ihdr[9] = 6; // 8-bit RGBA
  const raw = Buffer.alloc(size * (size * 4 + 1));
  for (let y = 0; y < size; y++) rgba.copy(raw, y * (size * 4 + 1) + 1, y * size * 4, (y + 1) * size * 4);
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr), chunk("IDAT", deflateSync(raw, { level: 9 })), chunk("IEND", Buffer.alloc(0)),
  ]);
}

/* The same scene without an alpha channel — colour type 2 instead of 6.
   iOS REJECTS an app icon that carries alpha, and `render` already writes 255
   into every alpha byte, so dropping the channel loses nothing. */
function encodePNGOpaque(size, rgba) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0); ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; ihdr[9] = 2; // 8-bit truecolour, no alpha
  const raw = Buffer.alloc(size * (size * 3 + 1));
  for (let y = 0; y < size; y++) {
    const row = y * (size * 3 + 1) + 1;
    for (let x = 0; x < size; x++) {
      const s = (y * size + x) * 4, d = row + x * 3;
      raw[d] = rgba[s]; raw[d + 1] = rgba[s + 1]; raw[d + 2] = rgba[s + 2];
    }
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr), chunk("IDAT", deflateSync(raw, { level: 9 })), chunk("IEND", Buffer.alloc(0)),
  ]);
}

/* ---------- scene helpers (all coordinates in 1024-space) ---------- */
const clamp = (v, a, b) => (v < a ? a : v > b ? b : v);
const mix = (a, b, t) => a.map((c, i) => c + (b[i] - c) * t);
const hex = (s) => [1, 3, 5].map((i) => parseInt(s.slice(i, i + 2), 16));
const sdRoundRect = (x, y, hw, hh, r) => {
  const qx = Math.abs(x) - (hw - r), qy = Math.abs(y) - (hh - r);
  return Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - r;
};
const HOLO = ["#5ce1e6", "#a78bfa", "#ffd479", "#7cf5a0"].map(hex);
const holo = (t) => {
  t = clamp(t, 0, 1) * (HOLO.length - 1);
  const i = Math.min(Math.floor(t), HOLO.length - 2);
  return mix(HOLO[i], HOLO[i + 1], t - i);
};

const BG = hex("#0c0e13"), GLOW_BG = hex("#1d2433"), INNER = hex("#141821");
const BARS = [
  { v: 116, w: 300, color: hex("#3fd68c") },
  { v: 206, w: 204, color: hex("#ffb454") },
  { v: 296, w: 256, color: hex("#a78bfa") },
];
const CX = 512, CY = 532, HW = 270, HH = 372, RAD = 46;
const ROT = (-7 * Math.PI) / 180, COS = Math.cos(ROT), SIN = Math.sin(ROT);

function render(size) {
  const px = Buffer.alloc(size * size * 4);
  const scale = 1024 / size, aa = scale * 1.3;
  const over = (base, color, cov) => mix(base, color, clamp(cov, 0, 1));
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const gx = (x + 0.5) * scale, gy = (y + 0.5) * scale;
      // background with a soft glow up top
      let c = mix(BG, GLOW_BG, 0.55 * Math.exp(-((gx - 512) ** 2 + (gy - 170) ** 2) / (2 * 380 ** 2)));
      // card-local coordinates (inverse-rotated)
      const dx = gx - CX, dy = gy - CY;
      const u = COS * dx - SIN * dy, v = SIN * dx + COS * dy;
      // drop shadow
      c = over(c, [0, 0, 0], 0.5 * clamp(0.5 - sdRoundRect(u - 16, v - 24, HW, HH, RAD) / 70, 0, 1));
      // card body: diagonal holo gradient
      const card = clamp(0.5 - sdRoundRect(u, v, HW, HH, RAD) / aa, 0, 1);
      c = over(c, holo((u + HW + v + HH) / (2 * (HW + HH))), card);
      // dark interior
      const inner = clamp(0.5 - sdRoundRect(u, v, HW - 30, HH - 30, RAD - 20) / aa, 0, 1);
      c = over(c, INNER, inner);
      if (inner > 0) {
        // lavender glow behind the sparkle
        const rr = Math.hypot(u, v + 150);
        c = over(c, hex("#a78bfa"), inner * 0.32 * Math.exp(-((rr / 250) ** 2)));
        // four-point sparkles (concave diamond: |x|^p + |y|^p)
        for (const s of [{ sx: 0, sy: -150, r: 150 }, { sx: 124, sy: -262, r: 52 }]) {
          const f = (Math.abs(u - s.sx) / s.r) ** 0.55 + (Math.abs(v - s.sy) / s.r) ** 0.55 - 1;
          const cov = clamp(0.5 - (f * s.r * 0.35) / aa, 0, 1);
          const tint = mix(hex("#ffffff"), hex("#cfc3ff"), clamp(Math.hypot(u - s.sx, v - s.sy) / s.r, 0, 1));
          c = over(c, tint, cov * inner);
        }
        // ledger bars
        for (const b of BARS) {
          const bx = -HW + 78 + b.w / 2;
          const cov = clamp(0.5 - sdRoundRect(u - bx, v - b.v, b.w / 2, 21, 21) / aa, 0, 1);
          c = over(c, b.color, cov * inner);
        }
      }
      const i = (y * size + x) * 4;
      px[i] = Math.round(clamp(c[0], 0, 255));
      px[i + 1] = Math.round(clamp(c[1], 0, 255));
      px[i + 2] = Math.round(clamp(c[2], 0, 255));
      px[i + 3] = 255;
    }
  }
  return px;
}

mkdirSync(OUT, { recursive: true });
// A list of one, kept as a loop because it was a list of four and may be again.
for (const [name, size] of [["favicon-32.png", 32]]) {
  writeFileSync(join(OUT, name), encodePNG(size, render(size)));
  console.log(`wrote public/${name}`);
}

// The iOS app icon comes from this same scene, so the phone and the browser tab
// never drift apart. It renders natively at 1024 rather than upscaling a smaller
// copy — every coordinate above is already in 1024-space, so this is the
// resolution the artwork was drawn for.
const IOS_ICON = join(ROOT, "ios", "Resources", "Assets.xcassets", "AppIcon.appiconset", "icon-1024.png");
mkdirSync(dirname(IOS_ICON), { recursive: true });
writeFileSync(IOS_ICON, encodePNGOpaque(1024, render(1024)));
console.log("wrote ios/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png");
