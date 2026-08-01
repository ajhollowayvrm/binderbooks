import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { VitePWA } from "vite-plugin-pwa";

export default defineConfig({
  // Served from https://<user>.github.io/binderbooks/ on GitHub Pages
  base: "/binderbooks/",
  plugins: [
    react(),
    VitePWA({
      registerType: "autoUpdate",
      // registration lives in main.jsx (virtual:pwa-register) so the app can
      // poll for new deploys and reload itself — the injected one-liner script
      // registered once and never noticed updates until a full relaunch
      injectRegister: false,
      manifest: false, // we ship our own public/manifest.webmanifest + icons
      workbox: {
        globPatterns: ["**/*.{js,css,html,png,webmanifest}"],
        navigateFallback: "/binderbooks/index.html",
        // label.html is a real page, not an app route — don't let the SW serve
        // index.html in its place
        navigateFallbackDenylist: [/label\.html$/],
        runtimeCaching: [
          { urlPattern: /^https:\/\/fonts\.googleapis\.com\//, handler: "StaleWhileRevalidate", options: { cacheName: "fonts-css" } },
          { urlPattern: /^https:\/\/fonts\.gstatic\.com\//, handler: "CacheFirst", options: { cacheName: "fonts", expiration: { maxEntries: 24, maxAgeSeconds: 31536000 } } },
          { urlPattern: /^https:\/\/images\.pokemontcg\.io\//, handler: "CacheFirst", options: { cacheName: "card-images", expiration: { maxEntries: 300, maxAgeSeconds: 604800 } } },
        ],
      },
    }),
  ],
});
