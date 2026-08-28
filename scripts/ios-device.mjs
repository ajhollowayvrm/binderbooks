// npm run ios:device — build, sign and install onto a connected iPhone.
//
// This is how a change reaches the phone. There is no CI and no over-the-air update: you run this,
// and about a minute later the new build is open on the device. It replaces the app in place, so
// the ledger in the container survives — same bundle id, same container, same localStorage.
//
// You also need it on a schedule you did not choose: a FREE Apple developer signature expires after
// 7 days, and the app then refuses to launch until it is re-signed. This is that, in one command.
//
// Three things here were not obvious and cost real time to work out, so they are automated rather
// than written down as instructions to follow by hand:
//
//  1. DEVELOPMENT_TEAM is NOT the number in the signing identity's name. The identity reads
//     "Apple Development: you@example.com (9Z2HDDXR94)" and that parenthetical is the identity's
//     own id — passing it gives `error: No Account for Team "9Z2HDDXR94"`, which reads like a
//     missing Xcode account rather than a wrong argument. The team is the certificate's OU field.
//  2. A free profile allows THREE sideloaded apps per device, total, across every project. The
//     fourth install fails with "its integrity could not be verified" and MIInstallerErrorDomain
//     error 13 — which sounds like a signing problem and is not one. The fix is to delete an app
//     (which deletes its container, and therefore its ledger) or to pay for an account.
//  3. Reinstalling does NOT reset the 7-day clock by itself. The clock starts when Apple ISSUES
//     the profile, not when you install it, and Xcode reuses a cached profile while it is still
//     valid. So an install on day 5 inherits the 2 days that remain. Moving the cached profile
//     aside makes Xcode ask Apple for a new one, and a new one is a full 7 days.
//
// All three were learned in the PokeVendor repo, which installs the same way; keep the two in step.
import { execFileSync } from 'node:child_process'
import { existsSync, readdirSync, renameSync, rmSync } from 'node:fs'
import { join, basename } from 'node:path'
import { tmpdir } from 'node:os'

const BUNDLE = 'com.ajholloway.binderbooks'
// Its own derived-data path, kept out of the plain `ios/build` a simulator run uses — .gitignore
// matches `ios/build*` for exactly this reason.
const DERIVED = 'ios/build-device'
const APP = `${DERIVED}/Build/Products/Release-iphoneos/BinderBooks.app`
const PROFILES = join(process.env.HOME, 'Library/Developer/Xcode/UserData/Provisioning Profiles')

// Refresh the signature when it has less than this left. A fresh profile is 7 days, so 6 means a
// tight edit-install loop asks Apple at most once a day, while any install after a day away comes
// back with a full week. The app is therefore always good for at least 6 days from your last push.
const REFRESH_UNDER_DAYS = 6

const sh = (cmd, args, opts = {}) => execFileSync(cmd, args, { encoding: 'utf8', ...opts })
const run = (cmd, args) => execFileSync(cmd, args, { stdio: 'inherit' })

/// The team id, read from the signing certificate's OU rather than guessed from its name.
function teamId() {
  const ids = sh('security', ['find-identity', '-v', '-p', 'codesigning'])
  const name = ids.match(/"(Apple Development: [^"]+)"/)?.[1]
  if (!name) throw new Error('no Apple Development identity in the keychain — sign in to Xcode → Settings → Accounts first')
  const pem = sh('security', ['find-certificate', '-c', name, '-p'])
  const subject = sh('openssl', ['x509', '-noout', '-subject'], { input: pem })
  const ou = subject.match(/OU\s*=\s*([A-Z0-9]+)/)?.[1]
  if (!ou) throw new Error(`could not read the team (OU) from the certificate for "${name}"`)
  return { team: ou, identity: name }
}

/// The first connected, paired iPhone. devicectl reaches a wirelessly paired phone too, so this
/// works over wifi — the transport has no bearing on signing or on the 7-day clock.
///
/// The State column has read "available" and "connected" for a ready, wired phone on different
/// Xcode/iOS versions, so this excludes "unavailable" instead of requiring "available" — the
/// substring check for "available" alone also matched "unavailable", which was never the intent.
function device() {
  const out = sh('xcrun', ['devicectl', 'list', 'devices'])
  const line = out.split('\n').find(l => /iPhone/.test(l) && !/unavailable/.test(l))
  if (!line) throw new Error('no available iPhone — plug one in, unlock it, and trust this Mac')
  const udid = line.match(/([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})/i)?.[1]
  if (!udid) throw new Error(`could not parse a device id from: ${line.trim()}`)
  return { udid, name: line.split(/\s{2,}/)[0].trim() }
}

/// The expiry date inside a .mobileprovision, or null if it will not decode.
function expiryOf(path) {
  try {
    const xml = sh('security', ['cms', '-D', '-i', path])
    const date = xml.match(/<key>ExpirationDate<\/key>\s*<date>([^<]+)<\/date>/)?.[1]
    return date ? new Date(date) : null
  } catch { return null }
}

/// The cached profile for this bundle id, if there is one.
function cachedProfile() {
  if (!existsSync(PROFILES)) return null
  for (const f of readdirSync(PROFILES).filter(f => f.endsWith('.mobileprovision'))) {
    const path = join(PROFILES, f)
    try {
      if (!sh('security', ['cms', '-D', '-i', path]).includes(BUNDLE)) continue
    } catch { continue }
    const expires = expiryOf(path)
    if (expires) return { path, expires }
  }
  return null
}

/// Move the cached profile aside so that xcodebuild has to fetch a new one. Returns the stash so
/// that a failed build can put it back — without that, a refresh attempt with no network or no
/// Xcode account leaves you with no profile at all and nothing to fall back to.
function stashProfile() {
  const p = cachedProfile()
  if (!p) return null
  const daysLeft = (p.expires - Date.now()) / 86400000
  if (daysLeft > REFRESH_UNDER_DAYS) {
    console.log(`signature good until ${p.expires.toDateString()} (${daysLeft.toFixed(1)} days) — keeping it`)
    return null
  }
  const stash = join(tmpdir(), basename(p.path))
  renameSync(p.path, stash)
  console.log(`signature expires ${p.expires.toDateString()} — asking Apple for a new one`)
  return { original: p.path, stash }
}

const { team, identity } = teamId()
const { udid, name } = device()
console.log(`signing as ${identity}\n   team   ${team}\n   device ${name} (${udid})\n`)

// Writes ios/www and regenerates the Xcode project. The app icon is committed, so ios:icon only
// needs running when scripts/gen-icons.mjs changes.
console.log('building the web bundle + the Xcode project…')
run('npm', ['run', 'ios'])

// Release, not Debug: Debug carries the DevBridge, which has no business on a phone you keep.
const XCODEBUILD = ['-project', 'ios/BinderBooks.xcodeproj', '-scheme', 'BinderBooks',
  '-sdk', 'iphoneos', '-destination', 'generic/platform=iOS', '-configuration', 'Release',
  '-derivedDataPath', DERIVED, '-allowProvisioningUpdates',
  `DEVELOPMENT_TEAM=${team}`, 'CODE_SIGN_STYLE=Automatic', 'build']

console.log('\nbuilding + signing for the device…')
const stashed = stashProfile()
try {
  run('xcodebuild', XCODEBUILD)
  if (stashed) rmSync(stashed.stash, { force: true })
} catch (e) {
  if (!stashed) throw e
  // Apple could not issue a new profile. Put the old one back and build with it, because an
  // install on the time that remains beats no install at all.
  renameSync(stashed.stash, stashed.original)
  console.error('\n⚠️  could not refresh the signature — restored the cached one and retrying.')
  console.error('   "No Accounts: Add a new account in Accounts settings" means Xcode has no Apple')
  console.error('   ID signed in. Open Xcode → Settings → Accounts and add yours, or this app will')
  console.error('   stop launching when the cached signature expires and will not re-sign.')
  run('xcodebuild', XCODEBUILD)
}

console.log('\ninstalling…')
try {
  run('xcrun', ['devicectl', 'device', 'install', 'app', '--device', udid, APP])
} catch {
  console.error('\n❌ install failed.')
  console.error('   If it mentioned "maximum number of installed apps using a free developer profile":')
  console.error('   a free profile allows THREE sideloaded apps per device across ALL your projects.')
  console.error('   Delete one from the phone to make room — note that removing an app deletes its')
  console.error('   container, and with it the local ledger. Connect Cloud sync first if it is this one.')
  process.exit(1)
}

run('xcrun', ['devicectl', 'device', 'process', 'launch', '--device', udid, BUNDLE])

const expires = expiryOf(join(APP, 'embedded.mobileprovision'))
console.log('\n✅ installed and launched.')
console.log(expires
  ? `   The signature lasts until ${expires.toDateString()}. Re-run this before then.`
  : '   A free signature expires after 7 days; re-run this when the app stops launching.')
