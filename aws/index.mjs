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
async function setPrices(setName) {
  const key = setName.toLowerCase();
  const hit = priceCache.get(key);
  if (hit && Date.now() - hit.t < PRICE_TTL) return hit.body;
  if (!groupsCache || Date.now() - groupsCache.t > PRICE_TTL) {
    const gr = await fetch("https://tcgcsv.com/tcgplayer/3/groups", { headers: TCGCSV_HEADERS });
    if (!gr.ok) throw new Error(`groups HTTP ${gr.status}`);
    const g = await gr.json();
    groupsCache = { t: Date.now(), list: g.results || [] };
  }
  const group = groupsCache.list.find((x) => x.name.toLowerCase().endsWith(key))
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
  const out = {};
  for (const pr of prods.results || []) {
    const num = (pr.extendedData || []).find((d) => d.name === "Number"); // absent on sealed products
    const sub = num && byProd[pr.productId];
    if (!sub) continue;
    const val = sub["Normal"] ?? sub["Holofoil"] ?? Object.values(sub)[0];
    if (val != null) out[normNum(num.value)] = val;
  }
  const body = { set: setName, group: group.name, prices: out };
  priceCache.set(key, { t: Date.now(), body });
  return body;
}

/* GET /graded?name=<card>&number=<num>&set=<set> — eBay-sold comps for PSA
   grades from pokemonpricetracker.com (Bearer key in PPT_KEY env var; free
   tier is 100 credits/day and a 5-card lookup with eBay data costs 10, so
   results are cached hard). Returns { card, set, number, market, grades }
   where grades is { "10": avg, "9": avg, ... } for whatever grades have
   recorded sales. */
const GRADED_TTL = 24 * 3600 * 1000;
const gradedCache = new Map();
async function gradedPrices(name, number, set) {
  const key = `${name}|${number}|${set}`.toLowerCase();
  const hit = gradedCache.get(key);
  if (hit && Date.now() - hit.t < GRADED_TTL) return hit.body;
  const u = new URL("https://www.pokemonpricetracker.com/api/v2/cards");
  u.searchParams.set("search", name);
  if (set) u.searchParams.set("set", set);
  u.searchParams.set("includeEbay", "true");
  u.searchParams.set("limit", "5");
  const r = await fetch(u, { headers: { authorization: `Bearer ${process.env.PPT_KEY}` } });
  if (!r.ok) throw new Error(`ppt HTTP ${r.status}`);
  const data = await r.json();
  const cards = data.cards || data.data || (Array.isArray(data) ? data : []);
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
  const body = {
    card: match.name,
    number: match.number ?? match.cardNumber ?? null,
    set: match.setName ?? match.set?.name ?? (typeof match.set === "string" ? match.set : null),
    market: match.prices?.market ?? null,
    grades,
    sales,
  };
  gradedCache.set(key, { t: Date.now(), body });
  return body;
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
  if (method === "GET" && event.rawPath?.endsWith("/graded")) {
    if (!process.env.PPT_KEY) return res(501, { error: "graded prices not configured" });
    const { name, number, set } = event.queryStringParameters || {};
    if (!name) return res(400, { error: "name required" });
    try {
      const body = await gradedPrices(name, number || "", set || "");
      return body && Object.keys(body.grades).length ? res(200, body) : res(404, { error: "no graded comps" });
    } catch (e) { console.error("graded route failed:", e); return res(502, { error: "graded price source unavailable" }); }
  }

  if (!authed(event)) return res(401, { error: "unauthorized" });

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
