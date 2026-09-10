#!/usr/bin/env python3
"""Build, sign, install, and launch Card Tracker on a connected iPhone.

    python3 scripts/ios-device.py            # build Release, install, launch
    python3 scripts/ios-device.py --dry-run  # show the plan, change nothing

A free Apple developer account signs for 7 days. When the signature expires the
app refuses to launch until it is re-signed. This script is that re-sign, and it
manages the four things a free account makes awkward:

1. DEVELOPMENT_TEAM is the certificate's OU field, not the code in the identity's
   name. The name reads "Apple Development: you (9Z2HDDXR94)" and that code is the
   identity's own id. Passing it fails with `No Account for Team`.
2. The 7-day clock starts when Apple issues the profile, not when you install.
   Xcode reuses a cached profile while it is valid, so an install on day 5 keeps
   only 2 days. When fewer than 6 days remain, the script moves the cached
   profile aside so xcodebuild asks Apple for a fresh one.
3. A free account allows three sideloaded apps per device. The fourth install
   fails with MIInstallerErrorDomain error 13, which reads like a signing error.
4. Xcode can look signed in while it is not. The Accounts pane reads a key that
   survives sign-out. The script reads the credential list and warns before it
   builds. xcodebuild cannot answer a two-factor prompt; only the Xcode GUI can.

Standard library only.
"""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IOS = ROOT / "ios"
PROJECT = IOS / "CardTracker.xcodeproj"
SCHEME = "CardTracker"
BUNDLE_ID = "com.ajholloway.cardtracker"
# Its own derived-data path. .gitignore matches ios/build* for this reason.
DERIVED = IOS / "build-device"
PROFILES = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
# Refresh the signature when fewer days than this remain. A fresh profile lasts
# 7 days, so a tight loop asks Apple at most once a day.
REFRESH_UNDER_DAYS = 6


def sh(*args: str, input: str | None = None) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True, input=input).stdout


def run(*args: str) -> None:
    print("$", " ".join(args), flush=True)
    subprocess.run(args, check=True)


def step(title: str) -> None:
    print(f"\n== {title}", flush=True)


# ------------------------------------------------------------------ preflight


def xcode_account_warning() -> str | None:
    """None when Xcode has a signed-in Apple ID with a usable credential.
    A message otherwise.

    The Accounts pane reads `IDEProvisioningTeamByIdentifier`, which survives a
    sign-out, so the pane can show a team while xcodebuild has no account. The
    credential list is `DVTDeveloperAccountManagerAppleIDLists`, and each entry
    needs a keychain item. Read both.
    """
    with tempfile.NamedTemporaryFile(suffix=".plist", delete=False) as tmp:
        path = Path(tmp.name)
    try:
        subprocess.run(["defaults", "export", "com.apple.dt.Xcode", str(path)], check=True, capture_output=True)
        with path.open("rb") as f:
            prefs = plistlib.load(f)
    except Exception:
        return "Could not read Xcode's preferences. If the build fails with 'No Accounts', sign in to Xcode."
    finally:
        path.unlink(missing_ok=True)

    lists = prefs.get("DVTDeveloperAccountManagerAppleIDLists")
    accounts = lists.get("IDE.Identifiers.Prod") if isinstance(lists, dict) else None
    if not accounts:
        return (
            "Xcode has no signed-in Apple ID, whatever the Accounts pane shows.\n"
            "  Open Xcode > Settings > Accounts, remove the stale entry if one is listed, and sign in\n"
            "  again. xcodebuild cannot answer the two-factor prompt; only the Xcode window can."
        )
    for account in accounts:
        account_id = account if isinstance(account, str) else str(account.get("identifier", ""))
        if not account_id:
            continue
        has_token = subprocess.run(
            ["security", "find-generic-password", "-s", "Xcode-Token", "-a", account_id],
            capture_output=True,
        ).returncode == 0
        if has_token:
            return None
    return (
        "Xcode lists an Apple ID but its keychain credential is missing or invalid.\n"
        "  Open Xcode > Settings > Accounts, remove the account, and add it again."
    )


def signing_identity() -> tuple[str, str]:
    """(identity name, team id). The team is the certificate's OU."""
    out = sh("security", "find-identity", "-v", "-p", "codesigning")
    m = re.search(r'"(Apple Development: [^"]+)"', out)
    if not m:
        sys.exit("No 'Apple Development' identity in the keychain. Sign in to Xcode > Settings > Accounts once; Xcode creates it.")
    name = m.group(1)
    pem = sh("security", "find-certificate", "-c", name, "-p")
    subject = sh("openssl", "x509", "-noout", "-subject", input=pem)
    ou = re.search(r"OU\s*=\s*([A-Z0-9]+)", subject)
    if not ou:
        sys.exit(f"Could not read the team (OU) from the certificate for {name}.")
    return name, ou.group(1)


def pick_device(wanted: str | None) -> tuple[str, str]:
    """(udid, name) of the connected iPhone. Wireless pairing counts."""
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as tmp:
        path = tmp.name
    subprocess.run(["xcrun", "devicectl", "list", "devices", "--json-output", path], check=True, capture_output=True)
    data = json.loads(Path(path).read_text())
    Path(path).unlink(missing_ok=True)

    phones = []
    for dev in data.get("result", {}).get("devices", []):
        props = dev.get("deviceProperties", {})
        hw = dev.get("hardwareProperties", {})
        conn = dev.get("connectionProperties", {})
        name = props.get("name", "?")
        udid = dev.get("identifier", "")
        platform = hw.get("platform", "")
        state = conn.get("tunnelState", "")
        if platform != "iOS":
            continue
        phones.append((udid, name, state))

    if wanted:
        for udid, name, state in phones:
            if wanted in (udid, name):
                return udid, name
        sys.exit(f"No iPhone named or identified '{wanted}'. Seen: {[n for _, n, _ in phones]}")

    ready = [p for p in phones if p[2] != "unavailable"]
    if not ready:
        sys.exit("No available iPhone. Plug one in, unlock it, and trust this Mac. Seen: " + ", ".join(f"{n} ({s})" for _, n, s in phones))
    udid, name, _ = ready[0]
    return udid, name


# ------------------------------------------------------------------- profiles


def profile_expiry(path: Path) -> datetime | None:
    try:
        xml = sh("security", "cms", "-D", "-i", str(path))
        plist = plistlib.loads(xml.encode())
    except Exception:
        return None
    exp = plist.get("ExpirationDate")
    if isinstance(exp, datetime):
        return exp if exp.tzinfo else exp.replace(tzinfo=timezone.utc)
    return None


def cached_profile() -> tuple[Path, datetime] | None:
    if not PROFILES.exists():
        return None
    for path in PROFILES.glob("*.mobileprovision"):
        try:
            xml = sh("security", "cms", "-D", "-i", str(path))
        except subprocess.CalledProcessError:
            continue
        if BUNDLE_ID not in xml:
            continue
        exp = profile_expiry(path)
        if exp:
            return path, exp
    return None


def stash_stale_profile(dry_run: bool) -> tuple[Path, Path] | None:
    """Move a profile with too little time left out of Xcode's way. Returns
    (original, stash) so a failed refresh can put it back."""
    found = cached_profile()
    if not found:
        print("no cached profile for this bundle id; xcodebuild will ask Apple for one")
        return None
    path, exp = found
    left = exp - datetime.now(timezone.utc)
    days = left.total_seconds() / 86400
    if days > REFRESH_UNDER_DAYS:
        print(f"signature good until {exp:%a %b %d} ({days:.1f} days); keeping it")
        return None
    print(f"signature expires {exp:%a %b %d} ({days:.1f} days); asking Apple for a new one")
    if dry_run:
        return None
    stash = Path(tempfile.gettempdir()) / path.name
    shutil.move(str(path), str(stash))
    return path, stash


# ----------------------------------------------------------------------- build


def build(team: str, configuration: str, dry_run: bool, account_unusable: bool = False) -> Path:
    app = DERIVED / "Build" / "Products" / f"{configuration}-iphoneos" / f"{SCHEME}.app"
    cmd = [
        "xcodebuild", "-project", str(PROJECT), "-scheme", SCHEME,
        "-sdk", "iphoneos", "-destination", "generic/platform=iOS",
        "-configuration", configuration, "-derivedDataPath", str(DERIVED),
        "-allowProvisioningUpdates",
        f"DEVELOPMENT_TEAM={team}", "CODE_SIGN_STYLE=Automatic", "build",
    ]
    if dry_run:
        print("$", " ".join(cmd))
        return app

    stashed = None if account_unusable else stash_stale_profile(dry_run=False)
    try:
        run(*cmd)
        if stashed:
            stashed[1].unlink(missing_ok=True)
    except subprocess.CalledProcessError:
        if not stashed:
            raise
        original, stash = stashed
        shutil.move(str(stash), str(original))
        print(
            "\nCould not refresh the signature. The cached one is back. Building with it.\n"
            "  'No Accounts: Add a new account in Accounts settings' means Xcode has no Apple ID\n"
            "  signed in. Sign in through Xcode > Settings > Accounts, then run this again,\n"
            "  or the app stops launching when the cached signature expires.",
            file=sys.stderr,
        )
        run(*cmd)
    return app


def install(udid: str, app: Path) -> None:
    try:
        run("xcrun", "devicectl", "device", "install", "app", "--device", udid, str(app))
    except subprocess.CalledProcessError:
        print(
            "\nInstall failed.\n"
            "  If the message mentions the maximum number of apps for a free developer profile,\n"
            "  or MIInstallerErrorDomain error 13: a free account allows three sideloaded apps\n"
            "  per device across every project. Delete one from the phone. Deleting an app also\n"
            "  deletes its container. Export the collection first if that app is this one.",
            file=sys.stderr,
        )
        sys.exit(1)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--device", help="iPhone name or identifier. Default: the first available iPhone.")
    ap.add_argument("--configuration", default="Release", choices=["Release", "Debug"], help="Release by default. Debug adds the simulator-only helpers.")
    ap.add_argument("--no-launch", action="store_true", help="install without launching")
    ap.add_argument("--dry-run", action="store_true", help="print the plan and change nothing")
    args = ap.parse_args()

    step("preflight")
    identity, team = signing_identity()
    udid, name = pick_device(args.device)
    print(f"signing as {identity}\n   team   {team}\n   device {name} ({udid})")
    warning = xcode_account_warning()
    if warning:
        cached = cached_profile()
        if cached:
            days = (cached[1] - datetime.now(timezone.utc)).total_seconds() / 86400
            print(f"warning: {warning}\n  A cached profile with {days:.1f} days left still builds. Continuing with it.")
        else:
            sys.exit(f"stop: {warning}\n  There is no cached profile for {BUNDLE_ID}, so the build cannot sign. Nothing was built.")

    step("Xcode project")
    if args.dry_run:
        print("$ xcodegen generate  (in ios/)")
    else:
        subprocess.run(["xcodegen", "generate"], cwd=IOS, check=True)

    step(f"build and sign ({args.configuration})")
    app = build(team, args.configuration, args.dry_run, account_unusable=warning is not None)

    step("install")
    if args.dry_run:
        print(f"$ xcrun devicectl device install app --device {udid} {app}")
        if not args.no_launch:
            print(f"$ xcrun devicectl device process launch --device {udid} {BUNDLE_ID}")
        return 0
    install(udid, app)

    if not args.no_launch:
        step("launch")
        run("xcrun", "devicectl", "device", "process", "launch", "--device", udid, BUNDLE_ID)

    exp = profile_expiry(app / "embedded.mobileprovision")
    step("done")
    if exp:
        days = (exp - datetime.now(timezone.utc)).total_seconds() / 86400
        print(f"Installed. The signature lasts until {exp:%a %b %d} ({days:.1f} days). Run this again before then.")
    else:
        print("Installed. A free signature lasts 7 days. Run this again when the app stops launching.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as err:
        print(f"\ncommand failed with exit code {err.returncode}: {' '.join(map(str, err.cmd))}", file=sys.stderr)
        sys.exit(err.returncode or 1)
    except KeyboardInterrupt:
        sys.exit(130)
