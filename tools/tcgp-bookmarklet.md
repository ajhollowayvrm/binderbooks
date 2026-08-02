# TCGplayer order -> BinderBooks

One run on a TCGplayer **Order Details** page turns the order (order #, date,
per-card lines, totals) into JSON. Paste it into **BinderBooks -> Sales ->
"Paste TCGP order"** to create the sale and auto-mark matching inventory cards
as Sold.

Readable source: [`tcgp-scraper.js`](./tcgp-scraper.js). The one-liner further
down is the same code minified - regenerate it if you edit the source
(`npx terser tools/tcgp-scraper.js -c -m --format ascii_only=true`, then prefix
`javascript:` and escape any `%` as `%25`).

## Getting the JSON back out

DevTools holds focus while a snippet runs, so `navigator.clipboard` is usually
blocked. The script covers that three ways at once:

1. the console `copy()` utility (works in Snippets and the Console),
2. an on-page box in the bottom-right with a **Copy JSON** button - a real click,
   so the copy always succeeds,
3. a plain `console.log` of the JSON, and the object as the snippet's return value.

## DevTools Snippet (recommended - works in every browser, including Arc)

Arc has no bookmarks bar and often strips `javascript:` URLs, so use a Snippet
there. Saved once, runs in one keypress on any page:

1. On a TCGplayer order page, open DevTools: `Ctrl+Shift+I` (Win) / `Cmd+Opt+I` (Mac).
2. **Sources** tab -> **Snippets** in the left pane (click `>>` if hidden) ->
   **+ New snippet**.
3. Name it `tcgp-binderbooks` and paste the **entire contents of
   [`tcgp-scraper.js`](./tcgp-scraper.js)**. Save (`Ctrl+S`).
4. Run it on any order page: open the snippet and press `Ctrl+Enter` (Win) /
   `Cmd+Enter` (Mac), or right-click it -> **Run**.

Snippets persist across restarts. Pasting the same source straight into the
**Console** works too, if you'd rather not save it.

## Bookmarklet (Chrome / Edge / Safari)

1. Show the bookmarks bar (Chrome/Edge: `Ctrl+Shift+B`).
2. Right-click the bar -> **Add page** / **Add bookmark**.
3. Name it `TCGP -> BinderBooks`.
4. Paste the one-liner below into the **URL** field (it starts with `javascript:`).
5. Save.

> Some browsers strip a leading `javascript:` when you paste into the URL box.
> If it complains, paste, then re-type `javascript:` at the very front.

```
javascript:(()=>{const t=t=>(t||"").replace(/\s+/g," ").trim(),e=e=>{const o=t(e).replace(/[$,()]/g,"").match(/-?\d+(?:\.\d+)?/);return o?parseFloat(o[0]):0},o=(t,e)=>[...(e||document).querySelectorAll(t)],n=(t,e)=>(e||document).querySelector(t),r=[],d=e=>{const o=e.match(/#\s*([0-9A-Za-z\/-]+)/),n=o?o[1]:"",r=e.split(" - ");let d=r.findIndex(t=>t.trim().startsWith("#"));const i=d>-1?d-1:r.length,a=r.slice(1,Math.max(1,i)).join(" - "),c=a.split(": ");let s="",l=a;return c.length>=3?(s=c[1],l=c.slice(2).join(": ")):2===c.length&&(s=c[0],l=c[1]),{name:t(l),set:t(s),number:t(n)}};let i=t(n("[data-testid=txtOrderHeader]")?.textContent).replace(/^Order:?\s*/i,"");if(!i){const e=t(document.body.innerText||document.body.textContent).match(/Order:?\s*([0-9A-Z]{5,}(?:-[0-9A-Z]+)+)/i);e&&(i=e[1])}if(!i){const t=location.pathname.match(/orders?\/([^/?#]+)/i);t&&(i=decodeURIComponent(t[1]))}i||r.push("No order number found \u2014 fill in the Item field by hand.");let a="";for(const e of o("strong,h4,h5,b,dt,label")){if(!/order date/i.test(t(e.textContent)))continue;const o=e.parentElement,n=t([o?.querySelector("p"),e.nextElementSibling,o?.nextElementSibling,o].filter(Boolean).map(t=>t.textContent).join(" ")).match(/\d{1,2}\/\d{1,2}\/\d{2,4}/);if(n){a=n[0];break}}if(!a){const e=t(document.body.innerText||document.body.textContent).match(/\d{1,2}\/\d{1,2}\/\d{4}/);e?(a=e[0],r.push(`Date label not found \u2014 guessed ${a} from the page. Verify it.`)):r.push("No order date found \u2014 set the date after importing.")}const c={},s=n("[data-testid=OrderDetails_TransactionDetails_Table]");for(const r of s?o("tbody tr",s):o("table tr")){const d=o("td,th",r);if(d.length<2||n("a",r))continue;const i=t(d[0].textContent).toLowerCase(),a=e(d[d.length-1].textContent);/net/.test(i)?c.net=a:/fee/.test(i)?c.fee=a:/order/.test(i)?c.order=a:/product|subtotal/.test(i)?c.product=a:/ship/.test(i)&&(c.shipping=a)}const l=n("[data-testid=OrderDetails_ProductList]")||document,p=t=>o("tbody tr a",t).length,u=n("[data-testid=OrderDetails_ProductList_Table]",l)||o("table",l).filter(p).sort((t,e)=>p(e)-p(t))[0]||n("table",l),h=u?o("thead th",u).map(e=>t(e.textContent).toLowerCase()):[],x=(...t)=>h.findIndex(e=>t.some(t=>e.includes(t))),b=x("quantity","qty"),f=x("extended","line total","total"),m=x("price","each","unit"),g=[];if(u)for(const r of o("tbody tr",u)){const i=n("[data-testid=OrderDetails_ProductList_ProductLink]",r)||n("a",r);if(!i)continue;const a=o("td",r),c=t=>t>-1&&a[t]?e(a[t].textContent):null,s=Math.max(1,Math.round(c(b)??(a.length>=3?e(a[a.length-2].textContent):1)??1)),l=c(f)??(a.length>=4?e(a[a.length-1].textContent):0),p=c(m),u=d(t(i.textContent));g.push({...u,qty:s,price:+((p??l/s)||0).toFixed(2)})}g.length||r.push("No card rows found \u2014 is this the Order Details page, fully loaded?");const y=g.reduce((t,e)=>t+e.price*e.qty,0),C={source:"tcgplayer-order",orderNumber:i,date:a,price:c.order||c.product||+y.toFixed(2),shipping:0,fees:c.fee||0,cards:g};c.net&&Math.abs(C.price-C.fees-c.net)>.02&&r.push(`Net check: price \u2212 fees = ${(C.price-C.fees).toFixed(2)}, TCGP says ${c.net.toFixed(2)}.`);const w=JSON.stringify(C,null,2);console.log(`%25cBinderBooks \xb7 order ${i||"?"} \xb7 ${g.length} card(s)`,"font-weight:700;color:#2f5d50"),console.log(w),r.forEach(t=>console.warn("\u26a0 "+t));try{"function"==typeof copy&&copy(w)}catch(t){}try{navigator.clipboard?.writeText(w).catch(()=>{})}catch(t){}document.getElementById("bb-out")?.remove();const $=document.createElement("div");$.id="bb-out",$.style.cssText="position:fixed;z-index:2147483647;right:16px;bottom:16px;width:420px;max-width:92vw;background:#14171a;color:#eee;font:13px/1.4 ui-monospace,Menlo,Consolas,monospace;border-radius:6px;box-shadow:0 10px 40px rgba(0,0,0,.45);padding:12px";const v=(t,e,o,n,r)=>`<button id="${t}" style="${n}padding:8px 12px;border:0;border-radius:4px;background:${e};color:${o};font:inherit;cursor:pointer">${r}</button>`;$.innerHTML=`<div style="font-weight:700;margin-bottom:6px">Order ${i||"?"} \xb7 ${g.length} card(s)</div>`+(r.length?`<div style="color:#ffca6b;margin-bottom:6px">${r.map(t=>"\u26a0 "+t).join("<br>")}</div>`:"")+'<textarea readonly style="width:100%25;height:150px;background:#0c0e10;color:#9fe7c8;border:1px solid #333;border-radius:4px;padding:8px;font:12px/1.4 inherit"></textarea><div style="margin-top:8px;display:flex;gap:8px">'+v("bb-copy","#2f5d50","#fff","flex:1;font-weight:700;","Copy JSON")+v("bb-close","#333","#ddd","","Close")+"</div>",document.body.appendChild($);const q=$.querySelector("textarea");q.value=w,$.querySelector("#bb-copy").onclick=()=>{q.select();try{document.execCommand("copy")}catch(t){navigator.clipboard?.writeText(w)}$.querySelector("#bb-copy").textContent="Copied \u2713"},$.querySelector("#bb-close").onclick=()=>$.remove()})();
```

## Use

1. Open a TCGplayer Seller Portal order at **Order Details**.
2. Run the snippet (or click the bookmark). The box in the corner shows the
   order # and card count.
3. In BinderBooks: **Sales** -> **Paste TCGP order** -> paste -> **Import order**.

## What it produces

```json
{
  "source": "tcgplayer-order",
  "orderNumber": "62955D06-88B131-5236F",
  "date": "6/19/2026",
  "price": 48.07,
  "shipping": 0,
  "fees": 6.77,
  "cards": [
    { "name": "Sliggoo", "set": "Chaos Rising", "number": "095/086", "qty": 1, "price": 2.99 }
  ]
}
```

`price` is the gross Order Amount and `fees` is the TCGP fee, so BinderBooks'
computed net (`price - fees`) matches TCGP's Net Amount payout. Your
out-of-pocket postage isn't shown on the order page, so `shipping` stays 0 -
edit the sale if you want to log it. `cards[].price` is the **per-unit** price
(the importer multiplies by `qty`).

## If it comes back empty

The script prefers TCGplayer's `data-testid` hooks and falls back to finding the
totals rows by label and the product table by "the table with the most product
links". If TCGplayer reshuffles the page badly enough to beat both, the corner
box lists what it couldn't find. It also warns when `price - fees` doesn't match
the Net Amount shown on the page - worth a look before importing.
