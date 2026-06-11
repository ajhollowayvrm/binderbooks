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
      manifest: false, // we ship our own public/manifest.webmanifest + icons
      workbox: {
        globPatterns: ["**/*.{js,css,html,png,webmanifest}"],
        navigateFallback: "/binderbooks/index.html",
        runtimeCaching: [
          { urlPattern: /^https:\/\/fonts\.googleapis\.com\//, handler: "StaleWhileRevalidate", options: { cacheName: "fonts-css" } },
          { urlPattern: /^https:\/\/fonts\.gstatic\.com\//, handler: "CacheFirst", options: { cacheName: "fonts", expiration: { maxEntries: 24, maxAgeSeconds: 31536000 } } },
          { urlPattern: /^https:\/\/images\.pokemontcg\.io\//, handler: "CacheFirst", options: { cacheName: "card-images", expiration: { maxEntries: 300, maxAgeSeconds: 604800 } } },
        ],
      },
    }),
  ],
});
