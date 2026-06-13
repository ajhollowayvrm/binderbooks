import React, { useState, useEffect, useCallback, useRef } from "react";
import Papa from "papaparse";
import {
  LayoutDashboard, PackageOpen, ShoppingCart, Tags, Search, Archive,
  Plus, Trash2, Pencil, ChevronDown, ChevronRight, Sparkles, Upload, X,
} from "lucide-react";

/* ------------------------------------------------------------------ */
/* hosted-app glue: localStorage persistence + optional API key       */
/* ------------------------------------------------------------------ */
const API_KEY = import.meta.env.VITE_POKEMONTCG_API_KEY;
const PTCG_OPTS = API_KEY ? { headers: { "X-Api-Key": API_KEY } } : undefined;
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
const syncFetch = async (method, body, since) => {
  const r = await fetch(since ? `${SYNC_URL}?since=${since}` : SYNC_URL, {
    method,
    headers: { "x-sync-token": syncToken(), ...(body ? { "content-type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (r.status === 404) return null;
  if (r.status === 204) return { unchanged: true }; // server: you already have the latest
  const j = await r.json().catch(() => ({}));
  if (!r.ok) { const e = new Error(j.error || `HTTP ${r.status}`); e.status = r.status; throw e; }
  return j;
};

/* ------------------------------------------------------------------ */
const KEY = "cardledger:v1";
const uid = () => Math.random().toString(36).slice(2, 10);

/* set list for the structured buy form — live from pokemontcg.io,
   cached for a week so the dropdown opens instantly */
const SETS_KEY = "cardledger:sets:v1";
let setsPromise = null;
async function fetchSets() {
  const r = await fetch("https://api.pokemontcg.io/v2/sets?orderBy=-releaseDate&select=name,releaseDate&pageSize=250", PTCG_OPTS);
  if (!r.ok) throw new Error(String(r.status));
  const data = await r.json();
  const names = [...new Set((data.data || []).map((s) => s.name))];
  if (!names.length) throw new Error("empty");
  try { localStorage.setItem(SETS_KEY, JSON.stringify({ t: Date.now(), names })); } catch {}
  return names;
}
/* card-search cache: query -> slimmed results, 24h TTL, ~30 most recent
   queries kept. Repeat searches are instant and rate-limit failures drop. */
const QCACHE_KEY = "cardledger:qcache:v2"; // v2: entries must carry fallback prices
const QCACHE_TTL = 24 * 3600 * 1000;
const cachedSets = () => { try { const c = JSON.parse(localStorage.getItem(SETS_KEY)); return c?.names || null; } catch { return null; } };
// words that describe a variant, not a card name — "ampharos full art" should
// search name:*ampharos* and float Illustration/Ultra Rares, not find nothing
const SEARCH_STOP = new Set(["full", "art", "fullart", "alt", "illustration", "special", "secret", "rainbow", "hyper", "holo", "reverse", "foil", "textured", "sir", "ir", "promo"]);
const DESC_RARITY = { full: ["illustration", "ultra", "full"], art: ["illustration", "ultra", "full"], fullart: ["illustration", "ultra", "full"], alt: ["illustration"], illustration: ["illustration"], special: ["special"], sir: ["special illustration"], ir: ["illustration"], secret: ["secret", "hyper"], rainbow: ["rainbow", "hyper"], hyper: ["hyper"], holo: ["holo"], reverse: ["reverse"], foil: ["holo"], textured: ["special illustration"], promo: ["promo"] };
const buildQuery = (q) => {
  const sets = cachedSets();
  let tokens = q.replace(/[^\w\s-]/g, " ").trim().split(/\s+/).filter(Boolean);
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
  const descriptors = [...new Set(tokens.filter((t) => SEARCH_STOP.has(t.toLowerCase())).map((t) => t.toLowerCase()))];
  const nameTokens = tokens.filter((t) => !SEARCH_STOP.has(t.toLowerCase()));
  const parts = nameTokens.map((t) => `name:*${t}*`);
  if (setFilter) parts.push(`set.name:"${setFilter}"`);
  return { terms: parts.join(" ") || `name:*${q.trim()}*`, descriptors, first: (nameTokens[0] || "").toLowerCase() };
};
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
const slimCard = (c) => ({
  id: c.id, name: c.name, number: c.number, rarity: c.rarity,
  set: { name: c.set?.name }, images: { small: c.images?.small },
  ...(c.tcgplayer ? { tcgplayer: { prices: c.tcgplayer.prices } } : {}),
});

/* fallback prices: pokemontcg.io has no price data for sets newer than
   Nov 2025, so cards missing a price get TCGplayer market values from the
   tcgcsv.com dump, proxied through our Lambda (see aws/index.mjs). */
const SETPRICE_KEY = "cardledger:setprices:v1";
const normNum = (s) => String(s).split("/")[0].trim().replace(/^0+(?=\w)/, "").toUpperCase();
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
async function fillMissingPrices(list) {
  const missing = list.filter((c) => cardPrice(c) == null && c.set?.name && c.number);
  if (!missing.length) return list;
  const maps = {};
  await Promise.all([...new Set(missing.map((c) => c.set.name))].map(async (s) => {
    let m = setPricesGet(s);
    if (!m) {
      try {
        const r = await fetch(`${SYNC_URL}prices?set=${encodeURIComponent(s)}`);
        if (!r.ok) return;
        m = (await r.json()).prices || {};
        setPricesPut(s, m);
      } catch { return; }
    }
    maps[s] = m;
  }));
  return list.map((c) => {
    if (cardPrice(c) != null) return c;
    const v = maps[c.set?.name]?.[normNum(c.number)];
    return v == null ? c : { ...c, tcgplayer: { prices: { holofoil: { market: v } } } };
  });
}

/* PSA comps for the grading-estimate fields: eBay sold averages per grade,
   proxied through the Lambda (see /graded in aws/index.mjs) so the
   pokemonpricetracker.com key stays server-side. */
const GRADED_KEY = "cardledger:graded:v1";
async function fetchGradedComps(name, set, number) {
  const key = `${name}|${set}|${number}`.toLowerCase();
  try {
    const c = (JSON.parse(localStorage.getItem(GRADED_KEY)) || {})[key];
    if (c && Date.now() - c.t < 24 * 3600 * 1000) return c.r;
  } catch {}
  const qs = new URLSearchParams({ name });
  if (set) qs.set("set", set);
  if (number) qs.set("number", number);
  const r = await fetch(`${SYNC_URL}graded?${qs}`);
  if (!r.ok) {
    const err = new Error("graded fetch failed");
    err.status = r.status;
    throw err;
  }
  const body = await r.json();
  try {
    const all = JSON.parse(localStorage.getItem(GRADED_KEY)) || {};
    all[key] = { t: Date.now(), r: body };
    const keys = Object.keys(all);
    if (keys.length > 30) keys.sort((a, b) => all[a].t - all[b].t).slice(0, keys.length - 30).forEach((k) => delete all[k]);
    localStorage.setItem(GRADED_KEY, JSON.stringify(all));
  } catch {}
  return body;
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
    setsPromise.then((n) => live && setSets(n)).catch(() => { setsPromise = null; if (live) setSets([]); });
    return () => { live = false; };
  }, [sets]);
  return sets; // null = loading, [] = unavailable, [...] = loaded
}

const SOURCES = ["Gamecraft", "Dragon's Keep", "Game Grid", "Croma TCG", "PokeBank", "GameStop", "TikTok Shop", "TCGplayer", "eBay", "PSA", "Other"];
const PRODUCTS = ["Booster Pack", "Booster Bundle", "Booster Box", "Elite Trainer Box", "Collection Box", "Tin", "Blister", "Single Card", "Supplies", "Other"];
const INV_SOURCES = ["Rip pull", "Gamecraft", "Dragon's Keep", "Game Grid", "Croma TCG", "PokeBank", "GameStop", "TikTok Shop", "eBay", "Other"];
const CHANNELS = ["TCGplayer", "eBay", "LGS consignment", "In-person", "Other"];
const BUY_CATS = ["Sealed", "Single", "Lot", "Grading", "Supplies"];
const GRADES = ["Raw", "PSA 10", "PSA 9", "PSA 8", "CGC 10", "CGC 9.5", "BGS 9.5", "Other"];
const INV_STATUS = ["Kept", "At grading", "Listed", "Sold"];
const stCls = (s) => ({ "Kept": "kept", "At grading": "grading", "Listed": "listed", "Sold": "sold" }[s] || "kept");

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
  s.inventory = s.inventory.map((c) => ({ status: "Kept", gradingCost: 0, ...c }));
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

const fmt = (n) => (n < 0 ? "-" : "") + "$" + Math.abs(n).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const ripValue = (r) => (r.hits || []).reduce((s, h) => s + (Number(h.value) || 0), 0);
const ripCostOf = (r, buys) => (r.buyId ? (Number((buys || []).find((b) => b.id === r.buyId)?.cost) || 0) : (Number(r.cost) || 0));
const ripPL = (r, buys) => ripValue(r) - ripCostOf(r, buys);
// a logged hit is a card you now hold — mirror it into inventory as a rip
// pull. Basis stays 0 because the rip already carries the cost.
function addHitToState(s, ripId, hit) {
  const h = { id: uid(), ...hit };
  const rip = s.rips.find((r) => r.id === ripId);
  const inv = { id: uid(), hitId: h.id, name: h.name, set: h.set || "", number: h.number || "", grade: "Raw", status: "Kept", source: "Rip pull", cost: 0, gradingCost: 0, value: Number(h.value) || 0, date: rip?.date || today() };
  return { rips: s.rips.map((r) => (r.id === ripId ? { ...r, hits: [...(r.hits || []), h] } : r)), inventory: [inv, ...(s.inventory || [])] };
}
const buyLineSet = (b) => { const s = [...new Set((b?.lines || []).map((l) => l.set).filter(Boolean))]; return s.length === 1 ? s[0] : ""; };
// which set a rip belongs to: explicit field, else the linked buy's lines,
// else a set name found in the product text, else the majority set of the hits
const ripSetOf = (r, buys, sets) => {
  if (r.set) return r.set;
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
const saleNet = (s) => (Number(s.price) || 0) - (Number(s.fees) || 0) - (Number(s.shipping) || 0) - (Number(s.consign) || 0);
const saleBasis = (s) => (s.cards || []).reduce((a, c) => a + (Number(c.basis) || 0), 0);
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
const invBasis = (c) => (Number(c.cost) || 0) + (Number(c.gradingCost) || 0);
// a card at the graders carries a value range — min/max of whichever PSA 10–6
// estimates the user filled in. Everything else just counts its single value.
const PSA_EST_GRADES = ["10", "9", "8", "7", "6"];
const gradeRange = (c) => {
  if (c.status !== "At grading") return null;
  const vals = PSA_EST_GRADES.map((g) => Number(c.gradeEst?.[g]) || 0).filter((v) => v > 0);
  return vals.length ? { lo: Math.min(...vals), hi: Math.max(...vals) } : null;
};
const invRange = (cards) => cards.reduce((a, c) => {
  const r = gradeRange(c), v = Number(c.value) || 0;
  return { lo: a.lo + (r ? r.lo : v), hi: a.hi + (r ? r.hi : v) };
}, { lo: 0, hi: 0 });
const fmtRange = (r) => (r.lo === r.hi ? fmt(r.lo) : `${fmt(r.lo)} – ${fmt(r.hi)}`);
const byDateDesc = (a, b) => (b.date || "").localeCompare(a.date || "");
const cardPrice = (c) => { const p = c.tcgplayer?.prices; if (!p) return null; const v = p.holofoil || p.normal || p.reverseHolofoil || p["1stEditionHolofoil"] || Object.values(p)[0]; return v?.market ?? v?.mid ?? null; };

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
    try {
      const r = await fetch(SYNC_URL, {
        method: "PUT",
        headers: { "x-sync-token": syncToken(), "content-type": "application/json" },
        body: JSON.stringify({ updatedAt: p.ts, data: p.data }),
        keepalive, // lets the request outlive the page when iOS backgrounds us
      });
      if (r.status === 409) { const remote = await syncFetch("GET"); if (remote) adoptRemote(remote); setSync("on"); return; }
      if (!r.ok) { const e = new Error(`HTTP ${r.status}`); e.status = r.status; throw e; }
      setSync("on");
    } catch (e) {
      if (!pendingPush.current) pendingPush.current = p; // keep it queued — retried on next edit or focus change
      setSync(e.status === 401 ? "badtoken" : "error");
    }
  }, [adoptRemote]);

  useEffect(() => { (async () => {
    let local = null;
    try { const r = await storage.get(KEY); if (r && r.value) local = migrate(JSON.parse(r.value)); } catch {}
    if (!syncToken()) { setState(local || seed()); return; }
    try {
      const remote = await syncFetch("GET", null, localStamp());
      const freshToken = (() => { try { return sessionStorage.getItem("cardledger:fresh") === "1"; } catch { return false; } })();
      if (remote && !remote.unchanged && freshToken && localStamp() > 0) {
        // setup link just installed a token, but this device already has its
        // own ledger — hold everything and let the user pick the winner
        pendingRemote.current = remote;
        choosing.current = true;
        remoteApply.current = true;
        setState(local || seed());
        setSync("choose");
        return;
      }
      try { sessionStorage.removeItem("cardledger:fresh"); } catch {}
      if (remote && !remote.unchanged && remote.updatedAt > localStamp()) adoptRemote(remote);
      else {
        const cur = local || seed();
        remoteApply.current = true; // loading isn't editing — don't re-stamp
        setState(cur);
        const ts = localStamp() || Date.now();
        if (!remote?.unchanged && (!remote || ts > remote.updatedAt)) {
          // cloud is behind us (a push never made it out) — heal it, same stamp
          setLocalStamp(ts);
          await syncFetch("PUT", { updatedAt: ts, data: JSON.stringify(cur) });
        }
      }
      setSync("on");
    } catch (e) {
      setState((s) => s || local || seed());
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

  const TABS = [
    ["dash", "Overview", LayoutDashboard], ["rips", "Rips", PackageOpen],
    ["buys", "Buys", ShoppingCart], ["sales", "Sales", Tags],
    ["inv", "Inventory", Archive], ["look", "Lookup", Search],
  ];

  return (
    <div className="cl-root">
      <Fonts />
      <header className="cl-head">
        <div className="cl-brand"><Sparkles size={18} className="cl-spark" /><span>Binder<span className="holo-text">Books</span></span></div>
        <div className="cl-tag">card P&amp;L ledger</div>
      </header>
      <nav className="cl-tabs">
        {TABS.map(([k, label, Icon]) => (<button key={k} className={"cl-tab" + (tab === k ? " on" : "")} onClick={() => setTab(k)}><Icon size={15} /> <span>{label}</span></button>))}
      </nav>
      <main className="cl-main">
        {tab === "dash" && <Dashboard state={state} go={setTab} reset={reset} sync={sync} connectSync={connectSync} disconnectSync={disconnectSync} resolveChoice={resolveChoice} />}
        {tab === "rips" && <Rips state={state} patch={patch} />}
        {tab === "buys" && <Buys state={state} patch={patch} />}
        {tab === "sales" && <Sales state={state} patch={patch} />}
        {tab === "inv" && <Inventory state={state} patch={patch} />}
        {tab === "look" && <Lookup state={state} patch={patch} />}
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
  const gradingCount = kept.filter((c) => gradeRange(c)).length;

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
  state.rips.forEach((r) => { const s = ripSetOf(r, state.buys, sets); ripBySet[s] = (ripBySet[s] || 0) + ripPL(r, state.buys); });
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
        {hasRange && <div className="cl-note" style={{ marginTop: 10 }}>{gradingCount} card{gradingCount === 1 ? "" : "s"} at grading — depending on how the PSA grades land, you'd end up anywhere from {fmt(netLo)} to {fmt(netHi)} overall.</div>}
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
          : <div className="cl-reset-confirm"><span>Wipes everything and reloads the starter data.</span><div className="cl-reset-actions"><button className="cl-cancel" onClick={() => setConfirmReset(false)}>Cancel</button><button className="cl-reset-go" onClick={() => { reset(); setConfirmReset(false); }}>Reset</button></div></div>}
      </div>
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
  const addRip = (r) => { patch((s) => ({ rips: [{ id: uid(), hits: [], ...r }, ...s.rips], buys: r.buyId ? s.buys.map((b) => (b.id === r.buyId ? { ...b, ripped: true } : b)) : s.buys })); setAdding(false); };
  const delRip = (id) => patch((s) => {
    const hitIds = new Set((s.rips.find((r) => r.id === id)?.hits || []).map((h) => h.id));
    return { rips: s.rips.filter((r) => r.id !== id), inventory: (s.inventory || []).filter((c) => !(hitIds.has(c.hitId) && c.status !== "Sold")) };
  });
  const addHit = (ripId, hit) => patch((s) => addHitToState(s, ripId, hit));
  const delHit = (ripId, hitId) => patch((s) => ({
    rips: s.rips.map((r) => (r.id === ripId ? { ...r, hits: r.hits.filter((h) => h.id !== hitId) } : r)),
    inventory: (s.inventory || []).filter((c) => !(c.hitId === hitId && c.status !== "Sold")),
  }));
  const sorted = [...state.rips].sort(byDateDesc);

  return (
    <div className="cl-stack">
      <Header title="Rips" sub="Cost of the packs vs. value of what you pulled" onAdd={() => setAdding(!adding)} addOpen={adding} />
      {adding && <RipForm buys={state.buys} onSave={addRip} onCancel={() => setAdding(false)} />}
      {state.rips.length === 0 && !adding && <Empty>Nothing ripped yet. Log a rip — say 5 packs of Chaos Rising — then drop in each hit and watch the P&amp;L land.</Empty>}
      <div className="cl-stack">
        {sorted.map((r) => {
          const pl = ripPL(r, state.buys); const isOpen = open === r.id;
          return (
            <div key={r.id} className="cl-card">
              <button className="cl-card-head" onClick={() => setOpen(isOpen ? null : r.id)}>
                <div className="cl-row-main"><div className="cl-row-title">{isOpen ? <ChevronDown size={15} /> : <ChevronRight size={15} />} {r.product || "Rip"}</div><div className="cl-row-meta">{r.packs ? `${r.packs} packs · ` : ""}{r.source || "—"} · {(r.hits || []).length} hits · {r.date}</div></div>
                <div className="cl-card-num"><div className={"cl-money " + (pl >= 0 ? "pos" : "neg")}>{fmt(pl)}</div><div className="cl-row-meta">{r.buyId ? "from buy" : "cost"} {fmt(ripCostOf(r, state.buys))}</div></div>
              </button>
              {isOpen && <div className="cl-card-body">
                <div className="cl-hits">
                  {(r.hits || []).length === 0 && <Empty>No hits added.</Empty>}
                  {(r.hits || []).map((h) => (<div key={h.id} className="cl-hit"><span className="holo-dot" /><div className="cl-hit-main"><div className="cl-hit-name">{h.name}</div>{h.set && <div className="cl-row-meta">{h.set}{h.number ? ` · ${h.number}` : ""}</div>}</div><div className="cl-money">{fmt(Number(h.value) || 0)}</div><button className="cl-x" onClick={() => delHit(r.id, h.id)}><X size={13} /></button></div>))}
                </div>
                <HitForm onAdd={(h) => addHit(r.id, h)} />
                <div className="cl-card-foot"><span>Pulled value {fmt(ripValue(r))}</span><button className="cl-del" onClick={() => delRip(r.id)}><Trash2 size={13} /> Delete rip</button></div>
              </div>}
            </div>
          );
        })}
      </div>
    </div>
  );
}
function RipForm({ buys, onSave, onCancel }) {
  const sets = useSets();
  const [f, setF] = useState({ product: "", set: "", packs: "", cost: "", source: "Gamecraft", date: today(), buyId: "" });
  const opts = [...(buys || [])].sort((a, b) => (b.category === "Sealed") - (a.category === "Sealed"));
  const linkBuy = (id) => {
    const b = (buys || []).find((x) => x.id === id);
    if (!b) return setF({ ...f, buyId: "" });
    setF({ ...f, buyId: id, cost: String(b.cost), source: b.source, product: f.product || b.item, set: f.set || buyLineSet(b) });
  };
  return (
    <Form>
      <Field label="Product"><input className="cl-in" placeholder="Chaos Rising booster" value={f.product} onChange={(e) => setF({ ...f, product: e.target.value })} /></Field>
      <Field label="Set (for analytics)"><SetPicker sets={sets} value={f.set} onChange={(v) => setF({ ...f, set: v })} allowEmpty /></Field>
      {(buys || []).length > 0 && <Field label="Ripped from a buy (optional — avoids double-counting cost)"><select className="cl-in" value={f.buyId} onChange={(e) => linkBuy(e.target.value)}><option value="">— not linked / enter new cost —</option>{opts.map((b) => <option key={b.id} value={b.id}>{b.item} · {b.source} · {fmt(Number(b.cost) || 0)}</option>)}</select></Field>}
      <div className="cl-grid2"><Field label="Packs"><input className="cl-in" inputMode="numeric" placeholder="5" value={f.packs} onChange={(e) => setF({ ...f, packs: e.target.value })} /></Field><Field label={f.buyId ? "Cost (from buy)" : "Total cost"}><MoneyInput value={f.cost} onChange={(v) => !f.buyId && setF({ ...f, cost: v })} /></Field></div>
      <div className="cl-grid2"><Field label="Bought from"><Select opts={SOURCES} value={f.source} onChange={(v) => setF({ ...f, source: v })} /></Field><Field label="Date"><input className="cl-in" type="date" value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} /></Field></div>
      <Actions onCancel={onCancel} label="Save rip" disabled={!f.product || (!f.buyId && !f.cost)} onSave={() => onSave({ product: f.product, set: f.set, packs: Number(f.packs) || 0, cost: f.buyId ? 0 : Number(f.cost) || 0, source: f.source, date: f.date, buyId: f.buyId || null })} />
    </Form>
  );
}
function CardAutocomplete({ value, onChange, onSelect, placeholder }) {
  const [results, setResults] = useState([]);
  const [open, setOpen] = useState(false);
  const [loading, setLoading] = useState(false);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState(false);
  const timer = useRef();
  const skip = useRef(false);
  const fillSeq = useRef(0);

  const run = async (q, attempt = 0) => {
    setError(false); setPending(false); setLoading(true); setOpen(true);
    try {
      const { terms, descriptors, first } = buildQuery(q);
      const want = [...new Set(descriptors.flatMap((d) => DESC_RARITY[d] || []))];
      const r = await fetch(`https://api.pokemontcg.io/v2/cards?q=${encodeURIComponent(terms)}&pageSize=24`, PTCG_OPTS);
      if (!r.ok) throw new Error(String(r.status));
      const data = await r.json();
      const filled = await fillMissingPrices((data.data || []).map(slimCard));
      const list = filled.sort((a, b) => {
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
      qcacheSet(terms, list);
      setResults(list);
    } catch (e) {
      if (attempt < 1) { await new Promise((res) => setTimeout(res, 700)); return run(q, attempt + 1); }
      setResults([]); setError(true);
    } finally { setLoading(false); }
  };

  useEffect(() => {
    if (timer.current) clearTimeout(timer.current);
    if (skip.current) { skip.current = false; setPending(false); return; }
    const q = value.trim();
    if (q.length < 2) { setResults([]); setOpen(false); setPending(false); setError(false); return; }
    const cached = qcacheGet(buildQuery(q).terms);
    if (cached) {
      setResults(cached); setError(false); setPending(false); setLoading(false); setOpen(true);
      const seq = ++fillSeq.current;
      fillMissingPrices(cached).then((filled) => {
        if (seq !== fillSeq.current || !filled.some((c, i) => c !== cached[i])) return;
        qcacheSet(buildQuery(q).terms, filled);
        setResults(filled);
      });
      return;
    }
    setPending(true);
    timer.current = setTimeout(() => run(q), 3000);
    return () => clearTimeout(timer.current);
  }, [value]);

  const choose = (c) => { skip.current = true; setOpen(false); setResults([]); setPending(false); setError(false); onSelect(c); };

  return (
    <div className="cl-ac">
      <input className="cl-in" placeholder={placeholder} value={value}
        onChange={(e) => onChange(e.target.value)}
        onFocus={() => (results.length || error) && setOpen(true)}
        onBlur={() => setTimeout(() => setOpen(false), 200)} />
      {open && (
        <div className="cl-ac-pop">
          {loading && <div className="cl-ac-loading">Searching the card database…</div>}
          {!loading && error && <button className="cl-ac-loading cl-ac-retry" onMouseDown={(e) => e.preventDefault()} onClick={() => run(value.trim())}>Card search didn’t respond — tap to retry</button>}
          {!loading && !error && results.length === 0 && <div className="cl-ac-loading">No matches — try just the Pokémon name</div>}
          {!loading && !error && results.map((c) => (
            <button key={c.id} className="cl-ac-item" onMouseDown={(e) => e.preventDefault()} onClick={() => choose(c)}>
              {c.images?.small ? <img src={c.images.small} alt="" className="cl-ac-img" /> : <div className="cl-ac-img" />}
              <div className="cl-ac-meta"><div className="cl-ac-name">{c.name}</div><div className="cl-row-meta">{c.set?.name} · {c.number}{c.rarity ? ` · ${c.rarity}` : ""}</div></div>
              <div className="cl-ac-price">{cardPrice(c) != null ? fmt(cardPrice(c)) : "—"}</div>
            </button>
          ))}
        </div>
      )}
      {pending && !open && <div className="cl-ac-hint">…will search in a moment</div>}
    </div>
  );
}
function HitForm({ onAdd }) {
  const [f, setF] = useState({ name: "", set: "", number: "", value: "" });
  const add = () => { if (!f.name) return; onAdd({ ...f, value: Number(f.value) || 0 }); setF({ name: "", set: "", number: "", value: "" }); };
  const pick = (c) => setF({ name: c.name, set: c.set?.name || "", number: c.number || "", value: cardPrice(c) != null ? String(cardPrice(c)) : "" });
  return (
    <div className="cl-hitform">
      <CardAutocomplete value={f.name} onChange={(v) => setF({ ...f, name: v })} onSelect={pick} placeholder="Add a hit — search card name" />
      <div className="cl-grid3"><input className="cl-in" placeholder="Set" value={f.set} onChange={(e) => setF({ ...f, set: e.target.value })} /><input className="cl-in" placeholder="No." value={f.number} onChange={(e) => setF({ ...f, number: e.target.value })} /><MoneyInput value={f.value} onChange={(v) => setF({ ...f, value: v })} placeholder="Value" /></div>
      <button className="cl-add-hit" onClick={add}><Plus size={14} /> Add hit</button>
    </div>
  );
}

/* ================================================================== */
function Buys({ state, patch }) {
  const [adding, setAdding] = useState(false);
  const [editId, setEditId] = useState(null);
  const add = (b) => { patch((s) => ({ buys: [{ id: uid(), ...b }, ...s.buys] })); setAdding(false); };
  const upd = (b) => { patch((s) => ({ buys: s.buys.map((x) => (x.id === b.id ? { ...x, ...b, seed: false } : x)) })); setEditId(null); };
  const del = (id) => patch((s) => ({ buys: s.buys.filter((b) => b.id !== id) }));
  const total = state.buys.reduce((s, b) => s + (Number(b.cost) || 0), 0);
  const sorted = [...state.buys].sort(byDateDesc);

  return (
    <div className="cl-stack">
      <Header title="Buys" sub={`Money out · ${fmt(total)} total`} onAdd={() => { setAdding(!adding); setEditId(null); }} addOpen={adding} />
      {adding && <BuyForm onSave={add} onCancel={() => setAdding(false)} />}
      {state.buys.length === 0 && !adding && <Empty>No purchases yet.</Empty>}
      <div className="cl-stack sm">
        {sorted.map((b) => editId === b.id
          ? <BuyForm key={b.id} initial={b} onSave={upd} onCancel={() => setEditId(null)} />
          : <div key={b.id} className="cl-row">
              <div className="cl-row-main"><div className="cl-row-title">{b.item}{b.seed && <span className="cl-seed">starter</span>}</div><div className="cl-row-meta"><span className="cl-chip">{b.category}</span>{b.ripped && <span className="cl-st grading">ripped</span>} {b.source} · {b.date}</div></div>
              <div className="cl-money out">{fmt(Number(b.cost) || 0)}</div>
              <button className="cl-x" onClick={() => { setEditId(b.id); setAdding(false); }}><Pencil size={13} /></button>
              <button className="cl-x" onClick={() => del(b.id)}><Trash2 size={13} /></button>
            </div>)}
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
function BuyForm({ initial, onSave, onCancel }) {
  const sets = useSets();
  const blank = () => ({ id: uid(), qty: "1", set: "", product: "Booster Pack", cost: "" });
  const [f, setF] = useState(initial
    ? { category: initial.category, source: initial.source, date: initial.date, item: initial.item || "", cost: numStr(initial.cost), total: numStr(initial.cost),
        lines: initial.lines?.length ? initial.lines.map((l) => ({ ...l, qty: String(l.qty || 1), cost: numStr(l.cost) })) : null }
    : { category: "Sealed", source: "Gamecraft", date: today(), item: "", cost: "", total: "", lines: [blank()] });
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
        <div className="cl-field">
          <span>Products</span>
          <div className="cl-stack sm">
            {f.lines.map((l) => <LineRow key={l.id} line={l} sets={sets} onChange={setLine} removable={f.lines.length > 1} onRemove={() => setF((p) => ({ ...p, lines: p.lines.filter((x) => x.id !== l.id) }))} />)}
            <button className="cl-addline" onClick={() => setF((p) => ({ ...p, lines: [...p.lines, blank()] }))}>+ Add another product</button>
          </div>
        </div>
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
        onSave={() => { const costs = f.lines ? lineCosts() : null; onSave({ ...(initial ? { id: initial.id } : {}), item: label, category: f.category, source: f.source, date: f.date, cost: total,
          ...(f.lines ? { lines: f.lines.map((l, i) => ({ id: l.id, qty: Number(l.qty) || 1, set: l.set, product: l.product, cost: costs[i] })) } : {}) }); }} />
    </Form>
  );
}

/* ================================================================== */
function Sales({ state, patch }) {
  const [adding, setAdding] = useState(false);
  const [editId, setEditId] = useState(null);
  const [msg, setMsg] = useState("");
  const fileRef = useRef();
  const soldIds = (x) => (x.cards || []).map((c) => c.invId).filter(Boolean);
  const markSold = (inv, ids) => (ids.length ? inv.map((c) => (ids.includes(c.id) ? { ...c, status: "Sold" } : c)) : inv);
  const add = (x) => { patch((s) => ({ sales: [{ id: uid(), ...x }, ...s.sales], inventory: markSold(s.inventory, soldIds(x)) })); setAdding(false); };
  const upd = (x) => { patch((s) => ({ sales: s.sales.map((y) => (y.id === x.id ? { ...y, ...x, seed: false } : y)), inventory: markSold(s.inventory, soldIds(x)) })); setEditId(null); };
  const del = (id) => patch((s) => ({ sales: s.sales.filter((x) => x.id !== id) }));
  const earned = state.sales.reduce((s, x) => s + saleNet(x), 0);
  const sorted = [...state.sales].sort(byDateDesc);

  const onFile = (e) => {
    const file = e.target.files?.[0]; if (!file) return;
    Papa.parse(file, { header: true, skipEmptyLines: true, complete: (res) => {
      const mapped = res.data.map((r) => {
        const total = parseFloat(r["Total Amt"] ?? r["Total"] ?? r["Item Subtotal"] ?? 0);
        if (!total) return null;
        const title = r["Item Title"] || "";
        return { id: uid(), item: r["Order #"] ? "TCGP " + String(r["Order #"]).split("-").pop() : "", cards: title ? [{ id: uid(), name: title, basis: 0 }] : [], channel: r["Order #"] ? "TCGplayer" : "eBay", price: total, fees: 0, shipping: 0, consign: 0, date: cleanDate(r["Order Date"] || r["Sale Date"] || "") };
      }).filter(Boolean);
      if (mapped.length) { patch((s) => ({ sales: [...mapped, ...s.sales] })); setMsg(`Imported ${mapped.length} orders.`); }
      else setMsg("No rows with a total amount found — check the export format.");
      if (fileRef.current) fileRef.current.value = "";
    }, error: () => setMsg("Couldn't read that file.") });
  };

  return (
    <div className="cl-stack">
      <Header title="Sales" sub={`Money in · ${fmt(earned)} net`} onAdd={() => { setAdding(!adding); setEditId(null); }} addOpen={adding} />
      <div className="cl-import"><button className="cl-import-btn" onClick={() => fileRef.current?.click()}><Upload size={14} /> Import CSV (TCGplayer / eBay export)</button><input ref={fileRef} type="file" accept=".csv" hidden onChange={onFile} />{msg && <div className="cl-import-msg">{msg}</div>}</div>
      {adding && <SaleForm inventory={state.inventory} onSave={add} onCancel={() => setAdding(false)} />}
      {state.sales.length === 0 && !adding && <Empty>No sales yet.</Empty>}
      <div className="cl-stack sm">
        {sorted.map((x) => editId === x.id
          ? <SaleForm key={x.id} initial={x} inventory={state.inventory} onSave={upd} onCancel={() => setEditId(null)} />
          : (() => { const net = saleNet(x); const ded = (Number(x.fees) || 0) + (Number(x.shipping) || 0) + (Number(x.consign) || 0); const cards = x.cards || []; const title = cards.length ? cards[0].name + (cards.length > 1 ? ` +${cards.length - 1}` : "") : (x.item || "Sale"); const basis = saleBasis(x); const ref = cards.length && x.item ? ` · ${x.item}` : ""; return (
              <div key={x.id} className="cl-row">
                <div className="cl-row-main"><div className="cl-row-title">{title}{x.seed && <span className="cl-seed">starter</span>}</div><div className="cl-row-meta"><span className="cl-chip">{x.channel}</span> {x.date}{ref}{ded > 0 && ` · −${ded.toFixed(2)} fees`}</div></div>
                <div className="cl-card-num"><div className="cl-money in">{fmt(net)}</div>{basis > 0 ? <div className="cl-row-meta">profit {fmt(net - basis)}</div> : null}</div>
                <button className="cl-x" onClick={() => { setEditId(x.id); setAdding(false); }}><Pencil size={13} /></button>
                <button className="cl-x" onClick={() => del(x.id)}><Trash2 size={13} /></button>
              </div>); })())}
      </div>
    </div>
  );
}
function SaleForm({ initial, inventory, onSave, onCancel }) {
  const kept = (inventory || []).filter((c) => c.status !== "Sold");
  const [f, setF] = useState(initial
    ? { item: initial.item || "", channel: initial.channel, price: String(initial.price), fees: numStr(initial.fees), shipping: numStr(initial.shipping), consign: numStr(initial.consign), date: initial.date, cards: (initial.cards || []).map((c) => ({ ...c })) }
    : { item: "", channel: "TCGplayer", price: "", fees: "", shipping: "", consign: "", date: today(), cards: [] });
  const [tname, setTname] = useState("");
  const [tbasis, setTbasis] = useState("");
  const [tmeta, setTmeta] = useState(null); // set/number from a picked search result
  const addInv = (id) => { const c = kept.find((x) => x.id === id); if (!c) return; setF((s) => ({ ...s, cards: [...s.cards, { id: uid(), invId: c.id, name: c.name, set: c.set, number: c.number, basis: invBasis(c) }] })); };
  const pickTyped = (c) => { setTname(c.name); setTmeta({ set: c.set?.name || "", number: c.number || "" }); };
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
      <div className="cl-typedadd">
        <CardAutocomplete value={tname} onChange={(v) => { setTname(v); setTmeta(null); }} onSelect={pickTyped} placeholder="…or search a card name" />
        <div className="cl-money-in cl-basisbox"><span>$</span><input className="cl-in bare" inputMode="decimal" placeholder="basis" value={tbasis} onChange={(e) => setTbasis(e.target.value.replace(/[^0-9.]/g, ""))} /></div>
        <button className="cl-add-card" onClick={addTyped}><Plus size={15} /></button>
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
function Inventory({ state, patch }) {
  const inv = state.inventory || [];
  const [adding, setAdding] = useState(false);
  const [editId, setEditId] = useState(null);
  const [filter, setFilter] = useState("All");
  const add = (c) => { patch((s) => ({ inventory: [{ id: uid(), ...c }, ...(s.inventory || [])] })); setAdding(false); };
  const upd = (c) => { patch((s) => ({ inventory: s.inventory.map((x) => (x.id === c.id ? { ...x, ...c } : x)) })); setEditId(null); };
  const del = (id) => patch((s) => ({ inventory: s.inventory.filter((c) => c.id !== id) }));
  const live = inv.filter((c) => c.status !== "Sold");
  const val = live.reduce((s, c) => s + (Number(c.value) || 0), 0);
  const basis = live.reduce((s, c) => s + invBasis(c), 0);
  const range = invRange(live);
  const hasRange = range.lo !== range.hi;
  const FILTERS = ["All", "Kept", "At grading", "Listed", "Sold"];
  const shown = (filter === "All" ? inv : inv.filter((c) => c.status === filter)).slice().sort(byDateDesc);

  return (
    <div className="cl-stack">
      <Header title="Inventory" sub={`${live.length} held · ${hasRange ? fmtRange(range) : fmt(val)} market`} onAdd={() => { setAdding(!adding); setEditId(null); }} addOpen={adding} />
      {live.length > 0 && <div className="cl-grid2"><Stat label="Cost basis" value={fmt(basis)} tone="out" /><Stat label="Unrealized" value={hasRange ? <span className="cl-range">{fmtRange({ lo: range.lo - basis, hi: range.hi - basis })}</span> : fmt(val - basis)} tone={range.lo - basis >= 0 ? "in" : range.hi - basis < 0 ? "neg" : "out"} /></div>}
      {adding && <InvForm onSave={add} onCancel={() => setAdding(false)} />}
      {inv.length > 0 && <div className="cl-pills">{FILTERS.map((x) => <button key={x} className={"cl-pill" + (filter === x ? " on" : "")} onClick={() => setFilter(x)}>{x}</button>)}</div>}
      {inv.length === 0 && !adding && <Empty>No cards yet. Add a keeper or a card you've sent for grading, or hit “+ Keep” from Lookup to pull one in with its market value.</Empty>}
      <div className="cl-stack sm">
        {shown.map((c) => editId === c.id
          ? <InvForm key={c.id} initial={c} onSave={upd} onCancel={() => setEditId(null)} />
          : <div key={c.id} className={"cl-row" + (c.status === "Sold" ? " sold" : "")}>
              <span className="holo-dot" />
              <div className="cl-row-main"><div className="cl-row-title">{c.name}</div><div className="cl-row-meta"><span className={"cl-st " + stCls(c.status)}>{c.status}</span><span className="cl-chip">{c.grade}</span>{c.set ? `${c.set}${c.number ? " · " + c.number : ""} · ` : ""}{c.source}</div></div>
              <div className="cl-card-num"><div className="cl-money" style={{ color: "var(--holo2)" }}>{gradeRange(c) ? fmtRange(gradeRange(c)) : fmt(Number(c.value) || 0)}</div>{invBasis(c) ? <div className="cl-row-meta">basis {fmt(invBasis(c))}</div> : null}</div>
              <button className="cl-x" onClick={() => { setEditId(c.id); setAdding(false); }}><Pencil size={13} /></button>
              <button className="cl-x" onClick={() => del(c.id)}><Trash2 size={13} /></button>
            </div>)}
      </div>
    </div>
  );
}
function InvForm({ initial, onSave, onCancel }) {
  const estStr = (e) => Object.fromEntries(PSA_EST_GRADES.map((g) => [g, numStr(e?.[g])]));
  const [f, setF] = useState(initial
    ? { name: initial.name, set: initial.set || "", number: initial.number || "", grade: initial.grade || "Raw", status: initial.status || "Kept", source: initial.source || "Rip pull", cost: numStr(initial.cost), gradingCost: numStr(initial.gradingCost), value: numStr(initial.value), gradeEst: estStr(initial.gradeEst), date: initial.date || today() }
    : { name: "", set: "", number: "", grade: "Raw", status: "Kept", source: "Rip pull", cost: "", gradingCost: "", value: "", gradeEst: estStr(null), date: today() });
  const [comps, setComps] = useState("");
  const estEmpty = PSA_EST_GRADES.every((g) => !Number(f.gradeEst[g]));
  const pullComps = async () => {
    if (comps === "loading") return;
    setComps("loading");
    try {
      const r = await fetchGradedComps(f.name, f.set, f.number);
      const got = PSA_EST_GRADES.filter((g) => Number(r.grades?.[g]) > 0);
      setF((s) => ({ ...s, gradeEst: { ...s.gradeEst, ...Object.fromEntries(got.map((g) => [g, String(r.grades[g])])) } }));
      const label = r.number && !String(r.card).includes(r.number) ? `${r.card} ${r.number}` : r.card;
      setComps(`PSA ${got.join(" / ")} filled from eBay solds (${got.map((g) => r.sales?.[g] || "–").join(" / ")} sales) — ${label}.`);
    } catch (e) {
      setComps(e.status === 501 ? "Not set up yet — the sync Lambda needs a pokemonpricetracker.com API key (see aws/deploy.ps1)."
        : e.status === 404 ? "No recent graded sales found for this card — fill the values in manually."
        : "Comps unavailable right now — fill the values in manually.");
    }
  };
  // comps arrive on their own: when a card is opened already at grading with
  // nothing filled in, when it's flipped to "At grading", or on leaving the
  // number field. Only the number field gets the blur trigger — pulling on
  // name blur fires mid-entry with no set/number and matches the wrong card.
  // The button stays as a manual refresh.
  useEffect(() => { if (f.status === "At grading" && f.name && estEmpty) pullComps(); }, []); // eslint-disable-line react-hooks/exhaustive-deps
  const autoPull = (status = f.status) => { if (status === "At grading" && f.name && estEmpty && comps === "") pullComps(); };
  return (
    <Form editing={!!initial}>
      <Field label="Card"><input className="cl-in" placeholder="Umbreon ex SIR" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></Field>
      <div className="cl-grid2"><Field label="Set"><input className="cl-in" placeholder="Prismatic Evolutions" value={f.set} onChange={(e) => setF({ ...f, set: e.target.value })} /></Field><Field label="Number"><input className="cl-in" placeholder="161/131" value={f.number} onChange={(e) => setF({ ...f, number: e.target.value })} onBlur={() => autoPull()} /></Field></div>
      <div className="cl-grid2"><Field label="Grade"><Select opts={GRADES} value={f.grade} onChange={(v) => setF({ ...f, grade: v })} /></Field><Field label="Status"><Select opts={INV_STATUS} value={f.status} onChange={(v) => { setF({ ...f, status: v }); autoPull(v); }} /></Field></div>
      {f.status === "At grading" && <div className="cl-field">
        <div className="cl-gradeest-head"><span>If it grades — what you think it's worth at each PSA grade</span><button className="cl-link" disabled={!f.name || comps === "loading"} onClick={pullComps}>{comps === "loading" ? "Pulling…" : "Pull eBay comps"}</button></div>
        <div className="cl-gradeest">{PSA_EST_GRADES.map((g) => <div key={g} className="cl-gradeest-cell"><span className="cl-gradeest-g">PSA {g}</span><MoneyInput placeholder="—" value={f.gradeEst[g]} onChange={(v) => setF({ ...f, gradeEst: { ...f.gradeEst, [g]: v } })} /></div>)}</div>
        {comps && <div className="cl-gradeest-note">{comps === "loading" ? "Pulling eBay sold comps…" : comps}</div>}
      </div>}
      <Field label="Source"><Select opts={INV_SOURCES} value={f.source} onChange={(v) => setF({ ...f, source: v })} /></Field>
      <div className="cl-grid3"><Field label="Cost basis"><MoneyInput value={f.cost} onChange={(v) => setF({ ...f, cost: v })} /></Field><Field label="Grading cost"><MoneyInput value={f.gradingCost} onChange={(v) => setF({ ...f, gradingCost: v })} /></Field><Field label="Market value"><MoneyInput value={f.value} onChange={(v) => setF({ ...f, value: v })} /></Field></div>
      <Actions onCancel={onCancel} label={initial ? "Update card" : "Add card"} disabled={!f.name} onSave={() => onSave({ ...(initial ? { id: initial.id } : {}), name: f.name, set: f.set, number: f.number, grade: f.grade, status: f.status, source: f.source, cost: Number(f.cost) || 0, gradingCost: Number(f.gradingCost) || 0, value: Number(f.value) || 0, gradeEst: Object.fromEntries(PSA_EST_GRADES.map((g) => [g, Number(f.gradeEst[g]) || 0])), date: f.date })} />
    </Form>
  );
}

/* ================================================================== */
function Lookup({ state, patch }) {
  const [q, setQ] = useState("");
  const [res, setRes] = useState([]);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState("");
  const [ripFor, setRipFor] = useState({});
  const [flashes, setFlashes] = useState({});
  const flash = (id, t) => { setFlashes((f) => ({ ...f, [id]: t })); setTimeout(() => setFlashes((f) => ({ ...f, [id]: null })), 1600); };

  const search = async () => {
    if (!q.trim()) return;
    setLoading(true); setErr(""); setRes([]);
    try {
      const { terms } = buildQuery(q.trim());
      const url = `https://api.pokemontcg.io/v2/cards?q=${encodeURIComponent(terms)}&pageSize=18&orderBy=-set.releaseDate`;
      const r = await fetch(url, PTCG_OPTS); if (!r.ok) throw new Error();
      const data = await r.json();
      const filled = await fillMissingPrices(data.data || []);
      setRes(filled);
      if (!filled.length) setErr("No cards matched. Try just the Pokémon's name.");
    } catch { setErr("Couldn't reach the price API. Check your connection and try again."); }
    finally { setLoading(false); }
  };
  const priceOf = cardPrice;

  const asBuy = (c) => { patch((s) => ({ buys: [{ id: uid(), item: `${c.name} ${c.number || ""}`.trim(), category: "Single", source: "Other", cost: priceOf(c) || 0, date: today() }, ...s.buys] })); flash(c.id, "Added to Buys"); };
  const asKeep = (c) => { patch((s) => ({ inventory: [{ id: uid(), name: c.name, set: c.set?.name, number: c.number, grade: "Raw", status: "Kept", source: "Other", cost: 0, gradingCost: 0, value: priceOf(c) || 0, date: today() }, ...(s.inventory || [])] })); flash(c.id, "Kept in inventory"); };
  const asHit = (c) => { const ripId = ripFor[c.id] || state.rips[0]?.id; if (!ripId) { flash(c.id, "Make a rip first"); return; } patch((s) => addHitToState(s, ripId, { name: c.name, set: c.set?.name, number: c.number, value: priceOf(c) || 0 })); flash(c.id, "Added as hit"); };

  return (
    <div className="cl-stack">
      <Header title="Card lookup" sub="Live TCGplayer market prices · pokemontcg.io" />
      <div className="cl-search"><input className="cl-in" placeholder="Search a card — e.g. Froakie" value={q} onChange={(e) => setQ(e.target.value)} onKeyDown={(e) => e.key === "Enter" && search()} /><button className="cl-search-btn" onClick={search}><Search size={15} /></button></div>
      {loading && <div className="cl-center">Searching…</div>}
      {err && <Empty>{err}</Empty>}
      <div className="cl-cards">
        {res.map((c) => { const price = priceOf(c); return (
          <div key={c.id} className="cl-lk">
            {c.images?.small && <img src={c.images.small} alt={c.name} className="cl-lk-img" loading="lazy" />}
            <div className="cl-lk-body">
              <div className="cl-lk-name">{c.name}</div>
              <div className="cl-row-meta">{c.set?.name} · {c.number}{c.rarity ? ` · ${c.rarity}` : ""}</div>
              <div className="cl-lk-price">{price != null ? fmt(price) : "no market price"}</div>
              <div className="cl-lk-actions"><button className="cl-mini" onClick={() => asBuy(c)}>+ Buy</button><button className="cl-mini" onClick={() => asKeep(c)}>+ Keep</button><button className="cl-mini holo-border" onClick={() => asHit(c)}>+ Hit</button></div>
              {state.rips.length > 0 && <select className="cl-rip-sel" value={ripFor[c.id] || ""} onChange={(e) => setRipFor({ ...ripFor, [c.id]: e.target.value })}><option value="">latest rip</option>{state.rips.map((r) => <option key={r.id} value={r.id}>{r.product || "Rip"}</option>)}</select>}
              {flashes[c.id] && <div className="cl-flash">{flashes[c.id]}</div>}
            </div>
          </div>); })}
      </div>
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
const Form = ({ children, editing }) => <div className={"cl-form" + (editing ? " cl-editing" : "")}>{children}</div>;
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
function cleanDate(s) { const d = new Date(String(s).replace(/^[A-Za-z]+,\s*/, "")); return isNaN(d) ? today() : d.toISOString().slice(0, 10); }

function Fonts() {
  return (<style>{`
    @import url('https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;600;700&family=Inter:wght@400;450;500;600&display=swap');
    .cl-root{--bg:#0c0e13;--surf:#161a22;--surf2:#1d222c;--line:#2a3140;--ink:#e8ebf2;--mut:#8b93a4;--pos:#3fd68c;--neg:#ff6f6f;--out:#ffb454;--holo2:#c4b5fd;
      background:radial-gradient(1200px 600px at 50% -10%,#19202c 0%,var(--bg) 60%);color:var(--ink);font-family:'Inter',system-ui,sans-serif;min-height:100vh;-webkit-font-smoothing:antialiased;}
    .cl-root *{box-sizing:border-box;}
    .holo-text{background:linear-gradient(110deg,#5ce1e6,#a78bfa,#ffd479,#7cf5a0,#5ce1e6);background-size:300% 100%;-webkit-background-clip:text;background-clip:text;color:transparent;animation:holo 6s linear infinite;}
    .holo-text.neg{background:linear-gradient(110deg,#ff9a8b,#ff6f6f,#ffb454,#ff6f6f,#ff9a8b);background-size:300% 100%;-webkit-background-clip:text;background-clip:text;}
    @keyframes holo{to{background-position:300% 0;}}
    @media (prefers-reduced-motion:reduce){.holo-text{animation:none;}}
    .holo-dot{width:8px;height:8px;border-radius:50%;flex:none;background:linear-gradient(110deg,#5ce1e6,#a78bfa,#ffd479);box-shadow:0 0 8px rgba(167,139,250,.6);}
    .holo-border{position:relative;border:1px solid transparent!important;background:linear-gradient(var(--surf2),var(--surf2)) padding-box,linear-gradient(110deg,#5ce1e6,#a78bfa,#ffd479) border-box!important;}
    .cl-head{display:flex;align-items:center;justify-content:space-between;padding:16px 18px 8px;}
    .cl-brand{display:flex;align-items:center;gap:8px;font-family:'Space Grotesk';font-weight:700;font-size:19px;letter-spacing:-.02em;}
    .cl-spark{color:#a78bfa;}
    .cl-tag{font-size:11px;color:var(--mut);text-transform:uppercase;letter-spacing:.14em;}
    .cl-tabs{display:flex;gap:4px;padding:4px 12px 0;overflow-x:auto;position:sticky;top:0;z-index:5;background:linear-gradient(180deg,var(--bg),rgba(12,14,19,.6));backdrop-filter:blur(8px);}
    .cl-tab{display:flex;align-items:center;gap:6px;padding:9px 13px;border:none;background:none;color:var(--mut);font-size:13px;font-weight:500;cursor:pointer;border-bottom:2px solid transparent;white-space:nowrap;font-family:'Inter';}
    .cl-tab.on{color:var(--ink);border-bottom-color:#a78bfa;}
    .cl-main{padding:16px 14px 60px;max-width:680px;margin:0 auto;}
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
    .cl-card{background:var(--surf);border:1px solid var(--line);border-radius:14px;}
    .cl-card-head{width:100%;display:flex;align-items:center;gap:10px;padding:13px 13px;background:none;border:none;color:inherit;cursor:pointer;text-align:left;font-family:'Inter';}
    .cl-card-num{text-align:right;}
    .cl-card-body{padding:0 13px 13px;border-top:1px solid var(--line);}
    .cl-hits{display:flex;flex-direction:column;gap:6px;margin:12px 0;}
    .cl-hit{display:flex;align-items:center;gap:9px;background:var(--surf2);border:1px solid var(--line);border-radius:10px;padding:8px 10px;}
    .cl-hit-main{flex:1;min-width:0;}
    .cl-hit-name{font-size:13px;font-weight:500;}
    .cl-card-foot{display:flex;justify-content:space-between;align-items:center;font-size:12px;color:var(--mut);margin-top:10px;}
    .cl-del{background:none;border:none;color:var(--neg);font-size:12px;cursor:pointer;display:flex;align-items:center;gap:5px;font-family:'Inter';}
    .cl-hitform{background:var(--surf2);border:1px dashed var(--line);border-radius:10px;padding:10px;display:flex;flex-direction:column;gap:7px;}
    .cl-add-hit{display:flex;align-items:center;justify-content:center;gap:6px;background:#222a36;border:1px solid var(--line);color:var(--ink);border-radius:8px;padding:8px;font-size:12.5px;cursor:pointer;font-family:'Inter';}
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
    .cl-import-msg{font-size:12px;color:var(--mut);margin-top:7px;}
    .cl-empty{background:var(--surf);border:1px dashed var(--line);border-radius:12px;padding:18px;text-align:center;font-size:12.5px;color:var(--mut);line-height:1.5;}
    .cl-search{display:flex;gap:8px;}
    .cl-search-btn{background:var(--surf2);border:1px solid var(--line);color:var(--ink);border-radius:10px;width:42px;display:grid;place-items:center;cursor:pointer;flex:none;}
    .cl-cards{display:grid;grid-template-columns:1fr 1fr;gap:10px;}
    .cl-lk{background:var(--surf);border:1px solid var(--line);border-radius:13px;overflow:hidden;display:flex;flex-direction:column;}
    .cl-lk-img{width:100%;aspect-ratio:3/4;object-fit:contain;background:#0c0f15;padding:8px;}
    .cl-lk-body{padding:9px 10px 11px;display:flex;flex-direction:column;gap:4px;}
    .cl-lk-name{font-size:13px;font-weight:600;font-family:'Space Grotesk';}
    .cl-lk-price{font-family:'Space Grotesk';font-weight:600;color:var(--pos);font-size:15px;font-variant-numeric:tabular-nums;margin-top:2px;}
    .cl-lk-actions{display:flex;gap:5px;margin-top:6px;}
    .cl-mini{flex:1;background:var(--surf2);border:1px solid var(--line);color:var(--ink);border-radius:8px;padding:7px 4px;font-size:11.5px;cursor:pointer;font-family:'Inter';}
    .cl-rip-sel{margin-top:6px;background:#10141b;border:1px solid var(--line);color:var(--mut);border-radius:8px;padding:5px;font-size:11px;font-family:'Inter';}
    .cl-flash{font-size:11px;color:#7cf5a0;margin-top:5px;text-align:center;}
    .cl-cardchips{display:flex;flex-wrap:wrap;gap:6px;}
    .cl-cardchips-empty{font-size:12px;color:var(--mut);}
    .cl-cardchip{display:inline-flex;align-items:center;gap:5px;background:#10141b;border:1px solid var(--line);border-radius:8px;padding:5px 8px;font-size:12px;}
    .cl-chip-x{background:none;border:none;color:var(--mut);cursor:pointer;display:flex;padding:0;}
    .cl-chip-x:hover{color:var(--neg);}
    .cl-typedadd{display:flex;gap:6px;align-items:stretch;}
    .cl-typedadd>.cl-in,.cl-typedadd>.cl-ac{flex:1;}
    .cl-basisbox{max-width:110px;}
    .cl-add-card{background:#222a36;border:1px solid var(--line);color:var(--ink);border-radius:9px;width:44px;display:grid;place-items:center;cursor:pointer;flex:none;}
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
    .cl-ac-hint{font-size:10.5px;color:var(--mut);margin-top:4px;padding-left:2px;font-style:italic;}
    @media (max-width:420px){.cl-grid3{grid-template-columns:1fr;}.cl-hero-num{font-size:40px;}.cl-inv-summary .cl-stat-num{font-size:16px;}.cl-inv-summary .cl-range{font-size:11px;}.cl-gradeest{grid-template-columns:repeat(3,1fr);}}
  `}</style>);
}
