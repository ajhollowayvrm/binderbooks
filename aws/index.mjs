// BinderBooks sync API — runs as AWS Lambda "binderbooks-sync" (us-west-2)
// behind API Gateway HTTP API "j18dixq7ei" ($default route, payload v2).
// The whole ledger is one JSON blob in the "binderbooks" DynamoDB table;
// writes are conditional on updatedAt so an out-of-date device gets a 409
// instead of clobbering newer data. The same table holds the card-data
// caches (set dumps, price history) under their own ids — see cacheGet.
// Every card fact the app shows — search, prices, printings, images,
// graded comps, price history — comes from pokemonpricetracker.com (PPT),
// and every route that reaches it sits behind the sync token, because PPT
// meters by credit and an open route would spend real money.
// (A Lambda function URL was the first attempt, but public function URLs
// return 403 on this account regardless of resource policy.)
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand, PutCommand } from "@aws-sdk/lib-dynamodb";
import { timingSafeEqual } from "node:crypto";

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = process.env.TABLE_NAME;
const ID = "ledger";
// DynamoDB items max out at 400 KB; leave headroom for attribute overhead
const MAX_BYTES = 350_000;

const res = (code, body) => ({
  statusCode: code,
  headers: { "content-type": "application/json" },
  body: JSON.stringify(body),
});

const authed = (event) => {
  const got = Buffer.from(String(event.headers?.["x-sync-token"] || ""));
  const want = Buffer.from(String(process.env.SYNC_TOKEN));
  return got.length === want.length && timingSafeEqual(got, want);
};

const normNum = (s) => String(s).split("/")[0].trim().replace(/^0+(?=\w)/, "").toUpperCase();
/* Set names are compared with their accents stripped. The ledger stores a set
   the way the old card database spelled it ("Pokémon GO") and TCGplayer — so
   PPT — spells the same set without the accent ("Pokemon GO"), so an exact
   compare misses a set both sides plainly have. Folding is only for matching —
   the names themselves are still returned and displayed as their source
   spells them. */
const foldSet = (s) => String(s || "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();
// legacy promo-set names in the ledger ("SWSH Black Star Promos") share no
// usable suffix with TCGplayer's set names, so those eras get explicit aliases
const GROUP_ALIASES = [
  [/scarlet.*violet.*(black star|promo)/, "sv: scarlet & violet promo cards"],
  [/^svp\b/, "sv: scarlet & violet promo cards"],
  // the ledger's transliteration of the Japanese set; the target only exists
  // in the Japanese list, so English lookups fall through harmlessly
  [/teresa festival|terastal fest/, "sv8a: terastal fest ex"],
  [/^me(ga evolution)?\b.*(black star|promo)/, "me: mega evolution promo"],
  [/^swsh\b.*(black star|promo)/, "swsh: sword & shield promo cards"],
  [/^sm\b.*(black star|promo)/, "sm promos"],
  [/^xy\b.*(black star|promo)/, "xy promos"],
];
// TCGplayer's catalog Number field is sometimes wrong (the Mega Greninja ex
// 081 promo is filed under its Chaos Rising number, 022/086) while the
// seller-facing product name carries the real number — prefer the name's
// " - <num>" suffix when it looks like a collector number
const nameNum = (name) => {
  const m = String(name).match(/.* - ([\w/.]+)/);
  return m && /^[A-Za-z]{0,5}\d/.test(m[1]) ? m[1] : null;
};
/* TCGplayer sells a stamped or patterned print as its own product, under the
   same name and the same collector number as the plain one: "Radiant
   Gardevoir - 069/196" and "Radiant Gardevoir - 069/196 (Prize Pack)" are both
   069/196 in Prize Pack Series Cards, and one is worth a hundred times the
   other. The parenthetical is the only thing separating them, so it is
   compared on its own wherever two cards are matched — never folded into the
   name, where a prefix test would read the plain card as the stamped one. */
const qualOf = (name) => (foldSet(name).match(/\(([^)]*)\)/g) || []).join(" ").replace(/[^a-z0-9]+/g, "");
// the name with TCGplayer's furniture off it: the " - 069/196" tail and every
// parenthetical, so only the card's own name is left to compare
const bareName = (name) => String(name ?? "").replace(/ - [\w/.]+/g, "").replace(/\s*\([^)]*\)/g, "");
// two qualifiers describe the same print when they agree, or when one spells
// out what the other abbreviates ("prize pack" / "prize pack series"). Absent
// on both sides is a match; absent on one side is not.
const qualNear = (a, b) => (!a && !b) || (!!a && !!b && (a === b || a.includes(b) || b.includes(a)));
// one price out of a card's per-printing map, for callers that want a single
// number. The client picks a printing deliberately when it knows the card's
// variant; this is the "don't care" answer, and the order is load-bearing —
// it's the collapse /prices has always returned.
const collapse = (sub) => (sub ? sub["Normal"] ?? sub["Holofoil"] ?? Object.values(sub)[0] ?? null : null);
/* --- the PPT client ---------------------------------------------------- */
// PPT bills credits on the requested `limit`, never on the rows that come
// back — a bare list call defaults to limit=50 and costs 50 credits even
// when one card matches, so every list call here names its limit. A 429
// carries Retry-After: a short one is the per-minute cap (wait it out,
// once), a long one is the daily budget (surface it — retrying can't help).
const PPT_BASE = "https://www.pokemonpricetracker.com/api/v2";
const pptLang = (lang) => (lang === "jp" ? "japanese" : "english");
async function pptFetch(path, params) {
  for (let attempt = 0; ; attempt++) {
    const u = new URL(`${PPT_BASE}/${path}`);
    for (const [k, v] of Object.entries(params)) if (v != null && v !== "") u.searchParams.set(k, v);
    const ctl = new AbortController();
    // beat API Gateway's 30s cut-off, same reasoning as identifyCards
    const t = setTimeout(() => ctl.abort(), 25_000);
    try {
      const r = await fetch(u, { headers: { authorization: `Bearer ${process.env.PPT_KEY}` }, signal: ctl.signal });
      if (r.status === 429 && attempt === 0) {
        const wait = Number(r.headers.get("retry-after"));
        if (wait > 0 && wait <= 10) { await new Promise((ok) => setTimeout(ok, wait * 1000)); continue; }
      }
      if (!r.ok) { const e = new Error(`ppt HTTP ${r.status}`); e.status = r.status; throw e; }
      return await r.json();
    } finally { clearTimeout(t); }
  }
}
// /cards answers with a list on a search and one bare object on an id
// lookup — normalize both to an array
async function pptCards(params) {
  const data = await pptFetch("cards", params);
  const cards = data.cards ?? data.data ?? data;
  return Array.isArray(cards) ? cards : cards && typeof cards === "object" ? [cards] : [];
}

/* --- the card-data cache ------------------------------------------------ */
/* Set dumps, the set list and price history live in the same DynamoDB table
   as the ledger, under their own ids ("set:en:base set", "sets:jp",
   "hist:en:1234:90"). A Lambda's in-memory Map dies with its container, and
   every cold start would otherwise re-buy the same set at its full card
   count in credits. The item stores the JSON as a string so the 400 KB size
   guard is exact; anything over the cap stays memory-only — caching must
   never fail a request. */
const memCache = new Map();
async function cacheGet(id, ttl) {
  const m = memCache.get(id);
  if (m && Date.now() - m.t < ttl) return m.body;
  try {
    const r = await ddb.send(new GetCommand({ TableName: TABLE, Key: { id } }));
    if (r.Item?.t && Date.now() - r.Item.t < ttl) {
      const body = JSON.parse(r.Item.data);
      memCache.set(id, { t: r.Item.t, body });
      return body;
    }
  } catch {}
  return null;
}
async function cachePut(id, body) {
  memCache.set(id, { t: Date.now(), body });
  try {
    const data = JSON.stringify(body);
    if (data.length <= MAX_BYTES) await ddb.send(new PutCommand({ TableName: TABLE, Item: { id, t: Date.now(), data } }));
  } catch {}
}

const SETS_TTL = 7 * 24 * 3600 * 1000;
async function pptSets(lang = "en") {
  const id = `sets:${lang}`;
  const hit = await cacheGet(id, SETS_TTL);
  if (hit) return hit;
  const data = await pptFetch("sets", { language: pptLang(lang), limit: "500" });
  const list = (data.data || [])
    .filter((s) => s.tcgPlayerNumericId)
    .map((s) => ({ name: s.name, numericId: s.tcgPlayerNumericId, releaseDate: (s.releaseDate || "").slice(0, 10), cardCount: s.cardCount || 0 }))
    .sort((a, b) => b.releaseDate.localeCompare(a.releaseDate));
  const body = { list };
  await cachePut(id, body);
  return body;
}

// PPT reprices daily, so a fresher dump than 24h buys nothing
const SET_TTL = 24 * 3600 * 1000;
async function pptSetData(setName, lang = "en") {
  const cacheId = `set:${lang}:${foldSet(setName)}`;
  const hit = await cacheGet(cacheId, SET_TTL);
  if (hit) return hit;
  const { list } = await pptSets(lang);
  /* Exact name wins before any partial match, and the reason is a real card:
     four later sets are named "<something> Base Set", and every one of them
     ends with "base set" — so "Base Set" used to resolve to SV01: Scarlet &
     Violet (2023) while the 1999 set it meant sat fifth in the same list.
     That is not a search miss, it is the wrong set's prices written onto a
     Base Set card. Same trap waits for any short set name that is also the
     tail of a newer one, so exactness is the rule, not a special case. */
  const key = setName.toLowerCase();
  const fkey = foldSet(key);
  const alias = GROUP_ALIASES.find(([re]) => re.test(key))?.[1];
  const group = (alias && list.find((x) => foldSet(x.name) === alias))
    || list.find((x) => foldSet(x.name) === fkey)
    || list.find((x) => foldSet(x.name).endsWith(fkey))
    || list.find((x) => foldSet(x.name).includes(fkey));
  if (!group) return null;
  // fetchAllInSet with no limit/offset returns the whole set in one response,
  // billed once at its card count; page defensively anyway in case a set
  // ever outgrows one response
  const raw = [];
  for (let offset = 0; ; ) {
    const page = await pptFetch("cards", {
      setId: String(group.numericId), fetchAllInSet: "true", language: pptLang(lang),
      ...(offset ? { limit: "200", offset: String(offset) } : {}),
    });
    const got = page.data || [];
    raw.push(...got);
    if (!page.metadata?.hasMore || !got.length) break;
    offset += got.length;
  }
  /* The internal product shape predates PPT and every consumer speaks it:
     { id, name, num, extNum, rarity, market, subs, img }. PPT product names
     are TCGplayer names ("Koraidon - 014 (Pokemon Center Exclusive)"), so
     nameNum and the qualifier matching carry over unchanged. Per-printing
     prices come from the card's top-level `variants` map — prices.variants
     and prices.conditions are deprecated upstream (removal Aug 2026). */
  const products = raw.map((c) => {
    const subs = {};
    for (const [printing, v] of Object.entries(c.variants || {})) {
      if (v?.marketPrice != null) subs[printing] = v.marketPrice;
    }
    const has = Object.keys(subs).length > 0;
    return {
      id: String(c.tcgPlayerId || ""), name: c.name || "",
      num: nameNum(c.name) || c.cardNumber || "", extNum: c.cardNumber || "",
      rarity: c.rarity || "",
      market: has ? collapse(subs) : (c.prices?.market ?? null),
      subs: has ? subs : null,
      img: c.imageCdnUrl200 || null,
    };
  });
  const body = { group: group.name, products };
  await cachePut(cacheId, body);
  return body;
}
async function setPrices(setName, lang) {
  const d = await pptSetData(setName, lang);
  if (!d) return null;
  // [Staff] and (Prerelease) variants share the plain card's number but carry
  // very different prices — they only fill a slot the plain card doesn't
  const subs = {};
  const assign = (p, overwrite) => {
    const k1 = normNum(p.num), k2 = normNum(p.extNum);
    if (overwrite) subs[k1] = p.subs; else subs[k1] ??= p.subs;
    // the catalog's own Number as a secondary key when it disagrees, never
    // clobbering a real card's slot
    if (k2 !== k1 && subs[k2] == null) subs[k2] = p.subs;
  };
  const priced = d.products.filter((p) => p.market != null);
  // every qualified print, not just [Staff] and (Prerelease): a Prize Pack
  // stamp or a Pokemon Center exclusive shares the plain card's number too, and
  // letting one overwrite that slot priced the plain card as the variant. The
  // plain print owns its number; a qualified one only fills a slot nothing
  // plain claims.
  const qualified = (p) => /\[|\(/.test(p.name);
  priced.filter(qualified).forEach((p) => assign(p, false));
  priced.filter((p) => !qualified(p)).forEach((p) => assign(p, true));
  // `prices` stays a flat { number: market } map. Clients running a cached
  // bundle read it straight into a card's value, and would write NaN — and
  // then sync it — if these became objects. Derived from `subs` rather than
  // tracked alongside, so the two can never disagree about a slot.
  const out = {};
  for (const n of Object.keys(subs)) out[n] = collapse(subs[n]);
  return { set: setName, group: d.group, prices: out, subs };
}
/* GET /catalog?set=<name> — a whole set's singles: name, number, rarity,
   market, per-printing subs, plus `img` (the thumbnail the binder and rip
   views render) and `productId` (PPT's product id, which buys exact
   2-credit graded/history lookups later). */
async function setCatalog(setName, lang) {
  const d = await pptSetData(setName, lang);
  if (!d) return null;
  return { set: setName, group: d.group, cards: d.products.map((p) => ({ name: p.name, num: p.num, rarity: p.rarity, market: p.market, subs: p.subs, img: p.img, productId: p.id })) };
}

/* GET /search?q=<text>&set=<name>&number=<num>&lang=<en|jp> — fuzzy card
   search, slimmed to the exact shape the client has always consumed (its
   cardPrice() reads tcgplayer.prices keyed normal/holofoil/reverseHolofoil,
   its rows split per priced printing). PPT's search takes plain words and
   "X/Y" numbers, so the client sends raw text — no query syntax anywhere. */
const printingKey = (p) => String(p).split(/\s+/).map((w, i) => (i ? w : w[0].toLowerCase() + w.slice(1))).join("");
const slimCard = (c) => {
  const prices = {};
  for (const [printing, v] of Object.entries(c.variants || {})) {
    if (v?.marketPrice != null) prices[printingKey(printing)] = { market: v.marketPrice };
  }
  // a card with a market but no variants map still deserves a price slot;
  // holofoil mirrors the client's own single-price fallback
  if (!Object.keys(prices).length && c.prices?.market != null) prices.holofoil = { market: c.prices.market };
  return {
    id: `ppt-${c.tcgPlayerId}`, productId: String(c.tcgPlayerId || ""),
    // the " - 041/086" tail and the "ME04: " prefix are TCGplayer-catalogue
    // furniture; a picked card writes these into the ledger, so they have to
    // arrive in the ledger's own plain vocabulary or every set splits into
    // "Chaos Rising" and "ME04: Chaos Rising" buckets
    name: String(c.name || "").replace(/ - [\w/.]+(?= \(|$)/, "").trim(),
    number: c.cardNumber || "", rarity: c.rarity || "",
    set: { name: String(c.setName || "").replace(/^\w{1,7}:\s+/, "") },
    images: { small: c.imageCdnUrl200 || null },
    ...(Object.keys(prices).length ? { tcgplayer: { prices } } : {}),
  };
};
async function cardSearch(q, set, number, lang) {
  const params = { search: number ? `${q} ${number}` : q, language: pptLang(lang), limit: "12" };
  if (set) params.set = foldSet(set);
  let cards = await pptCards(params);
  // a set spelling PPT doesn't recognize shouldn't sink the search
  if (!cards.length && set) { delete params.set; cards = await pptCards(params); }
  return cards.map(slimCard);
}

/* GET /history?productId=<id>&days=<n>&lang=<en|jp> — a card's market price
   over time, from PPT's per-printing daily history. Near Mint of the
   primary printing is "the" line; every printing with data rides along in
   byVariant so the modal can offer the reverse holo's history too. */
const HIST_TTL = 24 * 3600 * 1000;
async function priceHistory(productId, days, lang) {
  const cacheId = `hist:${lang}:${productId}:${days}`;
  const hit = await cacheGet(cacheId, HIST_TTL);
  if (hit) return hit;
  const cards = await pptCards({ tcgPlayerId: String(productId), includeHistory: "true", days: String(days), limit: "1", language: pptLang(lang) });
  const c = cards.find((x) => String(x.tcgPlayerId ?? "") === String(productId));
  if (!c) return null;
  const seriesOf = (v) => {
    const cond = v?.["Near Mint"] || Object.values(v || {})[0];
    return (cond?.history || [])
      .map((p) => ({ date: String(p.date).slice(0, 10), market: Number(p.market) }))
      .filter((p) => p.market > 0);
  };
  const byVariant = {};
  for (const [printing, v] of Object.entries(c.priceHistory?.variants || {})) {
    const s = seriesOf(v);
    if (s.length) byVariant[printing] = s;
  }
  const points = byVariant[c.prices?.primaryPrinting] || Object.values(byVariant)[0] || [];
  if (!points.length) return null;
  const body = {
    card: c.name, number: c.cardNumber || null, set: c.setName || null,
    productId: String(c.tcgPlayerId), points, byVariant,
    window: { from: points[0].date, to: points[points.length - 1].date },
  };
  await cachePut(cacheId, body);
  return body;
}

/* Resolve a ledger card (name + number + set) to PPT's product id through
   the cached set dump — the exact, 2-credit path for graded and history
   lookups, against a fuzzy name search's 6. Works for both languages now
   that the dumps themselves come from PPT. */
async function resolveProductId(name, number, set, lang) {
  if (!set || !number) return null;
  try {
    const d = await pptSetData(set, lang);
    if (!d) return null;
    const want = normNum(number);
    const clean = d.products.filter((p) => p.id && !/\[|\(prerelease\)/i.test(p.name));
    const sameNum = clean.filter((p) => normNum(p.num) === want);
    const pool = sameNum.length ? sameNum : clean.filter((p) => normNum(p.extNum) === want);
    /* A number is not always one card. "Koraidon - 014" and "Koraidon - 014
       (Pokemon Center Exclusive)" are both 014 in the same set and differ by
       ten times in price, so taking the first match on number alone priced a
       $52 card at $5. The ledger already carries the distinguishing words in
       the card's own name, so the qualifier decides — and it decides both
       ways. A card whose name carries one resolves to a product carrying the
       same one or to nothing at all: falling back to the plain print here
       returned its id as if it were exact, and every comp downstream then
       trusted it. A card with no qualifier prefers the plain print and only
       falls back when the set has none. Compared with accents folded: the
       ledger writes "Pokémon Center", the catalogue writes "Pokemon Center". */
    const wantQual = qualOf(name);
    const same = pool.filter((p) => qualNear(qualOf(p.name), wantQual));
    if (same.length > 1) console.log(`resolveProductId: ${same.length} products match "${name}" ${number} ${set} — taking ${same[0].name} (${same[0].id})`);
    const prod = same[0] || (wantQual ? null : pool[0]);
    return prod ? String(prod.id) : null;
  } catch { return null; } // dump unavailable — callers fall back to a name search
}

/* GET /graded?name=<card>&number=<num>&set=<set>&lang=<en|jp>&productId=<id>
   — eBay-sold comps by grade. `lang=jp` asks PPT's Japanese catalogue, which
   is a separate card with separate sold prices — not a translation of the
   English one. A `productId` (stored on the ledger card when it was picked
   from search) skips resolution entirely. Returns { card, set, number,
   market, grades } where grades is { "10": avg, "9": avg, ... } for whatever
   grades have recorded sales, plus the card-detail extras the app's card
   modal shows: byGrade (every company+grade bucket, e.g. "cgc9_5"), raw
   (ungraded solds), window (the date range the sales cover), image and url
   (TCGplayer CDN). */
const GRADED_TTL = 24 * 3600 * 1000;
const gradedCache = new Map();
// slim one salesByGrade bucket down to what the app renders; smartMarketPrice
// is their recency-filtered figure — raw averages skew low/stale
const slimBucket = (e) => {
  const v = e?.smartMarketPrice?.price ?? e?.marketPrice7Day ?? e?.averagePrice ?? e?.medianPrice;
  if (!(Number(v) > 0)) return null;
  const r2 = (n) => (Number(n) > 0 ? Math.round(Number(n) * 100) / 100 : null);
  return { price: r2(v), count: Number(e.count) || 0, median: r2(e.medianPrice), min: r2(e.minPrice), max: r2(e.maxPrice), trend: e.marketTrend || null };
};
async function gradedPrices(name, number, set, lang = "en", productId = "") {
  // the language is part of the identity of the card, so it is part of the key —
  // an English and a Japanese Umbreon are two cards with two sets of solds
  const key = `${name}|${number}|${set}|${lang}|${productId}`.toLowerCase();
  const hit = gradedCache.get(key);
  if (hit && Date.now() - hit.t < GRADED_TTL) return hit.body;
  const ppt = (params) => pptCards({ ...params, includeEbay: "true", language: pptLang(lang) });
  // cheapest path first: the caller's stored productId, else resolve one
  // through the set dump — 2 credits (one card with eBay data) instead of a
  // 3-candidate name search's 6, and no chance of comps for the wrong card
  let cards = [], byId = false;
  const tcgpId = productId || await resolveProductId(name, number, set, lang);
  if (tcgpId) {
    const got = await ppt({ tcgPlayerId: String(tcgpId), limit: "1" });
    // trust but verify: if PPT ever ignores the filter, don't accept arbitrary cards
    cards = got.filter((c) => String(c.tcgPlayerId ?? "") === String(tcgpId));
    byId = cards.length > 0;
    // a shape/field mismatch here silently triples the lookup cost — make it visible
    if (!cards.length) console.log(`graded: id lookup ${tcgpId} unusable, falling back to name search:`, JSON.stringify(got).slice(0, 300));
  }
  if (!cards.length) {
    /* name search: each returned card costs 2 credits with eBay data — limit 3
       keeps a lookup at 6 credits. The parenthetical comes off the query: a
       ledger card entered from the TCGplayer catalog is named "Radiant
       Gardevoir (Prize Pack)", and searching that phrase matches nothing while
       the bare name matches every print of the card. The qualifier is not
       thrown away — it decides which of them is this card, below. */
    const searchName = bareName(name).trim() || name;
    cards = await ppt({ search: searchName, ...(set ? { set: foldSet(set) } : {}), limit: "3" });
    // a set name PPT doesn't recognize shouldn't sink the lookup
    if (!cards.length && set) cards = await ppt({ search: searchName, limit: "3" });
  }
  /* Which of the search results is actually the card we were asked about.
     PPT's `search` is fuzzy by design: ask for "Umbreon ex 161" and it also
     offers the VMAX, the promo and last year's Umbreon. This used to end
     `|| cards[0]`, so any lookup whose number didn't match took the first
     result — and the caller writes that straight onto a ledger card's value.
     Comps for a different card are worse than no comps at all, because no
     comps says so and wrong comps doesn't. So nothing is returned unless it
     can be pinned down. */
  // "SVP 176" against a ledger's "176": compare the last token. normNum alone
  // never matched a promo, which is why promos always fell through to cards[0].
  const numTail = (x) => normNum(String(x ?? "").trim().split(/\s+/).pop() || "");
  const alnum = (x) => String(x ?? "").toLowerCase().replace(/[^a-z0-9]+/g, "");
  const setOf = (c) => c.setName ?? c.set?.name ?? (typeof c.set === "string" ? c.set : "");
  const near = (a, b) => a && b && (a === b || a.startsWith(b) || b.startsWith(a));
  let match;
  if (byId) {
    match = cards[0]; // resolved through the TCGplayer product id — already exact
  } else {
    /* narrow by name, then by set, keeping the wider pool when a filter empties
       it. Names compare bare — PPT writes "Radiant Gardevoir - 069/196 (Prize
       Pack)" where the ledger writes "Radiant Gardevoir (Prize Pack)", and a
       prefix test on the raw strings agreed with neither. */
    const named = cards.filter((c) => near(alnum(bareName(c.name)), alnum(bareName(name))));
    let pool = named.length ? named : cards;
    if (set) { const inSet = pool.filter((c) => near(alnum(setOf(c)), alnum(set))); if (inSet.length) pool = inSet; }
    // the number is the card's identity: given one, only that card will do.
    // Without one, only an unambiguous single candidate is safe to accept.
    const want = number ? numTail(number) : null;
    const pick = (list) => (want ? list.find((c) => numTail(c.number ?? c.cardNumber) === want) || null
      : list.length === 1 ? list[0] : null);
    /* And the number is not the whole identity. A stamped print shares it with
       the plain card, so a Prize Pack Radiant Gardevoir used to match the plain
       069/196 and take its eBay solds — the stamped print has barely any, and
       the plain one's numbers landed on the card's value looking like its own.
       A card named with a qualifier matches only a card carrying that
       qualifier; no such candidate is no comps, which the app says out loud. */
    const wantQual = qualOf(name);
    match = pick(pool.filter((c) => qualNear(qualOf(c.name), wantQual))) || (wantQual ? null : pick(pool));
    if (!match) console.log(`graded: no confident match for "${name}" ${number || "(no number)"} ${set || ""} — ${cards.length} candidate(s):`, cards.map((c) => `${c.name} ${c.number ?? c.cardNumber ?? "?"}`).join(" | "));
  }
  if (!match) return null;
  // salesByGrade.psaN: smartMarketPrice is their recency-filtered market
  // price; raw averages skew low because they include months-old sales
  const grades = {}, sales = {};
  for (const g of ["10", "9", "8", "7", "6"]) {
    const e = match.ebay?.salesByGrade?.[`psa${g}`];
    const v = e?.smartMarketPrice?.price ?? e?.marketPrice7Day ?? e?.averagePrice ?? e?.medianPrice;
    if (Number(v) > 0) {
      grades[g] = Math.round(Number(v) * 100) / 100;
      if (Number(e.count) > 0) sales[g] = Number(e.count);
    }
  }
  const sbg = match.ebay?.salesByGrade || {};
  const byGrade = {};
  for (const [k, v] of Object.entries(sbg)) {
    if (k === "ungraded") continue;
    const b = slimBucket(v);
    if (b) byGrade[k] = b;
  }
  const body = {
    card: match.name,
    number: match.number ?? match.cardNumber ?? null,
    set: match.setName ?? match.set?.name ?? (typeof match.set === "string" ? match.set : null),
    market: match.prices?.market ?? null,
    grades,
    sales,
    byGrade,
    raw: slimBucket(sbg.ungraded),
    window: { from: match.ebay?.dateRangeStart || null, to: match.ebay?.dateRangeEnd || null },
    image: match.imageCdnUrl400 || match.imageCdnUrl200 || match.imageUrl || null,
    url: match.tcgPlayerUrl || null,
    rarity: match.rarity || null,
  };
  gradedCache.set(key, { t: Date.now(), body });
  return body;
}

/* POST /identify — read a photographed card with Claude and report what's on
   it. Behind the token wall like everything else that costs money per call.
   Always answers with { cards: [...] }, even for one card, so scanning a
   whole binder page later is a prompt change rather than a new response
   shape. */
const IDENTIFY_MODEL = "claude-haiku-4-5";
const MAX_IMAGE_B64 = 5 * 1024 * 1024; // Lambda caps the whole request at 6MB
const MEDIA_TYPES = new Set(["image/jpeg", "image/png", "image/webp"]);
const IDENTIFY_SYSTEM = `You identify Pokémon trading cards from photographs for a collector's inventory app.

The card may be loose or sealed in a grading company's slab. A slab is a rigid plastic case with a printed label along the top carrying the company's name, a grade, and usually a certification number; read that label as well as the card inside it.

Report only what is actually visible. Never infer a collector number or a set from the card's name.

- name: the card name exactly as printed, without the set, the number, or any variant wording. Give the English name when the card is Japanese and you recognise the Pokémon; report the printed Japanese name only if you cannot.
- number: the collector number exactly as printed, including the denominator when one is shown ("095/086", "TG12/TG30", "SV107"). null if unreadable.
- setName: the full English expansion name, if you recognise it. null otherwise.
- setCode: the short expansion code printed beside the collector number or in a bottom corner ("ME4", "PRE", "SVI"). null if not visible. Do not derive it from the set name.
- variant: which printing this is.
    * "Reverse Holofoil" - foil covers the whole card face including the border and text box, while the artwork box itself is plain.
    * "Holofoil" - foil is confined to the artwork box.
    * "Normal" - no foil anywhere.
    * "Unknown" - the photograph doesn't show enough to tell.
  Full-art, illustration-rare and secret-rare cards have no reverse printing; report those as "Holofoil".
- language: "japanese" when the card's own text is in Japanese, "english" when it is in English, "unknown" when the photograph doesn't show enough text to tell. Judge this from the card, not from the slab label, which is in English either way.
- grader: the grading company named on the slab label - "PSA", "CGC", "BGS", or the name as printed for any other company. null when the card is not in a slab.
- grade: the numeric grade printed on that label, as a string ("10", "9.5"). Report the number alone, without the company or the adjective beside it, so a "GEM MT 10" is "10" and a "CGC Pristine 10" is "10". null when the card is not in a slab, or when the label is not legible.
- confidence: "high" only when the name and the number are both plainly legible.
- notes: one short sentence, only when something is ambiguous or unreadable. null otherwise.`;
const IDENTIFY_SCHEMA = {
  type: "object", additionalProperties: false, required: ["cards"],
  properties: {
    cards: {
      type: "array",
      items: {
        type: "object", additionalProperties: false,
        required: ["name", "number", "setName", "setCode", "variant", "language", "grader", "grade", "confidence", "notes"],
        properties: {
          name: { type: "string" },
          number: { type: ["string", "null"] },
          setName: { type: ["string", "null"] },
          setCode: { type: ["string", "null"] },
          variant: { type: "string", enum: ["Normal", "Holofoil", "Reverse Holofoil", "Unknown"] },
          language: { type: "string", enum: ["english", "japanese", "unknown"] },
          // the company is a free string so an SGC or an ACE slab still reports
          // what it says; the app maps the ones it knows and shows the rest
          grader: { type: ["string", "null"] },
          grade: { type: ["string", "null"] },
          confidence: { type: "string", enum: ["high", "medium", "low"] },
          notes: { type: ["string", "null"] },
        },
      },
    },
  },
};
async function identifyCards(image, mediaType, mode) {
  const ctl = new AbortController();
  // API Gateway cuts the integration off at 30s, so abort first — otherwise a
  // hung call surfaces as an opaque gateway 504 with nothing in the log
  const timer = setTimeout(() => ctl.abort(), 25000);
  let r;
  try {
    r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      signal: ctl.signal,
      headers: {
        "x-api-key": process.env.ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: IDENTIFY_MODEL,
        max_tokens: mode === "page" ? 4096 : 1024,
        system: IDENTIFY_SYSTEM,
        // constrains the reply to IDENTIFY_SCHEMA — still needs parsing, but
        // can't come back as prose or a fenced code block
        output_config: { format: { type: "json_schema", schema: IDENTIFY_SCHEMA } },
        messages: [{
          role: "user",
          content: [
            { type: "image", source: { type: "base64", media_type: mediaType, data: image } },
            { type: "text", text: mode === "page" ? "Identify every card in this photograph, in reading order." : "Identify this card." },
          ],
        }],
      }),
    });
  } finally { clearTimeout(timer); }
  if (!r.ok) {
    const e = new Error(`anthropic HTTP ${r.status}`);
    e.status = r.status;
    e.detail = (await r.text().catch(() => "")).slice(0, 300); // logged only, never returned
    throw e;
  }
  const msg = await r.json();
  // both of these bypass the schema guarantee, so check before parsing
  if (msg.stop_reason === "refusal" || msg.stop_reason === "max_tokens") {
    const e = new Error(`stop_reason ${msg.stop_reason}`); e.unreadable = true; throw e;
  }
  let parsed;
  try { parsed = JSON.parse((msg.content || []).find((b) => b.type === "text")?.text || ""); }
  catch { const e = new Error("unparsable reply"); e.unreadable = true; throw e; }
  return {
    cards: Array.isArray(parsed?.cards) ? parsed.cards : [],
    usage: msg.usage ? { input_tokens: msg.usage.input_tokens, output_tokens: msg.usage.output_tokens } : null,
  };
}

export const handler = async (event) => {
  const method = event.requestContext?.http?.method;
  // CORS preflight must get a 2xx; API Gateway injects the CORS headers
  if (method === "OPTIONS") return { statusCode: 204 };

  /* Everything below spends someone's money — PPT credits on the card
     routes, Anthropic tokens on /identify — so nothing answers without the
     sync token. CORS never guarded these (curl doesn't send an Origin); the
     token does. */
  if (!authed(event)) return res(401, { error: "unauthorized" });

  const qp = event.queryStringParameters || {};
  const lang = qp.lang === "jp" ? "jp" : "en";
  const isGet = (p) => method === "GET" && event.rawPath?.endsWith(p);
  if ((isGet("/sets") || isGet("/prices") || isGet("/catalog") || isGet("/search") || isGet("/graded") || isGet("/history")) && !process.env.PPT_KEY)
    return res(501, { error: "card data not configured" });

  if (isGet("/sets")) {
    try {
      const { list } = await pptSets(lang);
      // "SV07: Stellar Crown" -> "Stellar Crown": the dropdowns and the
      // ledger speak plain set names; pptSetData's fold matching resolves
      // them back to the prefixed ones
      const seen = new Set(); const names = [];
      for (const s of list) {
        const n = s.name.replace(/^\w{1,7}:\s+/, "");
        if (!seen.has(n)) { seen.add(n); names.push(n); }
      }
      return res(200, { names });
    } catch (e) {
      console.error("sets route failed:", e);
      return res(e.status === 429 ? 429 : 502, { error: e.status === 429 ? "daily card-data budget used" : "set list unavailable" });
    }
  }

  if (isGet("/prices")) {
    if (!qp.set) return res(400, { error: "set required" });
    try { const body = await setPrices(qp.set, lang); return body ? res(200, body) : res(404, { error: "set not found" }); }
    catch (e) {
      console.error("prices route failed:", e);
      return res(e.status === 429 ? 429 : 502, { error: e.status === 429 ? "daily card-data budget used" : "price source unavailable" });
    }
  }

  if (isGet("/catalog")) {
    if (!qp.set) return res(400, { error: "set required" });
    try { const body = await setCatalog(qp.set, lang); return body ? res(200, body) : res(404, { error: "set not found" }); }
    catch (e) {
      console.error("catalog route failed:", e);
      return res(e.status === 429 ? 429 : 502, { error: e.status === 429 ? "daily card-data budget used" : "catalog source unavailable" });
    }
  }

  if (isGet("/search")) {
    if (!qp.q) return res(400, { error: "q required" });
    try { return res(200, { cards: await cardSearch(qp.q, qp.set || "", qp.number || "", lang) }); }
    catch (e) {
      console.error("search route failed:", e);
      return res(e.status === 429 ? 429 : 502, { error: e.status === 429 ? "daily card-data budget used" : "card search unavailable" });
    }
  }

  if (isGet("/graded")) {
    if (!qp.name) return res(400, { error: "name required" });
    try {
      const body = await gradedPrices(qp.name, qp.number || "", qp.set || "", lang, qp.productId || "");
      // any sales signal counts — a card with only CGC/TAG or raw solds is
      // still worth returning even when no PSA grade has data
      const hasData = body && (Object.keys(body.grades).length || Object.keys(body.byGrade).length || body.raw);
      return hasData ? res(200, body) : res(404, { error: "no graded comps" });
    } catch (e) {
      console.error("graded route failed:", e);
      if (e.status === 429) return res(429, { error: "daily comps budget used" });
      return res(502, { error: "graded price source unavailable" });
    }
  }

  if (isGet("/history")) {
    const days = Math.min(Math.max(Number(qp.days) || 90, 7), 180);
    try {
      const pid = qp.productId || await resolveProductId(qp.name || "", qp.number || "", qp.set || "", lang);
      if (!pid) return res(404, { error: "card not resolved" });
      const body = await priceHistory(pid, days, lang);
      return body ? res(200, body) : res(404, { error: "no price history" });
    } catch (e) {
      console.error("history route failed:", e);
      if (e.status === 429) return res(429, { error: "daily card-data budget used" });
      return res(502, { error: "price history unavailable" });
    }
  }

  // must be method-scoped: the ledger GET below matches any authed GET
  // regardless of path
  if (method === "POST" && event.rawPath?.endsWith("/identify")) {
    if (!process.env.ANTHROPIC_API_KEY) return res(501, { error: "card scanning not configured" });
    let body;
    try {
      const raw = event.isBase64Encoded ? Buffer.from(event.body || "", "base64").toString("utf8") : event.body || "";
      body = JSON.parse(raw);
    } catch { return res(400, { error: "bad json" }); }
    const { image, media_type: mediaType = "image/jpeg", mode = "single" } = body || {};
    if (typeof image !== "string" || !image || !MEDIA_TYPES.has(mediaType)) return res(400, { error: "bad payload" });
    if (image.length > MAX_IMAGE_B64) return res(413, { error: "image too large" });
    try {
      const out = await identifyCards(image, mediaType, mode);
      return out.cards.length ? res(200, out) : res(422, { error: "couldn't read that card — retake the photo" });
    } catch (e) {
      // the upstream body can name the key or the account; log it, never return it
      console.error("identify route failed:", e.status || "", e.message, e.detail || "");
      if (e.unreadable) return res(422, { error: "couldn't read that card — retake the photo" });
      if (e.status === 429) return res(429, { error: "scan rate limit — try again in a moment" });
      return res(502, { error: "card scanner unavailable" });
    }
  }

  if (method === "GET") {
    const r = await ddb.send(new GetCommand({ TableName: TABLE, Key: { id: ID } }));
    if (!r.Item) return res(404, { error: "empty" });
    // conditional pull: client sends the stamp it has; identical -> tiny 204 instead of the blob
    if (Number(event.queryStringParameters?.since) === r.Item.updatedAt) return { statusCode: 204 };
    return res(200, { updatedAt: r.Item.updatedAt, data: r.Item.data });
  }

  if (method === "PUT") {
    let body;
    try { body = JSON.parse(event.body || ""); } catch { return res(400, { error: "bad json" }); }
    const { updatedAt, data } = body;
    if (typeof updatedAt !== "number" || typeof data !== "string" || data.length > MAX_BYTES)
      return res(400, { error: "bad payload" });
    try {
      await ddb.send(new PutCommand({
        TableName: TABLE,
        Item: { id: ID, updatedAt, data },
        ConditionExpression: "attribute_not_exists(id) OR updatedAt <= :ts",
        ExpressionAttributeValues: { ":ts": updatedAt },
      }));
    } catch (e) {
      if (e.name === "ConditionalCheckFailedException") return res(409, { error: "stale" });
      throw e;
    }
    return res(200, { ok: true });
  }

  return res(405, { error: "method not allowed" });
};
