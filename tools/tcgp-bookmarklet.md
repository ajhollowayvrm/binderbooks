# TCGplayer order → BinderBooks bookmarklet

One click on a TCGplayer **Order Details** page copies the order (order #, date,
per-card lines, totals) to your clipboard as JSON. Paste it into
**BinderBooks → Sales → "Paste TCGP order"** to create the sale and auto-mark
matching inventory cards as Sold.

Readable source: [`tcgp-scraper.js`](./tcgp-scraper.js). The line below is the
same code minified — keep them in sync if you edit.

## Arc Browser (recommended: DevTools Snippet)

Arc has no bookmarks bar and often strips `javascript:` URLs, so the bookmarklet
route is unreliable there. Use a **Snippet** instead — saved once, runs in one
keypress on any page:

1. On a TCGplayer order page, open DevTools: `Ctrl+Shift+I` (Win) / `Cmd+Opt+I` (Mac).
2. Go to the **Sources** tab → **Snippets** in the left pane
   (click `»` if it's hidden) → **+ New snippet**.
3. Name it `tcgp-binderbooks` and paste the **entire contents of
   [`tcgp-scraper.js`](./tcgp-scraper.js)** into the editor. Save (`Ctrl+S`).
4. To run it on any order page: open that snippet and press `Ctrl+Enter`
   (Win) / `Cmd+Enter` (Mac), or right-click it → **Run**.

When run from DevTools the clipboard copy may be blocked (DevTools has focus), so
the script falls back to a **popup with the JSON** — just select-all and copy
from there, then paste into BinderBooks. The snippet persists across restarts.

## Bookmarklet (Chrome / Edge / Safari)

1. Show your browser's bookmarks bar (Chrome/Edge: `Ctrl+Shift+B`).
2. Right-click the bar → **Add page** / **Add bookmark**.
3. Name it `TCGP → BinderBooks`.
4. In the **URL** field, paste the entire one-liner below (it starts with
   `javascript:`).
5. Save.

> Some browsers strip a leading `javascript:` when you paste into the URL box.
> If it complains, paste, then re-type `javascript:` at the very front.

## Use

1. Open a TCGplayer Seller Portal order at **Order Details**.
2. Click the **TCGP → BinderBooks** bookmark. You'll get an alert like
   *"Copied TCGP order … — 6 card(s)."*
3. In BinderBooks, go to **Sales**, click **Paste TCGP order**, paste, and hit
   **Import order**.

## The bookmarklet

```
javascript:(function(){function c(t){return(t||'').replace(/\s+/g,' ').trim()}function m(t){var x=c(t).replace(/[(),]/g,'').match(/-?\d+(\.\d+)?/);return x?parseFloat(x[0]):0}function qa(s,r){return[].slice.call((r||document).querySelectorAll(s))}function q(s,r){return(r||document).querySelector(s)}function pt(t){var n='',mm=t.match(/#\s*([0-9A-Za-z\/-]+)/);if(mm)n=mm[1];var p=t.split(' - '),h=-1;for(var i=0;i<p.length;i++){if(p[i].trim().charAt(0)==='#'){h=i;break}}var me=h>-1?h-1:p.length,mid=p.slice(1,Math.max(1,me)).join(' - '),s=mid.split(': '),sn='',nm='';if(s.length>=3){sn=s[1];nm=s.slice(2).join(': ')}else if(s.length===2){sn=s[0];nm=s[1]}else{nm=mid}return{name:c(nm),set:c(sn),number:c(n)}}var oh=q('[data-testid=txtOrderHeader]'),on=oh?c(oh.textContent).replace(/^Order:\s*/i,''):'',dt='';qa('strong,h4').forEach(function(e){if(/order date/i.test(c(e.textContent))&&!dt){var p=e.parentElement&&e.parentElement.querySelector('p');if(p)dt=c(p.textContent).split(',')[0]}});var a={},tx=q('[data-testid=OrderDetails_TransactionDetails_Table]');if(tx)qa('tbody tr',tx).forEach(function(r){var d=qa('td',r);if(d.length<2)return;var l=c(d[0].textContent).toLowerCase(),v=m(d[1].textContent);if(l.indexOf('product')>-1)a.product=v;else if(l.indexOf('shipping')>-1)a.shipping=v;else if(l.indexOf('order')>-1)a.order=v;else if(l.indexOf('fee')>-1)a.fee=v;else if(l.indexOf('net')>-1)a.net=v});var sec=q('[data-testid=OrderDetails_ProductList]')||document,tb=q('[data-testid=OrderDetails_ProductList_Table]',sec)||q('table',sec),cards=[];if(tb)qa('tbody tr',tb).forEach(function(r){var lk=q('[data-testid=OrderDetails_ProductList_ProductLink]',r)||q('a',r);if(!lk)return;var d=qa('td',r),qy=d.length>=3?(parseInt(m(d[d.length-2].textContent))||1):1,ex=d.length>=4?m(d[d.length-1].textContent):0,ps=pt(c(lk.textContent));cards.push({name:ps.name,set:ps.set,number:ps.number,qty:qy,price:ex})});var out={source:'tcgplayer-order',orderNumber:on,date:dt,price:a.order||a.product||0,shipping:0,fees:a.fee||0,cards:cards},js=JSON.stringify(out);function ok(){alert('Copied TCGP order '+on+' — '+cards.length+' card(s). Paste into BinderBooks → Sales.')}function fb(){var t=document.createElement('textarea');t.value=js;document.body.appendChild(t);t.select();try{document.execCommand('copy');ok()}catch(e){window.prompt('Copy this JSON:',js)}document.body.removeChild(t)}try{if(navigator.clipboard&&navigator.clipboard.writeText)navigator.clipboard.writeText(js).then(ok,fb);else fb()}catch(e){fb()}})();
```

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
computed net (`price − fees`) matches TCGP's Net Amount payout. Your
out-of-pocket postage isn't shown on the order page, so `shipping` stays 0 —
edit the sale if you want to log it.
