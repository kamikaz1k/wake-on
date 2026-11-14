#!/usr/bin/env python3
"""Build Wake On and install it on the iPhone, renewing signing when it has expired.

    python3 native/ios/scripts/deploy-phone.py            # build, renew if needed, install
    python3 native/ios/scripts/deploy-phone.py --check    # only report profile expiry
    python3 native/ios/scripts/deploy-phone.py --launch   # also open the app afterwards

Signing is renewed in this order, stopping at the first that works:
1. An App Store Connect API key (fully headless, needs nobody signed in). Configure it once
   in ~/.appstoreconnect/wakeon.env (outside the repo):
       ASC_KEY_ID=ABC123XYZ
       ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000
       ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_ABC123XYZ.p8
2. The Apple account saved in Xcode › Settings › Accounts (xcodebuild -allowProvisioningUpdates).
3. The running Xcode app: it opens the project and builds it once over AppleScript, which makes
   Xcode renew the profiles with the account it holds. Needs "claude can control Xcode" allowed
   once in Privacy & Security › Automation.
"""
import argparse
import datetime as dt
import os
import plistlib
import subprocess
import sys
import time
from pathlib import Path

IOS = Path(__file__).resolve().parent.parent
PROJECT = IOS / "WakeOn.xcodeproj"
DERIVED = IOS / "build-device"
APP = DERIVED / "Build/Products/Debug-iphoneos/WakeOn.app"
DEVICE = "5976CF6D-0FD6-5A57-9711-AA29F94404E7"
TEAM = "JDR6VAV2RA"
BUNDLES = ["dev.wakeon.ios", "dev.wakeon.ios.LiveActivity"]
PROFILES = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
ASC_ENV = Path.home() / ".appstoreconnect/wakeon.env"
ENV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
RENEW_BELOW_DAYS = 2


def log(message: str) -> None:
    print(f"[deploy] {message}", flush=True)


def profile_expiry() -> dict[str, dt.datetime]:
    """Latest expiry date per bundle id among the installed development profiles."""
    latest: dict[str, dt.datetime] = {}
    for path in PROFILES.glob("*.mobileprovision"):
        raw = subprocess.run(["security", "cms", "-D", "-i", str(path)],
                             capture_output=True).stdout
        if not raw:
            continue
        info = plistlib.loads(raw)
        app_id = info.get("Entitlements", {}).get("application-identifier", "")
        bundle = app_id.split(".", 1)[1] if "." in app_id else ""
        if bundle in BUNDLES:
            expiry = info["ExpirationDate"].replace(tzinfo=dt.timezone.utc)
            latest[bundle] = max(expiry, latest.get(bundle, expiry))
    return latest


def days_left() -> dict[str, float]:
    now = dt.datetime.now(dt.timezone.utc)
    expiry = profile_expiry()
    return {b: (expiry[b] - now).total_seconds() / 86400 if b in expiry else -1 for b in BUNDLES}


def report() -> bool:
    ok = True
    for bundle, days in days_left().items():
        state = "missing" if days < 0 and days == -1 else f"{days:.1f} days left"
        log(f"profile {bundle}: {state}")
        ok &= days >= RENEW_BELOW_DAYS
    return ok


def asc_flags() -> list[str]:
    if not ASC_ENV.exists():
        return []
    values = {}
    for line in ASC_ENV.read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip('"')
    key_path = Path(os.path.expanduser(values.get("ASC_KEY_PATH", "")))
    if not (values.get("ASC_KEY_ID") and values.get("ASC_ISSUER_ID") and key_path.is_file()):
        log(f"{ASC_ENV} is incomplete; ignoring it")
        return []
    return ["-authenticationKeyPath", str(key_path), "-authenticationKeyID", values["ASC_KEY_ID"],
            "-authenticationKeyIssuerID", values["ASC_ISSUER_ID"]]


def build() -> tuple[bool, str]:
    flags = asc_flags()
    log("building" + (" (App Store Connect key)" if flags else ""))
    result = subprocess.run(
        ["xcodebuild", "-project", str(PROJECT), "-scheme", "WakeOn", "-configuration", "Debug",
         "-destination", "generic/platform=iOS", "-derivedDataPath", str(DERIVED),
         "-allowProvisioningUpdates", *flags, f"DEVELOPMENT_TEAM={TEAM}", "build"],
        capture_output=True, text=True, env=ENV)
    output = result.stdout + result.stderr
    errors = sorted({l.strip() for l in output.splitlines() if "error:" in l})
    for line in errors[:8]:
        log(line)
    return result.returncode == 0, output


def renew_with_xcode_app(timeout: float = 300) -> bool:
    """Ask the Xcode app to open and build the project; it renews profiles itself."""
    before = profile_expiry()
    log("asking the Xcode app to renew signing (open + build over AppleScript)")
    script = f'''
    with timeout of {int(timeout)} seconds
      tell application "Xcode"
        set ws to open "{PROJECT}"
        repeat 120 times
          if loaded of ws then exit repeat
          delay 1
        end repeat
        set r to build ws
        repeat {int(timeout) - 30} times
          if completed of r then exit repeat
          delay 1
        end repeat
        return status of r as text
      end tell
    end timeout'''
    proc = subprocess.Popen(["osascript", "-e", script], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True)
    deadline = time.time() + timeout
    while time.time() < deadline:
        after = profile_expiry()
        if all(b in after and (b not in before or after[b] > before[b]) for b in BUNDLES):
            log("Xcode renewed the profiles")
            proc.kill()
            return True
        if proc.poll() is not None:
            out, err = proc.communicate()
            if "-1743" in err:
                log("macOS refused AppleScript control of Xcode. Allow it once in System Settings › "
                    "Privacy & Security › Automation.")
                return False
            if "-1712" in err:
                log("Xcode didn't answer (a macOS permission prompt may be waiting)")
            # The build finished; give the profile files a moment to appear.
            time.sleep(5)
            after = profile_expiry()
            return all(b in after and days_left()[b] >= RENEW_BELOW_DAYS for b in BUNDLES)
        time.sleep(2)
    proc.kill()
    log("timed out waiting for Xcode")
    return False


def install(launch: bool) -> bool:
    log("installing on the phone")
    result = subprocess.run(["xcrun", "devicectl", "device", "install", "app", "--device", DEVICE,
                             str(APP)], capture_output=True, text=True, env=ENV)
    if result.returncode != 0:
        lines = (result.stderr + result.stdout).strip().splitlines()
        log(next((l.strip() for l in lines if "ERROR" in l), lines[-1].strip() if lines else "install failed"))
        log("If the phone is unreachable: native/ios/scripts/device-link-check.py, "
            "restart Wi-Fi on both ends, or plug in the cable.")
        return False
    log("installed")
    if launch:
        subprocess.run(["xcrun", "devicectl", "device", "process", "launch", "--terminate-existing",
                        "--device", DEVICE, "dev.wakeon.ios"], capture_output=True, env=ENV)
        log("launched")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="only report profile expiry")
    parser.add_argument("--launch", action="store_true", help="open the app after installing")
    parser.add_argument("--no-install", action="store_true", help="build (and renew) only")
    args = parser.parse_args()

    fresh = report()
    if args.check:
        return 0 if fresh else 1
    ok, output = build()
    signing_failed = any(s in output for s in ("No Accounts", "No profiles for", "expired",
                                               "requires a provisioning profile"))
    if not ok and signing_failed:
        if not renew_with_xcode_app():
            log("could not renew signing automatically. Sign in once in Xcode › Settings › Accounts, "
                f"or add an App Store Connect key in {ASC_ENV}.")
            return 1
        report()
        ok, output = build()
    if not ok:
        return 1
    if not fresh and not signing_failed:
        report()
    return 0 if args.no_install or install(args.launch) else 1


if __name__ == "__main__":
    sys.exit(main())
