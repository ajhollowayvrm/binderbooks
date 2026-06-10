# BinderBooks

A Pokémon card buying / selling / ripping P&L ledger. Tracks purchases, rips
(cost vs. pulled value), sales with multi-card line items and real profit,
graded-card inventory with a lifecycle status, and a debounced fuzzy card-search
that pulls live TCGplayer market prices from the free pokemontcg.io API.

Data is saved in your browser's **localStorage** (per device/browser).

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

## Notes

- A "Reset all data" button lives at the bottom of the Overview tab.
- The app seeds with example data on first run; edit or delete those rows freely.
- Card search matches substrings of the **card name** and supports multi-word
  (e.g. "pika ex"), but the API doesn't do typo correction.
