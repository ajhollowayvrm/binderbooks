/*
 * BinderBooks — TCGplayer order scraper (snippet / bookmarklet source)
 * -------------------------------------------------------------------
 * Run on a TCGplayer Seller Portal "Order Details" page. Reads the order #,
 * date, per-card lines, and transaction totals from the DOM and emits a
 * normalized JSON blob three ways: logged to the console, copied to the
 * clipboard, and shown in an on-page box with a Copy button (DevTools steals
 * focus, so the async clipboard API often fails there). Paste it into
 * BinderBooks -> Sales -> "Paste TCGP order" -> Import order.
 *
 * The minified one-liner for the bookmarklet URL lives in
 * tools/tcgp-bookmarklet.md - regenerate it if you edit this file.
 *
 * Field mapping into a BinderBooks sale:
 *   price      = Order Amount (gross the buyer paid, incl. shipping collected)
 *   fees       = Fee Amount
 *   shipping   = 0  (your out-of-pocket postage isn't on this page; edit if needed)
 *   cards[].price = PER-UNIT price, since importOrder computes price x qty
 *   => net (price - fees) equals TCGP's "Net Amount" payout exactly.
 */
(() => {
  const c = (t) => (t || "").replace(/\s+/g, " ").trim();
  const money = (t) => {
    const m = c(t).replace(/[$,()]/g, "").match(/-?\d+(?:\.\d+)?/);
    return m ? parseFloat(m[0]) : 0;
  };
  const qa = (s, r) => [...(r || document).querySelectorAll(s)];
  const q = (s, r) => (r || document).querySelector(s);
  const warn = [];

  // "Pokemon - ME04: Chaos Rising: Sliggoo - 095/086 - #095/086 - Near Mint Holofoil"
  //   -> { name: "Sliggoo", set: "Chaos Rising", number: "095/086" }
  const parseTitle = (t) => {
    const hit = t.match(/#\s*([0-9A-Za-z\/-]+)/);
    const number = hit ? hit[1] : "";
    const parts = t.split(" - ");
    let hash = parts.findIndex((p) => p.trim().startsWith("#"));
    const midEnd = hash > -1 ? hash - 1 : parts.length; // drop the bare number before "#num"
    const mid = parts.slice(1, Math.max(1, midEnd)).join(" - ");
    const segs = mid.split(": ");
    let set = "", name = mid;
    if (segs.length >= 3) { set = segs[1]; name = segs.slice(2).join(": "); }   // code : set : name
    else if (segs.length === 2) { set = segs[0]; name = segs[1]; }
    return { name: c(name), set: c(set), number: c(number) };
  };

  /* ---------- order number ---------- */
  let orderNumber = c(q("[data-testid=txtOrderHeader]")?.textContent).replace(/^Order:?\s*/i, "");
  if (!orderNumber) {
    const m = c(document.body.innerText || document.body.textContent).match(/Order:?\s*([0-9A-Z]{5,}(?:-[0-9A-Z]+)+)/i);
    if (m) orderNumber = m[1];
  }
  if (!orderNumber) {
    const m = location.pathname.match(/orders?\/([^/?#]+)/i);
    if (m) orderNumber = decodeURIComponent(m[1]);
  }
  if (!orderNumber) warn.push("No order number found — fill in the Item field by hand.");

  /* ---------- order date ---------- */
  let date = "";
  for (const el of qa("strong,h4,h5,b,dt,label")) {
    if (!/order date/i.test(c(el.textContent))) continue;
    const box = el.parentElement;
    const near = c([box?.querySelector("p"), el.nextElementSibling, box?.nextElementSibling, box]
      .filter(Boolean).map((n) => n.textContent).join(" "));
    const m = near.match(/\d{1,2}\/\d{1,2}\/\d{2,4}/);
    if (m) { date = m[0]; break; }
  }
  if (!date) {
    const m = c(document.body.innerText || document.body.textContent).match(/\d{1,2}\/\d{1,2}\/\d{4}/);
    if (m) { date = m[0]; warn.push(`Date label not found — guessed ${date} from the page. Verify it.`); }
    else warn.push("No order date found — set the date after importing.");
  }

  /* ---------- transaction totals ---------- */
  const totals = {};
  const txTable = q("[data-testid=OrderDetails_TransactionDetails_Table]");
  for (const tr of txTable ? qa("tbody tr", txTable) : qa("table tr")) {
    const cells = qa("td,th", tr);
    if (cells.length < 2 || q("a", tr)) continue;          // skip product rows
    const label = c(cells[0].textContent).toLowerCase();
    const val = money(cells[cells.length - 1].textContent);
    if (/net/.test(label)) totals.net = val;
    else if (/fee/.test(label)) totals.fee = val;
    else if (/order/.test(label)) totals.order = val;
    else if (/product|subtotal/.test(label)) totals.product = val;
    else if (/ship/.test(label)) totals.shipping = val;
  }

  /* ---------- product lines ---------- */
  const sec = q("[data-testid=OrderDetails_ProductList]") || document;
  const withLinks = (t) => qa("tbody tr a", t).length;
  const table = q("[data-testid=OrderDetails_ProductList_Table]", sec)
    || qa("table", sec).filter(withLinks).sort((a, b) => withLinks(b) - withLinks(a))[0]
    || q("table", sec);
  const heads = table ? qa("thead th", table).map((th) => c(th.textContent).toLowerCase()) : [];
  const col = (...keys) => heads.findIndex((h) => keys.some((k) => h.includes(k)));
  const qtyCol = col("quantity", "qty");
  const extCol = col("extended", "line total", "total");
  const eachCol = col("price", "each", "unit");

  const cards = [];
  if (table) {
    for (const tr of qa("tbody tr", table)) {
      const link = q("[data-testid=OrderDetails_ProductList_ProductLink]", tr) || q("a", tr);
      if (!link) continue;
      const td = qa("td", tr);
      const at = (i) => (i > -1 && td[i] ? money(td[i].textContent) : null);
      const qty = Math.max(1, Math.round(at(qtyCol) ?? (td.length >= 3 ? money(td[td.length - 2].textContent) : 1) ?? 1));
      const ext = at(extCol) ?? (td.length >= 4 ? money(td[td.length - 1].textContent) : 0);
      const each = at(eachCol);
      const p = parseTitle(c(link.textContent));
      cards.push({ ...p, qty, price: +((each ?? ext / qty) || 0).toFixed(2) });   // per-unit price
    }
  }
  if (!cards.length) warn.push("No card rows found — is this the Order Details page, fully loaded?");

  /* ---------- assemble ---------- */
  const lineSum = cards.reduce((a, l) => a + l.price * l.qty, 0);
  const out = {
    source: "tcgplayer-order",
    orderNumber,
    date,
    price: totals.order || totals.product || +lineSum.toFixed(2),   // gross buyer paid
    shipping: 0,                                                    // your postage isn't on this page
    fees: totals.fee || 0,
    cards,
  };
  if (totals.net && Math.abs(out.price - out.fees - totals.net) > 0.02)
    warn.push(`Net check: price − fees = ${(out.price - out.fees).toFixed(2)}, TCGP says ${totals.net.toFixed(2)}.`);

  const json = JSON.stringify(out, null, 2);

  /* ---------- deliver ---------- */
  console.log(`%cBinderBooks · order ${orderNumber || "?"} · ${cards.length} card(s)`,
    "font-weight:700;color:#2f5d50");
  console.log(json);
  warn.forEach((w) => console.warn("⚠ " + w));
  try { if (typeof copy === "function") copy(json); } catch (e) { /* console-only API */ }
  try { navigator.clipboard?.writeText(json).catch(() => {}); } catch (e) { /* focus lost */ }

  document.getElementById("bb-out")?.remove();
  const box = document.createElement("div");
  box.id = "bb-out";
  box.style.cssText = "position:fixed;z-index:2147483647;right:16px;bottom:16px;width:420px;max-width:92vw;" +
    "background:#14171a;color:#eee;font:13px/1.4 ui-monospace,Menlo,Consolas,monospace;border-radius:6px;" +
    "box-shadow:0 10px 40px rgba(0,0,0,.45);padding:12px";
  const btn = (id, bg, fg, extra, text) => `<button id="${id}" style="${extra}padding:8px 12px;border:0;border-radius:4px;background:${bg};color:${fg};font:inherit;cursor:pointer">${text}</button>`;
  box.innerHTML =
    `<div style="font-weight:700;margin-bottom:6px">Order ${orderNumber || "?"} \u00b7 ${cards.length} card(s)</div>` +
    (warn.length ? `<div style="color:#ffca6b;margin-bottom:6px">${warn.map((w) => "\u26a0 " + w).join("<br>")}</div>` : "") +
    `<textarea readonly style="width:100%;height:150px;background:#0c0e10;color:#9fe7c8;border:1px solid #333;border-radius:4px;padding:8px;font:12px/1.4 inherit"></textarea>` +
    `<div style="margin-top:8px;display:flex;gap:8px">` +
      btn("bb-copy", "#2f5d50", "#fff", "flex:1;font-weight:700;", "Copy JSON") +
      btn("bb-close", "#333", "#ddd", "", "Close") +
    `</div>`;
  document.body.appendChild(box);
  const ta = box.querySelector("textarea");
  ta.value = json;
  box.querySelector("#bb-copy").onclick = () => {
    ta.select();
    try { document.execCommand("copy"); } catch (e) { navigator.clipboard?.writeText(json); }
    box.querySelector("#bb-copy").textContent = "Copied ✓";
  };
  box.querySelector("#bb-close").onclick = () => box.remove();

  return out;
})();
