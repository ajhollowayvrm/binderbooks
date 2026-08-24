/* ==================================================================
   Card art on the device.

   Two stores, one database, because one warm pass has to fill both.

   `img` holds the picture bytes, keyed by URL. It existed before this
   module (it lived in App.jsx) and its reason has not changed: the OS
   evicts the browser's HTTP cache, WKWebView most of all, so a picture
   the app has already downloaded must not be downloaded again.

   `art` is new. It holds the URL itself, keyed by the card's identity.
   Without it the blob store was unreachable at startup: a card record
   carries no picture, so the app had to ask PPT which URL the card
   used before it could look the bytes up locally. That cost a
   /catalog or a /search call on every load, and it left every tile
   waiting on a network round trip for a fact the device already knew.

   `primeArt` reads both stores once, before the first paint. After it
   runs, a card that has been seen before paints from memory with no
   request of any kind.
   ================================================================== */

const IMG_DB = "binderbooks-images";
const IMG_VERSION = 2;                 // v2 adds the `art` store
const IMG_CAP = 500;                   // ~200px thumbs run 20-60KB; the cap keeps this near 15-25MB
const IMG_HOST_STRIKES = 3;

/* A card's identity, and the `art` store's key. lookupCardMatch in
   App.jsx keys its own cache the same way and imports this, so the two
   can never drift apart. */
export const artKey = (card) =>
  `${card.name}|${card.set || ""}|${card.number || ""}|${card.productId || ""}`.toLowerCase();

let imgDbP = null;
const imgDb = () => {
  if (!imgDbP) imgDbP = new Promise((res, rej) => {
    if (typeof indexedDB === "undefined") { rej(new Error("no indexedDB")); return; }
    const r = indexedDB.open(IMG_DB, IMG_VERSION);
    /* Guarded per store rather than written as a fresh-install branch: this
       runs both for a new device and for a v1 database that already holds
       hundreds of blobs, and the v1 upgrade must not drop them. */
    r.onupgradeneeded = () => {
      const db = r.result;
      if (!db.objectStoreNames.contains("img")) {
        const st = db.createObjectStore("img", { keyPath: "url" });
        st.createIndex("t", "t");
      }
      if (!db.objectStoreNames.contains("art")) db.createObjectStore("art", { keyPath: "key" });
    };
    r.onsuccess = () => res(r.result);
    r.onerror = () => rej(r.error);
    /* Another tab on the old version blocks the upgrade. Reject instead of
       hanging, so the app paints from the network rather than not at all. */
    r.onblocked = () => rej(new Error("blocked"));
  });
  return imgDbP;
};

// url -> Promise<objectURL|null>. One promise per url: every tile that asks
// while a fetch runs awaits the same result, so nothing is fetched twice and
// no tile is left on the network copy. The object URLs live for the session
// on purpose — they are the cache — so they are never revoked.
const imgMem = new Map();
const imgReady = new Map(); // url -> objectURL, for a synchronous first render
const artIndex = new Map(); // artKey -> { url, rarity, pinned }
const hostStrikes = new Map(); // host -> consecutive failures
const hostOf = (u) => { try { return new URL(u).host; } catch { return ""; } };
const idbReq = (req) => new Promise((res, rej) => { req.onsuccess = () => res(req.result); req.onerror = () => rej(req.error); });

// FadeImg reads this to paint on its very first render, with no effect and
// no await. An empty answer means "not warmed", never "no picture".
export const readyURL = (url) => imgReady.get(url);

async function idbGet(url) {
  try { const db = await imgDb(); return await idbReq(db.transaction("img").objectStore("img").get(url)); } catch { return null; }
}
async function idbPut(url, blob) {
  try {
    const db = await imgDb();
    await idbReq(db.transaction("img", "readwrite").objectStore("img").put({ url, blob, t: Date.now() }));
    // eviction in its own transaction: an awaited request inside the put
    // transaction auto-commits it on older WebKit
    const st = db.transaction("img", "readwrite").objectStore("img");
    const cnt = await idbReq(st.count());
    if (cnt > IMG_CAP) {
      let drop = cnt - IMG_CAP;
      st.index("t").openCursor().onsuccess = (e) => { const cur = e.target.result; if (cur && drop-- > 0) { cur.delete(); cur.continue(); } };
    }
  } catch {} // a full or locked store loses one blob, never the image
}

/* Storing a blob needs a readable cross-origin response. Every art URL the
   Lambda serves today is PPT's imageCdnUrl200 on tcgplayer-cdn.tcgplayer.com,
   which allows one. A host that fails IMG_HOST_STRIKES times in a row is not
   fetched again this session. Its art then renders straight from the URL.
   One success clears the count, so a dropped connection does not disable
   the cache for the rest of the session. */
export function cachedImageURL(url) {
  if (!url || !/^https?:/.test(url)) return Promise.resolve(null);
  if (imgMem.has(url)) return imgMem.get(url);
  const p = (async () => {
    const rec = await idbGet(url);
    if (rec?.blob) { const o = URL.createObjectURL(rec.blob); imgReady.set(url, o); return o; }
    const host = hostOf(url);
    if ((hostStrikes.get(host) || 0) >= IMG_HOST_STRIKES) return null;
    try {
      const r = await fetch(url, { mode: "cors" });
      if (!r.ok) throw new Error(String(r.status));
      const blob = await r.blob();
      const o = URL.createObjectURL(blob);
      imgReady.set(url, o);
      hostStrikes.delete(host);
      idbPut(url, blob); // not awaited: the tile shows now, the store fills behind it
      return o;
    } catch {
      // a CORS refusal and a dead network look the same from here; the strike
      // count tells them apart over a few tries
      hostStrikes.set(host, (hostStrikes.get(host) || 0) + 1);
      return null;
    }
  })();
  imgMem.set(url, p);
  p.then((o) => { if (!o) imgMem.delete(url); }); // a miss may retry on the next mount
  return p;
}

/* ------------------------------------------------------------------ */
/* The art index                                                       */
/* ------------------------------------------------------------------ */
/* What one card resolved to last time, read with no await. The binder
   seeds its state from this, so the grid's first render already holds
   every URL it needs. */
export const artFor = (card) => (card?.name ? artIndex.get(artKey(card)) : undefined);

/* Remember what a card resolved to. `pinned` marks a picture the user
   chose by hand in the art picker. A later automatic lookup never
   overwrites one — that choice is the whole point of the picker. */
export function pinArt(card, url, rarity = "", pinned = false) {
  if (!card?.name || !url) return;
  const key = artKey(card);
  const cur = artIndex.get(key);
  if (cur?.pinned && !pinned) return;
  if (cur && cur.url === url && cur.rarity === (rarity || cur.rarity) && cur.pinned === (pinned || cur.pinned)) return;
  const rec = { key, url, rarity: rarity || cur?.rarity || "", pinned: pinned || !!cur?.pinned, t: Date.now() };
  artIndex.set(key, { url: rec.url, rarity: rec.rarity, pinned: rec.pinned });
  imgDb().then((db) => { db.transaction("art", "readwrite").objectStore("art").put(rec); }).catch(() => {});
}

/* Forget one card's picture. The picker calls this on the old identity
   before it pins the new one, so choosing an art never leaves an
   orphaned row behind. */
export function unpinArt(card) {
  if (!card?.name) return;
  const key = artKey(card);
  artIndex.delete(key);
  imgDb().then((db) => { db.transaction("art", "readwrite").objectStore("art").delete(key); }).catch(() => {});
}

/* One read of both stores, before the ledger renders. Every request goes
   out before the first await, because a readonly transaction commits as
   soon as its queue empties — the same rule catalogRowsForSets follows in
   catalog.js. Blobs are read only for the URLs this ledger actually uses;
   getAll() on `img` would pull 500 blobs, tens of megabytes, into memory.

   Every failure here is silent and harmless. A device with no IndexedDB,
   or a blocked upgrade, simply paints the way it did before: resolve, then
   fetch. */
export async function primeArt(cards) {
  if (!Array.isArray(cards) || !cards.length) return;
  let db;
  try { db = await imgDb(); } catch { return; }

  const keys = [...new Set(cards.filter((c) => c?.name).map(artKey))];
  if (!keys.length) return;
  let rows;
  try {
    const st = db.transaction("art", "readonly").objectStore("art");
    rows = await Promise.all(keys.map((k) => idbReq(st.get(k))));
  } catch { return; }

  const urls = new Set();
  for (const rec of rows) {
    if (!rec?.url) continue;
    artIndex.set(rec.key, { url: rec.url, rarity: rec.rarity || "", pinned: !!rec.pinned });
    urls.add(rec.url);
  }
  if (!urls.size) return;

  let blobs;
  try {
    const st = db.transaction("img", "readonly").objectStore("img");
    blobs = await Promise.all([...urls].map((u) => idbReq(st.get(u))));
  } catch { return; }

  for (const rec of blobs) {
    if (!rec?.blob || imgReady.has(rec.url)) continue;
    const o = URL.createObjectURL(rec.blob);
    imgReady.set(rec.url, o);
    // seed the request map too, so a tile that asks later never re-reads the
    // store for bytes this pass already holds
    imgMem.set(rec.url, Promise.resolve(o));
  }
}
