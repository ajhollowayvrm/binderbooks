import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// `--mode ios` builds the bundle the native shell ships (see ios/README.md).
// One setting changes for it: `base`. The shell serves the bundle from the root
// of a custom URL scheme, so the bundle must not carry the /binderbooks/ prefix.
// A relative base works under both hosts.
//
// The app shipped a service worker while GitHub Pages hosted it. Pages is off,
// the iPhone app is the only build that ships, and a custom scheme cannot
// register a worker. So the worker is deleted. The bundle inside the `.ipa` is
// the cache, and a new version arrives with a new build.
export default defineConfig(({ mode }) => ({
  base: mode === "ios" ? "./" : "/binderbooks/",
  plugins: [react()],
}));
