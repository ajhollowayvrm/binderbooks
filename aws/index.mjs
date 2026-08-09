// BinderBooks sync API — runs as AWS Lambda "binderbooks-sync" (us-west-2)
// behind API Gateway HTTP API "j18dixq7ei" ($default route, payload v2).
// The whole ledger is one JSON blob in the "binderbooks" DynamoDB table;
// writes are conditional on updatedAt so an out-of-date device gets a 409
// instead of clobbering newer data.
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

/* GET /prices?set=<name> — pokemontcg.io stopped publishing prices for sets
   after Nov 2025, so this proxies TCGplayer market prices from tcgcsv.com's
   daily dump (which has no CORS headers, hence the server-side hop) and
   returns { prices: { cardNumber: market } } for the set. */
const PRICE_TTL = 6 * 3600 * 1000;
const priceCache = new Map();
let groupsCache = null;
// some CDNs reject UA-less requests from cloud IPs; send a normal browser UA
const TCGCSV_HEADERS = { "user-agent": "Mozilla/5.0 (BinderBooks price sync; personal use)" };
const normNum = (s) => String(s).split("/")[0].trim().replace(/^0+(?=\w)/, "").toUpperCase();
// pokemontcg.io promo-set names ("SWSH Black Star Promos") share no usable
// suffix with TCGplayer's group names, so those eras get explicit aliases
const GROUP_ALIASES = [
  [/scarlet.*violet.*(black star|promo)/, "sv: scarlet & violet promo cards"],
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
// one price out of a card's per-printing map, for callers that want a single
// number. The client picks a printing deliberately when it knows the card's
// variant; this is the "don't care" answer, and the order is load-bearing —
// it's the collapse /prices has always returned.
const collapse = (sub) => (sub ? sub["Normal"] ?? sub["Holofoil"] ?? Object.values(sub)[0] ?? null : null);
async function setData(setName) {
  const key = setName.toLowerCase();
  const hit = priceCache.get(key);
  if (hit && Date.now() - hit.t < PRICE_TTL) return hit;
  if (!groupsCache || Date.now() - groupsCache.t > PRICE_TTL) {
    const gr = await fetch("https://tcgcsv.com/tcgplayer/3/groups", { headers: TCGCSV_HEADERS });
    if (!gr.ok) throw new Error(`groups HTTP ${gr.status}`);
    const g = await gr.json();
    groupsCache = { t: Date.now(), list: g.results || [] };
  }
  const alias = GROUP_ALIASES.find(([re]) => re.test(key))?.[1];
  const group = (alias && groupsCache.list.find((x) => x.name.toLowerCase() === alias))
    || groupsCache.list.find((x) => x.name.toLowerCase().endsWith(key))
    || groupsCache.list.find((x) => x.name.toLowerCase().includes(key));
  if (!group) return null;
  const [prods, prices] = await Promise.all([
    fetch(`https://tcgcsv.com/tcgplayer/3/${group.groupId}/products`, { headers: TCGCSV_HEADERS }).then((r) => { if (!r.ok) throw new Error(`products HTTP ${r.status}`); return r.json(); }),
    fetch(`https://tcgcsv.com/tcgplayer/3/${group.groupId}/prices`, { headers: TCGCSV_HEADERS }).then((r) => { if (!r.ok) throw new Error(`prices HTTP ${r.status}`); return r.json(); }),
  ]);
  const byProd = {};
  for (const p of prices.results || []) {
    if (p.marketPrice == null) continue;
    (byProd[p.productId] ||= {})[p.subTypeName] = p.marketPrice;
  }
  const products = [];
  for (const pr of prods.results || []) {
    const ext = (pr.extendedData || []).find((d) => d.name === "Number"); // absent on sealed products
    if (!ext) continue;
    const rar = (pr.extendedData || []).find((d) => d.name === "Rarity");
    const sub = byProd[pr.productId];
    products.push({ id: pr.productId, name: pr.name, num: nameNum(pr.name) || ext.value, extNum: ext.value, rarity: rar?.value || "", market: collapse(sub), subs: sub || null });
  }
  const data = { t: Date.now(), group: group.name, products };
  priceCache.set(key, data);
  return data;
}
async function setPrices(setName) {
  const d = await setData(setName);
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
  priced.filter((p) => /\[|\(prerelease\)/i.test(p.name)).forEach((p) => assign(p, false));
  priced.filter((p) => !/\[|\(prerelease\)/i.test(p.name)).forEach((p) => assign(p, true));
  // `prices` stays a flat { number: market } map. Clients running a cached
  // bundle read it straight into a card's value, and would write NaN — and
  // then sync it — if these became objects. Derived from `subs` rather than
  // tracked alongside, so the two can never disagree about a slot.
  const out = {};
  for (const n of Object.keys(subs)) out[n] = collapse(subs[n]);
  return { set: setName, group: d.group, prices: out, subs };
}
/* GET /catalog?set=<name> — the singles in a set straight from TCGplayer's
   catalog (via tcgcsv): name, number, rarity, market. Newly released cards
   land here days before pokemontcg.io knows them, so the app's Lookup tab
   falls back to this when its card database comes up empty. */
async function setCatalog(setName) {
  const d = await setData(setName);
  if (!d) return null;
  return { set: setName, group: d.group, cards: d.products.map((p) => ({ name: p.name, num: p.num, rarity: p.rarity, market: p.market, subs: p.subs })) };
}

/* GET /graded?name=<card>&number=<num>&set=<set> — eBay-sold comps for PSA
   grades from pokemonpricetracker.com (Bearer key in PPT_KEY env var; free
   tier is 100 credits/day and a 5-card lookup with eBay data costs 10, so
   results are cached hard). Returns { card, set, number, market, grades }
   where grades is { "10": avg, "9": avg, ... } for whatever grades have
   recorded sales, plus the card-detail extras the app's card modal shows:
   byGrade (every company+grade bucket, e.g. "cgc9_5"), raw (ungraded solds),
   window (the date range the sales cover), image and url (TCGplayer CDN). */
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
async function gradedPrices(name, number, set) {
  const key = `${name}|${number}|${set}`.toLowerCase();
  const hit = gradedCache.get(key);
  if (hit && Date.now() - hit.t < GRADED_TTL) return hit.body;
  const ppt = async (params) => {
    const u = new URL("https://www.pokemonpricetracker.com/api/v2/cards");
    for (const [k, v] of Object.entries(params)) u.searchParams.set(k, v);
    u.searchParams.set("includeEbay", "true");
    const r = await fetch(u, { headers: { authorization: `Bearer ${process.env.PPT_KEY}` } });
    if (!r.ok) { const e = new Error(`ppt HTTP ${r.status}`); e.status = r.status; throw e; }
    const data = await r.json();
    // searches return a list but id lookups return one bare card object —
    // normalize both to an array
    const cards = data.cards ?? data.data ?? data;
    return Array.isArray(cards) ? cards : cards && typeof cards === "object" ? [cards] : [];
  };
  // cheapest path first: resolve the card to its TCGplayer product id via the
  // set dump we already cache, then ask PPT for exactly that card — 2 credits
  // (one card with eBay data) instead of a 3-candidate name search's 6, and
  // no chance of comps from the wrong printing
  let cards = [];
  if (set && number) {
    let tcgpId = null;
    try {
      const d = await setData(set);
      if (d) {
        const want = normNum(number);
        const clean = d.products.filter((p) => p.id && !/\[|\(prerelease\)/i.test(p.name));
        const prod = clean.find((p) => normNum(p.num) === want) || clean.find((p) => normNum(p.extNum) === want);
        if (prod) tcgpId = prod.id;
      }
    } catch {} // dump unavailable — the name search below still works
    if (tcgpId) {
      const got = await ppt({ tcgPlayerId: String(tcgpId) });
      // trust but verify: if PPT ever ignores the filter, don't accept arbitrary cards
      cards = got.filter((c) => String(c.tcgPlayerId ?? "") === String(tcgpId));
      // a shape/field mismatch here silently triples the lookup cost — make it visible
      if (!cards.length) console.log(`graded: id lookup ${tcgpId} unusable, falling back to name search:`, JSON.stringify(got).slice(0, 300));
    }
  }
  if (!cards.length) {
    // name search: each returned card costs 2 credits with eBay data — limit 3
    // keeps a lookup at 6 credits
    cards = await ppt({ search: name, ...(set ? { set } : {}), limit: "3" });
    // a set name PPT doesn't recognize shouldn't sink the lookup
    if (!cards.length && set) cards = await ppt({ search: name, limit: "3" });
  }
  const cardNum = (c) => normNum(c.number ?? c.cardNumber ?? "");
  const want = number ? normNum(number) : null;
  const match = (want && cards.find((c) => cardNum(c) === want)) || cards[0];
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
   it. Unlike the price routes this one costs money per call, so it lives
   behind the token wall. Always answers with { cards: [...] }, even for one
   card, so scanning a whole binder page later is a prompt change rather than
   a new response shape. */
const IDENTIFY_MODEL = "claude-haiku-4-5";
const MAX_IMAGE_B64 = 5 * 1024 * 1024; // Lambda caps the whole request at 6MB
const MEDIA_TYPES = new Set(["image/jpeg", "image/png", "image/webp"]);
const IDENTIFY_SYSTEM = `You identify Pokémon trading cards from photographs for a collector's inventory app.

Report only what is actually visible on the card. Never infer a collector number or a set from the card's name.

- name: the card name exactly as printed, without the set, the number, or any variant wording.
- number: the collector number exactly as printed, including the denominator when one is shown ("095/086", "TG12/TG30", "SV107"). null if unreadable.
- setName: the full English expansion name, if you recognise it. null otherwise.
- setCode: the short expansion code printed beside the collector number or in a bottom corner ("ME4", "PRE", "SVI"). null if not visible. Do not derive it from the set name.
- variant: which printing this is.
    * "Reverse Holofoil" - foil covers the whole card face including the border and text box, while the artwork box itself is plain.
    * "Holofoil" - foil is confined to the artwork box.
    * "Normal" - no foil anywhere.
    * "Unknown" - the photograph doesn't show enough to tell.
  Full-art, illustration-rare and secret-rare cards have no reverse printing; report those as "Holofoil".
- confidence: "high" only when the name and the number are both plainly legible.
- notes: one short sentence, only when something is ambiguous or unreadable. null otherwise.`;
const IDENTIFY_SCHEMA = {
  type: "object", additionalProperties: false, required: ["cards"],
  properties: {
    cards: {
      type: "array",
      items: {
        type: "object", additionalProperties: false,
        required: ["name", "number", "setName", "setCode", "variant", "confidence", "notes"],
        properties: {
          name: { type: "string" },
          number: { type: ["string", "null"] },
          setName: { type: ["string", "null"] },
          setCode: { type: ["string", "null"] },
          variant: { type: "string", enum: ["Normal", "Holofoil", "Reverse Holofoil", "Unknown"] },
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

  // public market data, deliberately outside the token wall — the app needs
  // prices even on devices that haven't connected to sync
  if (method === "GET" && event.rawPath?.endsWith("/prices")) {
    const setName = event.queryStringParameters?.set;
    if (!setName) return res(400, { error: "set required" });
    try { const body = await setPrices(setName); return body ? res(200, body) : res(404, { error: "set not found" }); }
    catch (e) { console.error("prices route failed:", e); return res(502, { error: "price source unavailable" }); }
  }

  // also public market data, same deal as /prices
  if (method === "GET" && event.rawPath?.endsWith("/catalog")) {
    const setName = event.queryStringParameters?.set;
    if (!setName) return res(400, { error: "set required" });
    try { const body = await setCatalog(setName); return body ? res(200, body) : res(404, { error: "set not found" }); }
    catch (e) { console.error("catalog route failed:", e); return res(502, { error: "catalog source unavailable" }); }
  }

  // also public market data, same deal as /prices
  if (method === "GET" && event.rawPath?.endsWith("/graded")) {
    if (!process.env.PPT_KEY) return res(501, { error: "graded prices not configured" });
    const { name, number, set } = event.queryStringParameters || {};
    if (!name) return res(400, { error: "name required" });
    try {
      const body = await gradedPrices(name, number || "", set || "");
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

  if (!authed(event)) return res(401, { error: "unauthorized" });

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
