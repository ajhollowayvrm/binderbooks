import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { VitePWA } from "vite-plugin-pwa";

// `--mode ios` builds the bundle the native shell ships (see ios/README.md).
// Two things change for it, and nothing else does:
//   base — the shell serves the bundle from the root of a custom URL scheme, so
//     there is no /binderbooks/ prefix. A relative base works under both hosts.
//   PWA  — a service worker cannot register on a custom scheme, so shipping one
//     inside the .ipa only produces a console error. The bundle IS the cache
//     there; a new version arrives with a new build, never over the network.
export default defineConfig(({ mode }) => {
  const ios = mode === "ios";

  return {
    // Served from https://<user>.github.io/binderbooks/ on GitHub Pages
    base: ios ? "./" : "/binderbooks/",
    plugins: [
      react(),
      VitePWA({
        // `disable` rather than dropping the plugin: main.jsx imports
        // `virtual:pwa-register`, and that module is supplied BY this plugin.
        // Leaving it out of the ios build fails the build outright — rollup
        // cannot resolve the import. Disabled, the plugin emits no service
        // worker and resolves the import to a no-op.
        disable: ios,
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
            {
              urlPattern: /^https:\/\/fonts\.googleapis\.com\//,
              handler: "StaleWhileRevalidate",
              options: { cacheName: "fonts-css" },
            },
            {
              urlPattern: /^https:\/\/fonts\.gstatic\.com\//,
              handler: "CacheFirst",
              options: {
                cacheName: "fonts",
                expiration: { maxEntries: 24, maxAgeSeconds: 31536000 },
              },
            },
            {
              urlPattern: /^https:\/\/images\.pokemontcg\.io\//,
              handler: "CacheFirst",
              options: {
                cacheName: "card-images",
                expiration: { maxEntries: 300, maxAgeSeconds: 604800 },
              },
            },
          ],
        },
      }),
    ].filter(Boolean),
  };
});
