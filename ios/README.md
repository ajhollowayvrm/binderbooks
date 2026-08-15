# BinderBooks on iPhone

A native iOS app around the same web bundle. No Capacitor, no CocoaPods, no Swift to write.

Three files are the whole shell:

| File | What it is |
|---|---|
| `project.yml` | XcodeGen spec — the `.xcodeproj` is **generated**, never committed |
| `Sources/Shell.swift` | The entire app: a WKWebView, a URL-scheme handler, two JS bridges |
| `Resources/Assets.xcassets` | App icon and the launch-screen colour |

`npm run build:ios` writes the Vite build to `ios/www`, and the Xcode target carries that directory
in as a folder reference. Both `ios/www` and the generated `.xcodeproj` are gitignored, because
`npm run ios` rebuilds them.

---

## Why a shell at all

The app is already a PWA. Five things stay broken until you wrap it, and two of them are silent:

- **The CSV export does nothing.** `a.download` is inert in a WKWebView. The TCGplayer staged-upload
  file is the whole point of the Inventory export, and in a plain web view the button reports no
  error and writes no file. It goes through the system share sheet now.
- **`target="_blank"` opens nothing.** WKWebView asks the app to supply a web view for a new window.
  With no `WKUIDelegate` the answer is nil and the tap dies. Three links depend on it: the label
  printer, TCGplayer, and eBay solds.
- **Zoom.** iOS Safari has ignored `user-scalable=no` since iOS 10 as an accessibility policy, so a
  page cannot stop pinch and double-tap zoom however it writes its viewport meta. In a WKWebView the
  scroll view belongs to us and is pinned shut.
- **Origin.** The ledger lives in `localStorage`, and storage is keyed to origin. The page is served
  over a custom `binderbooks://` scheme rather than `file://`, which gives it a real, stable, secure
  origin — so the ledger survives app updates and `window.isSecureContext` is true.
- **The camera.** `<input type="file" capture="environment">` works by itself, but iOS terminates the
  app if `NSCameraUsageDescription` is missing. The two usage strings in `project.yml` are the whole
  camera integration.

---

## The API Gateway CORS allowlist — already done

Cloud sync and the Scan tab need the API to answer this app's origin, `binderbooks://local`. That
allowlist now reads `["*"]`, and the setting is already applied — there is nothing to do here.

It is worth knowing **why** it is a wildcard, because the obvious fix does not exist. API Gateway
refuses a non-http(s) origin:

```
BadRequestException: Invalid format for origin binderbooks://local
```

The shell's origin can therefore never appear on an explicit list. Widening the list costs nothing
real, because CORS was not the control protecting this API — `/prices` and `/catalog` are public by
design and were always curl-able, and every other route needs the `x-sync-token` header, which no
other origin can read. The reasoning in full, and the command, are in
[`aws/README.md`](../aws/README.md).

Two consequences to remember:

- **Do not narrow `AllowOrigins` again.** The iOS app stops working the moment the list is not `*`.
- **Do not change `Shell.scheme`.** It is the page's origin, so changing it orphans the local ledger
  on every device that already has the app.

---

## Getting it on your phone

### On a Mac (the fast path)

```sh
brew install xcodegen
npm run ios                    # build:ios + xcodegen generate
open ios/BinderBooks.xcodeproj
```

Plug the iPhone in, pick it as the run destination, ⌘R. Xcode signs with your Apple ID and installs
directly — no CI, no artifact, no sideloading tool. Signing settings are deliberately **not** in
`project.yml`, so the project behaves like any normal one: Signing & Capabilities → *Automatically
manage signing* → pick your Personal Team.

**Debug or Release?** ⌘R installs a **Debug** build, which contains the `DevBridge` automation
listener. It binds `127.0.0.1`, so nothing off the phone can reach it. For a build you keep, switch
the scheme to Release — Product → Scheme → Edit Scheme → Run → Build Configuration → *Release* —
which is what CI archives and carries no byte of the bridge.

**A free Apple ID expires the signature after 7 days.** The app then refuses to launch until you ⌘R
again. Your ledger survives that: it belongs to the container, and the container survives anything
short of deleting the app. Cloud sync makes this a non-event.

**Turn on Web Inspector.** `Shell.swift` sets `isInspectable = true`, so:

1. iPhone → Settings → Safari → Advanced → **Web Inspector** on
2. Mac Safari → Settings → Advanced → **Show features for web developers**
3. With the app running: Safari → Develop → *[your iPhone]* → **BinderBooks**

### From Windows (no Mac)

Compiling needs macOS + Xcode. **Signing** needs your Apple ID. Only the first belongs in CI.

1. **Push, or run the workflow by hand** — Actions → *iOS ipa* → Run workflow.
2. **Download the artifact** — the run page → Artifacts → `binderbooks-ipa` → unzip.
3. **Sign and install it** with [Sideloadly](https://sideloadly.io) or
   [SideStore](https://sidestore.io) / AltStore. They re-sign with your Apple ID on the way in, which
   is why there are no certificates or secrets in the workflow.

On a free Apple ID the install expires after 7 days and you may hold 3 sideloaded apps at once. A
paid account ($99/yr) removes both limits.

---

## Updating the app

The bundle inside the `.ipa` **is** the app. There is no service worker, so the 30-minute auto-update
the web version uses does not apply here — a change reaches the phone when you rebuild and reinstall.
The web app at GitHub Pages keeps auto-updating exactly as before.

---

## Driving it from the command line

`simctl` can screenshot a booted simulator but it cannot tap one. So Debug builds carry a `DevBridge`
— a loopback HTTP listener that runs JavaScript inside the live web view.

```sh
curl -s localhost:8788/ping
curl -s -X POST --data 'return location.origin' localhost:8788/eval
xcrun simctl io "iPhone 17 Pro" screenshot shot.png
```

Three things keep it out of the product: `#if DEBUG` (CI archives Release), it binds `127.0.0.1` by
name, and it adds no JavaScript API, so no app code can come to depend on it.

---

## Changing things

| Want to | Do |
|---|---|
| Change the app icon | Edit and rerun `npm run ios:icon` (1024×1024, **no alpha**) |
| Run on iPad too | `TARGETED_DEVICE_FAMILY: "1,2"` in `project.yml` |
| Allow landscape | Add the landscape orientations to `UISupportedInterfaceOrientations` |
| Add a native capability | A `WKScriptMessageHandler` case in `Shell.swift`. If you need a value back, use `WKScriptMessageHandlerWithReply` — `postMessage` then returns a real JS Promise |

---

## What the web layer knows about the shell

`Shell.swift` injects `window.__BINDERBOOKS_NATIVE__ = true` at document start. Three places read it:

- `src/main.jsx` skips `registerSW` — a custom scheme has no `navigator.serviceWorker` at all.
- `downloadFile` in `src/App.jsx` posts to the `saveFile` bridge instead of clicking an `<a download>`.
- `haptic` in `src/App.jsx` posts to the `haptics` bridge; every other host ignores the call.

Everything is guarded, so the same source still builds and runs for GitHub Pages with no shell.
