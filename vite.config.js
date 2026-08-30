import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Two builds come out of this file.
//
//   npm run build      the hosted web build. GitHub Pages serves it from
//                      /binderbooks/, deployed by .github/workflows/deploy.yml.
//   npm run build:ios  the bundle the native shell ships (see ios/README.md).
//                      The shell serves it from the root of a custom URL
//                      scheme, so it must not carry the /binderbooks/ prefix.
//                      A relative base works under both hosts.
//
// `__BB_SCAN__` is the Scan tab — photograph a card and Claude reads it. That
// is a phone job: it wants the back camera and the card in your hand. The web
// build is the desk half — uploading sales exports, pasting orders, printing
// labels — so it leaves the tab out, and CardSnap and the /identify call go
// with it rather than shipping to a browser that will never call them. The dev
// server keeps the tab so it stays workable on a laptop; the "use a photo you
// already took" input is the desktop path into it.
//
// Neither build ships a service worker. A custom scheme cannot register one,
// and a hosted build wants a push to be live on the next load rather than after
// a cache generation. The bundle inside the app is its own cache, and a new
// version arrives with a new build.
export default defineConfig(({ mode }) => ({
  base: mode === "ios" ? "./" : "/binderbooks/",
  define: {
    __BB_SCAN__: JSON.stringify(mode === "ios" || mode === "development"),
    // `__BB_NATIVE__` is the WKWebView build. The shell locks zoom there
    // (ios/Sources/Shell.swift), so a field smaller than 16px is safe and the
    // design keeps its 13.5px. Every other build runs in a browser that zooms
    // in on a small field when it takes focus, and iOS ignores maximum-scale.
    __BB_NATIVE__: JSON.stringify(mode === "ios"),
  },
  plugins: [react()],
  /* Tests run under jsdom, not node. src/App.jsx reads `location.hash` and
     `localStorage` while the module evaluates (the sync magic-link handler), so
     importing it at all needs a DOM. The `define` block above still applies, so
     `__BB_SCAN__` and `__BB_NATIVE__` resolve here as well. */
  test: {
    environment: "jsdom",
    include: ["src/**/*.test.{js,jsx}", "aws/**/*.test.{js,mjs}"],
  },
}));
