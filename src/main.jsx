import { createRoot } from "react-dom/client";
import { registerSW } from "virtual:pwa-register";
import App from "./App.jsx";

// auto-update: check for a new deploy every 30 min and whenever the app comes
// back to the foreground; in autoUpdate mode the new service worker takes over
// immediately and the page reloads itself (ledger state lives in localStorage,
// so a reload loses nothing but a half-typed form)
registerSW({
  immediate: true,
  onRegisteredSW(_url, reg) {
    if (!reg) return;
    const check = () => reg.update().catch(() => {});
    setInterval(check, 30 * 60 * 1000);
    document.addEventListener("visibilitychange", () => document.visibilityState === "visible" && check());
  },
});

createRoot(document.getElementById("root")).render(<App />);
