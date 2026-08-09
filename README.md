# BinderBooks

A Pokémon card buying / selling / ripping P&L ledger. Tracks purchases, rips
(cost vs. pulled value), sales with multi-card line items and real profit,
graded-card inventory with a lifecycle status, and a debounced fuzzy card-search
that pulls live TCGplayer market prices from the free pokemontcg.io API.

Data is saved in your browser's **localStorage** and synced to a private AWS
backend (DynamoDB behind a Lambda + API Gateway — see `aws/index.mjs`), so the
ledger persists across devices. Paste the sync token into the **Cloud sync**
panel on the Overview tab once per device; the token lives in `.sync-token`
locally (never committed) and as the `SYNC_TOKEN` env var on the
`binderbooks-sync` Lambda (us-west-2). Conflicts resolve last-write-wins; the
app re-pulls whenever it regains focus.

**Live site:** https://ajhollowayvrm.github.io/binderbooks/

## Run locally

```bash
npm install
npm run dev
```

Then open the printed URL (usually http://localhost:5173).

## Build & host

```bash
npm run build      # outputs static files to ./dist
npm run preview    # preview the production build locally
```

`dist/` is a plain static site — drop it on any static host (Vercel, Netlify,
Cloudflare Pages, GitHub Pages, S3, etc.). No backend required.

## Deploy to GitHub Pages

Every push to `main` triggers the GitHub Actions workflow in
`.github/workflows/deploy.yml`, which builds the app and deploys it to
https://ajhollowayvrm.github.io/binderbooks/ — live within a minute or two.
No manual deploy step needed.

## Optional: pokemontcg.io API key (recommended once hosted)

The card search uses the free pokemontcg.io API. Without a key it's rate-limited
and occasionally drops requests. To lift the limits:

1. Get a free key at https://dev.pokemontcg.io/
2. `cp .env.example .env`
3. Paste your key into `.env` as `VITE_POKEMONTCG_API_KEY=...`
4. Restart the dev server (and set the same env var in your host's dashboard for production)

The app works without a key — it just retries on failure and shows a tappable
retry if the API doesn't respond.

## Tools

Two standalone helpers that don't need the app running:

- **`tools/tcgp-scraper.js`** — paste into a DevTools Snippet (or the Console) on
  a TCGplayer Seller Portal **Order Details** page. It emits the order as JSON
  three ways (console `copy()`, an on-page box with a Copy button, and a
  `console.log`); paste that into **Sales → "Paste TCGP order"**. Setup, the
  bookmarklet one-liner, and the output shape are in
  [`tools/tcgp-bookmarklet.md`](tools/tcgp-bookmarklet.md).
- **`public/label.html`** — shipping-label formatter for a 4×6 thermal printer
  (Munbyn fanfold). Paste a mailing address; it drops the country line and scales
  the type to the largest size that fits along the 6-inch edge, anchored to the
  bottom, with a small return address in the top-left corner — so both blocks cut
  out cleanly. Live at
  <https://ajhollowayvrm.github.io/binderbooks/label.html>. The return address is
  typed once and kept in that browser's localStorage, so it never lands in the
  repo.

## Notes

- **TCGplayer bulk listing:** the Inventory tab can build a staged-upload CSV.
  The first time you list from a set, add its export from the TCGplayer Seller
  Portal (Pricing → Export Filtered CSV with out-of-stock rows included, or a
  Live Inventory export — those exports carry the per-condition SKU in
  "TCGplayer Id", which is what the importer matches on). BinderBooks caches
  the SKU rows for that set on the device, so later runs are just tick the
  cards and *Export CSV* — no file picker. Before you export it tells you
  which selected cards' sets aren't cached yet. It fills Add to Quantity and
  TCG Marketplace Price for every raw Kept card it can match, downloads
  `TCGP-Staged-Upload-<date>.csv`, and offers to flip the exported cards to
  Listed. Upload it via Seller Portal → Inventory → Import to Staged. Cached
  exports are listed (with age and size) under *Cached set exports* in the
  same panel, where you can refresh or clear them; they're per-device and
  never synced.
- A "Reset all data" button lives at the bottom of the Overview tab.
- The app seeds with example data on first run; edit or delete those rows freely.
- Card search matches substrings of the **card name** and supports multi-word
  (e.g. "pika ex"), but the API doesn't do typo correction. Set names in the
  query become set filters ("ampharos chaos rising"), and variant words like
  "full art" / "secret" / "reverse" float matching rarities to the top instead
  of being matched against the name.
