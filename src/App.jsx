import React, { useState, useEffect, useCallback, useMemo, useRef } from "react";
import Papa from "papaparse";
import {
  LayoutDashboard, PackageOpen, ShoppingCart, Tags, Search, Archive,
  Plus, Trash2, Pencil, ChevronDown, ChevronRight, Sparkles, Upload, X,
  CalendarRange, ChevronLeft, RefreshCw, ExternalLink, Camera, Library,
  LayoutGrid,
} from "lucide-react";
import {
  CSV_COLUMNS, importCatalogFile, catalogSets, catalogStats, searchCatalog,
  getCatalogRecords, catalogRowsForSets, recordToRow, clearCatalog,
} from "./catalog.js";
import { SET_CODES } from "./setCodes.js";
import BuyRow from "./components/BuyRow.jsx";
import InventoryRow from "./components/InventoryRow.jsx";
import SaleRow from "./components/SaleRow.jsx";
import RipCard from "./components/RipCard.jsx";
import BinderCard from "./components/BinderCard.jsx";

/* ------------------------------------------------------------------ */
/* hosted-app glue: localStorage persistence                           */
/* ------------------------------------------------------------------ */
const storage = {
  get: async (k) => { try { const v = localStorage.getItem(k); return v == null ? null : { key: k, value: v }; } catch { return null; } },
  set: async (k, v) => { try { localStorage.setItem(k, v); } catch (e) { /* quota / private mode */ } return { key: k, value: v }; },
};

/* cloud sync: API Gateway -> Lambda -> DynamoDB (see aws/index.mjs).
   The URL is public but useless without the secret token, which lives
   only in localStorage after you paste it once per device. */
const SYNC_URL = "https://j18dixq7ei.execute-api.us-west-2.amazonaws.com/";
const TOKEN_KEY = "cardledger:syncToken";
const STAMP_KEY = "cardledger:updatedAt";
// magic-link setup: opening the app with #sync=<token> installs the token on
// this device and scrubs it from the URL — new devices are one tap, no paste.
// The fragment never leaves the browser (not sent to servers or logged).
try {
  const m = location.hash.match(/[#&]sync=([\w-]+)/);
  if (m) {
    // flag a token this device didn't have before, so the app can ask which
    // ledger wins instead of letting timestamps decide silently
    if (localStorage.getItem("cardledger:syncToken") !== m[1]) sessionStorage.setItem("cardledger:fresh", "1");
    localStorage.setItem("cardledger:syncToken", m[1]);
    history.replaceState(null, "", location.pathname + location.search);
  }
} catch {}
const syncToken = () => { try { return localStorage.getItem(TOKEN_KEY) || ""; } catch { return ""; } };
const setSyncTokenLS = (t) => { try { t ? localStorage.setItem(TOKEN_KEY, t) : localStorage.removeItem(TOKEN_KEY); } catch {} };
const localStamp = () => { try { return Number(localStorage.getItem(STAMP_KEY)) || 0; } catch { return 0; } };
const setLocalStamp = (t) => { try { localStorage.setItem(STAMP_KEY, String(t)); } catch {} };
/* A mobile network can hold a request open with no reply and no error. A radio
   that wakes up, a captive portal, or an app that resumes from suspend all cause
   this. Each sync call uses a hard timeout. A stalled request then fails, and
   the app recovers from the failure. */
const SYNC_TIMEOUT = 12000;
const syncFetch = async (method, body, since) => {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), SYNC_TIMEOUT);
  try {
    const r = await fetch(since ? `${SYNC_URL}?since=${since}` : SYNC_URL, {
      method,
      headers: { "x-sync-token": syncToken(), ...(body ? { "content-type": "application/json" } : {}) },
      body: body ? JSON.stringify(body) : undefined,
      signal: ctl.signal,
    });
    if (r.status === 404) return null;
    if (r.status === 204) return { unchanged: true }; // server: you already have the latest
    const j = await r.json().catch(() => ({}));
    if (!r.ok) { const e = new Error(j.error || `HTTP ${r.status}`); e.status = r.status; throw e; }
    return j;
  } finally { clearTimeout(t); }
};
/* Every card fact — search, prices, images, comps, history — comes through
   the Lambda's PPT-backed routes, and every one of them sits behind the sync
   token because they spend metered credits. No token means no network call at
   all: the thrown 401 is what lets each caller show "connect sync" instead of
   burning a request that can only fail. */
const NO_TOKEN_MSG = "Connect cloud sync (Overview → Cloud sync) to search the card database and pull prices.";
async function cardFetch(path, params = {}) {
  const token = syncToken();
  if (!token) { const e = new Error(NO_TOKEN_MSG); e.status = 401; throw e; }
  const qs = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) if (v != null && v !== "") qs.set(k, v);
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), SYNC_TIMEOUT);
  try {
    const r = await fetch(`${SYNC_URL}${path}${qs.size ? `?${qs}` : ""}`, { headers: { "x-sync-token": token }, signal: ctl.signal });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) { const e = new Error(j.error || `HTTP ${r.status}`); e.status = r.status; throw e; }
    return j;
  } finally { clearTimeout(t); }
}

/* ------------------------------------------------------------------ */
const KEY = "cardledger:v1";
const uid = () => Math.random().toString(36).slice(2, 10);

/* set list for the structured buy form — the Lambda's /sets route (PPT's
   catalogue with the "SV07:"-style prefixes stripped), cached for a week so
   the dropdown opens instantly. The printed expansion codes the scanner
   resolves ("PRE" -> "Prismatic Evolutions") live in src/setCodes.js now —
   PPT's set list doesn't carry them. */
const SETS_KEY = "cardledger:sets:v3"; // v3: PPT names, no ptcgoCode
let setsPromise = null;
async function fetchSets() {
  const data = await cardFetch("sets", {});
  const names = [...new Set(data.names || [])];
  if (!names.length) throw new Error("empty");
  try { localStorage.setItem(SETS_KEY, JSON.stringify({ t: Date.now(), names })); } catch {}
  return { names };
}
/* card-search cache: query -> slimmed results, 24h TTL, ~30 most recent
   queries kept. Repeat searches are instant and rate-limit failures drop. */
const QCACHE_KEY = "cardledger:qcache:v3"; // v3: keyed by raw text, PPT-sourced rows
const QCACHE_TTL = 24 * 3600 * 1000;
const cachedSets = () => { try { const c = JSON.parse(localStorage.getItem(SETS_KEY)); return c?.names || null; } catch { return null; } };
// words that describe a variant, not a card name — "ampharos full art" should
// search name:*ampharos* and float Illustration/Ultra Rares, not find nothing
const SEARCH_STOP = new Set(["full", "art", "fullart", "alt", "illustration", "special", "secret", "rainbow", "hyper", "holo", "reverse", "foil", "textured", "sir", "ir", "promo"]);
const DESC_RARITY = { full: ["illustration", "ultra", "full"], art: ["illustration", "ultra", "full"], fullart: ["illustration", "ultra", "full"], alt: ["illustration"], illustration: ["illustration"], special: ["special"], sir: ["special illustration"], ir: ["illustration"], secret: ["secret", "hyper"], rainbow: ["rainbow", "hyper"], hyper: ["hyper"], holo: ["holo"], reverse: ["reverse"], foil: ["holo"], textured: ["special illustration"], promo: ["promo"] };
/* PPT's search is fuzzy over plain words, so nothing here becomes query
   syntax — this only reads intent out of the text: a set name becomes the
   /search set filter, a collector number becomes the number filter, and
   variant words ("full art") become sort hints rather than name terms. */
const parseQuery = (q) => {
  const sets = cachedSets();
  // "143/190" printed on a card means card 143 — the denominator is set size
  let tokens = q.replace(/(\d+)\s*\/\s*\d+/g, "$1").replace(/[^\w\s-]/g, " ").trim().split(/\s+/).filter(Boolean);
  // a set name in the query becomes a set filter ("ampharos chaos rising")
  let setFilter = null;
  if (sets?.length) {
    const lower = tokens.map((t) => t.toLowerCase());
    outer:
    for (let len = Math.min(4, tokens.length); len >= 1; len--) {
      for (let i = 0; i + len <= tokens.length; i++) {
        const phrase = lower.slice(i, i + len).join(" ");
        const exact = sets.find((s) => s.toLowerCase() === phrase);
        const partial = len >= 2 ? sets.filter((s) => s.toLowerCase().includes(phrase)) : [];
        const hit = exact || (partial.length === 1 ? partial[0] : null);
        if (hit) { setFilter = hit; tokens = tokens.filter((_, k) => k < i || k >= i + len); break outer; }
      }
    }
  }
  // a collector number becomes a number filter ("dedenne 143", "TG12") — as a
  // name term it matches nothing. Set matching ran first on purpose: "mew 151"
  // is the set named 151, not card #151.
  let number = null;
  tokens = tokens.filter((t) => {
    if (!number && /^(?:\d{1,3}|(?:tg|gg|rc|sv|swsh|sm|xy|bw|dp|hgss|cc)\d{1,3})[a-z]?$/i.test(t)) { number = t; return false; }
    return true;
  });
  const descriptors = [...new Set(tokens.filter((t) => SEARCH_STOP.has(t.toLowerCase())).map((t) => t.toLowerCase()))];
  const nameTokens = tokens.filter((t) => !SEARCH_STOP.has(t.toLowerCase()));
  return {
    q: nameTokens.join(" ") || q.trim(),
    set: setFilter || "",
    number: number ? number.replace(/^0+(?=\w)/, "").toUpperCase() : "",
    descriptors, first: (nameTokens[0] || "").toLowerCase(),
  };
};
/* one thin door to the Lambda's /search — raw text in, legacy-shaped slim
   cards out. The retry without the set filter lives server-side. */
async function searchCards({ q, set = "", number = "", lang = "en" }) {
  const j = await cardFetch("search", { q, set, number, lang: lang === "jp" ? "jp" : "" });
  return j.cards || [];
}
const qcacheRead = () => { try { return JSON.parse(localStorage.getItem(QCACHE_KEY)) || {}; } catch { return {}; } };
const qcacheGet = (terms) => { const c = qcacheRead()[terms]; return c && Date.now() - c.t < QCACHE_TTL ? c.r : null; };
const qcacheSet = (terms, results) => {
  try {
    const all = qcacheRead();
    all[terms] = { t: Date.now(), r: results };
    Object.keys(all).sort((a, b) => all[b].t - all[a].t).slice(30).forEach((k) => delete all[k]);
    localStorage.setItem(QCACHE_KEY, JSON.stringify(all));
  } catch {}
};
/* set prices: one { cardNumber: { printing: market } } map per set from the
   Lambda's PPT-backed /prices route. */
const SETPRICE_KEY = "cardledger:setprices:v2"; // v2: entries are per-printing maps, not scalars
const normNum = (s) => String(s || "").split("/")[0].trim().replace(/^0+(?=\w)/, "").toUpperCase();

/* printings. A card's reverse holo can be worth several times its normal
   printing, so which one a ledger card is decides what it's worth. TCGplayer
   (so PPT) names them one way and the price blocks key them another, hence
   the two tables. */
const VARIANTS = ["Normal", "Holofoil", "Reverse Holofoil"];
const PTCG_VARIANT_KEY = { "Normal": "normal", "Holofoil": "holofoil", "Reverse Holofoil": "reverseHolofoil" };
// list rows are tight on a phone — "Reverse Holofoil" doesn't fit next to a
// status and a grade chip
export const VARIANT_SHORT = { "Normal": "Normal", "Holofoil": "Holo", "Reverse Holofoil": "Reverse" };
// preference order per printing. The "" row is the Lambda's own collapse, so a
// card with no variant set prices exactly as it did before variants existed;
// the fallbacks keep Normal-only cards working when asked for a holo.
const SUB_ORDER = {
  "Normal": ["Normal", "Holofoil", "Reverse Holofoil"],
  "Holofoil": ["Holofoil", "Normal", "Reverse Holofoil"],
  "Reverse Holofoil": ["Reverse Holofoil", "Holofoil", "Normal"],
  "": ["Normal", "Holofoil", "Reverse Holofoil"],
};
// one printing's market price out of a /prices `subs` entry. Always a number
// or null — never an object. That guard matters more than the fallback chain:
// this value goes straight into a card's `value`, which then syncs, so an
// object here would zero out inventory on every device.
const subPrice = (entry, variant) => {
  if (entry == null) return null;
  if (typeof entry === "number") return entry; // scalar `prices`, or a v1 cache entry
  if (typeof entry !== "object") return null;
  for (const k of SUB_ORDER[variant] || SUB_ORDER[""]) if (typeof entry[k] === "number") return entry[k];
  // vintage subtypes ("1st Edition Holofoil", "Unlimited") match no row above
  const any = Object.values(entry).find((v) => typeof v === "number");
  return any ?? null;
};
const setPricesGet = (set) => { try { const c = (JSON.parse(localStorage.getItem(SETPRICE_KEY)) || {})[set]; return c && Date.now() - c.t < 24 * 3600 * 1000 ? c.p : null; } catch { return null; } };
const setPricesPut = (set, p) => {
  try {
    const all = JSON.parse(localStorage.getItem(SETPRICE_KEY)) || {};
    all[set] = { t: Date.now(), p };
    const keys = Object.keys(all);
    if (keys.length > 12) keys.sort((a, b) => all[a].t - all[b].t).slice(0, keys.length - 12).forEach((k) => delete all[k]);
    localStorage.setItem(SETPRICE_KEY, JSON.stringify(all));
  } catch {}
};
// one { cardNumber: { printing: market } } map per set from the Lambda's
// /prices route — read through subPrice, never directly. `force` skips the
// 24h client cache (explicit refreshes want today's prices) but still falls
// back to it if the network call fails. Falls back to the flat `prices` map
// so a client that ships ahead of the Lambda still prices cards.
async function fetchSetPrices(setName, force = false, lang = "en") {
  const key = lang === "jp" ? `${setName}|jp` : setName;
  if (!force) { const m = setPricesGet(key); if (m) return m; }
  try {
    const j = await cardFetch("prices", { set: setName, lang: lang === "jp" ? "jp" : "" });
    const m = j.subs || j.prices || {};
    setPricesPut(key, m);
    return m;
  } catch { return setPricesGet(key); }
}
/* Whole-set catalogs from the Lambda's /catalog route — every card's name,
   number, printing prices, thumbnail and PPT product id in one call, so a
   set's images cost one request total instead of one per card. Images never
   change once a card is printed, so the cache lives a month; prices inside
   go stale but this cache is only ever read for images and identity. */
const SETCATALOG_KEY = "cardledger:setcatalog:v1";
const SETCATALOG_TTL = 30 * 24 * 3600 * 1000;
const setCatalogGet = (key) => { try { const c = (JSON.parse(localStorage.getItem(SETCATALOG_KEY)) || {})[key]; return c && Date.now() - c.t < SETCATALOG_TTL ? c.l : null; } catch { return null; } };
const setCatalogPut = (key, list) => {
  try {
    const all = JSON.parse(localStorage.getItem(SETCATALOG_KEY)) || {};
    all[key] = { t: Date.now(), l: list };
    const keys = Object.keys(all);
    if (keys.length > 10) keys.sort((a, b) => all[a].t - all[b].t).slice(0, keys.length - 10).forEach((k) => delete all[k]);
    localStorage.setItem(SETCATALOG_KEY, JSON.stringify(all));
  } catch {}
};
const setCatalogInFlight = new Map(); // dedupes concurrent fetches for the same set
function fetchSetCatalog(setName, lang = "en") {
  const key = lang === "jp" ? `${setName}|jp` : setName;
  const cached = setCatalogGet(key);
  if (cached) return Promise.resolve(cached);
  if (setCatalogInFlight.has(key)) return setCatalogInFlight.get(key);
  const p = cardFetch("catalog", { set: setName, lang: lang === "jp" ? "jp" : "" })
    .then((j) => {
      const list = j.cards || [];
      setCatalogPut(key, list);
      return list;
    })
    .catch(() => [])
    .finally(() => setCatalogInFlight.delete(key));
  setCatalogInFlight.set(key, p);
  return p;
}
// catalog rows carry TCGplayer product names ("Pikachu - 058/102 (Pokemon
// Center Exclusive)") — compare with the number tail and qualifiers stripped
const bareName = (s) => String(s || "").replace(/ - [\w/.]+/g, "").replace(/\s*\([^)]*\)/g, "").toLowerCase().trim();
const imageInSet = (list, card) => (list && (
  (card.number && list.find((c) => normNum(c.num) === normNum(card.number))) ||
  list.find((c) => bareName(c.name) === bareName(card.name))
)) || null;
// a /prices per-printing map as price blocks in the app's card shape. This used to
// force every price under `holofoil` regardless of its real subtype, which
// left a card's displayed price unrelated to the printing it came from.
const subsToPrices = (e) => {
  if (e == null) return null;
  const prices = {};
  if (typeof e === "number") prices.holofoil = { market: e };
  else for (const [k, v] of Object.entries(e)) {
    const pk = PTCG_VARIANT_KEY[k];
    if (pk && typeof v === "number") prices[pk] = { market: v };
  }
  // vintage subtypes ("1st Edition Holofoil") map to no key above — fall back
  // to the single-price shape rather than dropping the card's price entirely
  if (!Object.keys(prices).length) { const v = subPrice(e, ""); if (v != null) prices.holofoil = { market: v }; }
  return Object.keys(prices).length ? prices : null;
};
/* a /catalog product as a search-result-shaped card, so the Lookup result
   list, the scanner, and the three add-paths all handle one shape. `set`
   stays the ledger's own name for the set, not TCGplayer's group name, so a
   later price refresh on the kept card resolves the same way. */
const catalogCard = (group, p, setName) => {
  const prices = subsToPrices(p.subs ?? p.market);
  return {
    id: `tcgp-${group}-${p.num}-${p.name}`,
    productId: p.productId || "",
    name: p.name.replace(/ - [\w/.]+$/, ""),
    number: p.num, rarity: p.rarity, set: { name: setName },
    images: { small: p.img || null },
    ...(prices ? { tcgplayer: { prices } } : {}),
  };
};
// a set name as read off a card -> the ledger's own name for it. Exact first,
// then a unique substring either way round ("Chaos Rising" vs "ME04: Chaos
// Rising"). Ambiguous matches are refused rather than guessed.
const matchSetName = (text, sets) => {
  const t = String(text || "").toLowerCase().trim();
  if (!t || !sets?.length) return null;
  const exact = sets.find((s) => s.toLowerCase() === t);
  if (exact) return exact;
  const part = sets.filter((s) => { const l = s.toLowerCase(); return l.includes(t) || t.includes(l); });
  return part.length === 1 ? part[0] : null;
};

/* ---- card scanner ------------------------------------------------- */
// Claude reads the card at 1568px on its long edge, so anything bigger is
// downscaled server-side and only costs upload time. Much smaller and the
// collector number stops being legible, which is the one glyph that matters.
// createImageBitmap rather than <img>: it honours EXIF orientation, and a
// sideways photo is the single most common cause of a bad read.
async function downscale(file, maxEdge = 1500, quality = 0.85) {
  let bmp;
  try { bmp = await createImageBitmap(file, { imageOrientation: "from-image" }); }
  catch { bmp = await createImageBitmap(file); } // older Safari has no options arg
  const scale = Math.min(1, maxEdge / Math.max(bmp.width, bmp.height));
  const w = Math.max(1, Math.round(bmp.width * scale)), h = Math.max(1, Math.round(bmp.height * scale));
  const cv = document.createElement("canvas");
  cv.width = w; cv.height = h;
  cv.getContext("2d").drawImage(bmp, 0, 0, w, h);
  bmp.close?.();
  return cv.toDataURL("image/jpeg", quality).split(",")[1]; // strip the data: prefix
}
// the scan route POSTs a photo, which cardFetch's GET-shaped helper doesn't
// carry — same token wall, its own fetch
const identifyFetch = async (body) => {
  const r = await fetch(`${SYNC_URL}identify`, {
    method: "POST",
    headers: { "x-sync-token": syncToken(), "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) { const e = new Error(j.error || `HTTP ${r.status}`); e.status = r.status; throw e; }
  return j;
};
const snapErrMsg = (e) =>
  e.status === 401 ? "Connect this device to cloud sync first — the scanner runs behind the same token."
  : e.status === 501 ? "Card scanning isn't set up yet — the sync Lambda needs an Anthropic API key (see aws/deploy.sh)."
  : e.status === 429 ? "Too many scans just now — give it a moment and try again."
  : e.status === 422 ? "Couldn't read that card. Retake the photo straight-on, filling the frame, in even light."
  : e.status === 413 ? "That photo was too large to send — try again."
  : e.name === "NotReadableError" || /createImageBitmap|decode/i.test(e.message || "") ? "That image format isn't supported — photograph the card directly instead of picking a HEIC from the library."
  : "The scanner is unavailable right now — try again in a moment.";
/* The slab label as one of the app's grades. The scanner reports the company
   and the number separately and free-form, because an SGC or an ACE slab still
   says something worth showing — but only a grade on a ladder the app can comp
   survives as a grade. Anything else lands on "Other", where nothing will try
   to price it off a bucket that doesn't exist. */
const readGrade = (hit) => {
  if (!hit?.grader || !hit?.grade) return "Raw";
  const co = String(hit.grader).toUpperCase().trim();
  const g = String(hit.grade).trim();
  return SLAB_GRADES[co]?.includes(g) ? `${co} ${g}` : "Other";
};
/* what Claude read -> a real catalog card. Set first (the printed code is the
   strongest signal), then the card: the fuzzy /search, then the whole-set
   /catalog dump when search misses a brand-new card. Every step may come up
   empty; the confirm sheet is editable. */
async function resolveScan(hit, sets, codes) {
  const printed = hit.number || "";
  const setName = (hit.setCode && codes?.[hit.setCode.toUpperCase()]) || matchSetName(hit.setName, sets) || "";
  const variant = hit.variant && hit.variant !== "Unknown" ? hit.variant : "";
  const lang = hit.language === "japanese" ? "jp" : "en";
  // the card prints "095/086" but every lookup stores and matches "95" — so
  // normalise before asking, or both attempts miss
  const num = normNum(printed);
  let card = null;
  if (hit.name && num) {
    try { card = (await lookupCardCandidates({ name: hit.name, set: setName, number: num, lang }))[0] || null; } catch {}
  }
  if (!card && setName && num) {
    try {
      const list = await fetchSetCatalog(setName, lang);
      const toks = String(hit.name || "").toLowerCase().split(/\s+/).filter(Boolean);
      const byNum = list.filter((x) => normNum(x.num) === num);
      const p = byNum.find((x) => toks.every((t) => x.name.toLowerCase().includes(t))) || byNum[0];
      if (p) card = catalogCard(setName, p, setName);
    } catch {}
  }
  return { card, setName, variant, number: card?.number || printed };
}

/* eBay sold comps: averages per graded bucket plus the raw ungraded average,
   proxied through the Lambda (see /graded in aws/index.mjs) so the
   pokemonpricetracker.com key stays server-side. `lang` picks which print run
   is being asked about — "jp" reaches PPT's Japanese catalogue, which is a
   different card with different sold prices, never a translation of the same
   listing. */
const GRADED_KEY = "cardledger:graded:v2"; // v2: entries carry byGrade/raw/image for the card modal
try { localStorage.removeItem("cardledger:graded:v1"); } catch {}
async function fetchGradedComps(name, set, number, lang = "en", productId = "") {
  // English keeps the old key shape, so an existing 24h cache still hits and the
  // daily PPT budget isn't re-spent on every card the moment this ships
  const key = `${name}|${set}|${number}`.toLowerCase() + (lang === "jp" ? "|jp" : "");
  const writeCache = (r) => {
    try {
      const all = JSON.parse(localStorage.getItem(GRADED_KEY)) || {};
      all[key] = { t: Date.now(), r };
      const keys = Object.keys(all);
      if (keys.length > 30) keys.sort((a, b) => all[a].t - all[b].t).slice(0, keys.length - 30).forEach((k) => delete all[k]);
      localStorage.setItem(GRADED_KEY, JSON.stringify(all));
    } catch {}
  };
  let cached;
  try { cached = (JSON.parse(localStorage.getItem(GRADED_KEY)) || {})[key]; } catch {}
  if (cached && Date.now() - cached.t < 24 * 3600 * 1000) {
    if (cached.r?._empty) { const e = new Error("no graded comps"); e.status = 404; throw e; }
    return cached.r;
  }
  try {
    const body = await cardFetch("graded", {
      name, set, number,
      lang: lang === "jp" ? "jp" : "",
      productId,
    });
    writeCache(body);
    return body;
  } catch (e) {
    // remember "no comps for this card" so auto-pull doesn't re-spend the daily
    // PPT budget on it every time the form reopens; transient failures (401 no
    // token, 429 budget exhausted, 5xx) stay uncached so they retry later
    if (e.status === 404) writeCache({ _empty: true });
    throw e;
  }
}

function useSets() {
  const [sets, setSets] = useState(() => {
    try { const c = JSON.parse(localStorage.getItem(SETS_KEY)); if (c && Date.now() - c.t < 7 * 864e5 && c.names?.length) return c.names; } catch {}
    return null;
  });
  useEffect(() => {
    if (sets) return;
    if (!setsPromise) setsPromise = fetchSets();
    let live = true;
    setsPromise.then((d) => live && setSets(d.names)).catch(() => { setsPromise = null; if (live) setSets([]); });
    return () => { live = false; };
  }, [sets]);
  return sets; // null = loading, [] = unavailable, [...] = loaded
}

// printed expansion code -> set name, for resolving a scanned card's set
// symbol. Static data now (src/setCodes.js) — PPT's set list carries no
// codes, and a table that never loads can never be the reason a scan fails.
function useSetCodes() {
  return SET_CODES;
}

const SOURCES = ["Gamecraft", "Dragon's Keep", "Game Grid", "Croma TCG", "PokeBank", "GameStop", "TikTok Shop", "Whatnot", "TCGplayer", "eBay", "PSA", "CGC", "BGS", "Other"];
const PRODUCTS = ["Booster Pack", "Booster Bundle", "Booster Box", "Elite Trainer Box", "Collection Box", "Tin", "Blister", "Single Card", "Supplies", "Other"];
const INV_SOURCES = ["Rip pull", "Gamecraft", "Dragon's Keep", "Game Grid", "Croma TCG", "PokeBank", "GameStop", "TikTok Shop", "Whatnot", "eBay", "Other"];
const CHANNELS = ["TCGplayer", "eBay", "LGS consignment", "In-person", "Other"];
const BUY_CATS = ["Sealed", "Single", "Lot", "Grading", "Supplies"];
const INV_STATUS = ["Kept", "At grading", "Listed", "Sold"];
// Graders you can send a submission to. Each one is also a buy `source`, because
// the send-to-grading flow writes the fee and the postage as one Grading buy.
const GRADERS = ["PSA", "CGC", "BGS"];
/* Each company grades on its own scale, and the same card sells for very
   different money in each one's slab — eBay solds for a Prismatic Umbreon ex
   161/131 read $5,575 in a PSA 10 against $2,574 in a CGC 10. So a card at the
   graders can only be valued against the company it is actually at. That is
   what `grader` on an inventory card records, and these are the grades worth
   estimating for each one, highest first. */
const GRADER_LADDER = {
  PSA: ["10", "9", "8", "7", "6"],
  CGC: ["10", "9.5", "9", "8.5", "8"],
  BGS: ["10", "9.5", "9", "8.5", "8"],
};
const DEFAULT_GRADER = "PSA";
// Cards sent before `grader` existed carry PSA estimates, because PSA was the
// only ladder the app had. Read every grader through this, never c.grader.
const cardGrader = (c) => (GRADER_LADDER[c?.grader] ? c.grader : DEFAULT_GRADER);
const estGrades = (c) => GRADER_LADDER[cardGrader(c)];
/* GRADER_LADDER is the handful of grades worth *estimating* while a card is
   still at the graders. A slab you already own is whatever the company actually
   put on the label, so the Grade picker offers the full scale each one issues —
   and a grade off this list is a grade the app can't price, which is a different
   thing from a grade it can't guess. */
const SLAB_GRADES = {
  PSA: ["10", "9", "8", "7", "6", "5", "4", "3", "2", "1"],
  CGC: ["10", "9.5", "9", "8.5", "8", "7.5", "7", "6.5", "6", "5", "4", "3", "2", "1"],
  BGS: ["10", "9.5", "9", "8.5", "8", "7.5", "7", "6.5", "6", "5", "4", "3", "2", "1"],
};
const GRADES = ["Raw", ...GRADERS.flatMap((co) => SLAB_GRADES[co].map((g) => `${co} ${g}`)), "Other"];
// Stable references passed to collapsed RipCards' `images` prop and to
// useCardImages when nothing is open — a fresh [] / {} literal every render
// would defeat both the hook's effect deps and RipCard's memo comparison.
const EMPTY_ARR = [];
const EMPTY_OBJ = {};
// The /graded route keys every company's sold buckets this way: "cgc9_5", "bgs10", "psa9".
const bucketKey = (grader, g) => String(grader).toLowerCase() + g.replace(".", "_");
/* Read one company's ladder out of a /graded body, as { grade: price } for the
   grades that have sales. byGrade carries every company; `grades` is the
   PSA-only map the same route returns, kept as the fallback so a card comped
   against an older Lambda still fills in. */
const compGrades = (r, grader) => Object.fromEntries(GRADER_LADDER[grader]
  .map((g) => [g, Number(r?.byGrade?.[bucketKey(grader, g)]?.price ?? (grader === DEFAULT_GRADER ? r?.grades?.[g] : 0)) || 0])
  .filter(([, p]) => p > 0));
// how many solds each of those prices came from, for the "filled from eBay" note
const compCount = (r, grader, g) => r?.byGrade?.[bucketKey(grader, g)]?.count ?? (grader === DEFAULT_GRADER ? r?.sales?.[g] : null) ?? null;
/* A grade off the GRADES list ("CGC 9.5") split back into the company and the
   number, or null for "Raw"/"Other". That pair names the card's own sold
   bucket, which is the only honest price for a card already in a slab — what a
   CGC 9.5 sells for, not what the raw card underneath would fetch. */
const slabOf = (grade) => {
  const m = /^(\S+)\s+([\d.]+)$/.exec(String(grade || ""));
  return m && SLAB_GRADES[m[1]]?.includes(m[2]) ? { grader: m[1], grade: m[2] } : null;
};
// that one bucket out of a /graded body: { price, count, median, min, max, trend }
const slabComp = (r, grade) => { const s = slabOf(grade); return (s && r?.byGrade?.[bucketKey(s.grader, s.grade)]) || null; };
// PPT writes numbers like "SVP 176" where the ledger has "176" (or "161/131");
// compare just the tail token so equal cards don't read as different ones
const numTail = (x) => normNum(String(x || "").trim().split(/\s+/).pop());
const alnumKey = (x) => String(x || "").toLowerCase().replace(/[^a-z0-9]+/g, "");
/* Does this /graded body actually describe the card we asked for? PPT's search
   is fuzzy, so a lookup can come back holding a near miss — the VMAX, the
   promo, the same Pokémon from another set. Writing that card's solds onto this
   one's value is silent and sticks, so every automatic use of a body is gated
   on this. The card detail view shows a near miss instead of dropping it,
   because a person looking at the screen can tell what happened. */
const wrongCardMsg = (r) => `The sold data came back for “${r?.card || "another card"}${r?.number ? ` · ${r.number}` : ""}”, which isn't this card — check the set and number, then try again.`;
const compsMatch = (r, c) => {
  if (!r) return false;
  if (c.number && r.number && numTail(r.number) !== numTail(c.number)) return false;
  const a = alnumKey(r.card), b = alnumKey(c.name);
  return !!a && !!b && (a === b || a.startsWith(b) || b.startsWith(a));
};
/* Japanese cards are their own print run with their own market. PPT carries
   a separate Japanese catalogue, so a card's language decides which catalogue
   every lookup asks — matching a JP card against the English one finds the
   English card of the same name and number and prices it as that. */
const LANGS = [["en", "English"], ["jp", "Japanese"]];
const cardLang = (c) => (c?.lang === "jp" ? "jp" : "en");
export const isJP = (c) => cardLang(c) === "jp";
// English raw singles are the only cards the TCGplayer path can price. Everything
// else — slabs, Japanese cards, an "Other" grade we can't read — is priced from
// its own eBay solds, or left alone when there are none.
const tcgPriceable = (c) => !isJP(c) && (c?.grade || "Raw") === "Raw";
export const stCls = (s) => ({ "Kept": "kept", "At grading": "grading", "Listed": "listed", "Sold": "sold" }[s] || "kept");
// A card at the graders reads "At CGC", not "At grading" — where it is decides
// what it is worth, so the list has to show it. The stored status is unchanged,
// so the status filter still matches.
export const statusLabel = (c) => (c.status === "At grading" && c.grader ? `At ${c.grader}` : c.status);

const TCGP_ORDERS = [
  {o:"3998E",b:"Lee Olson",p:3.47,d:"2026-06-09"},{o:"ABDBA",b:"Shane Davis",p:5.31,d:"2026-05-13"},
  {o:"EC37D",b:"Leslie Nagai",p:5.31,d:"2026-05-13"},{o:"9CC9F",b:"Jesus Fernandez",p:14.99,d:"2026-05-14"},
  {o:"41773",b:"Richard Stotler",p:5.81,d:"2026-05-14"},{o:"FD19C",b:"Dominick Telesco",p:2.81,d:"2026-05-14"},
  {o:"CBC1D",b:"Hunter Brake",p:6.99,d:"2026-05-14"},{o:"12B9A",b:"Jeremy Evans",p:27.99,d:"2026-05-15"},
  {o:"D2CFF",b:"Rhonda Haskins",p:6.49,d:"2026-05-15"},{o:"6023F",b:"Christian Bautista",p:3.31,d:"2026-05-15"},
  {o:"6F9F3",b:"Mason Diamond",p:4.06,d:"2026-05-15"},{o:"50E40",b:"John Junghans",p:4.81,d:"2026-05-18"},
  {o:"EC9EC",b:"Sergio Aquino",p:4.81,d:"2026-05-18"},{o:"8A5E2",b:"Patrick Coombe",p:3.06,d:"2026-05-20"},
  {o:"54848",b:"Andres Fernandez",p:11.49,d:"2026-05-20"},{o:"B401E",b:"Diego Mendez",p:25.99,d:"2026-05-22"},
  {o:"DD691",b:"Brendan Costello",p:5.99,d:"2026-05-25"},{o:"7A9B8",b:"Phil Maddaleno",p:2.27,d:"2026-05-27"},
  {o:"9F03D",b:"Chris Wrightson",p:16.99,d:"2026-05-29"},{o:"857DD",b:"Bryan Jimenez",p:6.5,d:"2026-05-29"},
  {o:"D9FF4",b:"Garry Breech",p:4.39,d:"2026-05-31"},{o:"4903A",b:"Erik Tweedy",p:18.95,d:"2026-06-02"},
  {o:"350A6",b:"Nate Dreslinski",p:7.69,d:"2026-06-02"},{o:"F1403",b:"Luis Borjas",p:5.19,d:"2026-06-04"},
  {o:"6D7EB",b:"Pedro Serrano",p:51.49,d:"2026-06-07"},{o:"4FC22",b:"Caleb Kim",p:7.99,d:"2026-05-10"},
  {o:"C8521",b:"Mario Castaneda",p:8.49,d:"2026-05-10"},{o:"8C58B",b:"Patrick Commins",p:11.99,d:"2026-05-13"},
  {o:"B221B",b:"Chinthan Muthuraj",p:24.49,d:"2026-05-14"},{o:"76FC9",b:"Gabriel Angcao",p:26.49,d:"2026-05-25"},
  {o:"0F1B6",b:"Mark Gano",p:35.99,d:"2026-06-03"},
];
const tcgpSales = () => TCGP_ORDERS.map((x) => ({ id: uid(), item: `TCGP ${x.o} · ${x.b.split(" ")[0]}`, cards: [], channel: "TCGplayer", price: x.p, fees: 0, shipping: 0, consign: 0, date: x.d, seed: true }));

const SEED_BUYS = [
  { item: "PokeBank", source: "PokeBank", category: "Lot", cost: 169.72, date: "2026-04-20" },
  { item: "TikTok Shop", source: "TikTok Shop", category: "Sealed", cost: 432.49, date: "2026-05-03" },
  { item: "Gamecraft", source: "Gamecraft", category: "Sealed", cost: 59.11, date: "2026-05-03" },
  { item: "PokeBank", source: "PokeBank", category: "Lot", cost: 462.98, date: "2026-05-03" },
  { item: "Gamecraft", source: "Gamecraft", category: "Sealed", cost: 96.73, date: "2026-05-05" },
  { item: "Gamecraft", source: "Gamecraft", category: "Sealed", cost: 42.98, date: "2026-05-06" },
  { item: "Gamecraft", source: "Gamecraft", category: "Sealed", cost: 318.35, date: "2026-05-07" },
  { item: "Gamecraft", source: "Gamecraft", category: "Sealed", cost: 17.2, date: "2026-05-08" },
  { item: "Croma TCG", source: "Croma TCG", category: "Single", cost: 280.24, date: "2026-05-08" },
  { item: "Gamecraft", source: "Gamecraft", category: "Sealed", cost: 26.87, date: "2026-05-10" },
  { item: "GameStop", source: "GameStop", category: "Sealed", cost: 60.0, date: "2026-05-13" },
  { item: "GameStop", source: "GameStop", category: "Sealed", cost: 51.5, date: "2026-05-13" },
  { item: "PSA grading", source: "PSA", category: "Grading", cost: 23.99, date: "2026-05-13" },
  { item: "PSA grading", source: "PSA", category: "Grading", cost: 49.99, date: "2026-05-13" },
  { item: "Gamecraft", source: "Gamecraft", category: "Sealed", cost: 322.35, date: "2026-05-14" },
  { item: "Dragon's Keep", source: "Dragon's Keep", category: "Sealed", cost: 141.83, date: "2026-05-14" },
  { item: "Gamecraft", source: "Gamecraft", category: "Sealed", cost: 60.18, date: "2026-05-15" },
  { item: "Gamecraft", source: "Gamecraft", category: "Sealed", cost: 25.28, date: "2026-05-17" },
  { item: "Dragon's Keep", source: "Dragon's Keep", category: "Sealed", cost: 112.82, date: "2026-05-17" },
  { item: "Gamecraft", source: "Gamecraft", category: "Sealed", cost: 51.58, date: "2026-05-17" },
  { item: "GameStop", source: "GameStop", category: "Sealed", cost: 89.98, date: "2026-05-17" },
  { item: "Gamecraft", source: "Gamecraft", category: "Sealed", cost: 42.98, date: "2026-05-19" },
  { item: "Game Grid", source: "Game Grid", category: "Sealed", cost: 129.76, date: "2026-05-20" },
  { item: "Game Grid", source: "Game Grid", category: "Sealed", cost: 86.51, date: "2026-05-20" },
  { item: "Gamecraft", source: "Gamecraft", category: "Sealed", cost: 17.2, date: "2026-06-02" },
  { item: "Gamecraft", source: "Gamecraft", category: "Sealed", cost: 42.98, date: "2026-06-04" },
  { item: "Gamecraft", source: "Gamecraft", category: "Sealed", cost: 17.2, date: "2026-06-07" },
];

function seed() {
  const sale = (name, channel, price, date) => ({ id: uid(), item: "", cards: name ? [{ id: uid(), name, basis: 0 }] : [], channel, price, fees: 0, shipping: 0, consign: 0, date, seed: true });
  return {
    version: 6, rips: [], inventory: [],
    buys: SEED_BUYS.map((b) => ({ id: uid(), ...b, seed: true })),
    sales: [
      sale("Mega Dragalge ex SIR — Chaos Rising", "eBay", 60.0, "2026-05-30"),
      sale("Froakie + Frogadier IR — Chaos Rising", "eBay", 40.0, "2026-05-30"),
      sale("Team Rocket's Mimikyu Full Art", "eBay", 32.0, "2026-05-06"),
      sale("Prismatic Lot 16 Pokeball + 2 Masterball", "eBay", 10.5, "2026-05-23"),
      sale("Prismatic Lot 7 ex — Pikachu", "eBay", 2.25, "2026-05-23"),
      sale("Prismatic Lot 3 Trainer + ACE", "eBay", 1.0, "2026-05-23"),
      sale("Mega Gengar (your card)", "LGS consignment", 935.0, "2026-05-15"),
      ...tcgpSales(),
    ],
  };
}

function migrate(s) {
  s = { ...s };
  if (!s.inventory) s.inventory = [];
  // defaults first so existing values win — this runs on every local and
  // remote load, which is what back-fills `variant` onto pre-scanner cards
  // a card already at the graders before `grader` existed was estimated against
  // PSA, because PSA was the only ladder — stamp that, so the ladder it shows
  // stays the ladder its numbers came from
  // `tcgplayerId` is the per-condition SKU a card was entered as. Cards from
  // before the catalog existed have none and keep exporting through the name
  // matcher, so nothing in an existing ledger has to be re-entered.
  // `productId` is PPT's product id — a different namespace from the export
  // SKU, never write one into the other. It buys exact comp/history lookups.
  s.inventory = s.inventory.map((c) => {
    const d = { status: "Kept", gradingCost: 0, gradingShip: 0, variant: "", grader: "", lang: "en", tcgplayerId: "", productId: "", ...c };
    if (d.status === "At grading" && !d.grader) d.grader = DEFAULT_GRADER;
    return d;
  });
  if (!s.version || s.version < 2) {
    const idx = s.sales.findIndex((x) => x.item === "TCGplayer orders (31)");
    if (idx >= 0) s.sales = [...tcgpSales(), ...s.sales.filter((_, i) => i !== idx)];
    s.version = 2;
  }
  s.sales = (s.sales || []).map((x) => {
    if (Array.isArray(x.cards)) return x;
    const cards = x.cardName ? [{ id: uid(), name: x.cardName, set: x.cardSet || "", number: x.cardNumber || "", basis: Number(x.costBasis) || 0, invId: x.invId || null }] : [];
    return { ...x, cards };
  });
  const buySig = (b) => `${b.source}|${(Number(b.cost) || 0).toFixed(2)}|${b.date}`;
  if (!s.version || s.version < 6) {
    const LEGACY = ["Booster / sealed haul", "Singles & lots", "Singles haul", "Sealed / singles", "TikTok Shop order", "GameStop pickup", "PSA grading"];
    const seedSigs = new Set(SEED_BUYS.map(buySig));
    const oldSig = {};
    (s.buys || []).forEach((b) => { oldSig[b.id] = buySig(b); });
    s.buys = (s.buys || []).filter((b) => !b.seed && !LEGACY.includes(b.item) && !seedSigs.has(buySig(b)));
    const fresh = SEED_BUYS.map((b) => ({ id: uid(), ...b, seed: true }));
    s.buys = [...s.buys, ...fresh];
    const newBySig = {};
    fresh.forEach((b) => { newBySig[buySig(b)] = b.id; });
    s.rips = (s.rips || []).map((r) => (r.buyId && oldSig[r.buyId] && newBySig[oldSig[r.buyId]] ? { ...r, buyId: newBySig[oldSig[r.buyId]] } : r));
    s.version = 6;
  }
  // safety net: collapse any exact-duplicate buys on every load
  const seenBuy = new Set();
  s.buys = (s.buys || []).filter((b) => { const k = `${b.item}|${buySig(b)}`; if (seenBuy.has(k)) return false; seenBuy.add(k); return true; });
  return s;
}

export const fmt = (n) => (n < 0 ? "-" : "") + "$" + Math.abs(n).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
export const ripValue = (r) => (r.hits || []).reduce((s, h) => s + (Number(h.value) || 0), 0);
export const ripCostOf = (r, buys) => (r.buyId ? (Number((buys || []).find((b) => b.id === r.buyId)?.cost) || 0) : (Number(r.cost) || 0));
export const ripPL = (r, buys) => ripValue(r) - ripCostOf(r, buys);
/* a logged hit is a card you now hold — mirror it into inventory as a rip pull.
   Basis stays 0 because the rip already carries the cost, which is the whole
   point of logging one: a lot of slabs bought together is one cost against the
   cards it produced, the same shape as packs against what came out of them.
   `lang` and `grade` ride along, because a JP booster box yields JP cards and a
   lot of slabs yields graded ones — neither is priced like an English raw. */
function addHitToState(s, ripId, hit) {
  const h = { id: uid(), ...hit };
  const rip = s.rips.find((r) => r.id === ripId);
  const inv = { id: uid(), hitId: h.id, name: h.name, set: h.set || "", number: h.number || "", variant: h.variant || "", tcgplayerId: h.tcgplayerId || "", productId: h.productId || "", lang: cardLang(h), grade: h.grade || "Raw", status: "Kept", source: "Rip pull", cost: 0, gradingCost: 0, gradingShip: 0, value: Number(h.value) || 0, date: rip?.date || today() };
  return { rips: s.rips.map((r) => (r.id === ripId ? { ...r, hits: [...(r.hits || []), h] } : r)), inventory: [inv, ...(s.inventory || [])] };
}
/* Editing a hit corrects the card it names, so the inventory row it produced
   has to follow. A Sold row does not: it is the record of what actually
   changed hands, and rewriting it to match a later correction would restate
   history. Same reasoning, and the same guard, as delHit. */
function updHitInState(s, ripId, hit) {
  return {
    rips: s.rips.map((r) => (r.id === ripId ? { ...r, hits: (r.hits || []).map((h) => (h.id === hit.id ? { ...h, ...hit } : h)) } : r)),
    inventory: (s.inventory || []).map((c) => (c.hitId === hit.id && c.status !== "Sold"
      ? { ...c, name: hit.name, set: hit.set || "", number: hit.number || "", variant: hit.variant || "", tcgplayerId: hit.tcgplayerId || "", productId: hit.productId || "", lang: cardLang(hit), grade: hit.grade || "Raw", value: Number(hit.value) || 0 }
      : c)),
  };
}

/* the three ways an identified card enters the ledger. Each takes a card in
   the app's search-result shape and returns a patch slice, so Lookup and the scanner
   add cards through the same code instead of two copies that drift.
   `c.variant` is optional — Lookup results don't carry one and price exactly
   as they always did. */
/* `cardPrice` is the English TCGplayer market price, which is the right opening
   value for an English raw single and the wrong one for anything else. A JP card
   or a slab starts at 0 — an empty field asks to be filled, where a plausible
   wrong number does not. Callers that pass a bare search-result card (Lookup)
   carry no language or grade and price exactly as they always did. */
const entryValue = (c) => (tcgPriceable(c) ? cardPrice(c, c.variant) || 0 : 0);
const entryLabel = (c) => `${c.name} ${c.number || ""} ${isJP(c) ? "JP" : ""} ${c.grade && c.grade !== "Raw" ? c.grade : ""}`.replace(/\s+/g, " ").trim();
const addAsBuy = (c) => (s) => ({ buys: [{ id: uid(), item: entryLabel(c), category: "Single", source: "Other", cost: entryValue(c), date: today() }, ...s.buys] });
const addAsKeep = (c) => (s) => ({ inventory: [{ id: uid(), name: c.name, set: c.set?.name, number: c.number, variant: c.variant || "", tcgplayerId: c.tcgplayerId || "", productId: c.productId || "", lang: cardLang(c), grade: c.grade || "Raw", status: "Kept", source: "Other", cost: 0, gradingCost: 0, gradingShip: 0, value: entryValue(c), date: today() }, ...(s.inventory || [])] });
const addAsHit = (c, ripId) => (s) => addHitToState(s, ripId, { name: c.name, set: c.set?.name, number: c.number, variant: c.variant || "", tcgplayerId: c.tcgplayerId || "", productId: c.productId || "", lang: cardLang(c), grade: c.grade || "Raw", value: entryValue(c) });
/* ------------------------------------------------------------------ */
/* A catalog row entering the ledger.

   TCGplayer writes the collector number into the product name — "Banette
   - 091/217 (Dusk Ball)" — but the ledger already has a `number` field,
   and a name carrying the number matches nothing in a name search. Strip
   the " - <number>" tail and keep the parenthetical, because that
   parenthetical is often the only thing separating two products that
   share a number, and it has to stay visible in the inventory list. */
const catalogCardName = (productName) => String(productName || "").replace(/ - [\w/.]+(?= \(|$)/, "").trim();
/* Present a catalog record in the app's search-result shape, so + Buy / + Keep /
   + Hit take it through exactly the same code as a Lookup result. The
   price is the export's own snapshot: market first, then the low columns,
   and nothing at all when the row has no price — which is every C- custom
   listing, and is why those never enter this way. */
const catalogEntryCard = (rec) => {
  const market = rec.market_price ?? rec.low_price ?? rec.low_with_ship ?? null;
  return {
    id: `tcgp:${rec.tcgplayer_id}`,
    tcgplayerId: rec.tcgplayer_id,
    name: catalogCardName(rec.product_name),
    set: { name: rec.set_name },
    number: rec.number || "",
    rarity: rec.rarity || "",
    variant: rec.printing,
    ...(market == null ? {} : { tcgplayer: { prices: { [PTCG_VARIANT_KEY[rec.printing]]: { market } } } }),
  };
};

const buyLineSet = (b) => { const s = [...new Set((b?.lines || []).map((l) => l.set).filter(Boolean))]; return s.length === 1 ? s[0] : ""; };
// which set a rip belongs to: explicit field, else the linked buy's lines,
// else a set name found in the product text, else the majority set of the hits
const ripSetOf = (r, buys, sets) => {
  if (r.set) return r.set;
  if (r.setPacks && r.setPacks.length) { const sp = [...r.setPacks].sort((a, b) => (Number(b.packs) || 0) - (Number(a.packs) || 0))[0]; if (sp?.set) return sp.set; }
  const b = r.buyId ? (buys || []).find((x) => x.id === r.buyId) : null;
  const fromLines = buyLineSet(b);
  if (fromLines) return fromLines;
  const text = `${r.product || ""} ${b?.item || ""}`.toLowerCase();
  if (sets?.length) {
    const m = sets.filter((s) => text.includes(s.toLowerCase())).sort((a, b2) => b2.length - a.length)[0];
    if (m) return m;
  }
  const counts = {};
  (r.hits || []).forEach((h) => { if (h.set) counts[h.set] = (counts[h.set] || 0) + 1; });
  const top = Object.entries(counts).sort((a, b2) => b2[1] - a[1])[0];
  return top ? top[0] : "Unknown";
};
// a rip can span several sets (a mixed box: 6 Perfect Order + 2 Phantasmal Flames).
// setPacks holds the per-set pack counts; older rips fall back to their single set.
const ripSetPacks = (r) => (r.setPacks && r.setPacks.length ? r.setPacks : (r.set ? [{ set: r.set, packs: Number(r.packs) || 0 }] : []));
// per-set P&L for a rip. Value is bucketed by each hit's own set; the box cost is
// split across sets weighted by that pulled value (the user's pick), so the set you
// hit big in carries more of the cost. Before any value is logged we fall back to
// splitting cost by pack count, then to the rip's single resolved set. The pieces
// always sum back to ripPL.
const ripSetSplit = (r, buys, sets) => {
  const cost = ripCostOf(r, buys);
  const valBySet = {};
  (r.hits || []).forEach((h) => { const s = h.set || ripSetOf(r, buys, sets); valBySet[s] = (valBySet[s] || 0) + (Number(h.value) || 0); });
  const totalVal = Object.values(valBySet).reduce((a, b) => a + b, 0);
  const out = {};
  if (totalVal > 0) {
    Object.entries(valBySet).forEach(([s, v]) => { out[s] = v - cost * (v / totalVal); });
  } else {
    const packs = ripSetPacks(r);
    const tot = packs.reduce((a, p) => a + (Number(p.packs) || 0), 0);
    if (tot > 0) packs.forEach((p) => { out[p.set] = (out[p.set] || 0) - cost * ((Number(p.packs) || 0) / tot); });
    else out[ripSetOf(r, buys, sets)] = -cost;
  }
  return out;
};
export const saleNet = (s) => (Number(s.price) || 0) - (Number(s.fees) || 0) - (Number(s.shipping) || 0) - (Number(s.consign) || 0);
export const saleBasis = (s) => (s.cards || []).reduce((a, c) => a + (Number(c.basis) || 0), 0);
// Dedup signature for a sale. Orders key off the TCGplayer order suffix (matches whether
// the ref was imported as "TCGP 5236F" or the full id "62955D06-88B131-5236F"); rows with no
// order # fall back to a channel/date/price/title signature so CSV reuploads stay idempotent.
// Some imports append a buyer name with an em-dash ("TCGP 5236F — Lee", sometimes mojibake'd
// to "â€”"); strip that off first so both spellings of the same order collapse to one key.
const orderKey = (item) => {
  const ref = String(item || "").replace(/^tcgp\s+/i, "").trim().split(/\s+(?:[-–—]|â€”)\s+/)[0].trim();
  return ref.split("-").pop().trim().toLowerCase();
};
const saleSig = (s) => {
  const k = orderKey(s.item);
  if (k) return "o:" + k;
  return "e:" + [s.channel || "", s.date || "", Number(s.price) || 0, (s.cards || [])[0]?.name || ""].join("|").toLowerCase();
};
// Re-point an existing sale ref at the full order number, carrying over any buyer name
// the old ref had ("TCGP 3998E — Lee" / "TCGP 3998E · Lee" -> "62955D06-…-3998E — Lee").
const refBuyer = (item) => {
  const parts = String(item || "").replace(/^tcgp\s+/i, "").split(/\s+(?:[·\-–—]|â€”)\s+/);
  return parts.length > 1 ? parts.slice(1).join(" — ").trim() : "";
};
const mergeRef = (oldItem, fullNo) => { const b = refBuyer(oldItem); return b ? `${fullNo} — ${b}` : fullNo; };
// split one sale's net across sets: explicit card set, else the inventory
// card it came from, else a set name in the card/order text. Net is weighted
// by basis when tracked, evenly otherwise.
const saleSetSplit = (s, inventory, sets) => {
  const net = saleNet(s);
  const cards = s.cards || [];
  if (!cards.length) return { Untagged: net };
  const totalBasis = cards.reduce((a, c) => a + (Number(c.basis) || 0), 0);
  const shares = {};
  cards.forEach((c) => {
    const w = totalBasis > 0 ? (Number(c.basis) || 0) / totalBasis : 1 / cards.length;
    let set = c.set;
    if (!set && c.invId) set = (inventory || []).find((x) => x.id === c.invId)?.set;
    if (!set && sets?.length) {
      const text = `${c.name || ""} ${s.item || ""}`.toLowerCase();
      set = sets.filter((nm) => text.includes(nm.toLowerCase())).sort((a, b) => b.length - a.length)[0];
    }
    set = set || "Untagged";
    shares[set] = (shares[set] || 0) + net * w;
  });
  return shares;
};
// True cost of a card: what it cost to get, plus what grading it cost. Postage to
// the grader is split across the cards in the submission, so a card carries its
// own share. All three must be here, or a graded card's ROI reads too high.
export const invBasis = (c) => (Number(c.cost) || 0) + (Number(c.gradingCost) || 0) + (Number(c.gradingShip) || 0);
// a card at the graders carries a value range — min/max of whichever estimates
// the user filled in, on the ladder of the company the card is at. Everything
// else just counts its single value.
export const gradeRange = (c) => {
  if (c.status !== "At grading") return null;
  const vals = estGrades(c).map((g) => Number(c.gradeEst?.[g]) || 0).filter((v) => v > 0);
  return vals.length ? { lo: Math.min(...vals), hi: Math.max(...vals) } : null;
};
const invRange = (cards) => cards.reduce((a, c) => {
  const r = gradeRange(c), v = Number(c.value) || 0;
  return { lo: a.lo + (r ? r.lo : v), hi: a.hi + (r ? r.hi : v) };
}, { lo: 0, hi: 0 });
export const fmtRange = (r) => (r.lo === r.hi ? fmt(r.lo) : `${fmt(r.lo)} – ${fmt(r.hi)}`);
export const byDateDesc = (a, b) => (b.date || "").localeCompare(a.date || "");
// `variant` is optional — without it this picks a printing the way it always
// has, so every existing caller is unaffected
const cardPrice = (c, variant) => {
  const p = c.tcgplayer?.prices; if (!p) return null;
  const want = PTCG_VARIANT_KEY[variant];
  const v = (want && p[want]) || p.holofoil || p.normal || p.reverseHolofoil || p["1stEditionHolofoil"] || Object.values(p)[0];
  return v?.market ?? v?.mid ?? null;
};
// Look up one stored card through /search — used by Inventory's "refresh
// prices" and the card modal. We only trust a match we can pin down (name +
// number, or name + set); a bare name is too ambiguous to auto-pick, so we
// skip it rather than risk grabbing the wrong card. The server's search is
// fuzzy, so the number filter below is the guarantee, not a nicety.
async function lookupCardCandidates(card) {
  if (!card.name) return [];
  const lang = card.lang === "jp" ? "jp" : "en";
  try {
    if (card.number) {
      const list = await searchCards({ q: card.name, set: card.set || "", number: normNum(card.number), lang });
      return list.filter((c) => normNum(c.number) === normNum(card.number));
    }
    if (card.set) return await searchCards({ q: card.name, set: card.set, lang });
  } catch { return []; }
  return []; // no number and no set — too ambiguous to match safely
}
async function lookupCardPrice(card, variant) {
  return (await lookupCardCandidates(card)).find((c) => cardPrice(c, variant) != null) || null;
}
// the modal also wants a match with no price (for the image and set info):
// prefer priced-with-image, then any image, then whatever matched. Skips the
// price backfill (the modal prices via the set dump separately) and keeps a
// session cache so reopening a card shows its image instantly.
const matchCache = new Map();
// The in-memory Map above only ever lasted one page load — every reload
// refetched every card's match again. This backs it with localStorage the
// same way qcacheGet/qcacheSet (above) back CardSearch's query cache: a
// card's picture never changes once printed, so a month-long TTL is safe.
// Only a hit gets persisted, never a miss — a miss today can become a hit
// once PPT indexes a new set, so caching "no match" would be wrong.
const MATCHCACHE_KEY = "cardledger:matchcache:v2"; // v2: PPT-sourced matches
const MATCHCACHE_TTL = 30 * 24 * 3600 * 1000;
const matchLsRead = () => { try { return JSON.parse(localStorage.getItem(MATCHCACHE_KEY)) || {}; } catch { return {}; } };
const matchLsGet = (key) => { const c = matchLsRead()[key]; return c && Date.now() - c.t < MATCHCACHE_TTL ? c.r : undefined; };
const matchLsPut = (key, hit) => {
  try {
    const all = matchLsRead();
    all[key] = { t: Date.now(), r: hit };
    Object.keys(all).sort((a, b) => all[b].t - all[a].t).slice(40).forEach((k) => delete all[k]);
    localStorage.setItem(MATCHCACHE_KEY, JSON.stringify(all));
  } catch {}
};
async function lookupCardMatch(card) {
  const key = `${card.name}|${card.set || ""}|${card.number || ""}`.toLowerCase();
  if (matchCache.has(key)) return matchCache.get(key);
  const persisted = matchLsGet(key);
  if (persisted !== undefined) { matchCache.set(key, persisted); return persisted; }
  const list = await lookupCardCandidates(card);
  const hit = list.find((c) => cardPrice(c) != null && c.images?.small) || list.find((c) => c.images?.small) || list[0] || null;
  if (hit) { matchCache.set(key, hit); matchLsPut(key, hit); } // misses stay uncached so a flaky API call retries next open
  return hit;
}
// Every other lookupCardMatch caller wants one card at a time (the modal).
// A screen that renders a card's whole collection at once would otherwise
// fire one request per card the moment it mounts — capping how many run in
// parallel keeps that from reading as a rate-limit stampede.
const CARD_IMG_PARALLEL = 4;
let cardImgInFlight = 0;
const cardImgQueue = [];
function throttledCardMatch(card) {
  return new Promise((resolve, reject) => {
    const run = () => {
      cardImgInFlight++;
      lookupCardMatch(card).then(resolve, reject).finally(() => {
        cardImgInFlight--;
        cardImgQueue.shift()?.();
      });
    };
    cardImgInFlight < CARD_IMG_PARALLEL ? run() : cardImgQueue.push(run);
  });
}
// One hook for every screen that wants card pictures. Cards batch by set
// (fetchSetCatalog above resolves a whole set in one call — Japanese sets
// included, through PPT's Japanese catalogue); whatever a set batch can't
// place — no set on the card, a stamped print, a printing the batch doesn't
// have — falls back to a throttled one-card lookup. The set cache and the
// per-card match cache are both module-level, so a card resolved on one
// screen (Binder, say) is instant on the next (Inventory, Lookup) — nothing
// here is fetched twice.
function useCardImages(cards) {
  const [images, setImages] = useState({}); // id -> url|null; a missing key means still resolving
  const setKeys = [...new Set(cards.filter((c) => c.set).map((c) => `${c.set}\t${isJP(c) ? "jp" : "en"}`))].sort().join("|");
  const cardIds = cards.map((c) => c.id).join("|");
  useEffect(() => {
    let live = true;
    (async () => {
      const maps = {};
      await Promise.all((setKeys ? setKeys.split("|") : []).map(async (k) => {
        const [name, lang] = k.split("\t");
        maps[k] = await fetchSetCatalog(name, lang);
      }));
      if (!live) return;
      const found = {};
      const leftover = [];
      for (const c of cards) {
        if (!c.name) { found[c.id] = null; continue; }
        const hit = c.set ? imageInSet(maps[`${c.set}\t${isJP(c) ? "jp" : "en"}`], c) : null;
        if (hit?.img) found[c.id] = hit.img;
        else leftover.push(c);
      }
      setImages((s) => ({ ...s, ...found }));
      leftover.forEach((c) => {
        throttledCardMatch(c).then(
          (m) => { if (live) setImages((s) => ({ ...s, [c.id]: m?.images?.small || null })); },
          () => { if (live) setImages((s) => ({ ...s, [c.id]: null })); },
        );
      });
    })();
    return () => { live = false; };
  }, [setKeys, cardIds]); // eslint-disable-line react-hooks/exhaustive-deps
  return images;
}

/* ================================================================== */
export default function App() {
  const [state, setState] = useState(null);
  const [tab, setTab] = useState("dash");
  const [sync, setSync] = useState(() => (syncToken() ? "checking" : "off"));
  const saving = useRef(false);
  const pushTimer = useRef(null);
  const pendingPush = useRef(null);
  const remoteApply = useRef(false); // state change came FROM the cloud — must not be re-stamped or re-pushed
  const pendingRemote = useRef(null); // cloud copy held while the user picks a winner
  const choosing = useRef(false); // while true, nothing pushes or adopts

  const adoptRemote = useCallback((remote) => {
    setLocalStamp(remote.updatedAt);
    remoteApply.current = true;
    setState(migrate(JSON.parse(remote.data)));
  }, []);

  const flushPush = useCallback(async (keepalive = false) => {
    const p = pendingPush.current;
    if (!p || !syncToken()) return;
    pendingPush.current = null;
    clearTimeout(pushTimer.current);
    // Do not abort a keepalive push. The browser sends it after the page closes.
    // Every other push uses the timeout. A stalled push then returns to the
    // queue, and the app sends it again.
    const ctl = new AbortController();
    const t = keepalive ? null : setTimeout(() => ctl.abort(), SYNC_TIMEOUT);
    try {
      const r = await fetch(SYNC_URL, {
        method: "PUT",
        headers: { "x-sync-token": syncToken(), "content-type": "application/json" },
        body: JSON.stringify({ updatedAt: p.ts, data: p.data }),
        keepalive, // lets the request outlive the page when iOS backgrounds us
        ...(keepalive ? {} : { signal: ctl.signal }),
      });
      if (r.status === 409) { const remote = await syncFetch("GET"); if (remote) adoptRemote(remote); setSync("on"); return; }
      if (!r.ok) { const e = new Error(`HTTP ${r.status}`); e.status = r.status; throw e; }
      setSync("on");
    } catch (e) {
      if (!pendingPush.current) pendingPush.current = p; // keep it queued — retried on next edit or focus change
      setSync(e.status === 401 ? "badtoken" : "error");
    } finally { clearTimeout(t); }
  }, [adoptRemote]);

  useEffect(() => { (async () => {
    let local = null;
    try { const r = await storage.get(KEY); if (r && r.value) local = migrate(JSON.parse(r.value)); } catch {}
    const cur = local || seed();
    if (!syncToken()) { setState(cur); return; }
    // Show the ledger from this device before the app calls the cloud. The cloud
    // check reconciles the two copies. It is not a precondition to read the
    // local copy. A slow request must not hold the first render, because local
    // storage already holds the data.
    remoteApply.current = true; // loading isn't editing — don't re-stamp
    setState(cur);
    const bootStamp = localStamp(); // moves only if the user edits while we wait
    try {
      const remote = await syncFetch("GET", null, bootStamp);
      const freshToken = (() => { try { return sessionStorage.getItem("cardledger:fresh") === "1"; } catch { return false; } })();
      if (remote && !remote.unchanged && freshToken && localStamp() > 0) {
        // setup link just installed a token, but this device already has its
        // own ledger — hold everything and let the user pick the winner
        pendingRemote.current = remote;
        choosing.current = true;
        setSync("choose");
        return;
      }
      try { sessionStorage.removeItem("cardledger:fresh"); } catch {}
      if (remote && !remote.unchanged && remote.updatedAt > localStamp()) adoptRemote(remote);
      else {
        const ts = localStamp() || Date.now();
        // `cur` holds the ledger from the start time. The user can edit the
        // ledger while this check runs. An edit is newer than `cur`, and the
        // edit sends its own push. Do not heal the cloud from `cur` after an
        // edit, because `cur` would replace the newer copy.
        const edited = localStamp() !== bootStamp || pendingPush.current;
        if (!edited && !remote?.unchanged && (!remote || ts > remote.updatedAt)) {
          // cloud is behind us (a push never made it out) — heal it, same stamp
          setLocalStamp(ts);
          await syncFetch("PUT", { updatedAt: ts, data: JSON.stringify(cur) });
        }
      }
      setSync("on");
    } catch (e) {
      setSync(e.status === 401 ? "badtoken" : "error");
    }
  })(); }, [adoptRemote]);

  useEffect(() => {
    if (!state || saving.current) return;
    if (remoteApply.current) {
      // cloud-sourced state: cache it locally but never push it back
      remoteApply.current = false;
      storage.set(KEY, JSON.stringify(state)).catch(() => {});
      return;
    }
    saving.current = true;
    const ts = Math.max(Date.now(), localStamp() + 1); // monotonic across device clock skew
    setLocalStamp(ts);
    storage.set(KEY, JSON.stringify(state)).catch(() => {}).finally(() => { saving.current = false; });
    if (!syncToken() || choosing.current) return;
    pendingPush.current = { ts, data: JSON.stringify(state) };
    clearTimeout(pushTimer.current);
    pushTimer.current = setTimeout(() => flushPush(), 1200);
  }, [state, flushPush]);

  useEffect(() => {
    const onVis = () => {
      if (!syncToken() || choosing.current) return;
      if (document.visibilityState === "hidden") { flushPush(true); return; } // iOS may kill us — push NOW
      if (pendingPush.current) { flushPush(); return; }
      (async () => {
        try { const remote = await syncFetch("GET", null, localStamp()); if (remote && !remote.unchanged && remote.updatedAt > localStamp()) adoptRemote(remote); setSync("on"); } catch {}
      })();
    };
    const onHide = () => flushPush(true);
    document.addEventListener("visibilitychange", onVis);
    window.addEventListener("pagehide", onHide);
    return () => { document.removeEventListener("visibilitychange", onVis); window.removeEventListener("pagehide", onHide); };
  }, [adoptRemote, flushPush]);

  const connectSync = useCallback(async (token) => {
    setSyncTokenLS(token.trim());
    setSync("checking");
    try {
      const remote = await syncFetch("GET");
      if (remote && localStamp() > 0) { pendingRemote.current = remote; choosing.current = true; setSync("choose"); return; }
      if (remote) adoptRemote(remote);
      else if (state) { const ts = Math.max(Date.now(), localStamp() + 1); setLocalStamp(ts); await syncFetch("PUT", { updatedAt: ts, data: JSON.stringify(state) }); }
      setSync("on");
    } catch (e) { setSync(e.status === 401 ? "badtoken" : "error"); }
  }, [state, adoptRemote]);
  const resolveChoice = useCallback(async (useCloud) => {
    const remote = pendingRemote.current;
    pendingRemote.current = null;
    try { sessionStorage.removeItem("cardledger:fresh"); } catch {}
    setSync("checking");
    try {
      if (useCloud && remote) adoptRemote(remote);
      else if (state) { const ts = Math.max(Date.now(), localStamp() + 1); setLocalStamp(ts); await syncFetch("PUT", { updatedAt: ts, data: JSON.stringify(state) }); }
      choosing.current = false;
      setSync("on");
    } catch (e) { choosing.current = false; setSync(e.status === 401 ? "badtoken" : "error"); }
  }, [state, adoptRemote]);
  const disconnectSync = useCallback(() => { setSyncTokenLS(""); choosing.current = false; pendingRemote.current = null; setSync("off"); }, []);

  const patch = useCallback((fn) => setState((s) => ({ ...s, ...fn(s) })), []);
  const reset = useCallback(() => { const fresh = seed(); storage.set(KEY, JSON.stringify(fresh)).catch(() => {}); setState(fresh); }, []);
  if (!state) return <div className="cl-root"><Fonts /><div className="cl-center">Loading your ledger…</div></div>;

  // `__BB_SCAN__` is baked in at build time (vite.config.js): the Scan tab is a
  // camera feature, so it ships in the phone app and on the dev server, and the
  // hosted web build leaves it out. Hence a built list rather than a fixed one.
  const TABS = [
    ["dash", "Overview", LayoutDashboard], ["month", "Monthly", CalendarRange],
    ["rips", "Rips", PackageOpen], ["buys", "Buys", ShoppingCart],
    ["sales", "Sales", Tags], ["inv", "Inventory", Archive],
    ["binder", "Binder", LayoutGrid],
    ["look", "Lookup", Search],
    ...(__BB_SCAN__ ? [["snap", "Scan", Camera]] : []),
  ];

  return (
    <div className="cl-root">
      <Fonts />
      <header className="cl-head">
        <div className="cl-brand"><Sparkles size={18} className="cl-spark" /><span>Binder<span className="holo-text">Books</span></span></div>
        <div className="cl-tag">card P&amp;L ledger</div>
      </header>
      <nav className="cl-tabs">
        {TABS.map(([k, label, Icon]) => (<button key={k} className={"cl-tab" + (tab === k ? " on" : "")} onClick={() => { haptic("select"); setTab(k); }}><Icon size={15} /> <span>{label}</span></button>))}
      </nav>
      <main className="cl-main cl-tabpane" key={tab}>
        {tab === "dash" && <Dashboard state={state} go={setTab} reset={reset} sync={sync} connectSync={connectSync} disconnectSync={disconnectSync} resolveChoice={resolveChoice} />}
        {tab === "month" && <Monthly state={state} />}
        {tab === "rips" && <Rips state={state} patch={patch} />}
        {tab === "buys" && <Buys state={state} patch={patch} />}
        {tab === "sales" && <Sales state={state} patch={patch} />}
        {tab === "inv" && <Inventory state={state} patch={patch} />}
        {tab === "binder" && <Binder state={state} patch={patch} go={setTab} />}
        {tab === "look" && <Lookup state={state} patch={patch} />}
        {__BB_SCAN__ && tab === "snap" && <CardSnap state={state} patch={patch} />}
      </main>
    </div>
  );
}

/* ================================================================== */
function Dashboard({ state, go, reset, sync, connectSync, disconnectSync, resolveChoice }) {
  const [confirmReset, setConfirmReset] = useState(false);
  const sets = useSets();
  const buyCost = state.buys.reduce((s, b) => s + (Number(b.cost) || 0), 0);
  const ripExtra = state.rips.filter((r) => !r.buyId).reduce((s, r) => s + (Number(r.cost) || 0), 0);
  const spent = buyCost + ripExtra;
  const earned = state.sales.reduce((s, x) => s + saleNet(x), 0);
  const net = earned - spent;
  const kept = (state.inventory || []).filter((c) => c.status !== "Sold");
  const invVal = kept.reduce((s, c) => s + (Number(c.value) || 0), 0);
  const invR = invRange(kept);
  const hasRange = invR.lo !== invR.hi;
  const netLo = earned + invR.lo - spent, netHi = earned + invR.hi - spent;
  const atGrading = kept.filter((c) => gradeRange(c));
  const gradingCount = atGrading.length;
  // name the companies the range actually came from, so the spread is readable
  // as "CGC grades", not an unattributed guess
  const gradingCos = [...new Set(atGrading.map(cardGrader))];
  const gradingWho = gradingCos.length === 1 ? `${gradingCos[0]} grades` : "grades";

  const bySource = {};
  state.buys.forEach((b) => { bySource[b.source || "Other"] = (bySource[b.source || "Other"] || 0) + (Number(b.cost) || 0); });
  state.rips.filter((r) => !r.buyId).forEach((r) => { bySource[r.source || "Other"] = (bySource[r.source || "Other"] || 0) + (Number(r.cost) || 0); });
  const byChannel = {};
  state.sales.forEach((s) => { byChannel[s.channel || "Other"] = (byChannel[s.channel || "Other"] || 0) + saleNet(s); });
  const bySet = {}, byProduct = {};
  state.buys.forEach((b) => (b.lines || []).forEach((l) => {
    const c = Number(l.cost) || 0;
    if (l.set) bySet[l.set] = (bySet[l.set] || 0) + c;
    if (l.product) byProduct[l.product] = (byProduct[l.product] || 0) + c;
  }));
  const ripsRanked = [...state.rips].sort((a, b) => ripPL(b, state.buys) - ripPL(a, state.buys));
  const ripBySet = {};
  state.rips.forEach((r) => Object.entries(ripSetSplit(r, state.buys, sets)).forEach(([k, v]) => { ripBySet[k] = (ripBySet[k] || 0) + v; }));
  const salesBySet = {};
  state.sales.forEach((s) => Object.entries(saleSetSplit(s, state.inventory, sets)).forEach(([k, v]) => { salesBySet[k] = (salesBySet[k] || 0) + v; }));
  const hasFees = state.sales.some((s) => s.fees || s.shipping || s.consign);

  return (
    <div className="cl-stack">
      <section className="cl-hero">
        <div className="cl-hero-label">Net on cards</div>
        <div className={"cl-hero-num holo-text" + (net < 0 ? " neg" : "")}>{fmt(net)}</div>
        <div className="cl-hero-sub">{net < 0 ? "in the red — keep ripping" : "in the green"} · realized</div>
      </section>
      <div className="cl-grid2"><Stat label="Spent" value={fmt(spent)} tone="out" /><Stat label="Earned (net)" value={fmt(earned)} tone="in" /></div>
      {!hasFees && <div className="cl-note">No platform fees or shipping costs are entered yet, so “earned” is gross. Edit a sale to add fees for true net.</div>}
      <Panel title="Kept inventory" action={<button className="cl-link" onClick={() => go("inv")}>Inventory ▸</button>}>
        {kept.length === 0
          ? <Empty>No cards held yet. Add keepers on the Inventory tab or from Lookup.</Empty>
          : <div className="cl-inv-summary">
              <div><div className="cl-row-meta">Cards held</div><div className="cl-stat-num">{kept.length}</div></div>
              <div><div className="cl-row-meta">Market value</div><div className="cl-stat-num" style={{ color: "var(--holo2)" }}>{hasRange ? <span className="cl-range">{fmtRange(invR)}</span> : fmt(invVal)}</div></div>
              <div><div className="cl-row-meta">Net if liquidated</div><div className="cl-stat-num" style={{ color: netLo >= 0 ? "var(--pos)" : netHi < 0 ? "var(--neg)" : "var(--out)" }}>{hasRange ? <span className="cl-range">{fmtRange({ lo: netLo, hi: netHi })}</span> : fmt(netLo)}</div></div>
            </div>}
        {hasRange && <div className="cl-note" style={{ marginTop: 10 }}>{gradingCount} card{gradingCount === 1 ? "" : "s"} at grading — depending on how the {gradingWho} land, you'd end up anywhere from {fmt(netLo)} to {fmt(netHi)} overall.</div>}
      </Panel>
      <Panel title="Where the money went" action={<button className="cl-link" onClick={() => go("buys")}>Buys ▸</button>}><BarList data={bySource} tone="out" /></Panel>
      {Object.keys(bySet).length > 0 && <Panel title="Spend by set"><BarList data={bySet} tone="out" /></Panel>}
      {Object.keys(byProduct).length > 0 && <Panel title="Spend by product"><BarList data={byProduct} tone="out" /></Panel>}
      <Panel title="Where it came back" action={<button className="cl-link" onClick={() => go("sales")}>Sales ▸</button>}><BarList data={byChannel} tone="in" /></Panel>
      {state.sales.length > 0 && <Panel title="Sales by set"><BarList data={salesBySet} tone="in" /></Panel>}
      <Panel title="Rip scoreboard" action={<button className="cl-link" onClick={() => go("rips")}>Rips ▸</button>}>
        {ripsRanked.length === 0 ? <Empty>No rips logged. Open a pack on the Rips tab and log your hits.</Empty>
          : <div className="cl-stack sm">{ripsRanked.slice(0, 5).map((r) => (
              <div key={r.id} className="cl-row"><div className="cl-row-main"><div className="cl-row-title">{r.product || "Rip"}</div><div className="cl-row-meta">{(r.hits || []).length} hits · cost {fmt(ripCostOf(r, state.buys))}</div></div><div className={"cl-money " + (ripPL(r, state.buys) >= 0 ? "pos" : "neg")}>{fmt(ripPL(r, state.buys))}</div></div>
            ))}</div>}
      </Panel>
      {state.rips.length > 0 && <Panel title="Rip P&L by set"><BarList data={ripBySet} tone="pl" /></Panel>}
      <Panel title="Cloud sync"><SyncPanel sync={sync} connect={connectSync} disconnect={disconnectSync} choose={resolveChoice} /></Panel>
      <div className="cl-reset">
        {!confirmReset
          ? <button className="cl-reset-btn" onClick={() => setConfirmReset(true)}>Reset all data</button>
          : <div className="cl-reset-confirm cl-tabpane"><span>Wipes everything and reloads the starter data.</span><div className="cl-reset-actions"><button className="cl-cancel" onClick={() => setConfirmReset(false)}>Cancel</button><button className="cl-reset-go" onClick={() => { reset(); setConfirmReset(false); }}>Reset</button></div></div>}
      </div>
    </div>
  );
}

/* ================================================================== */
const MONTH_NAMES = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
const monthKey = (d) => (d || "").slice(0, 7); // "YYYY-MM"
const monthLabel = (k) => { const [y, m] = (k || "").split("-"); return MONTH_NAMES[(+m || 1) - 1] + " " + y; };

// Monthly cash-flow P&L: money out = buys + standalone rip costs dated in the
// month; money in = sale nets dated in the month. Same model as the Overview,
// just sliced by calendar month so you can see how a single month is doing.
function Monthly({ state }) {
  const sets = useSets();
  const thisMonth = monthKey(today());

  // every month that has any activity, plus the current month so "this month
  // so far" always shows even before the first transaction lands.
  const months = (() => {
    const set = new Set([thisMonth]);
    state.buys.forEach((b) => b.date && set.add(monthKey(b.date)));
    state.sales.forEach((s) => s.date && set.add(monthKey(s.date)));
    state.rips.forEach((r) => r.date && set.add(monthKey(r.date)));
    return [...set].sort().reverse(); // newest first
  })();

  const [sel, setSel] = useState(thisMonth);
  const cur = months.includes(sel) ? sel : months[0];
  const idx = months.indexOf(cur);

  // net (in − out) for any month — used for the headline and the trend rail
  const netOf = (k) => {
    const out = state.buys.filter((b) => monthKey(b.date) === k).reduce((a, b) => a + (Number(b.cost) || 0), 0)
      + state.rips.filter((r) => !r.buyId && monthKey(r.date) === k).reduce((a, r) => a + (Number(r.cost) || 0), 0);
    const inn = state.sales.filter((s) => monthKey(s.date) === k).reduce((a, s) => a + saleNet(s), 0);
    return inn - out;
  };

  const buys = state.buys.filter((b) => monthKey(b.date) === cur);
  const sales = state.sales.filter((s) => monthKey(s.date) === cur);
  const rips = state.rips.filter((r) => monthKey(r.date) === cur);
  const buyCost = buys.reduce((a, b) => a + (Number(b.cost) || 0), 0);
  const ripExtra = rips.filter((r) => !r.buyId).reduce((a, r) => a + (Number(r.cost) || 0), 0);
  const spent = buyCost + ripExtra;
  const earned = sales.reduce((a, s) => a + saleNet(s), 0);
  const net = earned - spent;
  const isNow = cur === thisMonth;

  const bySource = {};
  buys.forEach((b) => { bySource[b.source || "Other"] = (bySource[b.source || "Other"] || 0) + (Number(b.cost) || 0); });
  rips.filter((r) => !r.buyId).forEach((r) => { bySource[r.source || "Other"] = (bySource[r.source || "Other"] || 0) + (Number(r.cost) || 0); });
  const byChannel = {};
  sales.forEach((s) => { byChannel[s.channel || "Other"] = (byChannel[s.channel || "Other"] || 0) + saleNet(s); });
  const ripBySet = {};
  rips.forEach((r) => Object.entries(ripSetSplit(r, state.buys, sets)).forEach(([k, v]) => { ripBySet[k] = (ripBySet[k] || 0) + v; }));
  const empty = !buys.length && !sales.length && !rips.length;

  return (
    <div className="cl-stack">
      <div className="cl-monthnav">
        <button className="cl-monthnav-btn" disabled={idx >= months.length - 1} onClick={() => setSel(months[idx + 1])} aria-label="Previous month"><ChevronLeft size={18} /></button>
        <select className="cl-in" value={cur} onChange={(e) => setSel(e.target.value)}>{months.map((k) => <option key={k} value={k}>{monthLabel(k)}{k === thisMonth ? " · so far" : ""}</option>)}</select>
        <button className="cl-monthnav-btn" disabled={idx <= 0} onClick={() => setSel(months[idx - 1])} aria-label="Next month"><ChevronRight size={18} /></button>
      </div>
      <section className="cl-hero">
        <div className="cl-hero-label">{monthLabel(cur)}{isNow ? " · so far" : ""}</div>
        <div className={"cl-hero-num holo-text" + (net < 0 ? " neg" : "")}>{fmt(net)}</div>
        <div className="cl-hero-sub">{empty ? "no activity logged this month" : (net < 0 ? "in the red this month" : "in the green this month") + " · realized"}</div>
      </section>
      <div className="cl-grid2"><Stat label="Spent" value={fmt(spent)} tone="out" /><Stat label="Earned (net)" value={fmt(earned)} tone="in" /></div>
      <div className="cl-inv-summary">
        <div><div className="cl-row-meta">Buys</div><div className="cl-stat-num">{buys.length}</div></div>
        <div><div className="cl-row-meta">Sales</div><div className="cl-stat-num">{sales.length}</div></div>
        <div><div className="cl-row-meta">Rips</div><div className="cl-stat-num">{rips.length}</div></div>
      </div>
      {Object.keys(bySource).length > 0 && <Panel title="Where the money went"><BarList data={bySource} tone="out" /></Panel>}
      {sales.length > 0 && <Panel title="Where it came back"><BarList data={byChannel} tone="in" /></Panel>}
      {rips.length > 0 && <Panel title="Rip P&L by set"><BarList data={ripBySet} tone="pl" /></Panel>}
      <Panel title="Month by month">
        {months.length === 0 ? <Empty>Nothing logged yet.</Empty>
          : <div className="cl-stack sm">{months.map((k) => { const n = netOf(k); return (
              <button key={k} className={"cl-month-row" + (k === cur ? " on" : "")} onClick={() => setSel(k)}>
                <span className="cl-row-title">{monthLabel(k)}{k === thisMonth ? " · so far" : ""}</span>
                <span className={"cl-money " + (n >= 0 ? "pos" : "neg")}>{fmt(n)}</span>
              </button>
            ); })}</div>}
      </Panel>
    </div>
  );
}

function SyncPanel({ sync, connect, disconnect, choose }) {
  const [tok, setTok] = useState("");
  const [copied, setCopied] = useState(false);
  const shareLink = async () => {
    const link = `${location.origin}${location.pathname}#sync=${syncToken()}`;
    if (navigator.share) { try { await navigator.share({ title: "BinderBooks", url: link }); } catch {} }
    else { try { await navigator.clipboard.writeText(link); setCopied(true); setTimeout(() => setCopied(false), 2000); } catch {} }
  };
  const label = {
    off: "Not connected — paste your sync token to back up this ledger",
    checking: "Connecting…",
    on: "Synced — changes back up to your AWS account",
    error: "Sync hiccup — working locally, will retry on your next change",
    badtoken: "Token rejected — paste it again",
    choose: "The cloud has a ledger and so does this device — pick which one wins",
  }[sync];
  return (
    <div className="cl-sync">
      <div className="cl-sync-status"><span className={"cl-sync-dot " + sync} />{label}</div>
      {(sync === "off" || sync === "badtoken") && (
        <div className="cl-sync-join">
          <input className="cl-in" type="password" placeholder="Sync token" value={tok} onChange={(e) => setTok(e.target.value)} />
          <button className="cl-sync-connect" disabled={!tok.trim()} onClick={() => connect(tok)}>Connect</button>
        </div>
      )}
      {sync === "choose" && (
        <div className="cl-sync-choose">
          <button className="cl-sync-connect" onClick={() => choose(true)}>Use cloud copy — replace this device</button>
          <button className="cl-sync-connect" onClick={() => choose(false)}>Upload this device's copy — replace cloud</button>
        </div>
      )}
      {sync === "on" && <button className="cl-link cl-sync-off" onClick={shareLink}>{copied ? "Link copied!" : "Send setup link to another device"}</button>}
      {(sync === "on" || sync === "error") && <button className="cl-link cl-sync-off" onClick={disconnect}>Disconnect this device</button>}
    </div>
  );
}

/* ================================================================== */
function Rips({ state, patch }) {
  const [adding, setAdding] = useState(false);
  const [open, setOpen] = useState(null);
  const addRip = useCallback((r) => { patch((s) => ({ rips: [{ id: uid(), hits: [], ...r }, ...s.rips], buys: r.buyId ? s.buys.map((b) => (b.id === r.buyId ? { ...b, ripped: true } : b)) : s.buys })); setAdding(false); }, [patch]);
  const delRip = useCallback((id) => patch((s) => {
    const rip = s.rips.find((r) => r.id === id);
    const hitIds = new Set((rip?.hits || []).map((h) => h.id));
    return {
      rips: s.rips.filter((r) => r.id !== id),
      inventory: (s.inventory || []).filter((c) => !(hitIds.has(c.hitId) && c.status !== "Sold")),
      buys: rip?.buyId ? s.buys.map((b) => (b.id === rip.buyId ? { ...b, ripped: false } : b)) : s.buys,
    };
  }), [patch]);
  const addHit = useCallback((ripId, hit) => patch((s) => addHitToState(s, ripId, hit)), [patch]);
  const updHit = useCallback((ripId, hit) => patch((s) => updHitInState(s, ripId, hit)), [patch]);
  const delHit = useCallback((ripId, hitId) => patch((s) => ({
    rips: s.rips.map((r) => (r.id === ripId ? { ...r, hits: r.hits.filter((h) => h.id !== hitId) } : r)),
    inventory: (s.inventory || []).filter((c) => !(c.hitId === hitId && c.status !== "Sold")),
  })), [patch]);
  const onToggle = useCallback((id) => setOpen((o) => (o === id ? null : id)), []);
  const sorted = useMemo(() => [...state.rips].sort(byDateDesc), [state.rips]);
  // Only the expanded rip renders its hit list, so only its hits need art —
  // resolving images for every rip's hits would feed every RipCard a
  // changing `images` reference and defeat its memoization.
  const openRip = sorted.find((r) => r.id === open);
  const hitImages = useCardImages(openRip?.hits || EMPTY_ARR);

  return (
    <div className="cl-stack">
      <Header title="Rips" sub="Cost of the packs vs. value of what you pulled" onAdd={() => setAdding(!adding)} addOpen={adding} />
      {adding && <RipForm buys={state.buys} rippedBuyIds={new Set(state.rips.map((r) => r.buyId).filter(Boolean))} onSave={addRip} onCancel={() => setAdding(false)} />}
      {state.rips.length === 0 && !adding && <Empty>Nothing ripped yet. Log a rip — say 5 packs of Chaos Rising — then drop in each hit and watch the P&amp;L land.</Empty>}
      <div className="cl-stack">
        {sorted.map((r) => (
          <RipCard key={r.id} rip={r} pl={ripPL(r, state.buys)} cost={ripCostOf(r, state.buys)} isOpen={open === r.id} images={open === r.id ? hitImages : EMPTY_OBJ} onToggle={onToggle} onDelete={delRip} onAddHit={addHit} onEditHit={updHit} onDeleteHit={delHit} />
        ))}
      </div>
    </div>
  );
}
function RipForm({ buys, rippedBuyIds, onSave, onCancel }) {
  const sets = useSets();
  const [f, setF] = useState({ product: "", cost: "", source: "Gamecraft", date: today(), buyId: "" });
  const [lines, setLines] = useState([{ set: "", packs: "" }]);
  // hide buys already ripped — linked to a rip, or flagged ripped by hand on the
  // buy itself. Newest first, sealed breaking ties so rippable boxes surface.
  const opts = (buys || []).filter((b) => !(b.ripped || rippedBuyIds?.has(b.id))).sort((a, b) => byDateDesc(a, b) || ((b.category === "Sealed") - (a.category === "Sealed")));
  const setLine = (i, k, v) => setLines((ls) => ls.map((l, j) => (j === i ? { ...l, [k]: v } : l)));
  const addLine = () => setLines((ls) => [...ls, { set: "", packs: "" }]);
  const delLine = (i) => setLines((ls) => (ls.length > 1 ? ls.filter((_, j) => j !== i) : ls));
  const linkBuy = (id) => {
    const b = (buys || []).find((x) => x.id === id);
    if (!b) return setF({ ...f, buyId: "" });
    setF({ ...f, buyId: id, cost: String(b.cost), source: b.source, product: f.product || b.name || b.item });
    // seed the per-set pack rows from the buy's product lines (a Mega Zygarde box
    // entered as 6× Perfect Order + 2× Phantasmal becomes those two rip rows),
    // merging duplicate sets by quantity; fall back to the buy's single set.
    const packsBySet = {};
    (b.lines || []).forEach((l) => { if (l.set) packsBySet[l.set] = (packsBySet[l.set] || 0) + (Number(l.qty) || 0); });
    const seed = Object.keys(packsBySet).length
      ? Object.entries(packsBySet).map(([set, packs]) => ({ set, packs: packs ? String(packs) : "" }))
      : (buyLineSet(b) ? [{ set: buyLineSet(b), packs: "" }] : null);
    if (seed) setLines((ls) => (ls.length === 1 && !ls[0].set && !ls[0].packs ? seed : ls));
  };
  const save = () => {
    const clean = lines.map((l) => ({ set: l.set, packs: Number(l.packs) || 0 })).filter((l) => l.set || l.packs);
    const totalPacks = clean.reduce((a, l) => a + l.packs, 0);
    const primary = [...clean].sort((a, b) => b.packs - a.packs)[0];
    onSave({
      product: f.product, set: primary ? primary.set : "", packs: totalPacks,
      setPacks: clean.length > 1 ? clean : undefined,
      cost: f.buyId ? 0 : Number(f.cost) || 0, source: f.source, date: f.date, buyId: f.buyId || null,
    });
  };
  return (
    <Form>
      <Field label="Product"><input className="cl-in" placeholder="Mega Zygarde EX Box" value={f.product} onChange={(e) => setF({ ...f, product: e.target.value })} /></Field>
      <Field label="Sets in this rip (add a row per set — packs split the cost by what you pull)">
        <div className="cl-stack sm">
          {lines.map((l, i) => (
            <div key={i} className="cl-setline">
              <SetPicker sets={sets} value={l.set} onChange={(v) => setLine(i, "set", v)} allowEmpty />
              <input className="cl-in cl-setline-packs" inputMode="numeric" placeholder="Packs" value={l.packs} onChange={(e) => setLine(i, "packs", e.target.value)} />
              {lines.length > 1 && <button className="cl-x" onClick={() => delLine(i)}><X size={13} /></button>}
            </div>
          ))}
          <button className="cl-add-hit" onClick={addLine}><Plus size={14} /> Add another set</button>
        </div>
      </Field>
      {opts.length > 0 && <Field label="Ripped from a buy (optional — avoids double-counting cost)"><select className="cl-in" value={f.buyId} onChange={(e) => linkBuy(e.target.value)}><option value="">— not linked / enter new cost —</option>{opts.map((b) => <option key={b.id} value={b.id}>{b.name || b.item} · {b.source} · {fmt(Number(b.cost) || 0)}</option>)}</select></Field>}
      <div className="cl-grid2"><Field label={f.buyId ? "Cost (from buy)" : "Total cost"}><MoneyInput value={f.cost} onChange={(v) => !f.buyId && setF({ ...f, cost: v })} /></Field><Field label="Date"><input className="cl-in" type="date" value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} /></Field></div>
      <Field label="Bought from"><Select opts={SOURCES} value={f.source} onChange={(v) => setF({ ...f, source: v })} /></Field>
      <Actions onCancel={onCancel} label="Save rip" disabled={!f.product || (!f.buyId && !f.cost)} onSave={save} />
    </Form>
  );
}
/* ==================================================================
   One card search, for every screen that looks a card up.

   Rips, Sales, Inventory and Lookup each searched differently before
   this. Rips and Sales asked the card database and nothing else,
   Inventory had no search at all and made you type the name, and only
   the Lookup panel could read the local TCGplayer catalog. So the same
   words found different cards on different screens, and a stamped print
   was reachable from exactly one of the four.

   Now every screen mounts this component. Two sources feed one list:

     1. the local TCGplayer catalog — offline, answers in milliseconds,
        carries the exact SKU and the printing, and is the only source
        that holds a stamped print at all;
     2. the card database — slower and online-only, but it covers cards
        the seller's own export never included, and it brings the images.

   The catalog answers first and the database fills in behind it. A row
   from the catalog shows its printing, which is also how you see that it
   carries a SKU. Every row hands the caller the same shape — the app's
   search-result card — so the forms and the three add-paths below take
   catalog rows and database rows through identical code. */

/* Stamped prints. TCGplayer sells the prerelease stamp as its own
   product and files it under "Miscellaneous Cards & Products", not under
   the set whose name is stamped on the card — "Reshiram (Stellar Crown
   Stamped)" is 022/142 and is not in Stellar Crown. The card database
   has no row for one at all. */
const MISC_SET = "Miscellaneous Cards & Products";
const STAMPED_RE = /\b(stamp|stamped|prerelease|staff)\b/i;
/* The set scope is shared by every screen and sticks between them: a
   stack of cards is nearly always one set, and picking it twice is the
   kind of step that gets skipped. */
const CATSET_KEY = "cardledger:catset:v1";
const CARD_SEARCH_MIN = 2;
const NO_EXTRA = [];

/* Two rows describe one card when the name and the collector number
   agree. The catalog copy wins, because it knows the printing and the
   SKU. Printings of one card are not duplicates — they are separate
   products with separate prices — so this only ever drops a database
   row that the catalog already answered. */
const cardDedupeKey = (c) => `${String(c.name || "").toLowerCase()}|${normNum(c.number)}`;

const noMatchMsg = (set, q) =>
  (set ? `Nothing in ${set} matches “${q}”.` : `Nothing matches “${q}”.`) +
  (STAMPED_RE.test(q) ? ` TCGplayer files stamped prints under ${MISC_SET} — try browsing that set, or import its export.` : "");

function CardSearch({
  value, onChange,                 // controlled text; omit both for an internal box
  onPick,                          // (card) => void — omit in a panel that only shows actions
  placeholder = "Search a card — name, number, or set",
  panel = false,                   // Lookup shows a list; the forms show a popover
  actions,                         // panel only: (card) => JSX rendered under each row
  extra = NO_EXTRA,                // panel only: cards from another source, listed first
}) {
  const [own, setOwn] = useState("");
  const controlled = value !== undefined;
  const q = controlled ? value : own;
  const setQ = controlled ? onChange : setOwn;

  const [sets, setSets] = useState([]);
  const [set, setSet] = useState(() => { try { return localStorage.getItem(CATSET_KEY) || ""; } catch { return ""; } });
  const [local, setLocal] = useState([]);
  const [remote, setRemote] = useState([]);
  const [busy, setBusy] = useState(false);
  const [failed, setFailed] = useState(false);
  const [open, setOpen] = useState(false);
  const skip = useRef(false);            // a pick must not reopen the popover
  const mounted = useRef(false);         // nor does opening an edit form with a name already in it

  useEffect(() => { catalogSets().then(setSets, () => setSets([])); }, []);
  const pickSet = (s) => { setSet(s); try { localStorage.setItem(CATSET_KEY, s); } catch {} };

  const typed = q.trim();
  /* A picked set browses itself with an empty box, but only in the panel.
     A form is one line on a phone, and filling it with a whole set the
     moment it opens buries the field the user came to type in. */
  const browsing = panel && !!set && typed.length < CARD_SEARCH_MIN;
  const searchable = typed.length >= CARD_SEARCH_MIN || browsing;

  /* The catalog is on the device, so it needs only enough delay to skip
     the keystrokes of a fast typist. */
  useEffect(() => {
    if (!searchable) { setLocal([]); return; }
    let live = true;
    const t = setTimeout(() => {
      searchCatalog({ set, q: typed, limit: 40 })
        .then((r) => { if (live) setLocal(r); }, () => { if (live) setLocal([]); });
    }, 120);
    return () => { live = false; clearTimeout(t); };
  }, [set, typed, searchable]);

  const runDatabase = async (text) => {
    const { q: term, set: setFilter, number, descriptors, first } = parseQuery(text);
    const want = [...new Set(descriptors.flatMap((d) => DESC_RARITY[d] || []))];
    const found = await searchCards({ q: term, set: setFilter, number });
    const list = found.sort((a, b) => {
      const av = a.name.toLowerCase().startsWith(first) ? 0 : 1;
      const bv = b.name.toLowerCase().startsWith(first) ? 0 : 1;
      if (av !== bv) return av - bv;
      if (want.length) {
        const ad = want.some((w) => (a.rarity || "").toLowerCase().includes(w)) ? 0 : 1;
        const bd = want.some((w) => (b.rarity || "").toLowerCase().includes(w)) ? 0 : 1;
        if (ad !== bd) return ad - bd;
      }
      return (cardPrice(b) || 0) - (cardPrice(a) || 0);
    }).slice(0, 14);
    qcacheSet(text.toLowerCase(), list);
    return list;
  };

  useEffect(() => {
    setFailed(false);
    if (typed.length < CARD_SEARCH_MIN) { setRemote([]); setBusy(false); return; }
    const cached = qcacheGet(typed.toLowerCase());
    if (cached) { setRemote(cached); setBusy(false); return; }
    let live = true;
    setBusy(true);
    // 900ms of quiet typing fires the request — the catalog has already
    // answered by then, so the box never looks idle while this waits
    const t = setTimeout(() => {
      runDatabase(typed).then(
        (list) => { if (live) { setRemote(list); setBusy(false); } },
        (e) => { if (live) { setRemote([]); setBusy(false); setFailed(e.status === 401 ? "token" : true); } });
    }, 900);
    return () => { live = false; clearTimeout(t); };
  }, [typed]);

  const rows = useMemo(() => {
    const seen = new Set();
    const out = [];
    const push = (card, printing, prefix) => {
      const key = cardDedupeKey(card);
      out.push({ key: `${prefix}${card.id}`, card, printing });
      seen.add(key);
    };
    for (const c of extra) push(c, null, "x");
    for (const rec of local) push(catalogEntryCard(rec), rec.printing, "c");
    /* A catalog row already exists per printing, but the card database returns
       one row per card with every printing's price inside it — so a reverse
       holo the catalog hasn't got would otherwise be invisible. Split it into
       the printings it actually carries a price for; a card with no price data
       stays one undifferentiated row. */
    for (const c of remote) {
      if (seen.has(cardDedupeKey(c))) continue;
      const prices = c.tcgplayer?.prices;
      const variants = prices ? VARIANTS.filter((v) => prices[PTCG_VARIANT_KEY[v]]) : [];
      if (variants.length) variants.forEach((v) => out.push({ key: `d${c.id}-${v}`, card: { ...c, variant: v }, printing: v }));
      else out.push({ key: `d${c.id}`, card: c });
    }
    return out.slice(0, panel ? 60 : 14);
  }, [extra, local, remote, panel]);

  /* Typing reopens the list. A pick sets `skip` first, because on a
     controlled box the pick itself rewrites the text and would otherwise
     reopen the popover the user just chose from. Mounting is not typing:
     an edit form opens with the card's name already in the box, and popping
     the list open over its own buttons is not what asking to edit meant. */
  useEffect(() => {
    if (!mounted.current) { mounted.current = true; return; }
    if (skip.current) { skip.current = false; return; }
    if (searchable) setOpen(true);
  }, [typed]);

  const choose = (c) => { skip.current = true; setOpen(false); onPick?.(c); };

  /* One row, one markup, both modes. The printing chip marks a row that
     came from the catalog and therefore carries a SKU. */
  const rowBody = (r) => {
    const c = r.card;
    const price = cardPrice(c, c.variant);
    return (<>
      {c.images?.small ? <img src={c.images.small} alt="" className="cl-ac-img" loading="lazy" /> : <div className="cl-ac-img" />}
      <div className="cl-ac-meta">
        <div className="cl-ac-name">{c.name}</div>
        <div className="cl-row-meta">
          {r.printing && <span className="cl-chip">{VARIANT_SHORT[r.printing] || r.printing}</span>}
          <span>{[c.set?.name, c.number, c.rarity].filter(Boolean).join(" · ")}</span>
        </div>
      </div>
      <div className="cl-ac-price">{price != null ? fmt(price) : "—"}</div>
    </>);
  };

  const status = failed === "token" ? NO_TOKEN_MSG
    : failed ? "retry"
    : busy && !rows.length ? "Searching the card database…"
    : !searchable ? `Type ${CARD_SEARCH_MIN} letters or more${sets.length ? ", or pick a set to browse it" : ""}.`
    : !rows.length ? noMatchMsg(set, typed)
    : null;
  const statusNode = status === "retry"
    ? <button className="cl-ac-loading cl-ac-retry" onMouseDown={(e) => e.preventDefault()} onClick={() => { setFailed(false); setBusy(true); runDatabase(typed).then((l) => { setRemote(l); setBusy(false); }, (e) => { setBusy(false); setFailed(e.status === 401 ? "token" : true); }); }}>Card search didn&rsquo;t respond &mdash; tap to retry</button>
    : status ? <div className={panel ? "cl-import-msg" : "cl-ac-loading"}>{status}</div>
    : null;

  const setPicker = sets.length > 0 && (
    <select className="cl-in cl-cs-set" value={set} onChange={(e) => pickSet(e.target.value)}>
      <option value="">All sets</option>
      {sets.map((s) => <option key={s.key} value={s.name}>{s.name} ({s.count})</option>)}
    </select>
  );
  const box = (
    <input
      className="cl-in"
      inputMode="search"
      placeholder={placeholder}
      value={q}
      onChange={(e) => setQ(e.target.value)}
      onFocus={() => searchable && setOpen(true)}
      onBlur={panel ? undefined : () => setTimeout(() => setOpen(false), 200)}
    />
  );

  if (panel) return (
    <div className="cl-cs">
      {setPicker}
      <div className="cl-search">{box}{q && <button className="cl-search-btn" onClick={() => setQ("")}><X size={15} /></button>}</div>
      {rows.length > 0 && <div className="cl-cs-rows">
        {rows.map((r) => (
          <div key={r.key} className="cl-cs-card cl-row-enter">
            {onPick
              ? <button className="cl-ac-item" onClick={() => choose(r.card)}>{rowBody(r)}</button>
              : <div className="cl-ac-item as-row">{rowBody(r)}</div>}
            {actions && <div className="cl-lk-actions">{actions(r.card)}</div>}
          </div>
        ))}
      </div>}
      {statusNode}
    </div>
  );

  return (
    <div className="cl-cs">
      {setPicker}
      <div className="cl-ac">
        {box}
        {open && <div className="cl-ac-pop">
          {rows.map((r) => (
            <button key={r.key} className="cl-ac-item cl-row-enter" onMouseDown={(e) => e.preventDefault()} onClick={() => choose(r.card)}>{rowBody(r)}</button>
          ))}
          {statusNode}
        </div>}
      </div>
    </div>
  );
}
/* The language and the grade stick between adds. A rip is one box or one lot,
   so its cards are nearly always all the same on both counts — retyping
   "Japanese, CGC 9" eight times is the kind of thing that gets skipped, and a
   slab logged as an English raw is then priced as one. */
/* With `initial` this edits that hit in place and reports through `onSave`;
   without it, it is the add form that lives under every rip's hit list. The
   printing select matters most in the edit case — a hit logged off the wrong
   search row is fixed there without retyping the card. */
export function HitForm({ initial, onAdd, onSave, onCancel }) {
  const blank = (keep) => ({ name: "", set: "", number: "", value: "", variant: "", tcgplayerId: "", productId: "", lang: keep?.lang || "en", grade: keep?.grade || "Raw" });
  const [f, setF] = useState(() => (initial
    ? { name: initial.name || "", set: initial.set || "", number: initial.number || "", value: initial.value != null ? String(initial.value) : "", variant: initial.variant || "", tcgplayerId: initial.tcgplayerId || "", lang: initial.lang || "en", grade: initial.grade || "Raw" }
    : blank()));
  // A card's art the moment it's picked — ephemeral, not stored on the hit
  // itself, since this app treats images as a live lookup everywhere else.
  const [preview, setPreview] = useState(null);
  const submit = () => {
    if (!f.name) return;
    const out = { ...f, value: Number(f.value) || 0 };
    if (initial) { onSave({ ...out, id: initial.id }); return; }
    onAdd(out); setF(blank(f)); setPreview(null);
  };
  // the search prices English raw singles, so its price is one. Name, set and
  // number are still worth taking for a slab or a JP card; the price is not,
  // and silently filling it is the mistake the grade field prevents.
  const priceable = f.grade === "Raw" && f.lang === "en";
  /* A catalog row carries its SKU and printing. Keep both — they are what
     let the TCGplayer upload list this hit without matching it by name. */
  const pick = (c) => {
    setF({
      ...f, name: c.name, set: c.set?.name || "", number: c.number || "",
      variant: c.variant || "", tcgplayerId: c.tcgplayerId || "", productId: c.productId || "",
      value: priceable && cardPrice(c, c.variant) != null ? String(cardPrice(c, c.variant)) : "",
    });
    setPreview(c.images?.small || null);
  };
  return (
    <div className="cl-hitform">
      <CardSearch value={f.name} onChange={(v) => { setF({ ...f, name: v }); setPreview(null); }} onPick={pick} placeholder="Add a hit — try “Dedenne Perfect Order” or “Dedenne 143”" />
      {preview && <div className="cl-hitform-preview"><img className="cl-hitform-preview-img" src={preview} alt={f.name} loading="lazy" /><span className="cl-row-meta">{f.name}</span></div>}
      <div className="cl-grid3">
        <Field label="Set"><input className="cl-in" placeholder="Set" value={f.set} onChange={(e) => setF({ ...f, set: e.target.value })} /></Field>
        <Field label="No."><input className="cl-in" placeholder="No." value={f.number} onChange={(e) => setF({ ...f, number: e.target.value })} /></Field>
        <Field label="Value"><MoneyInput value={f.value} onChange={(v) => setF({ ...f, value: v })} placeholder="Value" /></Field>
      </div>
      <div className="cl-grid2">
        <Field label="Language"><select className="cl-in" value={f.lang} onChange={(e) => setF({ ...f, lang: e.target.value })}>{LANGS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></Field>
        <Field label="Grade"><select className="cl-in" value={f.grade} onChange={(e) => setF({ ...f, grade: e.target.value })}>{GRADES.map((g) => <option key={g} value={g}>{g === "Raw" ? "Raw (ungraded)" : g}</option>)}</select></Field>
      </div>
      <Field label="Printing"><select className="cl-in" value={f.variant} onChange={(e) => setF({ ...f, variant: e.target.value })}><option value="">— not set —</option>{VARIANTS.map((v) => <option key={v} value={v}>{v}</option>)}</select></Field>
      {!priceable && <div className="cl-gradeest-note">Value these by hand — the card search prices English raw singles. Each one lands in Inventory {f.grade === "Raw" ? "as a Japanese card" : `as a ${f.grade} slab`}, where “Pull slab price” and “Refresh market prices” comp it properly.</div>}
      {initial
        ? <div className="cl-form-actions"><button className="cl-cancel" onClick={onCancel}>Cancel</button><button className="cl-hit-add" onClick={submit}>Save changes</button></div>
        : <button className="cl-hit-add" onClick={submit}><Plus size={14} /> Add hit</button>}
    </div>
  );
}

/* ================================================================== */
function Buys({ state, patch }) {
  const [adding, setAdding] = useState(false);
  const [editId, setEditId] = useState(null);
  const add = useCallback((b) => { patch((s) => ({ buys: [{ id: uid(), ...b }, ...s.buys] })); setAdding(false); }, [patch]);
  const upd = useCallback((b) => { patch((s) => ({ buys: s.buys.map((x) => (x.id === b.id ? { ...x, ...b, seed: false } : x)) })); setEditId(null); }, [patch]);
  const del = useCallback((id) => patch((s) => ({ buys: s.buys.filter((b) => b.id !== id) })), [patch]);
  const toggleRipped = useCallback((id) => patch((s) => ({ buys: s.buys.map((b) => (b.id === id ? { ...b, ripped: !b.ripped } : b)) })), [patch]);
  const onEdit = useCallback((id) => { setEditId(id); setAdding(false); }, []);
  const onCancelEdit = useCallback(() => setEditId(null), []);
  const total = useMemo(() => state.buys.reduce((s, b) => s + (Number(b.cost) || 0), 0), [state.buys]);
  const sorted = useMemo(() => [...state.buys].sort(byDateDesc), [state.buys]);

  return (
    <div className="cl-stack">
      <Header title="Buys" sub={`Money out · ${fmt(total)} total`} onAdd={() => { setAdding(!adding); setEditId(null); }} addOpen={adding} />
      {adding && <BuyForm onSave={add} onCancel={() => setAdding(false)} />}
      {state.buys.length === 0 && !adding && <Empty>No purchases yet.</Empty>}
      <div className="cl-stack sm">
        {sorted.map((b) => (
          <BuyRow key={b.id} buy={b} isEditing={editId === b.id} onEdit={onEdit} onDelete={del} onToggleRipped={toggleRipped} onSave={upd} onCancelEdit={onCancelEdit} />
        ))}
      </div>
    </div>
  );
}
function SetPicker({ sets, value, onChange, allowEmpty }) {
  // "other" switches the set dropdown to free text — for sets the API
  // doesn't have yet, or when the API is unavailable
  const [other, setOther] = useState(() => !!value && (sets ? !sets.includes(value) : true));
  if (other) return <input className="cl-in" placeholder="Set name" value={value} onChange={(e) => onChange(e.target.value)} />;
  return (
    <select className="cl-in" value={value} onChange={(e) => { const v = e.target.value; if (v === "__other") { setOther(true); onChange(""); } else onChange(v); }}>
      <option value="" disabled={!allowEmpty}>{sets === null ? "Loading sets…" : allowEmpty ? "— optional —" : "Set…"}</option>
      {(sets || []).map((s) => <option key={s} value={s}>{s}</option>)}
      <option value="__other">Other / type it…</option>
    </select>
  );
}
function LineRow({ line, sets, onChange, onRemove, removable }) {
  return (
    <div className="cl-lineitem">
      <div className="cl-line-r1">
        <input className="cl-in" inputMode="numeric" placeholder="Qty" value={line.qty} onChange={(e) => onChange({ ...line, qty: e.target.value.replace(/[^0-9]/g, "") })} />
        <SetPicker sets={sets} value={line.set} onChange={(v) => onChange({ ...line, set: v })} />
      </div>
      <div className={"cl-line-r2" + (removable ? "" : " nox")}>
        <select className="cl-in" value={line.product} onChange={(e) => onChange({ ...line, product: e.target.value })}>{PRODUCTS.map((p) => <option key={p} value={p}>{p}</option>)}</select>
        <MoneyInput value={line.cost} onChange={(v) => onChange({ ...line, cost: v })} placeholder="auto" />
        {removable && <button className="cl-x" onClick={onRemove}><X size={13} /></button>}
      </div>
    </div>
  );
}
export function BuyForm({ initial, onSave, onCancel }) {
  const sets = useSets();
  const blank = () => ({ id: uid(), qty: "1", set: "", product: "Booster Pack", cost: "" });
  const [f, setF] = useState(initial
    ? { category: initial.category, source: initial.source, date: initial.date, item: initial.item || "", name: initial.name || "", cost: numStr(initial.cost), total: numStr(initial.cost),
        lines: initial.lines?.length ? initial.lines.map((l) => ({ ...l, qty: String(l.qty || 1), cost: numStr(l.cost) })) : null }
    : { category: "Sealed", source: "Gamecraft", date: today(), item: "", name: "", cost: "", total: "", lines: [blank()] });
  const setLine = (ln) => setF((p) => ({ ...p, lines: p.lines.map((l) => (l.id === ln.id ? ln : l)) }));
  const anyBlank = !!f.lines && f.lines.some((l) => !l.cost);
  const sumExplicit = f.lines ? f.lines.reduce((s, l) => s + (Number(l.cost) || 0), 0) : 0;
  const total = f.lines ? (anyBlank ? Number(f.total) || 0 : sumExplicit) : Number(f.cost) || 0;
  // blank-cost lines split whatever the typed total leaves over, weighted by
  // qty; rounding cents land on the last blank line so the sum stays exact
  const lineCosts = () => {
    if (!anyBlank) return f.lines.map((l) => Number(l.cost) || 0);
    const blanks = f.lines.map((l, i) => (!l.cost ? i : -1)).filter((i) => i >= 0);
    const blankQty = blanks.reduce((s, i) => s + (Number(f.lines[i].qty) || 1), 0);
    const remainder = Math.max(0, total - sumExplicit);
    const out = f.lines.map((l) => Number(l.cost) || 0);
    let used = 0;
    blanks.forEach((i, k) => {
      out[i] = k === blanks.length - 1
        ? Math.round((remainder - used) * 100) / 100
        : Math.round((remainder * ((Number(f.lines[i].qty) || 1) / blankQty)) * 100) / 100;
      used += out[i];
    });
    return out;
  };
  const label = f.lines
    ? f.lines.filter((l) => l.set || l.product).map((l) => `${Number(l.qty) || 1}× ${l.set} ${l.product}`.replace(/\s+/g, " ").trim()).join(" · ")
    : f.item;
  const valid = f.lines
    ? f.lines.every((l) => l.set && l.product) && (anyBlank ? !!f.total : sumExplicit > 0)
    : !!f.item && !!f.cost;
  return (
    <Form editing={!!initial}>
      {f.lines ? (
        <>
          <Field label="Sealed product (optional — names the box itself)"><input className="cl-in" placeholder="Mega Zygarde EX Premium Collection" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></Field>
          <div className="cl-field">
            <span>{f.name ? "What's inside" : "Products"}</span>
            <div className="cl-stack sm">
              {f.lines.map((l) => <LineRow key={l.id} line={l} sets={sets} onChange={setLine} removable={f.lines.length > 1} onRemove={() => setF((p) => ({ ...p, lines: p.lines.filter((x) => x.id !== l.id) }))} />)}
              <button className="cl-addline" onClick={() => setF((p) => ({ ...p, lines: [...p.lines, blank()] }))}>+ Add another product</button>
            </div>
          </div>
        </>
      ) : (
        <>
          <Field label="Item"><input className="cl-in" placeholder="Prismatic ETB" value={f.item} onChange={(e) => setF({ ...f, item: e.target.value })} /></Field>
          <button className="cl-addline" onClick={() => setF({ ...f, lines: [blank()] })}>Switch to structured lines (qty · set · product)</button>
        </>
      )}
      <div className="cl-grid2"><Field label="Category"><Select opts={BUY_CATS} value={f.category} onChange={(v) => setF({ ...f, category: v })} /></Field><Field label="From"><Select opts={SOURCES} value={f.source} onChange={(v) => setF({ ...f, source: v })} /></Field></div>
      <div className="cl-grid2">
        {f.lines
          ? anyBlank
            ? <Field label="Total cost"><MoneyInput value={f.total} onChange={(v) => setF({ ...f, total: v })} /></Field>
            : <Field label="Total (sum of lines)"><div className="cl-in cl-total-ro">{fmt(total)}</div></Field>
          : <Field label="Cost"><MoneyInput value={f.cost} onChange={(v) => setF({ ...f, cost: v })} /></Field>}
        <Field label="Date"><input className="cl-in" type="date" value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} /></Field>
      </div>
      <Actions onCancel={onCancel} label={initial ? "Update buy" : "Save buy"} disabled={!valid || !total}
        onSave={() => { const costs = f.lines ? lineCosts() : null; onSave({ ...(initial ? { id: initial.id } : {}), item: label, name: (f.name || "").trim(), category: f.category, source: f.source, date: f.date, cost: total,
          ...(f.lines ? { lines: f.lines.map((l, i) => ({ id: l.id, qty: Number(l.qty) || 1, set: l.set, product: l.product, cost: costs[i] })) } : {}) }); }} />
    </Form>
  );
}

/* ================================================================== */
/* TCGPlayer order import: the bookmarklet on an order-details page copies a
   normalized JSON blob; we parse it into a sale with real per-card lines and
   reconcile against kept inventory so matched cards flip to Sold. */
const normKey = (s) => String(s || "").toLowerCase().replace(/[^a-z0-9]/g, "");
// Match a TCGP order line to a kept inventory card by name + collector number.
// Numbers go through normNum so the TCGP title's "095/086" (number / set total)
// lines up with the bare API number ("95") inventory stores — otherwise nothing
// flips to Sold. A missing number on either side falls back to a name-only match.
function matchInvCard(line, avail, used) {
  const ln = normKey(line.name), lnum = normNum(line.number);
  if (!ln) return null;
  return avail.find((c) => !used.has(c.id) && normKey(c.name) === ln && (!lnum || !normNum(c.number) || normNum(c.number) === lnum)) || null;
}
function parseTcgpOrder(text) {
  let o; try { o = JSON.parse(String(text).trim()); } catch { return { error: "That isn't valid JSON — copy the order again with the bookmarklet." }; }
  if (!o || o.source !== "tcgplayer-order" || !Array.isArray(o.cards) || !o.cards.length) return { error: "Not a TCGP order blob. Click the bookmarklet on an order-details page first." };
  return { order: o };
}

function Sales({ state, patch }) {
  const [adding, setAdding] = useState(false);
  const [editId, setEditId] = useState(null);
  const [msg, setMsg] = useState("");
  const [pasteOpen, setPasteOpen] = useState(false);
  const [pasteText, setPasteText] = useState("");
  const [q, setQ] = useState("");
  const [view, setView] = useState("all"); // all | bare | dups
  const fileRef = useRef();
  const soldIds = (x) => (x.cards || []).map((c) => c.invId).filter(Boolean);
  const markSold = (inv, ids) => (ids.length ? inv.map((c) => (ids.includes(c.id) ? { ...c, status: "Sold" } : c)) : inv);
  const add = useCallback((x) => { patch((s) => ({ sales: [{ id: uid(), ...x }, ...s.sales], inventory: markSold(s.inventory, soldIds(x)) })); setAdding(false); }, [patch]);
  const upd = useCallback((x) => { patch((s) => ({ sales: s.sales.map((y) => (y.id === x.id ? { ...y, ...x, seed: false } : y)), inventory: markSold(s.inventory, soldIds(x)) })); setEditId(null); }, [patch]);
  const del = useCallback((id) => patch((s) => ({ sales: s.sales.filter((x) => x.id !== id) })), [patch]);
  const onEditRow = useCallback((id) => { setEditId(id); setAdding(false); }, []);
  const onCancelEdit = useCallback(() => setEditId(null), []);
  const earned = state.sales.reduce((s, x) => s + saleNet(x), 0);
  const terms = q.trim().toLowerCase().split(/\s+/).filter(Boolean);
  const noCards = (x) => !(x.cards || []).length;
  const { sigCounts, bareCount, dupExtra } = useMemo(() => {
    const sigCounts = new Map();
    state.sales.forEach((x) => { const k = saleSig(x); sigCounts.set(k, (sigCounts.get(k) || 0) + 1); });
    const bareCount = state.sales.filter(noCards).length;
    const dupExtra = [...sigCounts.values()].reduce((a, c) => a + (c - 1), 0);
    return { sigCounts, bareCount, dupExtra };
  }, [state.sales]); // eslint-disable-line react-hooks/exhaustive-deps
  const isDup = (x) => sigCounts.get(saleSig(x)) > 1;
  const blob = (x) => [x.item, x.channel, x.date, (x.cards || []).map((c) => `${c.name} ${c.set || ""} ${c.number || ""}`).join(" "), x.price, saleNet(x)].join(" ").toLowerCase();
  const sorted = useMemo(() => [...state.sales]
    .filter((x) => (view !== "bare" || noCards(x)) && (view !== "dups" || isDup(x)) && terms.every((t) => blob(x).includes(t)))
    .sort(view === "dups" ? (a, b) => saleSig(a).localeCompare(saleSig(b)) || byDateDesc(a, b) : byDateDesc),
  [state.sales, view, q, sigCounts]); // eslint-disable-line react-hooks/exhaustive-deps

  const mergeDupes = () => {
    const groups = new Map();
    state.sales.forEach((x) => { const k = saleSig(x); const g = groups.get(k); g ? g.push(x) : groups.set(k, [x]); });
    const score = (x) => (x.cards?.length || 0) * 1000 + ((Number(x.fees) || 0) > 0 ? 40 : 0) + ((Number(x.shipping) || 0) > 0 ? 20 : 0) + Math.min(String(x.item || "").length, 99);
    const dropIds = new Set();
    for (const g of groups.values()) {
      if (g.length < 2) continue;
      const best = g.reduce((a, b) => (score(b) > score(a) ? b : a));
      g.forEach((x) => { if (x.id !== best.id) dropIds.add(x.id); });
    }
    if (!dropIds.size) { setMsg("No duplicate orders found."); return; }
    if (typeof window !== "undefined" && !window.confirm(`Remove ${dropIds.size} duplicate sale${dropIds.size === 1 ? "" : "s"}, keeping the most complete copy of each order?`)) return;
    patch((s) => ({ sales: s.sales.filter((x) => !dropIds.has(x.id)) }));
    setView("all");
    setMsg(`Removed ${dropIds.size} duplicate sale${dropIds.size === 1 ? "" : "s"}.`);
  };

  const onFile = (e) => {
    const file = e.target.files?.[0]; if (!file) return;
    Papa.parse(file, { header: true, skipEmptyLines: true, complete: (res) => {
      const bySig = new Map();
      state.sales.forEach((x) => { const k = saleSig(x); if (k && !bySig.has(k)) bySig.set(k, x); });
      const added = [], usedSig = new Set();
      const upgrades = new Map(); // existing sale id -> patched fields
      let skipped = 0;
      for (const r of res.data) {
        const total = parseFloat(r["Total Amt"] ?? r["Total"] ?? r["Item Subtotal"] ?? 0);
        if (!total) continue;
        const title = r["Item Title"] || "";
        const orderNo = r["Order #"] ? String(r["Order #"]).trim() : "";
        const sale = { id: uid(), item: orderNo, cards: title ? [{ id: uid(), name: title, basis: 0 }] : [], channel: orderNo ? "TCGplayer" : "eBay", price: total, fees: 0, shipping: 0, consign: 0, date: cleanDate(r["Order Date"] || r["Sale Date"] || "") };
        const sig = saleSig(sale);
        const match = sig ? bySig.get(sig) : null;
        if (match) {
          // existing order: the upload wins — overwrite with its values (price, date,
          // channel, full order number) and drop the starter tag. We keep the existing
          // id (so references survive) and don't touch fees/shipping/consign or card
          // lines the user entered by hand, since the CSV doesn't carry those.
          const fields = {};
          const setIf = (k, v) => { if (v !== undefined && match[k] !== v) fields[k] = v; };
          if (orderNo) setIf("item", mergeRef(match.item, orderNo));
          setIf("date", sale.date);
          setIf("price", sale.price);
          setIf("channel", sale.channel);
          if (sale.cards.length && !(match.cards || []).length) fields.cards = sale.cards;
          if (match.seed) fields.seed = false;
          if (Object.keys(fields).length && !upgrades.has(match.id)) upgrades.set(match.id, fields);
          else skipped++;
        } else if (sig && !usedSig.has(sig)) { usedSig.add(sig); added.push(sale); }
        else skipped++;
      }
      if (added.length || upgrades.size) {
        patch((s) => ({ sales: [...added, ...s.sales.map((x) => (upgrades.has(x.id) ? { ...x, ...upgrades.get(x.id) } : x))] }));
        const parts = [];
        if (added.length) parts.push(`${added.length} new`);
        if (upgrades.size) parts.push(`${upgrades.size} updated`);
        if (skipped) parts.push(`${skipped} already current`);
        setMsg("Import: " + parts.join(", ") + ".");
      } else if (skipped) setMsg(`Nothing to update — all ${skipped} order${skipped === 1 ? "" : "s"} are already current.`);
      else setMsg("No rows with a total amount found — check the export format.");
      if (fileRef.current) fileRef.current.value = "";
    }, error: () => setMsg("Couldn't read that file.") });
  };

  const importOrder = () => {
    const { order, error } = parseTcgpOrder(pasteText);
    if (error) { setMsg(error); return; }
    const avail = (state.inventory || []).filter((c) => c.status !== "Sold");
    const used = new Set();
    const cards = [];
    for (const line of order.cards) {
      const qty = Math.max(1, Math.round(Number(line.qty) || 1));
      for (let i = 0; i < qty; i++) {
        const m = matchInvCard(line, avail, used);
        if (m) { used.add(m.id); cards.push({ id: uid(), invId: m.id, name: m.name, set: m.set, number: m.number, basis: invBasis(m) }); }
        else cards.push({ id: uid(), name: line.name || "Card", set: line.set || "", number: line.number || "", basis: 0 });
      }
    }
    const lineSum = order.cards.reduce((a, l) => a + (Number(l.price) || 0) * Math.max(1, Math.round(Number(l.qty) || 1)), 0);
    add({
      item: order.orderNumber ? String(order.orderNumber) : "",
      cards, channel: "TCGplayer",
      price: Number(order.price) || lineSum,
      fees: Number(order.fees) || 0,
      shipping: Number(order.shipping) || 0,
      consign: 0,
      date: cleanDate(order.date),
    });
    setMsg(`Imported TCGP order · ${cards.length} card${cards.length === 1 ? "" : "s"}${used.size ? `, ${used.size} matched to inventory` : ""}.`);
    setPasteText(""); setPasteOpen(false);
  };

  return (
    <div className="cl-stack">
      <Header title="Sales" sub={`Money in · ${fmt(earned)} net`} onAdd={() => { setAdding(!adding); setEditId(null); }} addOpen={adding} />
      <div className="cl-import">
        <button className="cl-import-btn" onClick={() => fileRef.current?.click()}><Upload size={14} /> Import CSV (TCGplayer / eBay export)</button>
        <input ref={fileRef} type="file" accept=".csv" hidden onChange={onFile} />
        <button className="cl-import-btn" onClick={() => { setPasteOpen(!pasteOpen); setMsg(""); }} style={{ marginTop: 8 }}><Upload size={14} /> Paste TCGP order (from bookmarklet)</button>
        {pasteOpen && (
          <div style={{ marginTop: 8 }}>
            <textarea className="cl-in" rows={4} placeholder="Click the bookmarklet on a TCGplayer order-details page, then paste here…" value={pasteText} onChange={(e) => setPasteText(e.target.value)} style={{ width: "100%", resize: "vertical", fontFamily: "ui-monospace,monospace", fontSize: 12 }} />
            <div style={{ marginTop: 6 }}><button className="cl-add-card" onClick={importOrder} disabled={!pasteText.trim()}>Import order</button></div>
          </div>
        )}
        {/* opens in its own tab so an in-progress paste/import isn't torn down —
            BASE_URL keeps it right in dev ("/") and on Pages ("/binderbooks/") */}
        <a className="cl-import-btn" href={`${import.meta.env.BASE_URL}label.html`} target="_blank" rel="noopener noreferrer" style={{ marginTop: 8, textDecoration: "none" }}>
          <Tags size={14} /> Print a 4×6 shipping label <ExternalLink size={12} />
        </a>
        {msg && <div className="cl-import-msg">{msg}</div>}
      </div>
      {adding && <SaleForm inventory={state.inventory} onSave={add} onCancel={() => setAdding(false)} />}
      {state.sales.length === 0 && !adding && <Empty>No sales yet.</Empty>}
      {state.sales.length > 0 && (
        <div className="cl-salesearch">
          <Search size={15} className="cl-salesearch-ic" />
          <input className="cl-in bare" placeholder="Search order #, card, channel, date, amount…" value={q} onChange={(e) => setQ(e.target.value)} />
          {q && <button className="cl-salesearch-x" onClick={() => setQ("")}><X size={14} /></button>}
        </div>
      )}
      {(bareCount > 0 || dupExtra > 0) && (
        <div className="cl-pills">
          {bareCount > 0 && <button className={"cl-pill" + (view === "bare" ? " on" : "")} onClick={() => setView(view === "bare" ? "all" : "bare")}>Needs cards ({bareCount})</button>}
          {dupExtra > 0 && <button className={"cl-pill" + (view === "dups" ? " on" : "")} onClick={() => setView(view === "dups" ? "all" : "dups")}>Duplicates ({dupExtra})</button>}
        </div>
      )}
      {view === "dups" && dupExtra > 0 && <button className="cl-import-btn" onClick={mergeDupes}><Trash2 size={14} /> Merge {dupExtra} duplicate{dupExtra === 1 ? "" : "s"} — keep the most complete copy of each</button>}
      {(q || view !== "all") && <div className="cl-import-msg">Showing {sorted.length} of {state.sales.length} sales</div>}
      {state.sales.length > 0 && sorted.length === 0 && <Empty>{view === "bare" ? "Every sale has card lines attached — nothing left to enrich." : view === "dups" ? "No duplicate orders found." : `No sales match “${q}”.`}</Empty>}
      <div className="cl-stack sm">
        {sorted.map((x) => (
          <SaleRow key={x.id} sale={x} inventory={state.inventory} isEditing={editId === x.id} onEdit={onEditRow} onDelete={del} onSave={upd} onCancelEdit={onCancelEdit} />
        ))}
      </div>
    </div>
  );
}
export function SaleForm({ initial, inventory, onSave, onCancel }) {
  const kept = (inventory || []).filter((c) => c.status !== "Sold");
  const [f, setF] = useState(initial
    ? { item: initial.item || "", channel: initial.channel, price: String(initial.price), fees: numStr(initial.fees), shipping: numStr(initial.shipping), consign: numStr(initial.consign), date: initial.date, cards: (initial.cards || []).map((c) => ({ ...c })) }
    : { item: "", channel: "TCGplayer", price: "", fees: "", shipping: "", consign: "", date: today(), cards: [] });
  const [tname, setTname] = useState("");
  const [tbasis, setTbasis] = useState("");
  const [tmeta, setTmeta] = useState(null); // set/number from a picked search result
  const addInv = (id) => { const c = kept.find((x) => x.id === id); if (!c) return; setF((s) => ({ ...s, cards: [...s.cards, { id: uid(), invId: c.id, name: c.name, set: c.set, number: c.number, basis: invBasis(c) }] })); };
  const pickTyped = (c) => { setTname(c.name); setTmeta({ set: c.set?.name || "", number: c.number || "", variant: c.variant || "", tcgplayerId: c.tcgplayerId || "" }); };
  const addTyped = () => { if (!tname) return; setF((s) => ({ ...s, cards: [...s.cards, { id: uid(), name: tname, ...(tmeta || {}), basis: Number(tbasis) || 0 }] })); setTname(""); setTbasis(""); setTmeta(null); };
  const rmCard = (cid) => setF((s) => ({ ...s, cards: s.cards.filter((c) => c.id !== cid) }));
  const net = (Number(f.price) || 0) - (Number(f.fees) || 0) - (Number(f.shipping) || 0) - (Number(f.consign) || 0);
  const basis = f.cards.reduce((a, c) => a + (Number(c.basis) || 0), 0);
  const profit = basis > 0 ? net - basis : null;
  const availInv = kept.filter((c) => !f.cards.some((fc) => fc.invId === c.id));
  return (
    <Form editing={!!initial}>
      <Field label="Cards in this sale">
        <div className="cl-cardchips">
          {f.cards.length === 0 && <span className="cl-cardchips-empty">No cards attached yet</span>}
          {f.cards.map((c) => (
            <span key={c.id} className="cl-cardchip">{c.invId && <span className="holo-dot" />}{c.name}{c.number ? ` ${c.number}` : ""}{c.basis ? ` · ${fmt(Number(c.basis))}` : ""}<button className="cl-chip-x" onClick={() => rmCard(c.id)}><X size={11} /></button></span>
          ))}
        </div>
      </Field>
      {availInv.length > 0 && <Field label="Add a card you kept"><select className="cl-in" value="" onChange={(e) => { addInv(e.target.value); }}><option value="">— choose from inventory —</option>{availInv.map((c) => <option key={c.id} value={c.id}>{c.name}{c.number ? " " + c.number : ""} · basis {fmt(invBasis(c))}</option>)}</select></Field>}
      {/* The search stands on its own row: it carries a set picker and a
          result list, and squeezing those beside the basis box left no
          room for either. */}
      <CardSearch value={tname} onChange={(v) => { setTname(v); setTmeta(null); }} onPick={pickTyped} placeholder="…or search — name, set, number" />
      <div className="cl-typedadd">
        <div className="cl-money-in cl-basisbox"><span>$</span><input className="cl-in bare" inputMode="decimal" placeholder="basis" value={tbasis} onChange={(e) => setTbasis(e.target.value.replace(/[^0-9.]/g, ""))} /></div>
        <button className="cl-add-card" onClick={addTyped}><Plus size={15} /> Add card</button>
      </div>
      <div className="cl-grid2"><Field label="Channel"><Select opts={CHANNELS} value={f.channel} onChange={(v) => setF({ ...f, channel: v })} /></Field><Field label="Sale price"><MoneyInput value={f.price} onChange={(v) => setF({ ...f, price: v })} /></Field></div>
      <div className="cl-grid3"><Field label="Platform fees"><MoneyInput value={f.fees} onChange={(v) => setF({ ...f, fees: v })} /></Field><Field label="Shipping you paid"><MoneyInput value={f.shipping} onChange={(v) => setF({ ...f, shipping: v })} /></Field><Field label="Consignment cut"><MoneyInput value={f.consign} onChange={(v) => setF({ ...f, consign: v })} /></Field></div>
      <div className="cl-grid2"><Field label="Listing / order ref"><input className="cl-in" placeholder="optional" value={f.item} onChange={(e) => setF({ ...f, item: e.target.value })} /></Field><Field label="Date"><input className="cl-in" type="date" value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} /></Field></div>
      <div className="cl-net-preview"><span>Net <span className="cl-money in">{fmt(net)}</span></span>{profit != null && <span>Profit <span className={"cl-money " + (profit >= 0 ? "pos" : "neg")}>{fmt(profit)}</span></span>}</div>
      <Actions onCancel={onCancel} label={initial ? "Update sale" : "Save sale"} disabled={(f.cards.length === 0 && !f.item) || !f.price} onSave={() => onSave({ ...(initial ? { id: initial.id } : {}), item: f.item, cards: f.cards, channel: f.channel, date: f.date, price: Number(f.price) || 0, fees: Number(f.fees) || 0, shipping: Number(f.shipping) || 0, consign: Number(f.consign) || 0 })} />
    </Form>
  );
}

/* ================================================================== */
/* ------------------------------------------------------------------ */
/* TCGplayer staged upload: merge held raw cards into the seller's own
   TCGplayer CSV export. The "TCGplayer Id" the importer matches on is a
   per-condition SKU number that only TCGplayer's exports carry (PPT's
   `productId` is a different namespace — never write one into the other), so the flow is:
   export a CSV from the Seller Portal (Live Inventory export, or a
   Pricing-tab set export with out-of-stock rows included), feed it here
   once — it's cached per set from then on — and upload the file this
   builds via Inventory → Import to Staged. */
const TCGP_REQ_COLS = ["TCGplayer Id", "Set Name", "Product Name", "Number", "Condition", "Add to Quantity", "TCG Marketplace Price"];
// ledger sets use plain names ("Prismatic Evolutions"), TCGplayer
// prefixes them ("SV: Prismatic Evolutions") — suffix match covers all but
// the promo sets, whose names share no usable suffix
const TCGP_SET_ALIASES = [
  [/scarlet.*violet.*(black star|promo)/, "sv: scarlet & violet promo cards"],
  [/^me(ga evolution)?\b.*(black star|promo)/, "me: mega evolution promo"],
  [/^swsh\b.*(black star|promo)/, "swsh: sword & shield promo cards"],
  [/^sm\b.*(black star|promo)/, "sm promos"],
  [/^xy\b.*(black star|promo)/, "xy promos"],
];
const tcgpSetMatch = (rowSet, cardSet) => {
  const rs = String(rowSet || "").toLowerCase(), cs = String(cardSet || "").toLowerCase().trim();
  if (!rs || !cs) return false;
  for (const [re, target] of TCGP_SET_ALIASES) if (re.test(cs)) return rs === target;
  return rs === cs || rs.endsWith(cs);
};
const tcgpTok = (s) => String(s || "").toLowerCase().replace(/[^a-z0-9 ]/g, " ").split(/\s+/).filter(Boolean);
// score a TCGplayer product name against the ledger card name: shared words
// count for, extra product words against — so plain "Fezandipiti" outranks
// "Fezandipiti (Master Ball Pattern)" unless the card name actually says so
const tcgpNameScore = (cardName, prodName) => {
  const ct = new Set(tcgpTok(cardName));
  let s = 0;
  // strip only the " - <num>" token so variant markers like "[Staff]" or
  // "(Prerelease)" survive to be scored (and penalized when unasked-for)
  for (const t of tcgpTok(String(prodName).replace(/ - [\w/.]+/, " "))) s += ct.has(t) ? 1 : -0.5;
  return s;
};
// ledger cards carry no condition, so everything exports as Near Mint; the
// rank picks which NM printing row to use when a product has several. The
// card's own `variant` decides when it has one — cards from before that field
// existed fall back to the old name-text heuristic and rank exactly as before.
const tcgpCondRank = (cond, card) => {
  const c = String(cond || "").toLowerCase();
  if (!c.startsWith("near mint")) return -1;
  const rev = c.includes("reverse"), holo = c.includes("holofoil");
  const v = card?.variant || (/\breverse\b/i.test(String(card?.name || "")) ? "Reverse Holofoil" : "");
  if (v === "Reverse Holofoil") return rev ? 3 : holo ? 2 : 1;
  if (v === "Holofoil") return rev ? 0 : holo ? 3 : 1;
  if (v === "Normal") return rev ? 0 : holo ? 1 : 3;
  return rev ? 0 : holo ? 2 : 1; // printing unknown — the ordering this always used
};
function buildTcgpUpload(rows, cards) {
  // customs ("C-…" photo listings of one specific card) are never matched —
  // adding quantity to those would double-sell that physical card
  const usable = rows.filter((r) => /^\d+$/.test(String(r["TCGplayer Id"] || "").trim()) && tcgpCondRank(r["Condition"], null) >= 0);
  const picks = new Map(); // sku id -> { row, qty, values, ids }
  const unmatched = [];
  // the export's Number column is occasionally wrong (promos filed under
  // another set's number) while the product name's " - <num>" suffix is
  // right — a row matches on either. A card whose number matches neither
  // stays unmatched: falling back to name-only could stage a different
  // variant's SKU (DR vs UR share the base name), which mis-lists.
  const rowNum = (r) => {
    const m = String(r["Product Name"]).match(/.* - ([\w/.]+)$/);
    return m && /^[A-Za-z]{0,5}\d/.test(m[1]) ? m[1] : r["Number"];
  };
  for (const c of cards) {
    const inSet = usable.filter((r) => tcgpSetMatch(r["Set Name"], c.set));
    const want = c.number ? normNum(c.number) : null;
    let cands = want ? inSet.filter((r) => normNum(r["Number"]) === want || normNum(rowNum(r)) === want) : inSet;
    const names = [...new Set(cands.map((r) => r["Product Name"]))];
    if (names.length > 1) {
      // several products share the number (Poke Ball / Master Ball patterns)
      // or we're matching on name alone — a clear name winner decides, a tie
      // stays unmatched rather than guessing
      const scored = names.map((n) => [tcgpNameScore(c.name, n), n]).sort((a, b) => b[0] - a[0]);
      cands = scored[0][0] > 0 && scored[0][0] !== scored[1][0] ? cands.filter((r) => r["Product Name"] === scored[0][1]) : [];
    }
    if (!cands.length) { unmatched.push(c); continue; }
    const best = cands.reduce((a, r) => (tcgpCondRank(r["Condition"], c) > tcgpCondRank(a["Condition"], c) ? r : a));
    const key = String(best["TCGplayer Id"]).trim();
    const p = picks.get(key) || { row: best, qty: 0, values: [], ids: [] };
    p.qty++;
    p.ids.push(c.id);
    if (Number(c.value) > 0) p.values.push(Number(c.value));
    picks.set(key, p);
  }
  const out = [], exportedIds = [], needPrice = [];
  for (const { row, qty, values, ids } of picks.values()) {
    // list at the ledger's market value (lowest across copies); cards with no
    // value fall back to the export's own price columns
    const fallback = ["TCG Marketplace Price", "TCG Market Price", "TCG Low Price With Shipping", "TCG Low Price"].map((k) => Number(row[k])).find((v) => v > 0);
    const price = values.length ? Math.min(...values) : fallback;
    if (!(price > 0)) { needPrice.push(row["Product Name"]); continue; }
    out.push({ ...row, "Add to Quantity": String(qty), "TCG Marketplace Price": price.toFixed(2) });
    exportedIds.push(...ids);
  }
  out.sort((a, b) => String(a["Set Name"]).localeCompare(b["Set Name"]) || String(a["Product Name"]).localeCompare(b["Product Name"]));
  return { out, exportedIds, unmatched, needPrice };
}
/* Cached set exports.

   The SKU ids only exist in the seller's own export, so before this the flow
   asked for the file on every run — and picking the wrong set's export only
   failed at the end, in the "skipped" message. Instead we parse each export
   once, keep its rows per Set Name, and the normal run needs no file picker.

   Deliberately localStorage-only: this never goes through patch()/syncFetch().
   Sync stores the whole ledger as one DynamoDB item (400KB cap) and a couple
   of cached sets would break sync for everything. Per-device and rebuilt on
   demand, exactly like GRADED_KEY. */
const TCGP_SKU_KEY = "cardledger:tcgpsku:v1";
// entry shape: { savedAt, fields: <the export's own header, in order>, rows: [...] }
// keyed by row["Set Name"] lowercased/trimmed — one file can carry several sets
const TCGP_STALE_MS = 90 * 864e5;
// exactly the rows buildTcgpUpload's `usable` line keeps; everything else could
// never have matched, so dropping it costs nothing and saves a lot of quota
const tcgpCacheable = (r) =>
  /^\d+$/.test(String(r["TCGplayer Id"] || "").trim()) &&
  String(r["Condition"] || "").toLowerCase().startsWith("near mint");
const tcgpCacheRead = () => { try { return JSON.parse(localStorage.getItem(TCGP_SKU_KEY)) || {}; } catch { return {}; } };
/* Persist the cache. localStorage throws on quota (and in private mode); on a
   full store we evict the least-recently-saved set — never one of `keep`, the
   entries this write is adding — and retry a few times. If it still won't fit
   nothing was written, so the last good copy is still on disk: hand that back
   and let the caller keep the fresh rows in memory for the current export. */
const tcgpCacheSave = (all, keep = []) => {
  const kept = new Set(keep);
  const store = {};
  for (const [k, v] of Object.entries(all)) store[k] = { savedAt: v.savedAt, fields: v.fields, rows: v.rows };
  for (let i = 0; i < 4; i++) {
    try { localStorage.setItem(TCGP_SKU_KEY, JSON.stringify(store)); return { ok: true, all: store }; } catch {
      const victim = Object.keys(store).filter((k) => !kept.has(k)).sort((a, b) => (store[a].savedAt || 0) - (store[b].savedAt || 0))[0];
      if (!victim) break;
      delete store[victim];
    }
  }
  return { ok: false, all: tcgpCacheRead() };
};
const tcgpCacheBytes = (all) => { try { return JSON.stringify(all).length; } catch { return 0; } };
// keys are lowercased for matching; show the export's own casing
const tcgpSetLabel = (key, entry) => entry?.rows?.[0]?.["Set Name"] || key;
const tcgpAge = (t) => {
  const d = Math.floor((Date.now() - (t || 0)) / 864e5);
  if (d <= 0) return "saved today";
  if (d === 1) return "saved yesterday";
  if (d < 60) return `saved ${d} days ago`;
  const m = Math.round(d / 30);
  return `saved ${m} month${m === 1 ? "" : "s"} ago`;
};
// `a.download` is INERT inside the iOS shell's WKWebView: the click lands, no
// file is written, and nothing reports an error — so the export button silently
// does nothing. The shell takes {name, text} and puts the file through the
// system share sheet instead, which reaches Files, Mail and AirDrop.
const downloadFile = (name, text) => {
  if (window.__BINDERBOOKS_NATIVE__) {
    window.webkit?.messageHandlers?.saveFile?.postMessage({ name, text });
    return;
  }
  const url = URL.createObjectURL(new Blob([text], { type: "text/csv" }));
  const a = document.createElement("a");
  a.href = url; a.download = name;
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 4000);
};

// Taptics have no web API on iOS. The shell answers this; every other host
// ignores it, so call sites need no guard of their own.
const haptic = (kind = "light") => {
  if (window.__BINDERBOOKS_NATIVE__) window.webkit?.messageHandlers?.haptics?.postMessage(kind);
};

function Inventory({ state, patch }) {
  const inv = state.inventory || [];
  const [adding, setAdding] = useState(false);
  const [editId, setEditId] = useState(null);
  const [viewId, setViewId] = useState(null);
  const [filter, setFilter] = useState("All");
  const [syncMsg, setSyncMsg] = useState("");
  const [refreshing, setRefreshing] = useState(false);
  const [gradeOpen, setGradeOpen] = useState(false);
  const add = (c) => { patch((s) => ({ inventory: [{ id: uid(), ...c }, ...(s.inventory || [])] })); setAdding(false); };
  const upd = useCallback((c) => { patch((s) => ({ inventory: s.inventory.map((x) => (x.id === c.id ? { ...x, ...c } : x)) })); setEditId(null); }, [patch]);
  const del = useCallback((id) => patch((s) => ({ inventory: s.inventory.filter((c) => c.id !== id) })), [patch]);
  const onEditRow = useCallback((id) => { setEditId(id); setAdding(false); }, []);
  const onCancelEdit = useCallback(() => setEditId(null), []);
  const onOpenRow = useCallback((id) => setViewId(id), []);
  // Send a submission: flip the cards, stamp each one's share of the cost, and
  // write the single Grading buy that carries the cash. One patch, so the whole
  // submission syncs as one change.
  const sendToGrading = ({ ids, grader, fee, ship, date }) => {
    const shares = splitEvenly(ship, ids.length);
    const shipBy = new Map(ids.map((id, i) => [id, shares[i]]));
    const total = fee * ids.length + ship;
    const label = `${grader} grading (${ids.length} card${ids.length === 1 ? "" : "s"})`;
    patch((s) => ({
      // `grader` is what later values the card: its estimates come from that
      // company's solds, not PSA's. An estimate carried over from a different
      // company is the other company's price, so this drops it — the ladders
      // share grade names like "10", which would hide the mistake.
      inventory: (s.inventory || []).map((c) => (shipBy.has(c.id)
        ? { ...c, status: "At grading", grader, gradingCost: fee, gradingShip: shipBy.get(c.id), ...(cardGrader(c) === grader ? {} : { gradeEst: {} }) }
        : c)),
      buys: [...(s.buys || []), { id: uid(), item: label, name: "", category: "Grading", source: grader, date, cost: total }],
    }));
    setGradeOpen(false);
    setSyncMsg(`Sent ${ids.length} card${ids.length === 1 ? "" : "s"} to ${grader}. Logged ${fmt(total)} in Buys, split ${fmt(ship)} postage across them, and set them to value against ${grader} solds.`);
  };
  // Reconcile against sales: find cards still showing as held that actually sold —
  // either a sale line is already linked to them (invId), or an unlinked sale line
  // matches one by name + number. Each sale line claims at most one card, so a
  // second copy you still own stays put. Flip the matches to Sold and back-link the
  // sale line (and its basis) so the books read as if the sale had matched cleanly.
  const reconcileSold = () => {
    const sales = state.sales || [];
    const linked = new Set();
    sales.forEach((x) => (x.cards || []).forEach((c) => c.invId && linked.add(c.invId)));
    const pool = inv.filter((c) => c.status !== "Sold" && !linked.has(c.id));
    const used = new Set();
    const claimByLine = new Map();
    sales.forEach((x) => (x.cards || []).forEach((line) => {
      if (line.invId) return;
      const m = matchInvCard(line, pool, used);
      if (m) { used.add(m.id); claimByLine.set(line.id, m); }
    }));
    const directLive = inv.filter((c) => c.status !== "Sold" && linked.has(c.id)).map((c) => c.id);
    const sellIds = new Set([...directLive, ...[...claimByLine.values()].map((c) => c.id)]);
    if (!sellIds.size) { setSyncMsg("In sync — nothing that's sold is still showing as held."); return; }
    if (typeof window !== "undefined" && !window.confirm(`Mark ${sellIds.size} card${sellIds.size === 1 ? "" : "s"} as Sold? They appear in a recorded sale but still show as held.`)) return;
    patch((s) => ({
      inventory: (s.inventory || []).map((c) => (sellIds.has(c.id) ? { ...c, status: "Sold" } : c)),
      sales: (s.sales || []).map((x) => ({ ...x, cards: (x.cards || []).map((line) => {
        const m = claimByLine.get(line.id);
        return m ? { ...line, invId: m.id, basis: Number(line.basis) || invBasis(m), set: line.set || m.set, number: line.number || m.number } : line;
      }) })),
    }));
    setSyncMsg(`Marked ${sellIds.size} card${sellIds.size === 1 ? "" : "s"} as Sold.`);
  };
  // Pull current market prices from the price database for every held card we can pin
  // down (name + number, or name + set) — refreshing existing prices too, since they
  // go stale, not just filling blanks. Cards with only a name are skipped (too vague
  // to match safely). Also backfills a missing set/number from the match.
  //
  // That path is English raw singles only. A slab is not worth the raw market price
  // of the card inside it, and a Japanese card is not the English card of the same
  // name — so both are priced from their own eBay solds instead, a slab at the exact
  // grade on its label. Cards that use graded estimates (at grading, or already
  // comped) re-pull their ladder in the same pass. All of that draws a limited daily
  // budget, so we stop once it's gone.
  const refreshPrices = async () => {
    const held = inv.filter((c) => c.status !== "Sold" && c.name);
    const cands = held.filter((c) => tcgPriceable(c) && (c.number || c.set));
    const hasEst = (c) => estGrades(c).some((g) => Number(c.gradeEst?.[g]) > 0);
    // a slab or a JP card needs no set/number — the comps route can search on a name
    const compCands = held.filter((c) => !tcgPriceable(c) || c.status === "At grading" || hasEst(c));
    const total = new Set([...cands, ...compCands]).size;
    if (!total) { setSyncMsg("Nothing to refresh — held cards need a set or number to match against the database."); return; }
    setRefreshing(true);
    setSyncMsg(`Checking ${total} card${total === 1 ? "" : "s"}…`);
    const updates = {};
    let priced = 0, changed = 0, graded = 0, ownComps = 0, wrongCard = 0, gradedNote = "";
    const applyPrice = (c, price) => {
      updates[c.id] = { ...(updates[c.id] || {}), value: price };
      priced++;
      if (price !== (Number(c.value) || 0)) changed++;
    };
    /* fastest path: a card entered from the catalog already names its SKU,
       so its price is a local read of the row we imported. It also has to
       come first — a catalog card carries TCGplayer's product name and set
       name, which the search paths below would either fail to match
       or, worse, match to a different printing of the same card. */
    const bySku = cands.filter((c) => c.tcgplayerId);
    if (bySku.length) {
      try {
        const recs = await getCatalogRecords(bySku.map((c) => c.tcgplayerId));
        const found = new Map(recs.map((r) => [r.tcgplayer_id, r]));
        for (const c of bySku) {
          const rec = found.get(c.tcgplayerId);
          const v = rec ? (rec.market_price ?? rec.low_price ?? null) : null;
          if (v != null) applyPrice(c, v);
        }
      } catch { /* no catalog on this device — fall through to the old paths */ }
    }
    // fast path: one whole-set pull per distinct set+language (via the
    // Lambda's PPT-backed /prices) prices every card with a set + number in a
    // few requests total. Japanese cards batch through PPT's own Japanese
    // catalogue — they used to be unpriceable here.
    const setKeys = [...new Set(cands.filter((c) => c.set && c.number && !updates[c.id]).map((c) => `${c.set}\t${cardLang(c)}`))];
    const maps = {};
    await Promise.all(setKeys.map(async (k) => { const [name, lg] = k.split("\t"); const m = await fetchSetPrices(name, true, lg); if (m) maps[k] = m; }));
    const leftovers = [];
    for (const c of cands) {
      if (updates[c.id]?.value != null) continue; // already priced off its SKU
      // subPrice, never the raw entry — these are per-printing maps now, and
      // this value is written straight onto the card and then synced
      const v = c.set && c.number ? subPrice(maps[`${c.set}\t${cardLang(c)}`]?.[normNum(c.number)], c.variant) : null;
      if (v != null) applyPrice(c, v);
      else leftovers.push(c);
    }
    // slow path: whatever the set dump couldn't pin down (missing number, set
    // name PPT doesn't know) goes card-by-card through /search, which can
    // also backfill a missing set/number from its match
    for (const c of leftovers) {
      const m = await lookupCardPrice(c, c.variant);
      const price = m ? cardPrice(m, c.variant) : null;
      if (m && price != null) {
        applyPrice(c, price);
        updates[c.id] = { ...updates[c.id], ...(c.set ? {} : { set: m.set?.name || "" }), ...(c.number ? {} : { number: m.number || "" }) };
      }
    }
    // one /graded pull per card serves both jobs below, and the fetch caches for
    // 24h, so a card that needs a slab price and a ladder costs one lookup
    for (const c of compCands) {
      if (gradedNote) break; // budget gone or route unavailable — the rest would fail the same way
      let r;
      try {
        r = await fetchGradedComps(c.name, c.set, c.number, cardLang(c), c.productId || "");
      } catch (e) {
        if (e.status === 429) gradedNote = " · eBay comps budget used up, try the rest tomorrow";
        else if (e.status === 401) { gradedNote = " · " + NO_TOKEN_MSG; break; }
        else if (e.status === 501) gradedNote = " · eBay graded comps aren't set up";
        continue; // 404 / transient: just skip comps for this card
      }
      // comps for a near miss are worse than none — they overwrite a good value
      // with a different card's, and nothing on the screen would say so
      if (!compsMatch(r, c)) { wrongCard++; continue; }
      if (!tcgPriceable(c)) {
        /* A raw card takes the ungraded sold price; a slab takes the price of its
           own grade and nothing else. No bucket means nobody has sold one lately,
           and an unreadable grade ("Other", a company we don't know) means we
           can't tell what would have sold — both leave the value alone rather
           than fall back to the raw price, which undercounts every slab it
           touches. */
        const b = slabComp(r, c.grade);
        const v = b ? b.price : c.grade === "Raw" ? r.raw?.price ?? r.market ?? null : null;
        if (Number(v) > 0) { applyPrice(c, Math.round(Number(v) * 100) / 100); ownComps++; }
      }
      if (c.status === "At grading" || hasEst(c)) {
        // each card comps against its own grader — a CGC card priced off PSA
        // solds reads roughly double what it is worth
        const got = compGrades(r, cardGrader(c));
        if (Object.keys(got).length) {
          updates[c.id] = { ...(updates[c.id] || {}), gradeEst: { ...(c.gradeEst || {}), ...got } };
          graded++;
        }
      }
    }
    if (Object.keys(updates).length) patch((s) => ({ inventory: (s.inventory || []).map((c) => (updates[c.id] ? { ...c, ...updates[c.id] } : c)) }));
    setRefreshing(false);
    const missed = cands.length - (priced - ownComps);
    setSyncMsg(priced || graded
      ? `Refreshed ${priced} price${priced === 1 ? "" : "s"} (${changed} changed)${ownComps ? `, ${ownComps} from their own eBay solds` : ""}${graded ? `, ${graded} graded comp${graded === 1 ? "" : "s"}` : ""}${missed ? `; ${missed} not in the price database — those price from your imported TCGplayer CSV when it covers them` : ""}${wrongCard ? `; ${wrongCard} skipped — the sold data came back for a different card, check their set and number` : ""}${gradedNote}.`
      : `None of those ${total} card${total === 1 ? "" : "s"} are in the database yet — check back later${gradedNote}.`);
  };
  // Grading-candidate scan: pull eBay graded comps for every held raw card at
  // or above a value floor (highest value first, so the budget goes to the
  // cards that matter), stash a slim snapshot on each card, and rank by what
  // a PSA 10 nets over just selling raw. Snapshots live on the cards
  // themselves — they sync across devices and survive the comps cache, so a
  // scan the daily budget cuts short just resumes on the next run.
  const [scanOpen, setScanOpen] = useState(false);
  const [scanning, setScanning] = useState(false);
  const [scanMsg, setScanMsg] = useState("");
  const [scanFloor, setScanFloor] = useState("15");
  const [scanFee, setScanFee] = useState("25");
  const scanCands = inv
    .filter((c) => (c.status === "Kept" || c.status === "Listed") && c.grade === "Raw" && c.name && (Number(c.value) || 0) >= (Number(scanFloor) || 0))
    .sort((a, b) => (Number(b.value) || 0) - (Number(a.value) || 0));
  const runScan = async () => {
    if (scanning) return;
    if (!scanCands.length) { setScanMsg("No raw held cards at or above the value floor."); return; }
    setScanning(true);
    const updates = {};
    const isFresh = (c) => c.grading && Date.now() - c.grading.t < 3 * 864e5;
    let pulled = 0, failed = 0, skipped = 0, outOfBudget = false, i = 0;
    for (const c of scanCands) {
      i++;
      if (isFresh(c)) continue; // fresh enough from a previous run
      setScanMsg(`Pulling eBay comps… ${i}/${scanCands.length} (${c.name})`);
      try {
        const r = await fetchGradedComps(c.name, c.set, c.number, cardLang(c), c.productId || "");
        if (!compsMatch(r, c)) { skipped++; continue; } // solds for a different card rank nothing
        const slim = (k) => (r.byGrade?.[k] ? { p: r.byGrade[k].price, n: r.byGrade[k].count } : null);
        updates[c.id] = { grading: { t: Date.now(), raw: r.raw ? { p: r.raw.price, n: r.raw.count } : null, psa10: slim("psa10"), psa9: slim("psa9"), cgc10: slim("cgc10"), tag10: slim("tag10") } };
        pulled++;
      } catch (e) {
        if (e.status === 429 || e.status === 401) { outOfBudget = true; break; }
        if (e.status === 404) updates[c.id] = { grading: { t: Date.now(), none: true } };
        else failed++; // transient failure — the next scan retries it
      }
    }
    if (Object.keys(updates).length) patch((s) => ({ inventory: (s.inventory || []).map((c) => (updates[c.id] ? { ...c, ...updates[c.id] } : c)) }));
    setScanning(false);
    // waiting = the card that hit the wall plus whatever after it isn't fresh
    const waiting = outOfBudget ? 1 + scanCands.slice(i).filter((c) => !isFresh(c)).length : 0;
    setScanMsg(outOfBudget
      ? `Daily eBay-comps budget ran out — ${pulled} pulled this run, ${waiting} still waiting. Run it again after the daily reset to continue.`
      : failed || skipped
      ? `Done — ${pulled} pulled fresh${failed ? `, ${failed} lookup${failed === 1 ? "" : "s"} failed` : ""}${skipped ? `, ${skipped} came back for a different card and were skipped` : ""}.${failed ? " Run it again to retry those." : ""}`
      : `Done — ${pulled} pulled fresh${pulled < scanCands.length ? ", the rest were already current" : ""}.`);
  };
  const scanFeeN = Number(scanFee) || 0;
  const ranked = scanCands
    .filter((c) => c.grading && !c.grading.none && c.grading.psa10)
    .map((c) => {
      const raw = Number(c.value) || 0;
      const up10 = c.grading.psa10.p - raw - scanFeeN;
      const up9 = c.grading.psa9 ? c.grading.psa9.p - raw - scanFeeN : null;
      return { c, raw, up10, up9 };
    })
    .sort((a, b) => b.up10 - a.up10);
  const scanNoData = scanCands.filter((c) => c.grading && (c.grading.none || !c.grading.psa10)).length;
  // Build a TCGplayer staged-upload CSV: the user ticks the cards to list and
  // we fill Add to Quantity + price for each match into an upload-ready file.
  // The SKU ids come from cached set exports (see TCGP_SKU_KEY) — the picker
  // only appears when a selected card's set hasn't been cached yet.
  const tcgpFileRef = useRef();
  const [tcgpOpen, setTcgpOpen] = useState(false);
  const [tcgpSel, setTcgpSel] = useState(() => new Set());
  const [tcgpCache, setTcgpCache] = useState(tcgpCacheRead);
  const [tcgpCacheOpen, setTcgpCacheOpen] = useState(false);
  /* The catalog is the SKU source now. It holds whole sets rather than
     only the rows one export happened to carry, so a card entered from
     it already knows its SKU and needs no matching at export time. */
  const catFileRef = useRef();
  const [cat, setCat] = useState({ rows: 0, sets: [], lastImport: null });
  const [catBusy, setCatBusy] = useState("");
  const loadCatalog = useCallback(async () => {
    try {
      const [stats, sets] = await Promise.all([catalogStats(), catalogSets()]);
      setCat({ rows: stats.rows, sets, lastImport: stats.lastImport });
    } catch { /* no IndexedDB: the old cached-export path still works */ }
  }, []);
  useEffect(() => { loadCatalog(); }, [loadCatalog]);
  // TCGplayer's CSV is keyed on English product SKUs, so a JP card would list
  // against the English printing of the same name — the wrong card, at the wrong price
  const tcgpEligible = inv
    .filter((c) => c.status === "Kept" && c.grade === "Raw" && !isJP(c) && c.name && c.set)
    .sort((a, b) => (a.set || "").localeCompare(b.set || "") || (a.name || "").localeCompare(b.name || ""));
  const tcgpExcluded = inv.filter((c) => c.status === "Kept" && c.name).length - tcgpEligible.length;
  const toggleTcgp = () => {
    if (!tcgpOpen) setTcgpSel(new Set(tcgpEligible.map((c) => c.id)));
    setTcgpOpen(!tcgpOpen);
    setSyncMsg("");
  };
  const tcgpTick = (id) => setTcgpSel((s) => { const n = new Set(s); n.has(id) ? n.delete(id) : n.add(id); return n; });
  // Preflight coverage: which of the ticked cards we can put a SKU on.
  // A card carrying a tcgplayerId is covered outright — that is the point
  // of the catalog. Everything else still needs rows for its set, from the
  // catalog or from an older cached export, so the name matcher can work.
  // Reuses tcgpSetMatch so the promo aliases apply to both key lists.
  const tcgpCacheKeys = Object.keys(tcgpCache);
  const catKeys = cat.sets.map((s) => s.key);
  const skuKeys = [...new Set([...catKeys, ...tcgpCacheKeys])];
  const tcgpPicked = tcgpEligible.filter((c) => tcgpSel.has(c.id));
  const tcgpKeysFor = (cards) => tcgpCacheKeys.filter((k) => cards.some((c) => tcgpSetMatch(k, c.set)));
  const tcgpCovered = tcgpPicked.filter((c) => c.tcgplayerId || skuKeys.some((k) => tcgpSetMatch(k, c.set)));
  // name the sets the way the user does, not the TCGplayer-prefixed way
  const tcgpMissingSets = [...new Set(tcgpPicked.filter((c) => !tcgpCovered.includes(c)).map((c) => c.set))].sort();
  const tcgpCoveredSets = new Set(tcgpCovered.map((c) => c.set)).size;
  const tcgpDirect = tcgpCovered.filter((c) => c.tcgplayerId).length;
  const tcgpCoverage = !tcgpPicked.length
    ? "No cards selected."
    : !tcgpMissingSets.length
      ? `${tcgpPicked.length} card${tcgpPicked.length === 1 ? "" : "s"} across ${tcgpCoveredSets} set${tcgpCoveredSets === 1 ? "" : "s"} — ready to export.${tcgpDirect ? ` ${tcgpDirect} carr${tcgpDirect === 1 ? "ies" : "y"} an exact SKU.` : ""}`
      : tcgpCovered.length
        ? `${tcgpCovered.length} of ${tcgpPicked.length} cards ready. No SKUs for: ${tcgpMissingSets.join(", ")}.`
        : `Nothing covers ${tcgpMissingSets.length === 1 ? "that set" : "those sets"}: ${tcgpMissingSets.join(", ")}.`;
  /* Merge one listing into the upload. Two cards can land on the same SKU
     from different paths — one entered from the catalog, one matched by
     name — and TCGplayer reads a repeated id as two listings, so the
     quantities have to add up in one row. Price follows the rule the
     matcher has always used: the lowest across the copies being listed. */
  const mergeRow = (into, row) => {
    const id = String(row["TCGplayer Id"]).trim();
    const prev = into.get(id);
    if (!prev) { into.set(id, row); return; }
    const qty = (Number(prev["Add to Quantity"]) || 0) + (Number(row["Add to Quantity"]) || 0);
    const prices = [prev, row].map((r) => Number(r["TCG Marketplace Price"])).filter((v) => v > 0);
    into.set(id, { ...prev, "Add to Quantity": String(qty), "TCG Marketplace Price": (prices.length ? Math.min(...prices) : 0).toFixed(2) });
  };

  /* The direct path: a card that knows its SKU needs no matching at all.
     This is what the catalog buys us — no set aliasing, no name scoring,
     no five-products-share-a-number tie to lose. */
  const tcgpDirectRows = async (cards) => {
    const byId = new Map();
    for (const c of cards) {
      const p = byId.get(c.tcgplayerId) || { qty: 0, values: [], ids: [] };
      p.qty++; p.ids.push(c.id);
      if (Number(c.value) > 0) p.values.push(Number(c.value));
      byId.set(c.tcgplayerId, p);
    }
    const recs = await getCatalogRecords([...byId.keys()]);
    const found = new Map(recs.map((r) => [r.tcgplayer_id, r]));
    const rows = [], exportedIds = [], needPrice = [], stale = [], custom = [];
    for (const [id, p] of byId) {
      const rec = found.get(id);
      // the SKU was entered from a catalog this device no longer holds
      if (!rec) { stale.push(...cards.filter((c) => c.tcgplayerId === id).map((c) => c.name)); continue; }
      // a C- listing is one physical slab the seller already owns; adding
      // quantity to it would sell that single card twice
      if (rec.is_custom) { custom.push(rec.product_name); continue; }
      const price = p.values.length
        ? Math.min(...p.values)
        : [rec.market_price, rec.low_with_ship, rec.low_price].find((v) => v > 0);
      if (!(price > 0)) { needPrice.push(rec.product_name); continue; }
      rows.push(recordToRow(rec, { addQty: p.qty, price }));
      exportedIds.push(...p.ids);
    }
    return { rows, exportedIds, needPrice, stale, custom };
  };

  const tcgpExport = async () => {
    if (!tcgpCovered.length) { setSyncMsg("No SKUs for the selected cards yet — import a TCGplayer export first."); return; }
    setCatBusy("Building the upload…");
    try {
      const direct = tcgpCovered.filter((c) => c.tcgplayerId);
      const byName = tcgpCovered.filter((c) => !c.tcgplayerId);
      const skipped = [];
      const merged = new Map();
      const exportedIds = [];

      const needPrice = [];   // both paths report these together, in one line

      const d = await tcgpDirectRows(direct);
      for (const row of d.rows) mergeRow(merged, row);
      exportedIds.push(...d.exportedIds);
      needPrice.push(...d.needPrice);
      if (d.stale.length) skipped.push(`${d.stale.length} whose SKU is not in this device's catalog (re-import the export): ${d.stale.slice(0, 4).join(", ")}`);
      if (d.custom.length) skipped.push(`${d.custom.length} listed as a custom C- slab, which needs its own listing: ${d.custom.slice(0, 4).join(", ")}`);

      /* Cards from before the catalog existed keep the name matcher.
         It reads the catalog now instead of a second cache — the old
         cached exports still feed it so nothing breaks before the first
         catalog import. */
      if (byName.length) {
        const wantedCatKeys = catKeys.filter((k) => byName.some((c) => tcgpSetMatch(k, c.set)));
        const rows = [
          ...(wantedCatKeys.length ? await catalogRowsForSets(wantedCatKeys) : []),
          ...tcgpKeysFor(byName).flatMap((k) => tcgpCache[k]?.rows || []),
        ];
        const m = buildTcgpUpload(rows, byName);
        for (const row of m.out) mergeRow(merged, row);
        exportedIds.push(...m.exportedIds);
        if (m.unmatched.length) {
          const names = [...new Set(m.unmatched.map((c) => `${c.name} (${c.set})`))];
          skipped.push(`${m.unmatched.length} the matcher could not pin down — re-add them from the catalog to give them a SKU: ${names.slice(0, 6).join(", ")}${names.length > 6 ? ", …" : ""}`);
        }
        needPrice.push(...m.needPrice);
      }
      if (needPrice.length) skipped.push(`${needPrice.length} with no price anywhere (give them a market value first): ${needPrice.slice(0, 4).join(", ")}`);

      const out = [...merged.values()].sort((a, b) =>
        String(a["Set Name"]).localeCompare(String(b["Set Name"])) || String(a["Product Name"]).localeCompare(String(b["Product Name"])));
      if (!out.length) { setSyncMsg(`No cards matched. ${skipped.join(" · ")}`); return; }

      // always the export's own 16 columns, in order — download and upload
      // share one schema, so the file we build is the file we were given
      const csv = Papa.unparse({ fields: CSV_COLUMNS, data: out.map((r) => CSV_COLUMNS.map((f) => r[f] ?? "")) }, { quotes: true });
      const fname = `TCGP-Staged-Upload-${today()}.csv`;
      downloadFile(fname, csv);
      setTcgpOpen(false);
      setSyncMsg(`Saved ${fname}: ${out.length} listing${out.length === 1 ? "" : "s"} covering ${exportedIds.length} card${exportedIds.length === 1 ? "" : "s"}. Upload it in Seller Portal → Inventory → Import to Staged, then push live.${skipped.length ? " Skipped " + skipped.join(" · ") + "." : ""}`);
      if (typeof window !== "undefined" && exportedIds.length && window.confirm(`CSV saved. Mark the ${exportedIds.length} exported card${exportedIds.length === 1 ? "" : "s"} as Listed?\n(Cancel if you're not going to upload this file.)`)) {
        const ids = new Set(exportedIds);
        patch((s) => ({ inventory: (s.inventory || []).map((c) => (ids.has(c.id) ? { ...c, status: "Listed" } : c)) }));
      }
    } catch (e) {
      setSyncMsg(`Could not build the upload: ${e.message}`);
    } finally { setCatBusy(""); }
  };

  const onCatalogFile = async (e) => {
    const file = e.target.files?.[0];
    if (e.target) e.target.value = "";
    if (!file) return;
    setSyncMsg("");
    setCatBusy("Reading the export…");
    try {
      const r = await importCatalogFile(file, { onProgress: ({ kept }) => setCatBusy(`Imported ${kept.toLocaleString()} rows…`) });
      await loadCatalog();
      setSyncMsg(`Catalog updated: ${r.kept.toLocaleString()} Near Mint SKU${r.kept === 1 ? "" : "s"} across ${r.sets.length} set${r.sets.length === 1 ? "" : "s"}${r.skipped ? `, ${r.skipped.toLocaleString()} other rows left out` : ""}.`);
    } catch (err) {
      setSyncMsg(err.message || "Could not read that file.");
    } finally { setCatBusy(""); }
  };
  const onCatalogClear = async () => {
    if (typeof window !== "undefined" && !window.confirm("Delete every catalog row on this device?\nCards already entered keep their SKU, and a re-import restores the catalog.")) return;
    try { await clearCatalog(); await loadCatalog(); setSyncMsg("Catalog cleared."); }
    catch (e) { setSyncMsg(`Could not clear the catalog: ${e.message}`); }
  };
  // The picker now feeds the cache instead of building one file and forgetting
  // it — same validation and messages, but the rows survive the run.
  const onTcgpFile = (e) => {
    const file = e.target.files?.[0]; if (!file) return;
    Papa.parse(file, { header: true, skipEmptyLines: true, complete: (res) => {
      if (tcgpFileRef.current) tcgpFileRef.current.value = "";
      const fields = res.meta?.fields || [];
      const missingCols = TCGP_REQ_COLS.filter((k) => !fields.includes(k));
      if (missingCols.length) { setSyncMsg(`That doesn't look like a TCGplayer set export — missing column${missingCols.length === 1 ? "" : "s"}: ${missingCols.join(", ")}.`); return; }
      const savedAt = Date.now();
      const found = {};
      for (const r of res.data) {
        if (!tcgpCacheable(r)) continue;
        const key = String(r["Set Name"] || "").toLowerCase().trim();
        if (!key) continue;
        (found[key] || (found[key] = { savedAt, fields, rows: [] })).rows.push(r);
      }
      const keys = Object.keys(found);
      if (!keys.length) { setSyncMsg("That export had no Near Mint rows with a TCGplayer Id — re-export it from Seller Portal → Pricing with out-of-stock rows included."); return; }
      const { ok, all } = tcgpCacheSave({ ...tcgpCache, ...found }, keys);
      // storage full: nothing was written, but keep the fresh rows (and any
      // earlier session-only ones) in memory so this export still works
      const mem = Object.fromEntries(Object.entries(tcgpCache).filter(([, v]) => v.mem).concat(keys.map((k) => [k, { ...found[k], mem: true }])));
      setTcgpCache(ok ? all : { ...all, ...mem });
      const msg = keys.map((k) => `${tcgpCache[k] ? "Updated" : "Cached"} ${tcgpSetLabel(k, found[k])} (${found[k].rows.length} SKU${found[k].rows.length === 1 ? "" : "s"})`).join(" · ") + ".";
      setSyncMsg(ok ? msg : "Couldn't cache that set — storage is full. Clear some cached sets below. Using it for this export only.");
    }, error: () => setSyncMsg("Couldn't read that file.") });
  };
  const tcgpCacheDrop = (key) => {
    const next = { ...tcgpCache };
    const label = tcgpSetLabel(key, tcgpCache[key]);
    delete next[key];
    const { ok, all } = tcgpCacheSave(next);
    setTcgpCache(ok ? all : next); // the removal stands either way
    setSyncMsg(`Removed ${label}.`);
  };
  const tcgpCacheClear = () => {
    try { localStorage.removeItem(TCGP_SKU_KEY); } catch {}
    setTcgpCache({});
    setSyncMsg("Cleared all cached set exports.");
  };
  // a card already in someone's slab cannot be sent to a grader — offering it
  // here is how a CGC 9 ends up logged as a fresh submission with a second fee
  const gradable = inv.filter((c) => c.status === "Kept" && c.grade === "Raw");
  const live = inv.filter((c) => c.status !== "Sold");
  const val = live.reduce((s, c) => s + (Number(c.value) || 0), 0);
  const basis = live.reduce((s, c) => s + invBasis(c), 0);
  const range = invRange(live);
  const hasRange = range.lo !== range.hi;
  const FILTERS = ["All", "Kept", "At grading", "Listed", "Sold"];
  const shown = useMemo(() => (filter === "All" ? inv : inv.filter((c) => c.status === filter)).slice().sort(byDateDesc), [inv, filter]);
  const viewCard = viewId ? inv.find((c) => c.id === viewId) : null;

  return (
    <div className="cl-stack">
      <Header title="Inventory" sub={`${live.length} held · ${hasRange ? fmtRange(range) : fmt(val)} market`} onAdd={() => { setAdding(!adding); setEditId(null); }} addOpen={adding} />
      {live.length > 0 && <div className="cl-grid2"><Stat label="Cost basis" value={fmt(basis)} tone="out" /><Stat label="Unrealized" value={hasRange ? <span className="cl-range">{fmtRange({ lo: range.lo - basis, hi: range.hi - basis })}</span> : fmt(val - basis)} tone={range.lo - basis >= 0 ? "in" : range.hi - basis < 0 ? "neg" : "out"} /></div>}
      {inv.length > 0 && <div className="cl-import">
        <button className="cl-import-btn" onClick={refreshPrices} disabled={refreshing}><RefreshCw size={14} className={refreshing ? "cl-spin" : ""} /> {refreshing ? "Refreshing prices…" : "Refresh market prices (TCGplayer daily data)"}</button>
        {(state.sales || []).length > 0 && <button className="cl-import-btn" style={{ marginTop: 8 }} onClick={reconcileSold}><RefreshCw size={14} /> Check against sales — mark anything already sold</button>}
        <button className="cl-import-btn" style={{ marginTop: 8 }} onClick={() => { setScanOpen(!scanOpen); setSyncMsg(""); }}><Sparkles size={14} /> Grading candidates — rank raw cards by grading upside</button>
        {scanOpen && <div className="cl-tcgp-pick cl-tabpane">
          <div className="cl-scan-ctl">
            <Field label="Min raw value"><MoneyInput value={scanFloor} onChange={setScanFloor} /></Field>
            <Field label="Grading cost"><MoneyInput value={scanFee} onChange={setScanFee} /></Field>
            <button className="cl-save cl-scan-go" disabled={scanning || !scanCands.length} onClick={runScan}>{scanning ? "Scanning…" : `Scan ${scanCands.length} card${scanCands.length === 1 ? "" : "s"}`}</button>
          </div>
          <div className="cl-import-msg">Ranks raw held cards by what a PSA 10 nets over selling raw (recent eBay solds − raw value − grading cost). Spends the daily eBay-comps budget (~2 credits a card, highest-value cards first); results save to each card, so a scan the budget cuts short resumes next run.</div>
          {scanMsg && <div className="cl-import-msg">{scanMsg}</div>}
          {ranked.length > 0 && <div className="cl-stack sm" style={{ marginTop: 9 }}>
            {ranked.map(({ c, raw, up10, up9 }) => (
              <div key={c.id} className="cl-row click" onClick={() => setViewId(c.id)}>
                <span className="holo-dot" />
                <div className="cl-row-main">
                  <div className="cl-row-title">{c.name}</div>
                  <div className="cl-row-meta">
                    raw {fmt(raw)} · PSA 10 {fmt(c.grading.psa10.p)}{c.grading.psa10.n ? ` ×${c.grading.psa10.n}` : ""}{c.grading.psa9 ? ` · PSA 9 ${fmt(c.grading.psa9.p)}` : ""}
                    {up9 != null && <span className={"cl-st " + (up9 >= 0 ? "listed" : "grading")}>{up9 >= 0 ? "9 still profits" : `9 loses ${fmt(-up9)}`}</span>}
                  </div>
                </div>
                <div className="cl-card-num">
                  <div className={"cl-money " + (up10 >= 0 ? "pos" : "neg")}>{up10 >= 0 ? "+" : ""}{fmt(up10)}</div>
                  <div className="cl-row-meta">if it 10s</div>
                </div>
              </div>
            ))}
          </div>}
          {scanNoData > 0 && <div className="cl-import-msg">{scanNoData} card{scanNoData === 1 ? "" : "s"} had no usable graded-sales data.</div>}
        </div>}
        {gradable.length > 0 && <button className="cl-import-btn" style={{ marginTop: 8 }} onClick={() => { setGradeOpen(!gradeOpen); setSyncMsg(""); }}><Sparkles size={14} /> Send cards to grading — log the fee and the postage</button>}
        {gradeOpen && <GradingForm cards={gradable} onSend={sendToGrading} onCancel={() => setGradeOpen(false)} />}
        <button className="cl-import-btn" style={{ marginTop: 8 }} onClick={toggleTcgp}><Upload size={14} /> Upload to TCGplayer — choose cards for a staged CSV</button>
        <input ref={tcgpFileRef} type="file" accept=".csv" hidden onChange={onTcgpFile} />
        <input ref={catFileRef} type="file" accept=".csv" hidden onChange={onCatalogFile} />
        {tcgpOpen && <div className="cl-tcgp-pick cl-tabpane">
          {tcgpEligible.length === 0
            ? <div className="cl-import-msg" style={{ marginTop: 0 }}>No raw Kept cards with a set name to list — the CSV import only takes raw singles, not slabs.</div>
            : <>
              <div className="cl-tcgp-pick-head">
                <span>{tcgpSel.size} of {tcgpEligible.length} selected{tcgpExcluded ? ` · ${tcgpExcluded} not listable (graded, Japanese or no set)` : ""}</span>
                <span>
                  <button className="cl-link" onClick={() => setTcgpSel(new Set(tcgpEligible.map((c) => c.id)))}>All</button>
                  <button className="cl-link" onClick={() => setTcgpSel(new Set())}>None</button>
                </span>
              </div>
              {tcgpEligible.map((c) => <label key={c.id} className="cl-tcgp-pick-row">
                <input type="checkbox" checked={tcgpSel.has(c.id)} onChange={() => tcgpTick(c.id)} />
                <span className="cl-tcgp-pick-name">{c.name}</span>
                <span className="cl-row-meta">{c.set}{c.number ? ` · ${c.number}` : ""}</span>
                <span className="cl-money">{fmt(Number(c.value) || 0)}</span>
              </label>)}
              <div className="cl-import-msg">
                {skuKeys.length
                  ? tcgpCoverage
                  : "Import a TCGplayer Pricing Custom Export first — Seller Portal → Pricing → Export Filtered CSV, with out-of-stock rows included."}
              </div>
              {tcgpCovered.length > 0 && <button className="cl-import-btn" style={{ marginTop: 8 }} disabled={!!catBusy} onClick={tcgpExport}>
                <Upload size={14} /> {catBusy || `Export CSV (${tcgpCovered.length} card${tcgpCovered.length === 1 ? "" : "s"})`}
              </button>}
            </>}
          {/* The catalog is reference data, not the ledger: it lives only on
              this device, never syncs, and a re-import rebuilds it. Importing
              has to stay reachable with an empty inventory — the catalog is
              what you enter the first card from. */}
          <div className="cl-tcgp-cache">
            <div className="cl-row-main">
              <div className="cl-tcgp-pick-name">Catalog</div>
              <div className="cl-row-meta">
                {cat.rows
                  ? `${cat.rows.toLocaleString()} Near Mint SKUs · ${cat.sets.length} set${cat.sets.length === 1 ? "" : "s"}${cat.lastImport ? ` · ${tcgpAge(Date.parse(cat.lastImport.at))}` : ""}`
                  : "Empty — import an export to give new cards an exact SKU."}
              </div>
            </div>
            {cat.rows > 0 && <button className="cl-link" onClick={onCatalogClear}><Trash2 size={12} /> Clear</button>}
          </div>
          <button className="cl-import-btn" style={{ marginTop: 8 }} disabled={!!catBusy} onClick={() => catFileRef.current?.click()}>
            <Library size={14} /> {catBusy || (cat.rows ? "Import another TCGplayer export" : "Import a TCGplayer export")}
          </button>
          <div className="cl-import-msg" style={{ marginTop: 3 }}>
            Pricing Custom Export from Seller Portal → Pricing, with out-of-stock rows included. Near Mint rows are kept; the rest are left out.
          </div>
          {tcgpCacheKeys.length > 0 && <div className="cl-tcgp-cache">
            <button className="cl-link" onClick={() => setTcgpCacheOpen(!tcgpCacheOpen)}>
              {tcgpCacheOpen ? <ChevronDown size={13} /> : <ChevronRight size={13} />} Cached set exports ({tcgpCacheKeys.length})
            </button>
            {tcgpCacheOpen && <>
              {tcgpCacheKeys
                .slice()
                .sort((a, b) => tcgpSetLabel(a, tcgpCache[a]).localeCompare(tcgpSetLabel(b, tcgpCache[b])))
                .map((k) => <div key={k} className="cl-tcgp-cache-row">
                  <div className="cl-row-main">
                    <div className="cl-tcgp-pick-name">{tcgpSetLabel(k, tcgpCache[k])}</div>
                    <div className="cl-row-meta">
                      {(tcgpCache[k].rows || []).length} SKUs · {tcgpAge(tcgpCache[k].savedAt)}
                      {Date.now() - (tcgpCache[k].savedAt || 0) > TCGP_STALE_MS ? " · may be missing new products" : ""}
                      {tcgpCache[k].mem ? " · this session only" : ""}
                    </div>
                  </div>
                  {/* the OS picker can't be scoped to one set, so say which file to pick */}
                  <button className="cl-link" onClick={() => { setSyncMsg(`Pick a fresh ${tcgpSetLabel(k, tcgpCache[k])} export to replace the cached one.`); tcgpFileRef.current?.click(); }}>Refresh</button>
                  <button className="cl-link" onClick={() => tcgpCacheDrop(k)}>Remove</button>
                </div>)}
              <div className="cl-import-msg">
                {Math.max(1, Math.round(tcgpCacheBytes(tcgpCache) / 1024))} KB stored
                <button className="cl-link" style={{ marginLeft: 10 }} onClick={tcgpCacheClear}><Trash2 size={12} /> Clear all</button>
              </div>
            </>}
          </div>}
        </div>}
        {syncMsg && <div className="cl-import-msg">{syncMsg}</div>}
      </div>}
      {adding && <InvForm onSave={add} onCancel={() => setAdding(false)} />}
      {inv.length > 0 && <div className="cl-pills">{FILTERS.map((x) => <button key={x} className={"cl-pill" + (filter === x ? " on" : "")} onClick={() => setFilter(x)}>{x}</button>)}</div>}
      {inv.length === 0 && !adding && <Empty>No cards yet. Add a keeper or a card you've sent for grading, or hit “+ Keep” from Lookup to pull one in with its market value.</Empty>}
      <div className="cl-stack sm">
        {shown.map((c) => (
          <InventoryRow key={c.id} card={c} isEditing={editId === c.id} onEdit={onEditRow} onDelete={del} onOpen={onOpenRow} onSave={upd} onCancelEdit={onCancelEdit} />
        ))}
      </div>
      {viewCard && <CardModal card={viewCard} onClose={() => setViewId(null)}
        onEdit={() => { setViewId(null); setEditId(viewCard.id); setAdding(false); }}
        onValue={(v) => upd({ id: viewCard.id, value: v })} />}
    </div>
  );
}
/* Send a submission to the graders.
   One flow records the whole trip. Each card flips to "At grading" and takes the
   per-card fee plus its share of the postage, so its basis tells the truth. The
   submission also lands in Buys as one Grading entry, because "Spent" and "Net on
   cards" count buys, not card fields. The money is typed once and counted once:
   the buy carries the cash, and each card carries its share. */
const splitEvenly = (total, n) => {
  // split in cents, so the shares always add back to the total exactly — a naive
  // divide leaves a stray cent that makes the basis disagree with the buy
  const cents = Math.round((Number(total) || 0) * 100);
  const base = Math.floor(cents / n), rem = cents - base * n;
  return Array.from({ length: n }, (_, i) => (base + (i < rem ? 1 : 0)) / 100);
};
function GradingForm({ cards, onSend, onCancel }) {
  const [sel, setSel] = useState(new Set());
  const [grader, setGrader] = useState("PSA");
  const [fee, setFee] = useState("");
  const [ship, setShip] = useState("");
  const [date, setDate] = useState(today());
  const tick = (id) => setSel((s) => { const n = new Set(s); if (n.has(id)) n.delete(id); else n.add(id); return n; });
  const ids = cards.filter((c) => sel.has(c.id)).map((c) => c.id);
  const n = ids.length;
  const feeEach = Number(fee) || 0, shipTotal = Number(ship) || 0;
  const total = feeEach * n + shipTotal;
  const shipEach = n ? shipTotal / n : 0;
  return (
    <Form>
      <div className="cl-tcgp-pick-head">
        <span>{n} of {cards.length} selected</span>
        <span>
          <button className="cl-link" onClick={() => setSel(new Set(cards.map((c) => c.id)))}>All</button>
          <button className="cl-link" onClick={() => setSel(new Set())}>None</button>
        </span>
      </div>
      <div className="cl-stack sm" style={{ maxHeight: 260, overflowY: "auto" }}>
        {cards.map((c) => <label key={c.id} className="cl-tcgp-pick-row">
          <input type="checkbox" checked={sel.has(c.id)} onChange={() => tick(c.id)} />
          <span className="cl-tcgp-pick-name">{c.name}</span>
          <span className="cl-row-meta">{c.set}{c.number ? ` · ${c.number}` : ""}</span>
          <span className="cl-money">{fmt(Number(c.value) || 0)}</span>
        </label>)}
      </div>
      <div className="cl-grid2"><Field label="Grader"><Select opts={GRADERS} value={grader} onChange={setGrader} /></Field><Field label="Sent on"><input className="cl-in" type="date" value={date} onChange={(e) => setDate(e.target.value)} /></Field></div>
      <div className="cl-grid2"><Field label="Grading fee (each)"><MoneyInput value={fee} onChange={setFee} /></Field><Field label="Shipping (whole submission)"><MoneyInput value={ship} onChange={setShip} /></Field></div>
      {n > 0 && <div className="cl-net-preview">
        <span>{n} card{n === 1 ? "" : "s"} · {fmt(feeEach)} each + {fmt(shipTotal)} postage</span>
        <span className="cl-money out">{fmt(total)}</span>
      </div>}
      {n > 0 && <div className="cl-gradeest-note">Each card takes {fmt(feeEach + shipEach)} onto its basis ({fmt(feeEach)} fee + {fmt(shipEach)} postage). The {fmt(total)} also lands in Buys as one {grader} Grading entry, which is what moves Spent and Net. Any grading cost already on a selected card is replaced. Each card also records that it is at {grader}, so “Refresh market prices” values it against {grader} solds — {GRADER_LADDER[grader].join(" / ")} — not another company's.</div>}
      <Actions onCancel={onCancel} label={n ? `Send ${n} card${n === 1 ? "" : "s"} to ${grader}` : "Send to grading"} disabled={!n || !total}
        onSave={() => onSend({ ids, grader, fee: feeEach, ship: shipTotal, date })} />
    </Form>
  );
}
export function InvForm({ initial, onSave, onCancel }) {
  const estStr = (e, grader) => Object.fromEntries(GRADER_LADDER[grader].map((g) => [g, numStr(e?.[g])]));
  const [f, setF] = useState(initial
    ? { name: initial.name, set: initial.set || "", number: initial.number || "", variant: initial.variant || "", tcgplayerId: initial.tcgplayerId || "", productId: initial.productId || "", lang: cardLang(initial), grade: initial.grade || "Raw", status: initial.status || "Kept", grader: cardGrader(initial), source: initial.source || "Rip pull", cost: numStr(initial.cost), gradingCost: numStr(initial.gradingCost), gradingShip: numStr(initial.gradingShip), value: numStr(initial.value), gradeEst: estStr(initial.gradeEst, cardGrader(initial)), date: initial.date || today() }
    : { name: "", set: "", number: "", variant: "", tcgplayerId: "", productId: "", lang: "en", grade: "Raw", status: "Kept", grader: DEFAULT_GRADER, source: "Rip pull", cost: "", gradingCost: "", gradingShip: "", value: "", gradeEst: estStr(null, DEFAULT_GRADER), date: today() });
  const [comps, setComps] = useState("");
  const [slabMsg, setSlabMsg] = useState("");
  const slab = slabOf(f.grade);
  const ladder = GRADER_LADDER[f.grader] || GRADER_LADDER[DEFAULT_GRADER];
  // Switching grader empties the estimates on purpose. They were the other
  // company's sold prices, and carrying them over is the exact mistake this
  // field exists to stop — a PSA 10 figure sitting under a CGC 10 label.
  const setGrader = (grader) => setF((s) => ({ ...s, grader, gradeEst: estStr(null, grader) }));
  /* The market price is the English raw price, so it fills only a card
     that is both. It also never overwrites a value already typed — the
     figure in the box was put there on purpose. */
  const pickCard = (c) => setF((s) => {
    const price = tcgPriceable(s) ? cardPrice(c, c.variant) : null;
    return { ...s, name: c.name, set: c.set?.name || "", number: c.number || "",
      variant: c.variant || s.variant, tcgplayerId: c.tcgplayerId || "", productId: c.productId || "",
      value: s.value || (price != null ? String(price) : "") };
  });
  const pullComps = async () => {
    if (comps === "loading") return;
    setComps("loading");
    try {
      const r = await fetchGradedComps(f.name, f.set, f.number, f.lang, f.productId || "");
      if (!compsMatch(r, f)) { setComps(wrongCardMsg(r)); return; }
      const got = compGrades(r, f.grader);
      // read off the ladder, not Object.keys — JS sorts "10" and "9" ahead of
      // "9.5", which would print the grades out of order
      const grades = ladder.filter((g) => got[g] > 0);
      if (!grades.length) { setComps(`No recent ${f.grader} sales found for this card — fill the values in manually.`); return; }
      setF((s) => ({ ...s, gradeEst: { ...s.gradeEst, ...Object.fromEntries(grades.map((g) => [g, String(got[g])])) } }));
      const label = r.number && !String(r.card).includes(r.number) ? `${r.card} ${r.number}` : r.card;
      setComps(`${f.grader} ${grades.join(" / ")} filled from eBay solds (${grades.map((g) => compCount(r, f.grader, g) || "–").join(" / ")} sales) — ${label}.`);
    } catch (e) {
      setComps(e.status === 401 ? NO_TOKEN_MSG
        : e.status === 501 ? "Not set up yet — the sync Lambda needs a pokemonpricetracker.com API key (see aws/deploy.sh)."
        : e.status === 429 ? "Daily eBay-comps budget is used up — try again tomorrow, or fill the values in manually."
        : e.status === 404 ? "No recent graded sales found for this card — fill the values in manually."
        : "Comps unavailable right now — fill the values in manually.");
    }
  };
  /* A card already in a slab has one honest market value: what that slab sells
     for. This reads the bucket for the exact grade on the label — never a
     neighbouring grade, and never the raw price, which is what the card would
     be worth cracked out. */
  const pullSlab = async () => {
    if (slabMsg === "loading" || !slab) return;
    setSlabMsg("loading");
    try {
      const r = await fetchGradedComps(f.name, f.set, f.number, f.lang, f.productId || "");
      if (!compsMatch(r, f)) { setSlabMsg(wrongCardMsg(r)); return; }
      const b = slabComp(r, f.grade);
      if (!b) { setSlabMsg(`No recent ${f.grade} sales found for this card — the other grades it did sell in are on the card's detail view. Fill the value in manually.`); return; }
      setF((x) => ({ ...x, value: String(b.price) }));
      const spread = b.min != null && b.max != null && b.min !== b.max ? `, ${fmt(b.min)} – ${fmt(b.max)}` : "";
      setSlabMsg(`${f.grade} · ${fmt(b.price)} from ${b.count} eBay sold${b.count === 1 ? "" : "s"}${spread}.`);
    } catch (e) {
      setSlabMsg(e.status === 401 ? NO_TOKEN_MSG
        : e.status === 501 ? "Not set up yet — the sync Lambda needs a pokemonpricetracker.com API key (see aws/deploy.sh)."
        : e.status === 429 ? "Daily eBay-comps budget is used up — try again tomorrow, or fill the value in manually."
        : e.status === 404 ? "No recent sales found for this card — fill the value in manually."
        : "Comps unavailable right now — fill the value in manually.");
    }
  };
  // comps are pulled only on the "Pull eBay comps" button below — auto-pull
  // burned through pokemonpricetracker.com's daily credit budget too fast.
  return (
    <Form editing={!!initial}>
      {/* Inventory used to be the one screen with no card search on it —
          you typed the name, the set and the number by hand, and nothing
          gave the card a SKU. Picking a row fills all four fields and the
          printing, so a card added here lists on TCGplayer with no
          name-matching step at all. The fields stay editable, because a
          card the search cannot reach still has to be enterable. */}
      <Field label="Find the card"><CardSearch onPick={pickCard} placeholder="Search a card — name, number, or set" /></Field>
      <Field label="Card"><input className="cl-in" placeholder="Umbreon ex SIR" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></Field>
      <div className="cl-grid2"><Field label="Set"><input className="cl-in" placeholder="Prismatic Evolutions" value={f.set} onChange={(e) => setF({ ...f, set: e.target.value })} /></Field><Field label="Number"><input className="cl-in" placeholder="161/131" value={f.number} onChange={(e) => setF({ ...f, number: e.target.value })} /></Field></div>
      {/* "Printing" is what TCGplayer calls it on the listing form; the field
          is `variant` in the ledger. Raw select rather than <Select> so the
          unset option can carry a label instead of rendering blank. */}
      <div className="cl-grid2"><Field label="Language"><select className="cl-in" value={f.lang} onChange={(e) => setF({ ...f, lang: e.target.value })}>{LANGS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></Field><Field label="Printing"><select className="cl-in" value={f.variant} onChange={(e) => setF({ ...f, variant: e.target.value })}><option value="">— not set —</option>{VARIANTS.map((v) => <option key={v} value={v}>{v}</option>)}</select></Field></div>
      {f.lang === "jp" && <div className="cl-gradeest-note">Japanese cards are priced from their own eBay solds. “Refresh market prices” leaves them out of the English TCGplayer data, so a JP card can never pick up the price of the English card with the same name and number.</div>}
      <div className="cl-grid2"><Field label="Grade"><Select opts={GRADES} value={f.grade} onChange={(v) => setF({ ...f, grade: v })} /></Field><Field label="Status"><Select opts={INV_STATUS} value={f.status} onChange={(v) => setF({ ...f, status: v })} /></Field></div>
      <Field label="Source"><Select opts={INV_SOURCES} value={f.source} onChange={(v) => setF({ ...f, source: v })} /></Field>
      {f.status === "At grading" && <>
        {/* Where the card is decides what it is worth — the same card sells for
            very different money in a PSA slab and a CGC one, so the estimates
            below follow this field. */}
        <Field label="At which grader"><Select opts={GRADERS} value={f.grader} onChange={setGrader} /></Field>
        <div className="cl-field">
          <div className="cl-gradeest-head"><span>If it grades — what you think it's worth at each {f.grader} grade</span><button className="cl-link" disabled={!f.name || comps === "loading"} onClick={pullComps}>{comps === "loading" ? "Pulling…" : "Pull eBay comps"}</button></div>
          <div className="cl-gradeest">{ladder.map((g) => <div key={g} className="cl-gradeest-cell"><span className="cl-gradeest-g">{f.grader} {g}</span><MoneyInput placeholder="—" value={f.gradeEst[g] || ""} onChange={(v) => setF({ ...f, gradeEst: { ...f.gradeEst, [g]: v } })} /></div>)}</div>
          {comps && <div className="cl-gradeest-note">{comps === "loading" ? `Pulling eBay ${f.grader} sold comps…` : comps}</div>}
        </div>
      </>}
      <div className="cl-grid2"><Field label="Cost basis"><MoneyInput value={f.cost} onChange={(v) => setF({ ...f, cost: v })} /></Field><Field label="Market value"><MoneyInput value={f.value} onChange={(v) => setF({ ...f, value: v })} /></Field></div>
      {slab && <div className="cl-field">
        <div className="cl-gradeest-head"><span>Value it at what a {f.grade} slab sells for</span><button className="cl-link" disabled={!f.name || slabMsg === "loading"} onClick={pullSlab}>{slabMsg === "loading" ? "Pulling…" : "Pull slab price"}</button></div>
        {slabMsg && <div className="cl-gradeest-note">{slabMsg === "loading" ? `Pulling eBay ${f.grade} sold comps…` : slabMsg}</div>}
      </div>}
      {/* Both grading costs count toward the basis. "Send cards to grading" fills
          them in for a whole submission; these fields correct one card. */}
      <div className="cl-grid2"><Field label="Grading cost"><MoneyInput value={f.gradingCost} onChange={(v) => setF({ ...f, gradingCost: v })} /></Field><Field label="Grading shipping"><MoneyInput value={f.gradingShip} onChange={(v) => setF({ ...f, gradingShip: v })} /></Field></div>
      <div className="cl-net-preview"><span>True basis</span><span className="cl-money out">{fmt((Number(f.cost) || 0) + (Number(f.gradingCost) || 0) + (Number(f.gradingShip) || 0))}</span></div>
      {/* gradeEst is written on the saved card's ladder only, so a card that
          moved graders can never keep a stale grade from the old scale */}
      <Actions onCancel={onCancel} label={initial ? "Update card" : "Add card"} disabled={!f.name} onSave={() => onSave({ ...(initial ? { id: initial.id } : {}), name: f.name, set: f.set, number: f.number, variant: f.variant, tcgplayerId: f.tcgplayerId, productId: f.productId || "", lang: f.lang, grade: f.grade, status: f.status, grader: f.grader, source: f.source, cost: Number(f.cost) || 0, gradingCost: Number(f.gradingCost) || 0, gradingShip: Number(f.gradingShip) || 0, value: Number(f.value) || 0, gradeEst: Object.fromEntries(ladder.map((g) => [g, Number(f.gradeEst[g]) || 0])), date: f.date })} />
    </Form>
  );
}

/* ------------------------------------------------------------------ */
/* The price-over-time strip in the card modal. One series, so the section
   title is the legend; the line wears the market accent and every number
   wears an ink token, never the series color. The hover readout follows the
   pointer (touch included) and names the exact day and price. */
function PriceSpark({ points }) {
  const [at, setAt] = useState(null); // index under the pointer
  const W = 320, H = 56, PAD = 4;
  const vals = points.map((p) => p.market);
  const lo = Math.min(...vals), hi = Math.max(...vals);
  const span = hi - lo || 1;
  const x = (i) => PAD + (i / Math.max(1, points.length - 1)) * (W - PAD * 2);
  const y = (v) => H - PAD - ((v - lo) / span) * (H - PAD * 2);
  const d = points.map((p, i) => `${i ? "L" : "M"}${x(i).toFixed(1)},${y(p.market).toFixed(1)}`).join("");
  const cur = points[points.length - 1];
  const pick = (e) => {
    const box = e.currentTarget.getBoundingClientRect();
    const fx = (e.clientX - box.left) / box.width;
    setAt(Math.max(0, Math.min(points.length - 1, Math.round(fx * (points.length - 1)))));
  };
  const a = at != null ? points[at] : null;
  return (
    <div className="cl-spark">
      <svg viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" className="cl-spark-svg"
        onPointerMove={pick} onPointerDown={pick} onPointerLeave={() => setAt(null)}>
        <path d={d} fill="none" stroke="var(--holo2)" strokeWidth="2" strokeLinejoin="round" strokeLinecap="round" vectorEffect="non-scaling-stroke" />
        {a
          ? <><line x1={x(at)} y1={PAD} x2={x(at)} y2={H - PAD} stroke="var(--line)" strokeWidth="1" vectorEffect="non-scaling-stroke" /><circle cx={x(at)} cy={y(a.market)} r="3.5" fill="var(--holo2)" /></>
          : <circle cx={x(points.length - 1)} cy={y(cur.market)} r="3.5" fill="var(--holo2)" />}
      </svg>
      <div className="cl-spark-meta">
        {a
          ? <span>{a.date} · <b>{fmt(a.market)}</b></span>
          : <span>{points[0].date} → {cur.date} · now <b>{fmt(cur.market)}</b></span>}
        <span className="cl-row-meta">low {fmt(lo)} · high {fmt(hi)}</span>
      </div>
    </div>
  );
}

/* Card detail modal — opened by tapping an inventory row. Pulls four PPT
   slots in parallel through the Lambda: the whole-set dump for a live
   market price, /search for the card image/details, /graded for recent
   eBay solds (raw + slabbed), and /history for the price line. The graded
   pull spends the daily PPT credit budget (cached 24h client & server) —
   fine here because opening a card is a deliberate one-card action, unlike
   the form auto-pull that was removed for draining the budget. Japanese
   cards resolve everything through PPT's Japanese catalogue. */
const CM_COMPANIES = [["psa", "PSA"], ["cgc", "CGC"], ["tag", "TAG"]];
const CM_GRADES = ["10", "9.5", "9", "8"];
const cmTrend = (t) => (t === "up" ? <span className="cl-cm-tr up">▲</span> : t === "down" ? <span className="cl-cm-tr down">▼</span> : null);
const cmErrMsg = (s) => (s === 401 ? NO_TOKEN_MSG
  : s === 501 ? "eBay comps aren't set up on the sync Lambda."
  : s === 429 ? "Daily eBay-comps budget is used up — sold data comes back tomorrow."
  : s === 404 ? "No recent eBay solds found for this card."
  : "eBay sold data is unavailable right now.");
function CardModal({ card, onClose, onEdit, onValue }) {
  const [match, setMatch] = useState(null);   // /search match: null = looking, false = none found
  const [live, setLive] = useState(null);     // market from the set dump
  const [comps, setComps] = useState({ state: "loading" }); // /graded body
  const [hist, setHist] = useState(null);     // /history body: null = looking, false = none
  useEffect(() => {
    let ok = true;
    setMatch(null); setLive(null); setComps({ state: "loading" }); setHist(null);
    const lang = cardLang(card);
    // four independent slots, fired together — each fills as it lands (the
    // first market value to arrive wins; the rest keep theirs)
    (async () => {
      if (!card.set || !card.number) return;
      const m = await fetchSetPrices(card.set, false, lang);
      const v = subPrice(m?.[normNum(card.number)], card.variant);
      if (ok && v != null) setLive((p) => (p != null ? p : v));
    })();
    (async () => {
      // the set catalog the binder already warmed carries this card's art —
      // read it first so the modal never says "no image" for a card whose
      // tile is showing one
      if (card.set) {
        const row = imageInSet(await fetchSetCatalog(card.set, lang), card);
        if (ok && row?.img) setMatch((m) => m || { images: { small: row.img }, rarity: row.rarity, set: { name: card.set }, number: row.num });
      }
      const hit = await lookupCardMatch(card);
      if (!ok) return;
      setMatch((m) => hit || m || false);
      if (!hit) return;
      let v = cardPrice(hit, card.variant);
      // ledger card missing set/number: the match names them, so its set dump can still price it
      if (v == null && hit.set?.name && hit.number && !(card.set && card.number)) {
        const m = await fetchSetPrices(hit.set.name, false, lang);
        v = subPrice(m?.[normNum(hit.number)], card.variant);
      }
      if (ok && v != null) setLive((p) => (p != null ? p : v));
    })();
    (async () => {
      try { const r = await fetchGradedComps(card.name, card.set, card.number, lang, card.productId || ""); if (ok) setComps({ state: "ok", data: r }); }
      catch (e) { if (ok) setComps({ state: "err", status: e.status || 0 }); }
    })();
    (async () => {
      try {
        const h = await cardFetch("history", { productId: card.productId || "", name: card.productId ? "" : card.name, set: card.productId ? "" : card.set, number: card.productId ? "" : card.number, lang: lang === "jp" ? "jp" : "", days: "90" });
        if (ok) setHist(h?.points?.length > 1 ? h : false);
      } catch { if (ok) setHist(false); } // 401/404/429 alike: the section just doesn't render
    })();
    return () => { ok = false; };
  }, [card.id]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    const onKey = (e) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKey);
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => { window.removeEventListener("keydown", onKey); document.body.style.overflow = prev; };
  }, [onClose]);

  const data = comps.data;
  const img = (match && match.images?.small) || data?.image || null;
  const market = live != null ? live : data?.market ?? null;
  const value = Number(card.value) || 0;
  const basis = invBasis(card);
  const unreal = value - basis;
  const rarity = match?.rarity || data?.rarity || "";
  /* What this card is worth, and it is not always the TCGplayer market price.
     A card in a slab is worth what that slab sells for, so it reads its own
     grade's sold bucket — and if no one has sold one lately there is no honest
     number to offer, which is a better answer than the raw price of the card
     sealed inside it. */
  const slabbed = !!slabOf(card.grade);
  const slabB = slabComp(data, card.grade);
  const headline = slabB ? { v: slabB.price, lab: `${card.grade} · ${slabB.count} eBay sold${slabB.count === 1 ? "" : "s"}` }
    : slabbed ? null
    : market != null ? { v: market, lab: `TCGplayer market${card.variant ? ` · ${card.variant}` : ""}` }
    : null;
  const held = card.date ? Math.max(0, Math.round((Date.now() - new Date(card.date + "T12:00:00").getTime()) / 864e5)) : null;
  const shownKeys = new Set(CM_COMPANIES.flatMap(([co]) => CM_GRADES.map((g) => bucketKey(co, g))));
  const extras = Object.entries(data?.byGrade || {})
    .flatMap(([k, b]) => {
      if (shownKeys.has(k)) return [];
      const m = k.match(/^([a-z]+)([\d_]+)$/);
      return m ? [{ label: `${m[1].toUpperCase()} ${m[2].replace("_", ".")}`, ...b }] : [];
    })
    .sort((a, b) => b.price - a.price);
  const anyGraded = Object.keys(data?.byGrade || {}).length > 0;
  // shown, not dropped: on a screen someone is looking at, naming the near miss
  // beats hiding it — they can fix the set or number and pull again
  const mismatch = data && !compsMatch(data, card);
  const grader = cardGrader(card);
  const ests = estGrades(card).filter((g) => Number(card.gradeEst?.[g]) > 0);
  const tcgpUrl = data?.url || `https://www.tcgplayer.com/search/pokemon/product?q=${encodeURIComponent(`${card.name} ${card.number || ""}`.trim())}`;
  // the search that finds this exact card: a slab's grade and a JP printing both
  // pull a different set of listings, so both belong in the terms
  const ebayUrl = `https://www.ebay.com/sch/i.html?_nkw=${encodeURIComponent(`pokemon ${isJP(card) ? "japanese " : ""}${card.name} ${card.number || ""} ${slabbed ? card.grade : ""}`.replace(/\s+/g, " ").trim())}&LH_Sold=1&LH_Complete=1`;
  const rawMeta = data?.raw ? [
    `${data.raw.count} sale${data.raw.count === 1 ? "" : "s"}`,
    data.raw.median != null ? `median ${fmt(data.raw.median)}` : null,
    data.raw.min != null && data.raw.max != null ? `${fmt(data.raw.min)} – ${fmt(data.raw.max)}` : null,
  ].filter(Boolean).join(" · ") : "";

  return (
    <div className="cl-modal-ov" onClick={onClose}>
      <div className="cl-modal" role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()}>
        <button className="cl-x cl-cm-close" onClick={onClose}><X size={16} /></button>
        <div className="cl-cm-top">
          {img
            ? <img className="cl-cm-img" src={img} alt={card.name} />
            : <div className="cl-cm-img ph">{match === null || comps.state === "loading" ? "loading…" : "no image found"}</div>}
          <div className="cl-cm-head">
            <div className="cl-cm-name">{card.name}</div>
            <div className="cl-row-meta">{card.set || match?.set?.name || data?.set || "set unknown"}{(card.number || match?.number || data?.number) ? ` · ${card.number || match?.number || data?.number}` : ""}{rarity ? ` · ${rarity}` : ""}</div>
            <div className="cl-row-meta"><span className={"cl-st " + stCls(card.status)}>{statusLabel(card)}</span><span className="cl-chip">{card.grade}</span>{isJP(card) && <span className="cl-chip">JP</span>}{card.variant && <span className="cl-chip">{VARIANT_SHORT[card.variant] || card.variant}</span>}</div>
            <div className="cl-cm-mkt">
              <div className="cl-cm-mkt-num">{headline ? fmt(headline.v) : "—"}</div>
              {/* name what this price is for — the button below writes it into
                  the ledger, and silently applying a normal price to a reverse
                  holo, or a raw price to a slab, is exactly what the variant and
                  grade fields exist to stop */}
              <div className="cl-cm-mkt-lab">{headline ? headline.lab
                : slabbed ? `${card.grade} — no recent solds`
                : `TCGplayer market${card.variant ? ` · ${card.variant}` : ""} — no data`}</div>
            </div>
            {headline && Math.abs(headline.v - value) > 0.005 && card.status !== "Sold" &&
              <button className="cl-mini cl-cm-apply" onClick={() => onValue(Math.round(headline.v * 100) / 100)}>Set ledger value to {fmt(headline.v)}</button>}
          </div>
        </div>

        <div className="cl-cm-stats">
          <div className="cl-cm-stat"><span>Ledger value</span><b>{fmt(value)}</b></div>
          <div className="cl-cm-stat"><span>Cost basis</span><b>{fmt(basis)}</b></div>
          <div className="cl-cm-stat"><span>Unrealized</span><b className={unreal >= 0 ? "pos" : "neg"}>{fmt(unreal)}</b></div>
        </div>

        {hist && <>
          <div className="cl-cm-sec">Market price — last 90 days</div>
          <PriceSpark points={hist.points} />
        </>}

        <div className="cl-cm-sec">Recent eBay solds — raw</div>
        {comps.state === "loading" && <div className="cl-cm-note">Pulling eBay sold data…</div>}
        {comps.state === "err" && <div className="cl-cm-note">{cmErrMsg(comps.status)}</div>}
        {comps.state === "ok" && (data.raw
          ? <div className="cl-cm-raw"><span className="cl-cm-raw-price">{fmt(data.raw.price)}{cmTrend(data.raw.trend)}</span><span className="cl-row-meta">{rawMeta}</span></div>
          : <div className="cl-cm-note">No recent raw solds recorded.</div>)}

        {comps.state === "ok" && <>
          <div className="cl-cm-sec">Graded eBay solds</div>
          {anyGraded ? <>
            <div className="cl-cm-grid">
              <span />
              {CM_COMPANIES.map(([co, label]) => <span key={co} className="cl-cm-co">{label}</span>)}
              {CM_GRADES.map((g) => (
                <React.Fragment key={g}>
                  <span className="cl-cm-g">{g}</span>
                  {CM_COMPANIES.map(([co]) => {
                    const b = data.byGrade?.[bucketKey(co, g)];
                    return (
                      <span key={co} className="cl-cm-cell">
                        {b ? <><span className="cl-money">{fmt(b.price)}{cmTrend(b.trend)}</span><span className="cl-cm-cnt">{b.count} sold</span></> : <span className="cl-cm-none">—</span>}
                      </span>);
                  })}
                </React.Fragment>
              ))}
            </div>
            {extras.length > 0 && <div className="cl-cm-extra">{extras.map((x) => <span key={x.label} className="cl-chip">{x.label} {fmt(x.price)} · {x.count} sold</span>)}</div>}
          </> : <div className="cl-cm-note">No graded sales recorded for this card.</div>}
          {mismatch && <div className="cl-cm-note warn">Sold data matched “{data.card}{data.number ? ` · ${data.number}` : ""}” — that isn't this card, so these prices are for something else. Correcting this card's set and number will pull the right ones.</div>}
          {data.window?.from && <div className="cl-cm-foot">Sold data {String(data.window.from).slice(0, 10)} → {String(data.window.to).slice(0, 10)} · pokemonpricetracker.com</div>}
        </>}
        {ests.length > 0 && <div className="cl-cm-foot">Your {grader} estimates: {ests.map((g) => `${g} → ${fmt(Number(card.gradeEst[g]))}`).join(" · ")}</div>}

        <div className="cl-cm-sec">Details</div>
        <div className="cl-cm-meta">{card.source}{card.date ? ` · added ${card.date}` : ""}{held != null ? ` · held ${held} day${held === 1 ? "" : "s"}` : ""}{Number(card.gradingCost) > 0 ? ` · grading ${fmt(Number(card.gradingCost))}` : ""}</div>
        <div className="cl-cm-links">
          <a className="cl-mini" href={tcgpUrl} target="_blank" rel="noreferrer"><ExternalLink size={12} /> TCGplayer</a>
          <a className="cl-mini" href={ebayUrl} target="_blank" rel="noreferrer"><ExternalLink size={12} /> eBay solds</a>
          <button className="cl-mini" onClick={onEdit}><Pencil size={12} /> Edit card</button>
        </div>
      </div>
    </div>
  );
}

/* ================================================================== */
/* Binder: every held card as one image, grouped into a page per set —
   the shelf-of-binders view of the same rows Inventory lists as text.
   Tapping a card opens the same CardModal Inventory uses, so a look and
   an edit both land in one place. A card's picture is a live lookup off
   the whole-set /catalog dump (BinderCard below, cached by fetchSetCatalog
   and lookupCardMatch) — Japanese cards included; a card that lookup can't
   pin down falls back to a name tile instead of a broken image. */
function Binder({ state, patch, go }) {
  const inv = state.inventory || [];
  const [q, setQ] = useState("");
  const [showSold, setShowSold] = useState(false);
  const [viewId, setViewId] = useState(null);
  const typed = q.trim().toLowerCase();
  const cards = useMemo(() => inv
    .filter((c) => (showSold || c.status !== "Sold") && c.name)
    .filter((c) => !typed || c.name.toLowerCase().includes(typed) || (c.set || "").toLowerCase().includes(typed))
    .sort((a, b) => (a.set || "").localeCompare(b.set || "") || normNum(a.number).localeCompare(normNum(b.number), undefined, { numeric: true }) || a.name.localeCompare(b.name)),
  [inv, showSold, typed]);
  const pages = useMemo(() => {
    const out = [];
    for (const c of cards) {
      const key = c.set || "Unsorted";
      const page = out[out.length - 1]?.key === key ? out[out.length - 1] : (out.push({ key, cards: [] }), out[out.length - 1]);
      page.cards.push(c);
    }
    return out;
  }, [cards]);
  const viewCard = viewId ? inv.find((c) => c.id === viewId) : null;
  const setValue = (v) => patch((s) => ({ inventory: s.inventory.map((x) => (x.id === viewCard.id ? { ...x, value: v } : x)) }));
  const images = useCardImages(cards);

  return (
    <div className="cl-stack">
      <Header title="Binder" sub={`${cards.length} card${cards.length === 1 ? "" : "s"}${pages.length > 1 ? ` · ${pages.length} sets` : ""}`} />
      {inv.length === 0
        ? <Empty>No cards yet. Add a keeper from Inventory or Lookup and it shows up here.</Empty>
        : <>
          <div className="cl-salesearch">
            <Search size={15} className="cl-salesearch-ic" />
            <input className="cl-in bare" placeholder="Search your binder — name or set" value={q} onChange={(e) => setQ(e.target.value)} />
            {q && <button className="cl-salesearch-x" onClick={() => setQ("")}><X size={14} /></button>}
          </div>
          <label className="cl-binder-soldtoggle"><input type="checkbox" checked={showSold} onChange={(e) => setShowSold(e.target.checked)} /> Show sold cards</label>
          {cards.length === 0 && <Empty>Nothing matches “{q}”.</Empty>}
          {pages.map((p) => (
            <div key={p.key} className="cl-binder-page">
              <div className="cl-binder-page-head"><span>{p.key}</span><span className="cl-row-meta">{p.cards.length} card{p.cards.length === 1 ? "" : "s"}</span></div>
              <div className="cl-binder-grid">
                {p.cards.map((c) => <BinderCard key={c.id} card={c} img={images[c.id]} onOpen={setViewId} />)}
              </div>
            </div>
          ))}
        </>}
      {viewCard && <CardModal card={viewCard} onClose={() => setViewId(null)}
        onEdit={() => { setViewId(null); go?.("inv"); }}
        onValue={setValue} />}
    </div>
  );
}
/* ================================================================== */
/* Card lookup: the same CardSearch every other screen uses, with the
   three add-paths hung off each row.

   Below it sits the one thing CardSearch cannot do — browse a whole
   TCGplayer set straight from the Lambda. That reaches a set the seller
   has never exported and a card the database has not indexed yet, which
   is most of the first week after a release. Its results are handed
   back to CardSearch as `extra`, so they render as the same rows in the
   same list rather than in a second list of their own. */
function Lookup({ state, patch }) {
  const [ripId, setRipId] = useState("");
  const [flashes, setFlashes] = useState({});
  const flash = (id, t) => { setFlashes((f) => ({ ...f, [id]: t })); setTimeout(() => setFlashes((f) => ({ ...f, [id]: null })), 1600); };

  const sets = useSets();
  const [catSet, setCatSet] = useState("");
  const [catQ, setCatQ] = useState("");
  const [catRows, setCatRows] = useState(NO_EXTRA);
  const [catMsg, setCatMsg] = useState("");
  const [catLoading, setCatLoading] = useState(false);
  const browseSet = async () => {
    const name = catSet.trim();
    if (!name || catLoading) return;
    setCatLoading(true); setCatMsg(""); setCatRows(NO_EXTRA);
    try {
      const j = await cardFetch("catalog", { set: name });
      const toks = catQ.toLowerCase().replace(/[^a-z0-9\s]/g, " ").split(/\s+/).filter(Boolean);
      /* A collector number is not always in the product name: "Reshiram
         (Stellar Crown Stamped)" carries 022/142 only on `num`, so a
         name-only filter drops it the moment the user types the number
         printed on the card. */
      const hasTok = (p, t) =>
        p.name.toLowerCase().includes(t) ||
        String(p.num || "").toLowerCase().includes(t) ||
        normNum(p.num) === normNum(t);
      const list = (j.cards || [])
        .filter((p) => toks.every((t) => hasTok(p, t)))
        .sort((a, b) => (b.market || 0) - (a.market || 0))
        .slice(0, 40)
        .map((p) => catalogCard(j.group, p, name));
      setCatRows(list.length ? list : NO_EXTRA);
      setCatMsg(list.length ? `${list.length} from ${j.group}, listed above.`
        : toks.length ? `Nothing in ${j.group} matches “${toks.join(" ")}” — empty this box to browse the whole set.`
        : "No singles found in that set.");
    } catch (e) {
      setCatMsg(e.status === 404 ? "The price database doesn't have a set by that name — pick one from the suggestions."
        : e.status === 401 ? NO_TOKEN_MSG
        : "The set catalog is unavailable right now — try again.");
    } finally { setCatLoading(false); }
  };

  const rip = ripId || state.rips[0]?.id;
  const asBuy = (c) => { patch(addAsBuy(c)); flash(c.id, "Added to Buys"); };
  const asKeep = (c) => { patch(addAsKeep(c)); flash(c.id, "Kept in inventory"); };
  const asHit = (c) => {
    if (!rip) { flash(c.id, "Make a rip first"); return; }
    patch(addAsHit(c, rip));
    flash(c.id, "Added as hit");
  };

  return (
    <div className="cl-stack">
      <Header title="Card lookup" sub="The catalog on this device, then the card database" />
      {state.rips.length > 0 && <select className="cl-rip-sel" style={{ width: "100%" }} value={ripId} onChange={(e) => setRipId(e.target.value)}>
        <option value="">+ Hit goes to the latest rip</option>
        {state.rips.map((r) => <option key={r.id} value={r.id}>+ Hit → {r.product || "Rip"}</option>)}
      </select>}
      <CardSearch
        panel
        extra={catRows}
        placeholder="Search a card — e.g. 091, banette dusk, or reshiram stamped"
        actions={(c) => (<>
          <div className="cl-lk-actions" style={{ marginTop: 0 }}>
            <button className="cl-mini" onClick={() => asBuy(c)}>+ Buy</button>
            <button className="cl-mini" onClick={() => asKeep(c)}>+ Keep</button>
            <button className="cl-mini holo-border" onClick={() => asHit(c)}>+ Hit</button>
          </div>
          {flashes[c.id] && <div className="cl-flash">{flashes[c.id]}</div>}
        </>)}
      />
      <div className="cl-cat">
        <div className="cl-row-meta">Missing from both? A new set reaches TCGplayer's catalog first — name it here and its cards join the list above:</div>
        <div className="cl-search">
          <input className="cl-in" list="bb-set-list" placeholder="Set — e.g. ME Black Star Promos" value={catSet} onChange={(e) => setCatSet(e.target.value)} onKeyDown={(e) => e.key === "Enter" && browseSet()} />
          <button className="cl-search-btn" onClick={browseSet}><PackageOpen size={15} /></button>
        </div>
        <input className="cl-in" placeholder="Filter that set — leave empty for all of it" value={catQ} onChange={(e) => setCatQ(e.target.value)} onKeyDown={(e) => e.key === "Enter" && browseSet()} />
        <datalist id="bb-set-list">{(sets || []).map((s) => <option key={s} value={s} />)}</datalist>
        {(catLoading || catMsg) && <div className="cl-import-msg">{catLoading ? "Reading TCGplayer's catalog…" : catMsg}</div>}
      </div>
    </div>
  );
}

/* ================================================================== */
/* Card scanner: photograph a card, Claude reads what's on it, and the
   match drops into the same three add-paths the Lookup tab uses.
   Named `snap` throughout — `scan` already belongs to the grading-
   candidate scanner on the Inventory tab. */
function CardSnap({ state, patch }) {
  const sets = useSets();
  const codes = useSetCodes();
  const camRef = useRef(null);
  const libRef = useRef(null);
  const [busy, setBusy] = useState("");   // "" | "reading" | "matching"
  const [err, setErr] = useState("");
  const [shot, setShot] = useState("");   // object URL of the photo just taken
  const [d, setD] = useState(null);       // the editable draft
  const [ripId, setRipId] = useState("");
  const [done, setDone] = useState("");
  const connected = !!syncToken();

  // one place owns revoking: the cleanup fires whenever `shot` changes and on
  // unmount, so nothing else has to remember to release the object URL
  useEffect(() => () => { if (shot) URL.revokeObjectURL(shot); }, [shot]);
  const dropShot = () => setShot("");

  const onPhoto = async (e) => {
    const file = e.target.files?.[0];
    e.target.value = ""; // without this, re-shooting the same file fires no change
    if (!file) return;
    setErr(""); setD(null); setDone("");
    setShot(URL.createObjectURL(file));
    setBusy("reading");
    try {
      const image = await downscale(file);
      const { cards } = await identifyFetch({ image, media_type: "image/jpeg", mode: "single" });
      const hit = cards?.[0];
      if (!hit) { const x = new Error("nothing found"); x.status = 422; throw x; }
      setBusy("matching");
      const lang = hit.language === "japanese" ? "jp" : "en";
      // the catalogue behind resolveScan is English, so a JP card is left with
      // what was read off it rather than matched to the English card that
      // shares its name — that match would bring the wrong set and price
      // the printing and the number were read off the card itself, so they hold
      // for a JP card; only the catalogue match is dropped
      const r = lang === "jp"
        ? { card: null, setName: hit.setName || "", variant: hit.variant && hit.variant !== "Unknown" ? hit.variant : "", number: hit.number || "" }
        : await resolveScan(hit, sets, codes);
      setD({ id: r.card?.id || "snap-" + uid(), card: r.card, name: r.card?.name || hit.name || "", set: r.setName, number: r.number, variant: r.variant, lang, grade: readGrade(hit), confidence: hit.confidence, notes: hit.notes });
    } catch (e2) { setErr(snapErrMsg(e2)); dropShot(); }
    finally { setBusy(""); }
  };

  // re-run the match after the set or number is corrected by hand. There is
  // nothing to re-match a JP card against — the catalogue is English, and the
  // card it would find is the English printing, not this one.
  const rematch = async () => {
    if (d.lang === "jp") return;
    setBusy("matching");
    try {
      const r = await resolveScan({ name: d.name, number: d.number, setName: d.set, setCode: null, variant: d.variant || "Unknown" }, sets, codes);
      setD((p) => ({ ...p, card: r.card, id: r.card?.id || p.id, set: r.setName || p.set, number: r.number || p.number }));
    } catch { setErr("Couldn't reach the card database — try again."); }
    finally { setBusy(""); }
  };

  // what the add-paths actually receive. Edits flow straight through, so the
  // price re-derives the moment the printing changes — which is the whole
  // point of asking for it.
  const card = d && { ...(d.card || { images: {} }), id: d.id, name: d.name, number: d.number, set: { name: d.set }, variant: d.variant, lang: d.lang, grade: d.grade };
  // the catalogue price is the English raw one, so it is shown only for a card
  // that is one — a slab or a JP card is comped in Inventory, not here
  const price = card && tcgPriceable(card) ? cardPrice(card, d.variant) : null;
  const priceable = !!card && tcgPriceable(card);
  const clear = () => { setD(null); dropShot(); };
  const add = (slice, msg) => { patch(slice); setDone(msg); clear(); };

  return (
    <div className="cl-stack">
      <Header title="Scan a card" sub="Photograph it — the name, number, set and printing are read for you" />
      {!connected
        ? <Empty>Connect this device to cloud sync on the Overview tab first — the scanner runs behind the same token.</Empty>
        : <>
          <div className="cl-import">
            <button className="cl-import-btn" disabled={!!busy} onClick={() => camRef.current?.click()}>
              <Camera size={14} /> {busy === "reading" ? "Reading the card…" : busy === "matching" ? "Matching to the catalog…" : "Photograph a card"}
            </button>
            <button className="cl-import-btn" style={{ marginTop: 8 }} disabled={!!busy} onClick={() => libRef.current?.click()}>
              <Upload size={14} /> Use a photo you already took
            </button>
            {/* capture="environment" opens the camera straight to the back
                lens; the second input has no capture so the library is still
                reachable, which is also the way to test this on a desktop */}
            <input ref={camRef} type="file" accept="image/*" capture="environment" hidden onChange={onPhoto} />
            <input ref={libRef} type="file" accept="image/*" hidden onChange={onPhoto} />
          </div>
          {err && <Empty>{err}</Empty>}
          {done && <div className="cl-flash">{done}</div>}
          {!d && !busy && !err && <div className="cl-note">Fill the frame with one card, straight on, in even light. The collector number in the bottom corner is what pins the match down.</div>}
          {d && <Panel title="Is this right?" action={d.lang === "jp" ? null : <button className="cl-link" disabled={!!busy} onClick={rematch}>Re-match</button>}>
            <div className="cl-cm-top">
              {shot ? <img className="cl-cm-img" src={shot} alt="the card you photographed" /> : <div className="cl-cm-img ph">no photo</div>}
              <div className="cl-cm-head">
                <div className="cl-cm-name">{d.name || "not read"}</div>
                <div className="cl-row-meta">{d.set || "set unknown"}{d.number ? ` · ${d.number}` : ""}</div>
                <div className="cl-cm-mkt">
                  <div className="cl-cm-mkt-num">{price != null ? fmt(price) : "—"}</div>
                  <div className="cl-cm-mkt-lab">{!priceable
                    ? `${d.grade !== "Raw" ? d.grade : "Japanese"} — comped in Inventory`
                    : `TCGplayer market${d.variant ? ` · ${d.variant}` : ""}${price == null ? " — no data" : ""}`}</div>
                </div>
              </div>
            </div>
            {(d.confidence !== "high" || d.notes) && <div className="cl-note" style={{ marginTop: 10 }}>{d.notes || "Parts of this were hard to read — check them before adding."}</div>}
            {!d.card && d.lang !== "jp" && <div className="cl-note" style={{ marginTop: 10 }}>No catalog match, so there's no market price yet. Correct the set or number and hit Re-match, or add it as-is and set the value by hand.</div>}
            <Field label="Card"><input className="cl-in" value={d.name} onChange={(e) => setD({ ...d, name: e.target.value })} /></Field>
            <div className="cl-grid2">
              <Field label="Set"><SetPicker sets={sets} value={d.set} onChange={(v) => setD({ ...d, set: v })} allowEmpty /></Field>
              <Field label="Number"><input className="cl-in" value={d.number} onChange={(e) => setD({ ...d, number: e.target.value })} /></Field>
            </div>
            <div className="cl-grid2">
              <Field label="Language">
                <select className="cl-in" value={d.lang} onChange={(e) => setD({ ...d, lang: e.target.value })}>
                  {LANGS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
                </select>
              </Field>
              <Field label="Printing">
                <select className="cl-in" value={d.variant} onChange={(e) => setD({ ...d, variant: e.target.value })}>
                  <option value="">— not set —</option>
                  {VARIANTS.map((v) => <option key={v} value={v}>{v}</option>)}
                </select>
              </Field>
            </div>
            <Field label="Grade">
              <select className="cl-in" value={d.grade} onChange={(e) => setD({ ...d, grade: e.target.value })}>
                {GRADES.map((g) => <option key={g} value={g}>{g === "Raw" ? "Raw (ungraded)" : g}</option>)}
              </select>
            </Field>
            {!priceable && <div className="cl-note" style={{ marginTop: 0 }}>
              {d.grade !== "Raw" ? `Read as a ${d.grade} slab. ` : "Read as a Japanese card. "}
              It goes in at no value — open it in Inventory and hit {d.grade !== "Raw" ? "“Pull slab price”" : "“Refresh market prices”"} to comp it against its own eBay solds.
            </div>}
            {state.rips.length > 0 && <Field label="Add a hit to"><select className="cl-in" value={ripId} onChange={(e) => setRipId(e.target.value)}><option value="">latest rip</option>{state.rips.map((r) => <option key={r.id} value={r.id}>{r.product || "Rip"}</option>)}</select></Field>}
            <div className="cl-snap-go">
              <button className="cl-mini" disabled={!d.name} onClick={() => add(addAsBuy(card), "Added to Buys.")}>+ Buy</button>
              <button className="cl-mini" disabled={!d.name} onClick={() => add(addAsKeep(card), "Kept in inventory.")}>+ Keep</button>
              <button className="cl-mini holo-border" disabled={!d.name || !state.rips.length} onClick={() => add(addAsHit(card, ripId || state.rips[0]?.id), "Added as a rip hit.")}>+ Hit</button>
              <button className="cl-mini" onClick={clear}>Discard</button>
            </div>
          </Panel>}
        </>}
    </div>
  );
}

/* ================================================================== */
function Header({ title, sub, onAdd, addOpen }) {
  return (<div className="cl-vhead"><div><h2 className="cl-h2">{title}</h2>{sub && <div className="cl-vsub">{sub}</div>}</div>{onAdd && <button className={"cl-addbtn" + (addOpen ? " on" : "")} onClick={onAdd}>{addOpen ? <X size={16} /> : <Plus size={16} />}</button>}</div>);
}
const Stat = ({ label, value, tone }) => (<div className={"cl-stat " + tone}><div className="cl-stat-label">{label}</div><div className="cl-stat-num">{value}</div></div>);
const Panel = ({ title, action, children }) => (<section className="cl-panel"><div className="cl-panel-head"><span>{title}</span>{action}</div>{children}</section>);
const Empty = ({ children }) => <div className="cl-empty">{children}</div>;
const Field = ({ label, children }) => <label className="cl-field"><span>{label}</span>{children}</label>;
const Form = ({ children, editing }) => <div className={"cl-form cl-tabpane" + (editing ? " cl-editing" : "")}>{children}</div>;
const Actions = ({ onCancel, onSave, label, disabled }) => (<div className="cl-form-actions">{onCancel && <button className="cl-cancel" onClick={onCancel}>Cancel</button>}<button className="cl-save" disabled={disabled} onClick={onSave}>{label}</button></div>);
const Select = ({ opts, value, onChange }) => (<select className="cl-in" value={value} onChange={(e) => onChange(e.target.value)}>{opts.map((o) => <option key={o} value={o}>{o}</option>)}</select>);
const MoneyInput = ({ value, onChange, placeholder = "0.00" }) => (<div className="cl-money-in"><span>$</span><input className="cl-in bare" inputMode="decimal" placeholder={placeholder} value={value} onChange={(e) => onChange(e.target.value.replace(/[^0-9.]/g, ""))} /></div>);
function BarList({ data, tone }) {
  const rows = Object.entries(data).filter(([, v]) => Math.abs(v) > 0.001).sort((a, b) => b[1] - a[1]);
  if (!rows.length) return <Empty>Nothing here yet.</Empty>;
  const max = Math.max(...rows.map(([, v]) => Math.abs(v)));
  const rowTone = (v) => (tone === "pl" ? (v >= 0 ? "in" : "out") : tone); // pl = profit/loss: green gains, orange losses
  return <div className="cl-bars">{rows.map(([k, v]) => (<div key={k} className="cl-bar"><div className="cl-bar-top"><span>{k}</span><span className={"cl-money" + (tone === "pl" ? (v >= 0 ? " pos" : " neg") : "")}>{fmt(v)}</span></div><div className="cl-bar-track"><div className={"cl-bar-fill " + rowTone(v)} style={{ width: `${Math.max(4, (Math.abs(v) / max) * 100)}%` }} /></div></div>))}</div>;
}
function numStr(n) { return n ? String(n) : ""; }
function today() { return new Date().toISOString().slice(0, 10); }
// Normalise a date string to YYYY-MM-DD. We parse the formats TCGplayer/eBay
// actually emit by hand instead of leaning on new Date(): the CSV export's
// "Tuesday, 09 June 2026" (day-first) only parses in V8, so Firefox/Safari were
// silently falling back to today() for every imported order. Building the string
// from calendar parts also avoids the UTC round-trip shifting the day.
const MONTHS = { jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7, aug: 8, sep: 9, oct: 10, nov: 11, dec: 12 };
const ymd = (y, m, d) => `${y}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
function cleanDate(s) {
  const str = String(s).replace(/^[A-Za-z]+,\s*/, "").trim(); // drop leading weekday
  let m;
  if ((m = str.match(/^(\d{4})-(\d{1,2})-(\d{1,2})/))) return ymd(+m[1], +m[2], +m[3]); // ISO
  if ((m = str.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})/))) return ymd(+m[3], +m[1], +m[2]); // M/D/YYYY (bookmarklet)
  if ((m = str.match(/^(\d{1,2})\s+([A-Za-z]+)\.?\s+(\d{4})/)) && MONTHS[m[2].slice(0, 3).toLowerCase()]) return ymd(+m[3], MONTHS[m[2].slice(0, 3).toLowerCase()], +m[1]); // DD Month YYYY (CSV)
  if ((m = str.match(/^([A-Za-z]+)\.?\s+(\d{1,2}),?\s+(\d{4})/)) && MONTHS[m[1].slice(0, 3).toLowerCase()]) return ymd(+m[3], MONTHS[m[1].slice(0, 3).toLowerCase()], +m[2]); // Month DD, YYYY
  const d = new Date(str);
  return isNaN(d) ? today() : ymd(d.getFullYear(), d.getMonth() + 1, d.getDate());
}

function Fonts() {
  return (<style>{`
    @import url('https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;600;700&family=Inter:wght@400;450;500;600&display=swap');
    .cl-root{--bg:#0c0e13;--surf:#161a22;--surf2:#1d222c;--line:#2a3140;--ink:#e8ebf2;--mut:#8b93a4;--pos:#3fd68c;--neg:#ff6f6f;--out:#ffb454;--holo2:#c4b5fd;
      background:radial-gradient(1200px 600px at 50% -10%,#19202c 0%,var(--bg) 60%);color:var(--ink);font-family:'Inter',system-ui,sans-serif;min-height:100vh;-webkit-font-smoothing:antialiased;
      /* Safe area. Every inset is 0 without a notch, so all three of these are inert on desktop, on
         Android and in a normal browser tab — they only do work where the app draws edge to edge
         (the iOS shell, and Safari's add-to-home-screen mode). */
      padding-top:env(safe-area-inset-top);}
    .cl-root *{box-sizing:border-box;}
    .holo-text{background:linear-gradient(110deg,#5ce1e6,#a78bfa,#ffd479,#7cf5a0,#5ce1e6);background-size:300% 100%;-webkit-background-clip:text;background-clip:text;color:transparent;animation:holo 6s linear infinite;}
    .holo-text.neg{background:linear-gradient(110deg,#ff9a8b,#ff6f6f,#ffb454,#ff6f6f,#ff9a8b);background-size:300% 100%;-webkit-background-clip:text;background-clip:text;}
    @keyframes holo{to{background-position:300% 0;}}
    @media (prefers-reduced-motion:reduce){.holo-text{animation:none;}}
    /* hover/active-state easing, shared across every interactive class below
       instead of a transition on each — state swaps (active tab, selected
       pill, ripped toggle, disabled) ease instead of snapping */
    .cl-tab, .cl-pill, .cl-x, .cl-save, .cl-cancel, .cl-link, .cl-row.click, .cl-hit.click,
    .cl-monthnav-btn, .cl-month-row, .cl-chip-x, .cl-reset-btn, .cl-addline,
    .cl-ac-item, .cl-import-btn, .cl-mini, .cl-card-head, .cl-binder-card,
    .cl-del, .cl-search-btn, .cl-addbtn, .cl-reset-go {
      transition: color .15s ease, background-color .15s ease, border-color .15s ease, opacity .15s ease, transform .1s ease;
    }
    /* tap feedback — a light press-scale on every button-like tappable
       element, since the app has haptics on native but nothing visual on web */
    .cl-tab:active, .cl-pill:active, .cl-x:active, .cl-save:active:not(:disabled),
    .cl-cancel:active, .cl-link:active:not(:disabled), .cl-row.click:active, .cl-hit.click:active,
    .cl-monthnav-btn:active:not(:disabled), .cl-chip-x:active, .cl-reset-btn:active,
    .cl-addline:active, .cl-ac-item:active, .cl-import-btn:active:not(:disabled),
    .cl-mini:active:not(:disabled), .cl-card-head:active, .cl-binder-card:active,
    .cl-del:active, .cl-search-btn:active, .cl-addbtn:active, .cl-reset-go:active {
      transform: scale(.96);
    }
    @media (prefers-reduced-motion: reduce) {
      .cl-tab, .cl-pill, .cl-x, .cl-save, .cl-cancel, .cl-link, .cl-row.click, .cl-hit.click,
      .cl-monthnav-btn, .cl-month-row, .cl-chip-x, .cl-reset-btn, .cl-addline,
      .cl-ac-item, .cl-import-btn, .cl-mini, .cl-card-head, .cl-binder-card,
      .cl-del, .cl-search-btn, .cl-addbtn, .cl-reset-go { transition: none; }
      .cl-tab:active, .cl-pill:active, .cl-x:active, .cl-save:active:not(:disabled),
      .cl-cancel:active, .cl-link:active:not(:disabled), .cl-row.click:active, .cl-hit.click:active,
      .cl-monthnav-btn:active:not(:disabled), .cl-chip-x:active, .cl-reset-btn:active,
      .cl-addline:active, .cl-ac-item:active, .cl-import-btn:active:not(:disabled),
      .cl-mini:active:not(:disabled), .cl-card-head:active, .cl-binder-card:active,
      .cl-del:active, .cl-search-btn:active, .cl-addbtn:active, .cl-reset-go:active {
        transform: none;
      }
    }
    /* tab-content fade-in on switch — replayed each time via key={tab} */
    .cl-tabpane{animation:tabIn .16s ease-out;}
    @keyframes tabIn{from{opacity:0;transform:translateY(4px);}to{opacity:1;transform:none;}}
    @media (prefers-reduced-motion:reduce){.cl-tabpane{animation:none;}}
    /* list-row entrance — applied per-row on mount, so only genuinely new or
       newly-filtered-in rows animate, never the whole list */
    .cl-row-enter{animation:rowIn .16s ease-out;}
    @keyframes rowIn{from{opacity:0;transform:translateY(-4px);}to{opacity:1;transform:none;}}
    @media (prefers-reduced-motion:reduce){.cl-row-enter{animation:none;}}
    .holo-dot{width:8px;height:8px;border-radius:50%;flex:none;background:linear-gradient(110deg,#5ce1e6,#a78bfa,#ffd479);box-shadow:0 0 8px rgba(167,139,250,.6);}
    .holo-border{position:relative;border:1px solid transparent!important;background:linear-gradient(var(--surf2),var(--surf2)) padding-box,linear-gradient(110deg,#5ce1e6,#a78bfa,#ffd479) border-box!important;}
    .cl-head{display:flex;align-items:center;justify-content:space-between;padding:16px 18px 8px;}
    .cl-brand{display:flex;align-items:center;gap:8px;font-family:'Space Grotesk';font-weight:700;font-size:19px;letter-spacing:-.02em;}
    .cl-spark{color:#a78bfa;}
    .cl-tag{font-size:11px;color:var(--mut);text-transform:uppercase;letter-spacing:.14em;}
    /* sticky offsets are measured against the VIEWPORT, so padding on .cl-root cannot move these —
       without their own top offset the tabs slide under the status bar as the header scrolls away */
    .cl-tabs{display:flex;gap:4px;padding:4px 12px 0;overflow-x:auto;position:sticky;top:env(safe-area-inset-top);z-index:5;background:linear-gradient(180deg,var(--bg),rgba(12,14,19,.6));backdrop-filter:blur(8px);}
    .cl-tab{display:flex;align-items:center;gap:6px;padding:9px 13px;border:none;background:none;color:var(--mut);font-size:13px;font-weight:500;cursor:pointer;border-bottom:2px solid transparent;white-space:nowrap;font-family:'Inter';}
    .cl-tab.on{color:var(--ink);border-bottom-color:#a78bfa;}
    .cl-main{padding:16px 14px calc(60px + env(safe-area-inset-bottom));max-width:680px;margin:0 auto;}
    .cl-center{padding:40px;text-align:center;color:var(--mut);}
    .cl-stack{display:flex;flex-direction:column;gap:14px;}
    .cl-stack.sm{gap:8px;}
    .cl-hero{background:linear-gradient(160deg,var(--surf2),var(--surf));border:1px solid var(--line);border-radius:18px;padding:24px 20px;text-align:center;position:relative;overflow:hidden;}
    .cl-hero:before{content:"";position:absolute;inset:0;background:radial-gradient(400px 120px at 50% 0,rgba(167,139,250,.12),transparent);pointer-events:none;}
    .cl-hero-label{font-size:12px;color:var(--mut);text-transform:uppercase;letter-spacing:.16em;}
    .cl-hero-num{font-family:'Space Grotesk';font-weight:700;font-size:46px;line-height:1.05;margin:6px 0;letter-spacing:-.03em;font-variant-numeric:tabular-nums;}
    .cl-hero-sub{font-size:12.5px;color:var(--mut);}
    .cl-grid2{display:grid;grid-template-columns:1fr 1fr;gap:10px;}
    .cl-grid3{display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px;}
    .cl-setline{display:flex;gap:8px;align-items:center;}
    .cl-setline>:first-child{flex:1;min-width:0;}
    /* The packs box carries both cl-in and cl-setline-packs. Each is a single
       class, and .cl-in sets width:100% further down this sheet, so the later
       rule wins and a plain width here loses. The box then fills the row, the
       set menu collapses to its arrows, and the page scrolls sideways.
       flex-basis sets a flex item's main size ahead of width, so 0 0 78px holds
       whatever the cascade does. The two-class selector fixes the width too,
       for the day this stops being a flex row. */
    .cl-setline .cl-setline-packs{flex:0 0 78px;width:78px;}
    .cl-stat{background:var(--surf);border:1px solid var(--line);border-radius:14px;padding:14px;}
    .cl-stat-label{font-size:11.5px;color:var(--mut);text-transform:uppercase;letter-spacing:.1em;}
    .cl-stat-num{font-family:'Space Grotesk';font-weight:600;font-size:24px;margin-top:4px;font-variant-numeric:tabular-nums;letter-spacing:-.02em;}
    .cl-stat.in .cl-stat-num{color:var(--pos);}.cl-stat.out .cl-stat-num{color:var(--out);}.cl-stat.neg .cl-stat-num{color:var(--neg);}
    .cl-inv-summary{display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px;}
    .cl-inv-summary .cl-stat-num{font-size:19px;}
    .cl-range{font-size:15px;line-height:1.35;display:inline-block;}
    .cl-inv-summary .cl-range{font-size:12.5px;}
    .cl-gradeest{display:grid;grid-template-columns:repeat(5,1fr);gap:6px;}
    .cl-gradeest-cell{display:flex;flex-direction:column;gap:3px;min-width:0;}
    .cl-gradeest-cell .cl-money-in{padding:0 8px;min-width:0;}
    .cl-gradeest-cell .cl-in{min-width:0;padding:10px 4px;}
    .cl-gradeest-g{font-size:9.5px;color:var(--mut);text-transform:uppercase;letter-spacing:.06em;}
    .cl-gradeest-head{display:flex;justify-content:space-between;align-items:center;gap:8px;}
    .cl-gradeest-note{font-size:11px;color:var(--mut);line-height:1.4;}
    .cl-link:disabled{opacity:.45;cursor:default;}
    .cl-note{background:rgba(255,180,84,.08);border:1px solid rgba(255,180,84,.25);color:#ffd9a8;border-radius:12px;padding:11px 13px;font-size:12.5px;line-height:1.45;}
    .cl-monthnav{display:flex;align-items:center;gap:8px;}
    .cl-monthnav .cl-in{flex:1;text-align:center;font-family:'Space Grotesk';font-weight:600;}
    .cl-monthnav-btn{flex:none;display:flex;align-items:center;justify-content:center;width:38px;height:38px;border-radius:12px;background:var(--surf);border:1px solid var(--line);color:var(--ink);cursor:pointer;}
    .cl-monthnav-btn:hover:not(:disabled){border-color:var(--holo2);}
    .cl-monthnav-btn:disabled{opacity:.35;cursor:default;}
    .cl-month-row{display:flex;justify-content:space-between;align-items:center;width:100%;text-align:left;background:var(--surf2);border:1px solid var(--line);border-radius:12px;padding:11px 13px;cursor:pointer;font-family:'Inter';color:var(--ink);}
    .cl-month-row:hover{border-color:var(--line);background:#222834;}
    .cl-month-row.on{border-color:var(--holo2);}
    .cl-month-row .cl-row-title{font-size:13.5px;}
    .cl-panel{background:var(--surf);border:1px solid var(--line);border-radius:16px;padding:14px 14px 16px;}
    .cl-panel-head{display:flex;justify-content:space-between;align-items:center;font-family:'Space Grotesk';font-weight:600;font-size:14px;margin-bottom:12px;}
    .cl-link{background:none;border:none;color:var(--mut);font-size:12px;cursor:pointer;font-family:'Inter';}
    .cl-link:hover{color:var(--ink);}
    .cl-bars{display:flex;flex-direction:column;gap:10px;}
    .cl-bar-top{display:flex;justify-content:space-between;font-size:12.5px;margin-bottom:4px;}
    .cl-bar-track{height:6px;background:#11151c;border-radius:4px;overflow:hidden;}
    .cl-bar-fill{height:100%;border-radius:4px;}
    .cl-bar-fill.out{background:linear-gradient(90deg,#ffb454,#ff8f54);}
    .cl-bar-fill.in{background:linear-gradient(90deg,#3fd68c,#2bbf9a);}
    .cl-row{display:flex;align-items:center;gap:9px;background:var(--surf);border:1px solid var(--line);border-radius:12px;padding:11px 12px;}
    .cl-row.sold{opacity:.55;}
    .cl-row.click{cursor:pointer;}
    .cl-row.click:hover{border-color:#3d465c;}
    .cl-row-main{flex:1;min-width:0;}
    .cl-row-title{font-size:13.5px;font-weight:500;display:flex;align-items:center;gap:7px;}
    .cl-row-meta{font-size:11.5px;color:var(--mut);margin-top:3px;display:flex;align-items:center;gap:6px;flex-wrap:wrap;}
    .cl-money{font-family:'Space Grotesk';font-weight:600;font-variant-numeric:tabular-nums;font-size:14px;letter-spacing:-.01em;}
    .cl-money.pos,.cl-money.in{color:var(--pos);}.cl-money.neg{color:var(--neg);}.cl-money.out{color:var(--out);}
    .cl-chip{background:#222834;border:1px solid var(--line);border-radius:5px;padding:1px 6px;font-size:10.5px;color:var(--ink);letter-spacing:.02em;}
    .cl-st{border-radius:5px;padding:1px 6px;font-size:9.5px;letter-spacing:.05em;text-transform:uppercase;font-weight:600;}
    .cl-st.kept{background:rgba(167,139,250,.16);color:#c4b5fd;}
    .cl-st.grading{background:rgba(255,180,84,.16);color:#ffce9e;}
    .cl-st.listed{background:rgba(92,225,230,.14);color:#8fe7eb;}
    .cl-st.sold{background:#222834;color:var(--mut);}
    .cl-seed{background:rgba(167,139,250,.15);color:#c4b5fd;border-radius:5px;padding:1px 6px;font-size:9.5px;text-transform:uppercase;letter-spacing:.08em;margin-left:6px;}
    .cl-x{background:none;border:none;color:var(--mut);cursor:pointer;padding:4px;flex:none;border-radius:6px;}
    .cl-x:hover{color:var(--ink);background:#222834;}
    .cl-x.on{color:var(--holo2);}
    .cl-card{background:var(--surf);border:1px solid var(--line);border-radius:14px;}
    .cl-card-head{width:100%;display:flex;align-items:center;gap:10px;padding:13px 13px;background:none;border:none;color:inherit;cursor:pointer;text-align:left;font-family:'Inter';}
    .cl-card-num{text-align:right;}
    .cl-card-body{padding:0 13px 13px;border-top:1px solid var(--line);}
    .cl-hits{display:flex;flex-direction:column;gap:6px;margin:12px 0;}
    .cl-hit{display:flex;align-items:center;gap:9px;background:var(--surf2);border:1px solid var(--line);border-radius:10px;padding:8px 10px;}
    .cl-hit.click{cursor:pointer;}
    .cl-hit.click:hover{border-color:#3d465c;}
    .cl-hit-imgwrap{position:relative;width:34px;height:47px;flex:none;border-radius:5px;overflow:hidden;background:var(--surf2);border:1px solid var(--line);}
    .cl-hit-img{width:100%;height:100%;object-fit:contain;background:#0c0f15;}
    .cl-hit-ph{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;padding:2px;text-align:center;font-size:7.5px;line-height:1.15;color:var(--mut);}
    .cl-hit-ph.named{color:var(--ink);}
    .cl-hit-main{flex:1;min-width:0;}
    .cl-hit-name{font-size:13px;font-weight:500;}
    .cl-card-foot{display:flex;justify-content:space-between;align-items:center;font-size:12px;color:var(--mut);margin-top:10px;}
    .cl-del{background:none;border:none;color:var(--neg);font-size:12px;cursor:pointer;display:flex;align-items:center;gap:5px;font-family:'Inter';}
    .cl-hitform{background:var(--surf2);border:1px solid var(--line);border-radius:12px;padding:12px;display:flex;flex-direction:column;gap:9px;}
    .cl-hitform-preview{display:flex;align-items:center;gap:8px;}
    .cl-hitform-preview-img{width:34px;height:47px;object-fit:contain;flex:none;border-radius:5px;background:#0c0f15;border:1px solid var(--line);}
    .cl-add-hit{display:flex;align-items:center;justify-content:center;gap:6px;background:#222a36;border:1px solid var(--line);color:var(--ink);border-radius:8px;padding:8px;font-size:12.5px;cursor:pointer;font-family:'Inter';}
    .cl-hit-add{background:linear-gradient(110deg,#7c6df0,#a78bfa);border:none;color:#fff;border-radius:8px;padding:9px;font-size:12.5px;font-weight:600;cursor:pointer;font-family:'Space Grotesk';display:flex;align-items:center;justify-content:center;gap:6px;}
    .cl-vhead{display:flex;justify-content:space-between;align-items:flex-end;}
    .cl-h2{font-family:'Space Grotesk';font-weight:700;font-size:21px;margin:0;letter-spacing:-.02em;}
    .cl-vsub{font-size:12.5px;color:var(--mut);margin-top:2px;}
    .cl-addbtn{width:36px;height:36px;border-radius:10px;border:1px solid var(--line);background:var(--surf2);color:var(--ink);cursor:pointer;display:grid;place-items:center;}
    .cl-addbtn.on{background:#2a1f2a;color:var(--neg);}
    .cl-pills{display:flex;gap:6px;overflow-x:auto;padding-bottom:2px;}
    .cl-pill{background:var(--surf2);border:1px solid var(--line);color:var(--mut);border-radius:999px;padding:6px 13px;font-size:12px;cursor:pointer;white-space:nowrap;font-family:'Inter';}
    .cl-pill.on{color:var(--ink);border-color:#a78bfa;background:#221f33;}
    .cl-form{background:var(--surf2);border:1px solid var(--line);border-radius:14px;padding:14px;display:flex;flex-direction:column;gap:11px;}
    .cl-form.cl-editing{border-color:#a78bfa;}
    .cl-field{display:flex;flex-direction:column;gap:5px;font-size:11.5px;color:var(--mut);}
    .cl-in{width:100%;background:#10141b;border:1px solid var(--line);border-radius:9px;padding:10px 11px;color:var(--ink);font-size:13.5px;font-family:'Inter';outline:none;}
    .cl-in:focus{border-color:#a78bfa;}
    .cl-in.bare{border:none;padding:10px 4px;background:none;}
    .cl-money-in{display:flex;align-items:center;background:#10141b;border:1px solid var(--line);border-radius:9px;padding:0 11px;color:var(--mut);font-size:13.5px;}
    .cl-money-in span{font-family:'Space Grotesk';}
    .cl-form-actions{display:flex;gap:8px;}
    .cl-form-actions .cl-save{flex:1;}
    .cl-cancel{background:none;border:1px solid var(--line);color:var(--mut);border-radius:10px;padding:11px 16px;font-size:13px;cursor:pointer;font-family:'Inter';}
    .cl-save{background:linear-gradient(110deg,#7c6df0,#a78bfa);border:none;color:#fff;border-radius:10px;padding:11px;font-size:14px;font-weight:600;cursor:pointer;font-family:'Space Grotesk';}
    .cl-save:disabled{opacity:.4;cursor:not-allowed;}
    .cl-net-preview{font-size:13px;color:var(--mut);display:flex;justify-content:space-between;align-items:center;gap:10px;}
    .cl-import{background:var(--surf);border:1px solid var(--line);border-radius:12px;padding:11px;}
    .cl-import-btn{display:flex;align-items:center;gap:8px;background:none;border:none;color:#c4b5fd;font-size:13px;cursor:pointer;font-family:'Inter';}
    .cl-import-btn:disabled{opacity:.45;cursor:default;}
    .cl-tcgp-pick{margin-top:9px;border:1px solid var(--line);border-radius:10px;padding:8px 10px;}
    .cl-tcgp-pick-head{display:flex;justify-content:space-between;align-items:center;font-size:11.5px;color:var(--mut);margin-bottom:5px;}
    .cl-tcgp-pick-head .cl-link{color:#c4b5fd;margin-left:10px;}
    .cl-tcgp-pick-row{display:flex;align-items:center;gap:8px;padding:3px 0;cursor:pointer;}
    .cl-tcgp-pick-row input{accent-color:#a78bfa;flex:none;}
    .cl-tcgp-pick-row .cl-row-meta{margin-top:0;flex:none;}
    .cl-tcgp-pick-row .cl-money{margin-left:auto;font-size:12.5px;}
    .cl-tcgp-pick-name{font-size:12.5px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
    .cl-tcgp-cache{margin-top:10px;border-top:1px solid var(--line);padding-top:8px;}
    .cl-tcgp-cache > .cl-link{display:flex;align-items:center;gap:4px;color:#c4b5fd;padding:0;}
    .cl-tcgp-cache-row{display:flex;align-items:center;gap:8px;padding:4px 0;}
    .cl-tcgp-cache-row .cl-row-meta{margin-top:2px;}
    .cl-tcgp-cache-row .cl-link{color:#c4b5fd;flex:none;}
    .cl-import-msg .cl-link{color:#c4b5fd;display:inline-flex;align-items:center;gap:4px;vertical-align:-2px;}
    .cl-scan-ctl{display:grid;grid-template-columns:1fr 1fr auto;gap:8px;align-items:end;margin-bottom:8px;}
    .cl-scan-go{padding:11px 14px;font-size:13px;}
    .cl-cat{background:var(--surf);border:1px solid var(--line);border-radius:12px;padding:11px;display:flex;flex-direction:column;gap:8px;}
    .cl-cat .cl-row-meta{margin-top:0;}
    .cl-import-btn:disabled{opacity:.6;cursor:default;}
    .cl-import-msg{font-size:12px;color:var(--mut);margin-top:7px;}
    .cl-empty{background:var(--surf);border:1px dashed var(--line);border-radius:12px;padding:18px;text-align:center;font-size:12.5px;color:var(--mut);line-height:1.5;}
    .cl-search{display:flex;gap:8px;}
    .cl-search-btn{background:var(--surf2);border:1px solid var(--line);color:var(--ink);border-radius:10px;width:42px;display:grid;place-items:center;cursor:pointer;flex:none;}
    .cl-salesearch{display:flex;align-items:center;gap:6px;background:#10141b;border:1px solid var(--line);border-radius:9px;padding:0 9px;}
    .cl-salesearch:focus-within{border-color:#a78bfa;}
    .cl-salesearch-ic{color:var(--mut);flex:none;}
    .cl-salesearch .cl-in.bare{flex:1;padding:10px 0;}
    .cl-salesearch-x{background:none;border:none;color:var(--mut);cursor:pointer;display:grid;place-items:center;padding:4px;flex:none;}
    .cl-lk-actions{display:flex;gap:5px;margin-top:6px;}
    /* scanner: the add row wraps rather than shrinking the buttons, so the
       tap targets stay full size on a narrow phone */
    .cl-snap-go{display:flex;flex-wrap:wrap;gap:6px;margin-top:12px;}
    .cl-snap-go .cl-mini{flex:1 1 auto;justify-content:center;padding:9px 12px;}
    .cl-mini{flex:1;background:var(--surf2);border:1px solid var(--line);color:var(--ink);border-radius:8px;padding:7px 4px;font-size:11.5px;cursor:pointer;font-family:'Inter';}
    .cl-rip-sel{margin-top:6px;background:#10141b;border:1px solid var(--line);color:var(--mut);border-radius:8px;padding:5px;font-size:11px;font-family:'Inter';}
    .cl-flash{font-size:11px;color:#7cf5a0;margin-top:5px;text-align:center;animation:flashIn .18s ease-out;}
    @keyframes flashIn{from{opacity:0;transform:translateY(-3px);}to{opacity:1;transform:none;}}
    @media (prefers-reduced-motion:reduce){.cl-flash{animation:none;}}
    .cl-spin{animation:spin .8s linear infinite;}
    @media (prefers-reduced-motion:reduce){.cl-spin{animation:none;}}
    @keyframes spin{to{transform:rotate(360deg);}}
    .cl-cardchips{display:flex;flex-wrap:wrap;gap:6px;}
    .cl-cardchips-empty{font-size:12px;color:var(--mut);}
    .cl-cardchip{display:inline-flex;align-items:center;gap:5px;background:#10141b;border:1px solid var(--line);border-radius:8px;padding:5px 8px;font-size:12px;}
    .cl-chip-x{background:none;border:none;color:var(--mut);cursor:pointer;display:flex;padding:0;}
    .cl-chip-x:hover{color:var(--neg);}
    .cl-typedadd{display:flex;gap:6px;align-items:stretch;}
    .cl-typedadd>.cl-in,.cl-typedadd>.cl-ac{flex:1;}
    .cl-basisbox{max-width:110px;}
    .cl-add-card{background:#222a36;border:1px solid var(--line);color:var(--ink);border-radius:9px;flex:1;display:flex;align-items:center;justify-content:center;gap:6px;padding:0 14px;cursor:pointer;font-family:'Inter';font-size:12.5px;}
    .cl-reset{margin-top:6px;display:flex;justify-content:center;}
    .cl-reset-btn{background:none;border:1px solid var(--line);color:var(--mut);border-radius:10px;padding:9px 14px;font-size:12px;cursor:pointer;font-family:'Inter';}
    .cl-reset-btn:hover{color:var(--neg);border-color:var(--neg);}
    .cl-reset-confirm{display:flex;flex-direction:column;gap:8px;background:var(--surf);border:1px solid var(--line);border-radius:12px;padding:12px;width:100%;font-size:12.5px;color:var(--mut);text-align:center;}
    .cl-reset-actions{display:flex;gap:8px;}
    .cl-reset-actions .cl-cancel{flex:1;}
    .cl-reset-go{flex:1;background:#3a2030;border:1px solid var(--neg);color:var(--neg);border-radius:10px;padding:10px;font-size:13px;cursor:pointer;font-family:'Space Grotesk';font-weight:600;}
    .cl-sync{display:flex;flex-direction:column;gap:10px;}
    .cl-sync-status{display:flex;align-items:center;gap:8px;font-size:12.5px;color:var(--mut);}
    .cl-sync-dot{width:8px;height:8px;border-radius:50%;flex:none;background:var(--mut);}
    .cl-sync-dot.on{background:var(--pos);box-shadow:0 0 8px rgba(63,214,140,.55);}
    .cl-sync-dot.error,.cl-sync-dot.badtoken{background:var(--neg);}
    .cl-sync-dot.checking{background:var(--out);}
    .cl-sync-join{display:flex;gap:6px;}
    .cl-sync-join .cl-in{flex:1;}
    .cl-sync-connect{background:#222a36;border:1px solid var(--line);color:var(--ink);border-radius:9px;padding:0 16px;cursor:pointer;font-family:'Inter';font-size:13px;flex:none;}
    .cl-sync-connect:disabled{opacity:.5;cursor:default;}
    .cl-sync-off{align-self:flex-start;padding:0;}
    .cl-sync-choose{display:flex;flex-direction:column;gap:8px;}
    .cl-sync-choose .cl-sync-connect{padding:10px 14px;text-align:left;}
    .cl-lineitem{border:1px solid var(--line);border-radius:11px;padding:9px;display:flex;flex-direction:column;gap:8px;background:var(--surf);}
    .cl-line-r1{display:grid;grid-template-columns:64px 1fr;gap:8px;}
    .cl-line-r2{display:grid;grid-template-columns:1fr 112px 30px;gap:8px;align-items:center;}
    .cl-line-r2.nox{grid-template-columns:1fr 112px;}
    .cl-addline{background:none;border:1px dashed var(--line);color:var(--mut);border-radius:10px;padding:9px;font-size:12.5px;cursor:pointer;font-family:'Inter';}
    .cl-addline:hover{color:var(--ink);border-color:var(--mut);}
    .cl-total-ro{display:flex;align-items:center;color:var(--out);font-variant-numeric:tabular-nums;}
    /* one card search, one row style: the popover in a form and the list
       on the Lookup tab render the same .cl-ac-item */
    .cl-cs{display:flex;flex-direction:column;gap:8px;}
    .cl-cs-rows{display:flex;flex-direction:column;gap:7px;}
    .cl-cs-card{border:1px solid var(--line);border-radius:10px;background:var(--surf);overflow:hidden;}
    .cl-cs-card .cl-ac-item{border-bottom:none;}
    .cl-cs-card .cl-ac-item.as-row{cursor:default;}
    .cl-cs-card .cl-lk-actions{margin:0;padding:0 10px 9px;}
    /* three buttons share a padded row on a phone — "+ Keep" wrapped to a
       second line and made the row twice as tall as its neighbours */
    .cl-cs-card .cl-lk-actions .cl-mini{white-space:nowrap;padding:7px 2px;}
    .cl-cs-card .cl-flash{padding:0 10px 8px;margin-top:0;}
    .cl-ac{position:relative;}
    .cl-ac-pop{position:absolute;top:100%;left:0;right:0;z-index:30;margin-top:4px;background:var(--surf);border:1px solid var(--line);border-radius:10px;max-height:280px;overflow-y:auto;box-shadow:0 14px 34px rgba(0,0,0,.55);}
    .cl-ac-loading{padding:12px;text-align:center;color:var(--mut);font-size:12px;}
    .cl-ac-item{display:flex;align-items:center;gap:9px;width:100%;background:none;border:none;border-bottom:1px solid var(--line);padding:8px 10px;cursor:pointer;text-align:left;color:var(--ink);font-family:'Inter';}
    .cl-ac-item:last-child{border-bottom:none;}
    .cl-ac-item:hover{background:var(--surf2);}
    .cl-ac-img{width:34px;height:47px;object-fit:contain;flex:none;background:#0c0f15;border-radius:4px;}
    .cl-ac-meta{flex:1;min-width:0;}
    .cl-ac-name{font-size:13px;font-weight:600;}
    .cl-ac-price{font-family:'Space Grotesk';font-weight:600;color:var(--pos);font-size:13px;font-variant-numeric:tabular-nums;flex:none;}
    .cl-ac-retry{width:100%;background:none;border:none;color:#ffce9e;cursor:pointer;font-family:'Inter';}
    .cl-modal-ov{position:fixed;inset:0;z-index:60;background:rgba(6,8,13,.72);backdrop-filter:blur(5px);display:flex;align-items:center;justify-content:center;padding:16px;animation:ovIn .15s ease-out;}
    .cl-modal{background:var(--surf);border:1px solid var(--line);border-radius:18px;width:100%;max-width:540px;max-height:min(88vh,780px);overflow-y:auto;padding:16px;position:relative;animation:cmIn .18s ease-out;}
    @keyframes cmIn{from{transform:translateY(16px);opacity:.5;}to{transform:none;opacity:1;}}
    @keyframes ovIn{from{opacity:0;}to{opacity:1;}}
    @media (prefers-reduced-motion:reduce){.cl-modal{animation:none;}.cl-modal-ov{animation:none;}}
    .cl-cm-close{position:absolute;top:10px;right:10px;background:var(--surf2);}
    .cl-cm-top{display:flex;gap:14px;}
    .cl-cm-img{width:158px;flex:none;align-self:flex-start;border-radius:12px;background:#0c0f15;}
    .cl-cm-img.ph{aspect-ratio:3/4;display:grid;place-items:center;color:var(--mut);font-size:11px;border:1px dashed var(--line);}
    .cl-cm-head{flex:1;min-width:0;display:flex;flex-direction:column;gap:6px;padding-right:26px;}
    .cl-cm-name{font-family:'Space Grotesk';font-weight:700;font-size:17px;letter-spacing:-.01em;line-height:1.2;}
    .cl-cm-mkt-num{font-family:'Space Grotesk';font-weight:700;font-size:27px;color:var(--pos);font-variant-numeric:tabular-nums;letter-spacing:-.02em;}
    .cl-cm-mkt-lab{font-size:10.5px;color:var(--mut);text-transform:uppercase;letter-spacing:.1em;margin-top:1px;}
    .cl-cm-apply{flex:0 0 auto;align-self:flex-start;}
    .cl-cm-stats{display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px;margin-top:12px;}
    .cl-cm-stat{background:var(--surf2);border:1px solid var(--line);border-radius:10px;padding:8px 10px;display:flex;flex-direction:column;gap:2px;}
    .cl-cm-stat span{font-size:10px;color:var(--mut);text-transform:uppercase;letter-spacing:.08em;}
    .cl-cm-stat b{font-family:'Space Grotesk';font-size:14.5px;font-variant-numeric:tabular-nums;}
    .cl-cm-stat b.pos{color:var(--pos);}.cl-cm-stat b.neg{color:var(--neg);}
    .cl-cm-sec{font-family:'Space Grotesk';font-weight:600;font-size:13.5px;margin:16px 0 8px;}
    .cl-cm-note{font-size:12px;color:var(--mut);line-height:1.45;}
    .cl-cm-note.warn{color:#ffce9e;margin-top:8px;}
    .cl-cm-raw{display:flex;align-items:baseline;gap:10px;flex-wrap:wrap;}
    .cl-cm-raw-price{font-family:'Space Grotesk';font-weight:700;font-size:19px;color:var(--pos);font-variant-numeric:tabular-nums;}
    .cl-cm-raw .cl-row-meta{margin-top:0;}
    .cl-cm-grid{display:grid;grid-template-columns:34px repeat(3,1fr);gap:6px;align-items:stretch;}
    .cl-cm-co{font-size:10.5px;color:var(--mut);text-transform:uppercase;letter-spacing:.08em;text-align:center;align-self:end;padding-bottom:2px;}
    .cl-cm-g{font-size:11.5px;color:var(--mut);display:flex;align-items:center;justify-content:center;font-family:'Space Grotesk';font-weight:600;}
    .cl-cm-cell{background:var(--surf2);border:1px solid var(--line);border-radius:9px;padding:7px 4px;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:2px;min-height:44px;}
    .cl-cm-cell .cl-money{font-size:12.5px;}
    .cl-cm-cnt{font-size:9.5px;color:var(--mut);}
    .cl-cm-none{color:#3a4356;}
    .cl-cm-tr{font-size:9px;margin-left:3px;}
    .cl-cm-tr.up{color:var(--pos);}.cl-cm-tr.down{color:var(--neg);}
    .cl-cm-extra{display:flex;flex-wrap:wrap;gap:6px;margin-top:8px;}
    .cl-cm-foot{font-size:10.5px;color:var(--mut);margin-top:8px;}
    .cl-spark{margin-top:2px;}
    .cl-spark-svg{display:block;width:100%;height:56px;touch-action:none;cursor:crosshair;}
    .cl-spark-meta{display:flex;justify-content:space-between;gap:8px;font-size:11px;color:var(--mut);margin-top:2px;font-variant-numeric:tabular-nums;}
    .cl-spark-meta b{color:var(--ink);font-weight:600;}
    .cl-cm-meta{font-size:12px;color:var(--mut);line-height:1.5;}
    .cl-cm-links{display:flex;gap:6px;margin-top:10px;}
    .cl-cm-links .cl-mini{display:flex;align-items:center;justify-content:center;gap:5px;text-decoration:none;}
    .cl-binder-soldtoggle{display:flex;align-items:center;gap:7px;font-size:12.5px;color:var(--mut);cursor:pointer;}
    .cl-binder-page-head{display:flex;justify-content:space-between;align-items:baseline;font-family:'Space Grotesk';font-weight:600;font-size:13.5px;padding:2px 1px;}
    .cl-binder-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(104px,1fr));gap:10px;margin-top:8px;}
    .cl-binder-card{display:flex;flex-direction:column;gap:5px;background:none;border:none;padding:0;cursor:pointer;font-family:'Inter';text-align:left;}
    .cl-binder-imgwrap{position:relative;aspect-ratio:5/7;border-radius:9px;overflow:hidden;background:var(--surf2);border:1px solid var(--line);}
    .cl-binder-img{width:100%;height:100%;object-fit:contain;background:#0c0f15;}
    .cl-binder-ph{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;padding:8px;text-align:center;font-size:10.5px;line-height:1.3;color:var(--mut);}
    .cl-binder-ph.named{color:var(--ink);}
    .cl-binder-sold{position:absolute;top:5px;right:5px;background:rgba(12,14,19,.82);color:var(--mut);font-size:9px;letter-spacing:.05em;text-transform:uppercase;font-weight:600;border-radius:5px;padding:2px 5px;}
    .cl-binder-cap{display:flex;flex-direction:column;gap:1px;}
    .cl-binder-name{font-size:11.5px;color:var(--ink);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
    .cl-binder-money{font-family:'Space Grotesk';font-weight:600;font-size:11.5px;color:var(--holo2);font-variant-numeric:tabular-nums;}
    @media (max-width:420px){.cl-grid3{grid-template-columns:1fr;}.cl-hero-num{font-size:40px;}.cl-inv-summary .cl-stat-num{font-size:16px;}.cl-inv-summary .cl-range{font-size:11px;}.cl-gradeest{grid-template-columns:repeat(3,1fr);}.cl-cm-img{width:116px;}.cl-cm-mkt-num{font-size:22px;}.cl-scan-ctl{grid-template-columns:1fr 1fr;}.cl-scan-go{grid-column:1/-1;}.cl-binder-grid{grid-template-columns:repeat(auto-fill,minmax(88px,1fr));}}
  `}</style>);
}
