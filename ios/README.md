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

The ledger is a plain web app and runs in any browser. Five things stay broken until you wrap it in
a native shell, and two of them are silent:

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
  camera integration. This is the one thing the two builds do not share: the Scan tab ships in this
  app and on the dev server, and the hosted web build leaves it out entirely (`__BB_SCAN__` in
  `vite.config.js`), because scanning wants the card in your hand.

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

A Mac is the only path. Nothing builds this app in CI, and there is no over-the-air update.

```sh
brew install xcodegen
npm run ios:device
```

That builds the web bundle, regenerates the project, signs a **Release** build and installs it onto
the first available iPhone, then launches it. Roughly a minute end to end. `scripts/ios-device.mjs`
carries the two facts that make it work and are not guessable — how to find the team id, and what
the free-profile app limit really is.

The phone does not need a cable if it is paired for network development: `devicectl` finds it as
`<name>.coredevice.local` over Wi-Fi.

**It installs over the app that is already there.** Same bundle id means the same container, so the
ledger survives an update. Only *deleting* the app destroys it.

**Release, so no DevBridge.** The automation listener below is `#if DEBUG`, and this path builds
Release, so it is not in what lands on the phone. That matters because the alternative below is not.

### In Xcode instead

For breakpoints, or to watch the console:

```sh
npm run ios                    # build:ios + xcodegen generate
open ios/BinderBooks.xcodeproj
```

Plug the iPhone in, pick it as the run destination, ⌘R. Signing settings are deliberately **not** in
`project.yml`, so the project behaves like any normal one: Signing & Capabilities → *Automatically
manage signing* → pick your Personal Team.

**⌘R installs a Debug build**, which contains the `DevBridge` automation listener. It binds
`127.0.0.1`, so nothing off the phone can reach it, but it has no business on a phone you keep.
Either use `npm run ios:device`, or switch the scheme to Release — Product → Scheme → Edit Scheme →
Run → Build Configuration → *Release*.

**A free Apple ID expires the signature after 7 days.** The app then refuses to launch until you ⌘R
again. You may also hold 3 sideloaded apps at once. A paid account ($99/yr) removes both limits.
Your ledger survives an expiry: it belongs to the container, and the container survives anything
short of deleting the app. Cloud sync makes this a non-event.

**Turn on Web Inspector.** `Shell.swift` sets `isInspectable = true`, so:

1. iPhone → Settings → Safari → Advanced → **Web Inspector** on
2. Mac Safari → Settings → Advanced → **Show features for web developers**
3. With the app running: Safari → Develop → *[your iPhone]* → **BinderBooks**

---

## Updating the app

`npm run ios:device` is the whole update loop. The bundle inside the app **is** the app — there is no
service worker and nothing is fetched at runtime — so a change reaches the phone when you build and
install, and not before.

### Why there is no over-the-air update

The shell could fetch the web bundle from S3 at launch and update itself with no Mac in the loop.
That was designed and then rejected on 2026-08-16. Recorded here so it is not re-proposed:

- **It needs far more than a download.** A manifest, a SHA-256 per file, a staging directory and an
  atomic swap — and then a probation-and-rollback path, because a bundle that fails to boot would
  otherwise leave the app dead on the phone until a reinstall. That is the opposite of the goal.
- **It downloads and executes code.** Whoever controls the bucket prefix controls the app. Per-file
  hashes stop corruption, not a hostile publisher, since the same access replaces the manifest too.
  Closing that properly means signing the manifest and pinning a key in the app.
- **It cannot update this file.** `Shell.swift`, the Info.plist and the entitlements still need a
  real install, so the Mac never actually leaves the loop.
- **The simple version of it is worse.** Pointing the web view at an `https://` URL needs none of the
  above, but it changes the page's origin — which orphans the ledger in `localStorage` on every
  device that already has the app. See the warning at the top of this file.

`npm run ios:device` costs one command and about a minute, updates native and web together, and has
none of those problems. Revisit only if the app ever needs to update on a phone that is nowhere near
this Mac.

**GitHub Pages being back changes none of this.** There is a live `https://` copy of the bundle
again, which makes "just point the web view at it" look free — it is not. It is the fourth bullet
above: a different origin, and the ledger on every phone that already has the app lives under
`binderbooks://local`. The hosted build is a second client of the same sync backend, not an update
channel for this one.

---

## Driving it from the command line

`simctl` can screenshot a booted simulator but it cannot tap one. So Debug builds carry a `DevBridge`
— a loopback HTTP listener that runs JavaScript inside the live web view.

```sh
curl -s localhost:8788/ping
curl -s -X POST --data 'return location.origin' localhost:8788/eval
xcrun simctl io "iPhone 17 Pro" screenshot shot.png
```

Three things keep it out of a Release build: `#if DEBUG`, it binds `127.0.0.1` by name, and it adds
no JavaScript API, so no app code can come to depend on it. `npm run ios:device` builds Release, so
the normal way onto the phone excludes it. Only ⌘R installs a Debug build.

---

## Changing things

| Want to | Do |
|---|---|
| Change the app icon | Edit `scripts/gen-icons.mjs` and rerun `npm run ios:icon`. That one generator draws the browser favicon **and** the app icon from the same scene, so they cannot drift apart. The iOS copy renders natively at 1024 and drops its alpha channel, because iOS rejects an app icon that carries one |
| Run on iPad too | `TARGETED_DEVICE_FAMILY: "1,2"` in `project.yml` |
| Allow landscape | Add the landscape orientations to `UISupportedInterfaceOrientations` |
| Add a native capability | A `WKScriptMessageHandler` case in `Shell.swift`. If you need a value back, use `WKScriptMessageHandlerWithReply` — `postMessage` then returns a real JS Promise |

---

## What the web layer knows about the shell

`Shell.swift` injects `window.__BINDERBOOKS_NATIVE__ = true` at document start. Two places read it:

- `downloadFile` in `src/App.jsx` posts to the `saveFile` bridge instead of clicking an `<a download>`.
- `haptic` in `src/App.jsx` posts to the `haptics` bridge; every other host ignores the call.

Everything is guarded, so the same source still builds and runs in a normal browser with no shell.
