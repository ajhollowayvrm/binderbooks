/*
 * BinderBooks — TCGplayer order scraper (bookmarklet source)
 * ----------------------------------------------------------
 * Run this on a TCGplayer Seller Portal "Order Details" page. It reads the
 * order #, date, per-card lines, and the transaction totals straight from the
 * page DOM, then copies a normalized JSON blob to your clipboard. Paste that
 * into BinderBooks → Sales → "Paste TCGP order".
 *
 * The minified one-line `javascript:` version (for the bookmark URL) lives in
 * tools/tcgp-bookmarklet.md — keep the two in sync if you edit this.
 *
 * Field mapping into a BinderBooks sale:
 *   price    = Order Amount (gross the buyer paid, incl. shipping collected)
 *   fees     = Fee Amount
 *   shipping = 0  (your out-of-pocket postage isn't on this page; edit if needed)
 *   => net (price - fees) equals TCGP's "Net Amount" payout exactly.
 */
(function () {
  function c(t) { return (t || "").replace(/\s+/g, " ").trim(); }
  // pull a number out of "$48.07" or "($6.77)" -> 48.07 / 6.77
  function money(t) { var x = c(t).replace(/[(),]/g, "").match(/-?\d+(\.\d+)?/); return x ? parseFloat(x[0]) : 0; }
  function qa(s, r) { return [].slice.call((r || document).querySelectorAll(s)); }
  function q(s, r) { return (r || document).querySelector(s); }

  // "Pokemon - ME04: Chaos Rising: Sliggoo - 095/086 - #095/086 - Near Mint Holofoil"
  //   -> { name: "Sliggoo", set: "Chaos Rising", number: "095/086" }
  function parseTitle(t) {
    var number = "", mm = t.match(/#\s*([0-9A-Za-z\/-]+)/); if (mm) number = mm[1];
    var parts = t.split(" - ");
    var hash = -1; for (var i = 0; i < parts.length; i++) { if (parts[i].trim().charAt(0) === "#") { hash = i; break; } }
    var midEnd = hash > -1 ? hash - 1 : parts.length; // drop the bare number that precedes "#number"
    var mid = parts.slice(1, Math.max(1, midEnd)).join(" - "); // "ME04: Chaos Rising: Sliggoo"
    var segs = mid.split(": "), set = "", name = "";
    if (segs.length >= 3) { set = segs[1]; name = segs.slice(2).join(": "); }     // code : set : name
    else if (segs.length === 2) { set = segs[0]; name = segs[1]; }
    else { name = mid; }
    return { name: c(name), set: c(set), number: c(number) };
  }

  // --- order number ---
  var oh = q("[data-testid=txtOrderHeader]");
  var orderNumber = oh ? c(oh.textContent).replace(/^Order:\s*/i, "") : "";

  // --- order date (take the calendar date, drop the time/zone) ---
  var date = "";
  qa("strong,h4").forEach(function (el) {
    if (/order date/i.test(c(el.textContent)) && !date) {
      var p = el.parentElement && el.parentElement.querySelector("p");
      if (p) date = c(p.textContent).split(",")[0]; // "6/19/2026, 4:31 PM (MDT)" -> "6/19/2026"
    }
  });

  // --- transaction totals ---
  var a = {}, tx = q("[data-testid=OrderDetails_TransactionDetails_Table]");
  if (tx) qa("tbody tr", tx).forEach(function (tr) {
    var td = qa("td", tr); if (td.length < 2) return;
    var label = c(td[0].textContent).toLowerCase(), val = money(td[1].textContent);
    if (label.indexOf("product") > -1) a.product = val;
    else if (label.indexOf("shipping") > -1) a.shipping = val;
    else if (label.indexOf("order") > -1) a.order = val;
    else if (label.indexOf("fee") > -1) a.fee = val;
    else if (label.indexOf("net") > -1) a.net = val;
  });

  // --- product lines (scope to the main Products section, not the Contact-Buyer drawer copy) ---
  var sec = q("[data-testid=OrderDetails_ProductList]") || document;
  var table = q("[data-testid=OrderDetails_ProductList_Table]", sec) || q("table", sec);
  var cards = [];
  if (table) qa("tbody tr", table).forEach(function (tr) {
    var link = q("[data-testid=OrderDetails_ProductList_ProductLink]", tr) || q("a", tr);
    if (!link) return;
    var td = qa("td", tr);
    var qty = td.length >= 3 ? (parseInt(money(td[td.length - 2].textContent)) || 1) : 1;
    var ext = td.length >= 4 ? money(td[td.length - 1].textContent) : 0;
    var p = parseTitle(c(link.textContent));
    cards.push({ name: p.name, set: p.set, number: p.number, qty: qty, price: ext });
  });

  var out = {
    source: "tcgplayer-order",
    orderNumber: orderNumber,
    date: date,
    price: a.order || a.product || 0,
    shipping: 0,
    fees: a.fee || 0,
    cards: cards,
  };

  // --- copy to clipboard, with fallbacks ---
  var js = JSON.stringify(out);
  function ok() { alert("Copied TCGP order " + orderNumber + " - " + cards.length + " card(s). Paste into BinderBooks Sales."); }
  function fallback() {
    var ta = document.createElement("textarea"); ta.value = js; document.body.appendChild(ta); ta.select();
    try { document.execCommand("copy"); ok(); } catch (e) { window.prompt("Copy this JSON:", js); }
    document.body.removeChild(ta);
  }
  try {
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(js).then(ok, fallback);
    else fallback();
  } catch (e) { fallback(); }
})();
