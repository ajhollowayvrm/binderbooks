/* ==================================================================
   TCGplayer catalog — identity, not our own taxonomy.

   BinderBooks used to describe a card with name + set + number + a
   `variant` string, then guess which TCGplayer SKU that meant at export
   time. That guess cannot represent a Prize Pack stamp or a Master Ball
   pattern, because TCGplayer models those as separate products rather
   than as attributes of one:

     Air Balloon - 079/086 (Cosmos Holo)   -> 9122382
     Fezandipiti (Master Ball Pattern)     -> 8490488

   So we stop inventing a taxonomy and store TCGplayer's rows instead.
   The file we import is a Pricing Custom Export, which is the same 16
   columns we upload back — one schema, no mapping layer.

   Storage is IndexedDB, not localStorage. A full catalog is tens of MB
   and localStorage caps out around 5 MB; the set-export cache in
   App.jsx already has an eviction loop because of it. IndexedDB is also
   per-device and never syncs, which is what we want — the sync backend
   stores the whole ledger as one DynamoDB item with a 400 KB cap.
   ================================================================== */
import Papa from "papaparse";

const DB_NAME = "binderbooks-catalog";
const DB_VERSION = 1;
const STORE = "catalog";
const META = "meta";

/* The export's 16 columns, in order. Download and upload share this
   list — that is the whole reason we chose this export shape. */
export const CSV_COLUMNS = [
  "TCGplayer Id", "Product Line", "Set Name", "Product Name", "Title", "Number",
  "Rarity", "Condition", "TCG Market Price", "TCG Direct Low",
  "TCG Low Price With Shipping", "TCG Low Price", "Total Quantity",
  "Add to Quantity", "TCG Marketplace Price", "Photo URL",
];
/* A file missing any of these cannot be a pricing export. We check the
   header before we write a single row, so a wrong file fails loudly
   instead of importing zero rows and looking like a no-op. */
const REQUIRED_COLUMNS = ["TCGplayer Id", "Set Name", "Product Name", "Condition"];

export const PRINTINGS = ["Normal", "Holofoil", "Reverse Holofoil"];
/* Import keeps Near Mint only: the seller rips what he sells, so stock
   is pack-fresh. `grade` stays a real field rather than a constant,
   because a damaged pull is a different SKU, not a schema change. */
const KEEP_GRADE = "Near Mint";

/* ------------------------------------------------------------------ */
/* Condition splits into two things                                    */
/* ------------------------------------------------------------------ */
/* `Condition` carries grade and printing in one field: "Near Mint",
   "Near Mint Holofoil", "Near Mint Reverse Holofoil". Split on the way
   in and recombine on the way out, so the round trip is lossless.
   Order matters — "Reverse Holofoil" must be tested before "Holofoil",
   or every reverse row reads as a holo. */
export function splitCondition(condition) {
  const raw = String(condition || "").trim();
  if (!raw) return null;
  for (const printing of ["Reverse Holofoil", "Holofoil"]) {
    if (raw.toLowerCase().endsWith(printing.toLowerCase())) {
      const grade = raw.slice(0, raw.length - printing.length).trim();
      return grade ? { grade, printing } : null;
    }
  }
  return { grade: raw, printing: "Normal" };
}
/* Normal renders as an empty printing, which is how the export writes
   it — "Near Mint", not "Near Mint Normal". */
export const joinCondition = (grade, printing) =>
  printing && printing !== "Normal" ? `${grade} ${printing}` : grade;

/* ------------------------------------------------------------------ */
/* Row -> record                                                       */
/* ------------------------------------------------------------------ */
/* Collector numbers arrive as "079/086" and as "079". Match on the part
   before the slash with leading zeros stripped, so a typed "79" finds
   both. This mirrors normNum in App.jsx deliberately: catalog.js must
   not import from App.jsx, and the two must agree on what a number is. */
const normNum = (s) => String(s || "").split("/")[0].trim().replace(/^0+(?=\w)/, "").toUpperCase();

const num = (v) => {
  const s = String(v ?? "").trim();
  if (!s) return null;
  const n = Number(s);
  return Number.isFinite(n) ? n : null;
};

/* Search tokens. Everything that is not a letter or a digit is a
   separator, so "Air Balloon - 079/086 (Cosmos Holo)" yields
   ["air","balloon","079","86","cosmos","holo"] — the parenthetical
   variant is searchable, which is what lets "master ball" pick the
   Master Ball printing out of five products sharing a number. */
const tokenize = (s) =>
  String(s || "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim().split(/\s+/).filter(Boolean);

/* A zero-padded number token also indexes unpadded, so typing "4" finds
   "004". We index both rather than normalising to one, because the user
   may type either and prefix search cannot strip zeros at query time. */
const numberForms = (t) => (/^0\d+$/.test(t) ? [t, t.replace(/^0+/, "")] : [t]);

/* The set is a token like any other, under a prefix that a real token
   can never produce (tokenize() emits only [a-z0-9]). That lets a
   set-scoped search intersect at the index instead of fetching records
   and filtering them — one seek, no scan. */
const setToken = (setKey) => `set:${setKey}`;

function buildTokens(rec) {
  const out = new Set([setToken(rec.set_key)]);
  /* On a C- listing the seller's own Title holds the real name; the
     catalog Product Name is the sealed card's. Index both. */
  for (const field of [rec.product_name, rec.title]) {
    for (const t of tokenize(field)) for (const f of numberForms(t)) out.add(f);
  }
  for (const t of tokenize(rec.number)) for (const f of numberForms(t)) out.add(f);
  return [...out];
}

/* One CSV row -> one stored record, or null when the row is not one we
   keep. Returning null rather than throwing keeps a malformed line from
   aborting an import of 70,000 good ones. */
export function rowToRecord(row, seenAt) {
  const id = String(row["TCGplayer Id"] ?? "").trim();
  if (!id) return null;
  const split = splitCondition(row["Condition"]);
  if (!split || split.grade !== KEEP_GRADE) return null;

  const setName = String(row["Set Name"] ?? "").trim();
  const number = String(row["Number"] ?? "").trim();
  const rec = {
    tcgplayer_id: id,
    product_line: String(row["Product Line"] ?? "").trim(),
    set_name: setName,
    product_name: String(row["Product Name"] ?? "").trim(),
    number,                                   // NOT unique within a set
    rarity: String(row["Rarity"] ?? "").trim() || null,
    grade: split.grade,
    printing: split.printing,
    market_price: num(row["TCG Market Price"]),
    direct_low: num(row["TCG Direct Low"]),
    low_with_ship: num(row["TCG Low Price With Shipping"]),
    low_price: num(row["TCG Low Price"]),
    /* A custom listing is one physical graded card the seller already
       owns, photographed and titled by him. It has no catalog price and
       must never take Add to Quantity — that would double-sell the one
       card in the slab. Flag it here; the listing path is separate work. */
    is_custom: /^C-/i.test(id) ? 1 : 0,
    title: String(row["Title"] ?? "").trim() || null,
    photo_url: String(row["Photo URL"] ?? "").trim() || null,
    last_seen_at: seenAt,
    set_key: setName.toLowerCase(),
    number_norm: normNum(number),
  };
  rec.tokens = buildTokens(rec);
  return rec;
}

/* Record -> CSV row. `Total Quantity` stays blank on purpose: it is
   absolute, and writing it would overwrite live stock with whatever we
   happened to know. `Add to Quantity` is additive and is the safe one. */
export function recordToRow(rec, { addQty = 0, price = null } = {}) {
  const money = (v) => (v == null ? "" : String(v));
  return {
    "TCGplayer Id": rec.tcgplayer_id,
    "Product Line": rec.product_line,
    "Set Name": rec.set_name,
    "Product Name": rec.product_name,
    "Title": rec.title || "",
    "Number": rec.number || "",
    "Rarity": rec.rarity || "",
    "Condition": joinCondition(rec.grade, rec.printing),
    "TCG Market Price": money(rec.market_price),
    "TCG Direct Low": money(rec.direct_low),
    "TCG Low Price With Shipping": money(rec.low_with_ship),
    "TCG Low Price": money(rec.low_price),
    "Total Quantity": "",
    "Add to Quantity": String(addQty),
    "TCG Marketplace Price": price == null ? "" : Number(price).toFixed(2),
    "Photo URL": rec.photo_url || "",
  };
}

/* ------------------------------------------------------------------ */
/* IndexedDB                                                           */
/* ------------------------------------------------------------------ */
let dbPromise = null;

export function openCatalog() {
  if (dbPromise) return dbPromise;
  dbPromise = new Promise((resolve, reject) => {
    if (typeof indexedDB === "undefined") { reject(new Error("This browser has no IndexedDB.")); return; }
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(STORE)) {
        const store = db.createObjectStore(STORE, { keyPath: "tcgplayer_id" });
        store.createIndex("by_set", ["set_key", "number_norm"]);
        store.createIndex("by_line", "product_line");
        /* multiEntry makes IndexedDB maintain the inverted index for
           us: one entry per token per record, so a prefix range over
           this index is the full-text search. */
        store.createIndex("by_token", "tokens", { multiEntry: true });
      }
      if (!db.objectStoreNames.contains(META)) db.createObjectStore(META, { keyPath: "k" });
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error || new Error("Could not open the catalog database."));
    /* Another tab holding an old version blocks the upgrade. Say so
       rather than hanging on a promise that never settles. */
    req.onblocked = () => reject(new Error("Close the other BinderBooks tabs and try again."));
  });
  return dbPromise;
}

const txDone = (tx) => new Promise((resolve, reject) => {
  tx.oncomplete = () => resolve();
  tx.onerror = () => reject(tx.error);
  tx.onabort = () => reject(tx.error || new Error("The catalog write was aborted."));
});
const reqDone = (req) => new Promise((resolve, reject) => {
  req.onsuccess = () => resolve(req.result);
  req.onerror = () => reject(req.error);
});

const metaGet = async (db, k) => (await reqDone(db.transaction(META, "readonly").objectStore(META).get(k)))?.v ?? null;
async function metaSet(db, k, v) {
  const tx = db.transaction(META, "readwrite");
  tx.objectStore(META).put({ k, v });
  await txDone(tx);
}

/* ------------------------------------------------------------------ */
/* Import                                                              */
/* ------------------------------------------------------------------ */
/* Stream the file and write in batches. A full-catalog export is far
   too big to hold as one parsed array, and the phone is the device most
   likely to be asked to do it. Papa hands us chunks; we pause the
   parser while each batch commits, so memory stays flat no matter how
   large the file is. */
const BATCH = 500;

async function writeBatch(db, records) {
  const tx = db.transaction(STORE, "readwrite");
  const store = tx.objectStore(STORE);
  /* put() is an upsert on tcgplayer_id. We never delete: a product
     missing from a later export means it was not in that pull, not that
     it stopped existing. Running the same file twice therefore changes
     nothing except last_seen_at, which is what "idempotent" means here. */
  for (const rec of records) store.put(rec);
  await txDone(tx);
}

/* Import one Pricing Custom Export. Resolves with what it did, so the
   UI can report it; rejects only on a file we cannot use at all. */
export function importCatalogFile(file, { onProgress } = {}) {
  return new Promise((resolve, reject) => {
    openCatalog().then((db) => {
      const seenAt = new Date().toISOString();
      const setNames = {};          // set_key -> the export's own casing
      let kept = 0, skipped = 0, headerChecked = false, failed = null;

      const finish = async () => {
        if (failed) { reject(failed); return; }
        if (!kept) {
          reject(new Error("That file had no Near Mint rows with a TCGplayer Id. Re-export it from Seller Portal, Pricing, with out-of-stock rows included."));
          return;
        }
        try {
          /* Union the set list across imports. One export rarely covers
             every set, and forgetting the earlier ones would hide rows
             that are still in the store. */
          const known = (await metaGet(db, "sets")) || {};
          await metaSet(db, "sets", { ...known, ...setNames });
          await metaSet(db, "lastImport", { at: seenAt, kept, skipped, sets: Object.values(setNames).sort() });
          resolve({ kept, skipped, sets: Object.values(setNames).sort(), at: seenAt });
        } catch (e) { reject(e); }
      };

      Papa.parse(file, {
        header: true,
        skipEmptyLines: true,
        chunkSize: 1024 * 512,
        chunk: (results, parser) => {
          if (failed) return;
          if (!headerChecked) {
            headerChecked = true;
            const fields = results.meta?.fields || [];
            const missing = REQUIRED_COLUMNS.filter((c) => !fields.includes(c));
            if (missing.length) {
              failed = new Error(`That does not look like a TCGplayer pricing export. It is missing: ${missing.join(", ")}.`);
              parser.abort();
              return;
            }
          }
          const records = [];
          for (const row of results.data) {
            const rec = rowToRecord(row, seenAt);
            if (!rec) { skipped++; continue; }
            setNames[rec.set_key] = rec.set_name;
            records.push(rec);
          }
          if (!records.length) return;

          parser.pause();
          (async () => {
            for (let i = 0; i < records.length; i += BATCH) {
              await writeBatch(db, records.slice(i, i + BATCH));
            }
            kept += records.length;
            onProgress?.({ kept, skipped });
          })().then(() => parser.resume(), (e) => { failed = e; parser.abort(); });
        },
        complete: finish,
        error: (e) => reject(e instanceof Error ? e : new Error("Could not read that file.")),
      });
    }, reject);
  });
}

/* ------------------------------------------------------------------ */
/* Reads                                                               */
/* ------------------------------------------------------------------ */
/* A set's rows sort as ["setkey", number]. Appending ￿ to the key
   itself bounds the whole set without assuming anything about how
   number_norm sorts — including the 347 rows in the sample file that
   have no number at all. */
const setRange = (setKey) => IDBKeyRange.bound([setKey], [setKey + "￿"]);

/* Every set in the store, with a live row count. The count comes from
   the index rather than from a stored tally, so it cannot drift out of
   step with what an upsert actually wrote. */
export async function catalogSets() {
  const db = await openCatalog();
  const names = (await metaGet(db, "sets")) || {};
  const index = db.transaction(STORE, "readonly").objectStore(STORE).index("by_set");
  const out = await Promise.all(
    Object.entries(names).map(async ([key, name]) => ({ key, name, count: await reqDone(index.count(setRange(key))) })),
  );
  return out.filter((s) => s.count > 0).sort((a, b) => a.name.localeCompare(b.name));
}

export async function catalogStats() {
  const db = await openCatalog();
  const rows = await reqDone(db.transaction(STORE, "readonly").objectStore(STORE).count());
  return { rows, lastImport: await metaGet(db, "lastImport") };
}

export const getCatalogRecord = async (id) =>
  reqDone((await openCatalog()).transaction(STORE, "readonly").objectStore(STORE).get(String(id)));

export async function getCatalogRecords(ids) {
  const db = await openCatalog();
  const store = db.transaction(STORE, "readonly").objectStore(STORE);
  const rows = await Promise.all([...new Set(ids.map(String))].map((id) => reqDone(store.get(id))));
  return rows.filter(Boolean);
}

/* Every Near Mint row for one set, in the CSV row shape. This is what
   feeds the old name-scoring matcher in App.jsx, so cards that predate
   tcgplayerId keep exporting without a second cache to maintain.

   Every request goes out before the first await, on purpose: a readonly
   transaction commits as soon as its queue empties, so awaiting one
   request and then issuing the next can find the transaction already
   closed. Issue them all, then await. Same reason in the reads below. */
export async function catalogRowsForSets(setKeys) {
  const db = await openCatalog();
  const index = db.transaction(STORE, "readonly").objectStore(STORE).index("by_set");
  const batches = [...new Set(setKeys)].map((key) => reqDone(index.getAll(setRange(key))));
  return (await Promise.all(batches)).flatMap((recs) => recs.map((rec) => recordToRow(rec)));
}

const prefixRange = (t) => IDBKeyRange.bound(t, t + "￿");

/* ------------------------------------------------------------------ */
/* Search                                                              */
/* ------------------------------------------------------------------ */
/* Ranking. Two rows can be equally valid matches and only the
   parenthetical tells them apart, so the score has to prefer the plain
   product when the query says nothing about a variant — "Fezandipiti"
   must beat "Fezandipiti (Master Ball Pattern)" — while letting
   "fezandipiti master ball" flip that round. Extra words in the product
   name cost, exactly as tcgpNameScore does for the old matcher. */
function score(rec, tokens, raw) {
  const name = (rec.product_name || "").toLowerCase();
  const nameTokens = tokenize(rec.product_name);
  const want = new Set(tokens);
  let s = 0;
  if (raw && rec.number_norm && normNum(raw) === rec.number_norm) s += 100;
  if (raw && name.startsWith(raw.toLowerCase())) s += 40;
  for (const t of tokens) {
    if (nameTokens.some((n) => n === t)) s += 12;
    else if (nameTokens.some((n) => n.startsWith(t))) s += 8;
  }
  for (const n of nameTokens) if (!want.has(n) && !/^\d+$/.test(n)) s -= 1.5;
  return s;
}

/* Printing order within one product, so the three Near Mint rows of the
   same card always appear in the same order and the list does not
   reshuffle as the user types. */
const printingRank = (p) => PRINTINGS.indexOf(p);

/* Fetching a record per intersected id is the one unbounded cost here.
   Scoped to a set it never bites, but an unscoped "a" against a full
   catalog would match tens of thousands and lock the phone up, so the
   intersection is truncated before any record is read. */
const MAX_FETCH = 1500;

/* Ceilings for the substring fallback below. SCAN_HITS is well above any
   result list the caller renders, so scoring still has candidates to rank.
   SCAN_ROWS bounds the miss case — a query that matches nothing walks this
   many records and gives up rather than the whole catalog. */
const SCAN_HITS = 300;
const SCAN_ROWS = 50000;
let scanGen = 0; // bumps per substring scan; a cursor that sees a newer value stops

/* Scoped, prefix-matched search over the catalog.

   Every term intersects at the index — including the set, which is
   stored as a token — so a set-scoped query never fetches a record it
   is going to discard. An empty query with a set browses that set. */
export async function searchCatalog({ set = "", q = "", limit = 40, includeCustom = false } = {}) {
  const db = await openCatalog();
  const raw = String(q || "").trim();
  const tokens = tokenize(raw).flatMap(numberForms);
  const setKey = String(set || "").toLowerCase().trim();

  if (!setKey && !tokens.length) return [];
  /* One character with no set to narrow it is not a search, it is a
     scan of the whole catalog. Ask for a second character instead. */
  if (!setKey && raw.length < 2) return [];

  /* One transaction for the index lookups, with every request issued
     before the first await so the transaction cannot commit underneath
     them. The record reads below take a fresh transaction of their own. */
  const index = db.transaction(STORE, "readonly").objectStore(STORE).index("by_token");
  const ranges = [
    ...(setKey ? [IDBKeyRange.only(setToken(setKey))] : []),
    ...tokens.map(prefixRange),
  ];
  const lists = await Promise.all(ranges.map((r) => reqDone(index.getAllKeys(r))));

  /* Intersect smallest-first: the rarest term does the narrowing, so a
     common word like "energy" never drives the cost. */
  lists.sort((a, b) => a.length - b.length);
  let ids = lists[0] || [];
  for (let i = 1; i < lists.length && ids.length; i++) {
    const next = new Set(lists[i]);
    ids = ids.filter((id) => next.has(id));
  }

  let recs;
  if (ids.length) {
    const store = db.transaction(STORE, "readonly").objectStore(STORE);
    recs = (await Promise.all(ids.slice(0, MAX_FETCH).map((id) => reqDone(store.get(id))))).filter(Boolean);
  } else if (tokens.length) {
    /* The token index is prefix-only. "zard" finds nothing, but Charizard is
       in the catalog. When the prefixes return nothing, fall back to a
       substring scan. A set scopes the cursor to that set, so the scan is a
       few hundred rows. Without a set the cursor walks the catalog. Three
       limits bound that walk: it stops after SCAN_HITS matches, after
       SCAN_ROWS rows when the query matches nothing, and as soon as a newer
       query starts — an abandoned scan must not run to the end of the store
       on the main thread while the next keystroke's scan begins. */
    const gen = ++scanGen;
    const store = db.transaction(STORE, "readonly").objectStore(STORE);
    const hasTok = (r, t) => `${r.product_name} ${r.title || ""} ${r.number || ""}`.toLowerCase().includes(t);
    recs = [];
    await new Promise((done) => {
      const src = setKey ? store.index("by_set").openCursor(IDBKeyRange.bound([setKey, ""], [setKey, "\uffff"])) : store.openCursor();
      let seen = 0;
      src.onsuccess = (e) => {
        const cur = e.target.result;
        if (!cur || gen !== scanGen || (!setKey && ++seen > SCAN_ROWS)) return done();
        if (tokens.every((t) => hasTok(cur.value, t))) recs.push(cur.value);
        if (recs.length >= SCAN_HITS) return done();
        cur.continue();
      };
      src.onerror = () => done();
    });
  } else return [];
  const usable = includeCustom ? recs : recs.filter((r) => !r.is_custom);

  return usable
    .map((r) => ({ rec: r, s: score(r, tokens, raw) }))
    .sort((a, b) =>
      b.s - a.s ||
      a.rec.product_name.localeCompare(b.rec.product_name) ||
      printingRank(a.rec.printing) - printingRank(b.rec.printing))
    .slice(0, limit)
    .map((x) => x.rec);
}

/* ------------------------------------------------------------------ */
/* Teardown                                                            */
/* ------------------------------------------------------------------ */
export async function clearCatalog() {
  const db = await openCatalog();
  const tx = db.transaction([STORE, META], "readwrite");
  tx.objectStore(STORE).clear();
  tx.objectStore(META).clear();
  await txDone(tx);
}
