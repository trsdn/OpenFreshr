#!/usr/bin/env python3
"""Coverage-Test v2 - realistischere Einschaetzung.

Neu gegenueber v1:
  * Casks werden zusaetzlich ueber Bundle-IDs aus uninstall/zap-Stanzas
    gematcht (noetig fuer .pkg-Casks wie Office, OneDrive, Teams)
  * Vierte Quelle: Microsoft AutoUpdate (MAU) fuer com.microsoft.*
  * Fuenfte Quelle: Apple softwareupdate fuer com.apple.*
  * Rauschen wird getrennt ausgewiesen (Shortcuts-Droplets, eigene Apps)
"""

import json
import plistlib
import re
import subprocess
from collections import Counter
from pathlib import Path

HERE = Path(__file__).parent
APP_DIRS = [Path("/Applications"), Path.home() / "Applications",
            Path("/Applications/Utilities")]

# Apps, die der User selbst baut -> Update-Quelle liegt in seiner Hand
OWN_PREFIXES = ("com.torsten", "com.torstenmahr", "com.trsdn",
                "com.openwritr", "com.openswitchr", "com.printfilemanager",
                "com.md2loop", "com.hiveterm", "audio.openconnct",
                "com.github.trsdn")


def find_apps():
    seen = {}
    for d in APP_DIRS:
        if d.is_dir():
            for app in sorted(d.glob("*.app")):
                seen.setdefault(app.name, app)
    return list(seen.values())


def read_app(app: Path):
    data = {}
    try:
        with open(app / "Contents" / "Info.plist", "rb") as fh:
            data = plistlib.load(fh)
    except Exception:
        pass
    return {
        "name": app.name,
        "bundle_id": data.get("CFBundleIdentifier", ""),
        "version": data.get("CFBundleShortVersionString")
        or data.get("CFBundleVersion", ""),
        "sparkle_feed": data.get("SUFeedURL", ""),
        "sparkle_fw": (app / "Contents" / "Frameworks" / "Sparkle.framework").exists(),
        "mas": (app / "Contents" / "_MASReceipt" / "receipt").exists(),
        "electron": (app / "Contents" / "Frameworks"
                     / "Electron Framework.framework").exists(),
    }


BID = re.compile(r"^[a-zA-Z0-9]+(\.[a-zA-Z0-9_-]+){2,}$")


def load_casks():
    casks = json.loads((HERE / "cask.json").read_text())
    by_app, by_bid = {}, {}

    def harvest_ids(obj, token):
        """Bundle-IDs aus uninstall/zap-Stanzas einsammeln."""
        if isinstance(obj, dict):
            for key, val in obj.items():
                if key in ("quit", "signal", "launchctl", "login_item",
                           "pkgutil", "kext", "delete", "trash"):
                    vals = val if isinstance(val, list) else [val]
                    for v in vals:
                        if isinstance(v, list):
                            v = v[-1] if v else ""
                        if isinstance(v, str) and BID.match(v.strip()):
                            by_bid.setdefault(v.strip().lower(), token)
                else:
                    harvest_ids(val, token)
        elif isinstance(obj, list):
            for item in obj:
                harvest_ids(item, token)

    for c in casks:
        token = c.get("token", "")
        for art in c.get("artifacts") or []:
            if not isinstance(art, dict):
                continue
            for a in art.get("app") or []:
                target = a if isinstance(a, str) else a.get("target", "")
                if target:
                    by_app.setdefault(str(target).lower(), token)
            for key in ("uninstall", "zap"):
                if key in art:
                    harvest_ids(art[key], token)
    return by_app, by_bid


def brew_installed():
    try:
        return set(subprocess.run(["brew", "list", "--cask"], capture_output=True,
                                  text=True, timeout=60).stdout.split())
    except Exception:
        return set()


def classify(a, by_app, by_bid, installed):
    bid = (a["bundle_id"] or "").lower()

    if bid == "com.apple.shortcuts.droplet":
        return "noise", [], ""
    if bid.startswith(OWN_PREFIXES):
        return "own", ["eigenes Repo / GitHub Releases"], ""
    if a["name"].startswith("Hermes-Setup-Backup"):
        return "noise", [], ""

    cask = by_app.get(a["name"].lower()) or by_bid.get(bid, "")
    src = []
    if a["mas"]:
        src.append("MAS")
    if a["sparkle_feed"]:
        src.append("Sparkle")
    elif a["sparkle_fw"]:
        src.append("Sparkle(rt)")
    if cask:
        src.append("brew*" if cask in installed else "brew")
    if bid.startswith("com.microsoft."):
        src.append("MAU")
    if bid.startswith("com.apple."):
        src.append("softwareupdate")
    return ("covered" if src else "open"), src, cask


def main():
    apps = [read_app(a) for a in find_apps()]
    by_app, by_bid = load_casks()
    installed = brew_installed()

    buckets = {"covered": [], "open": [], "own": [], "noise": []}
    for a in apps:
        kind, src, cask = classify(a, by_app, by_bid, installed)
        a["sources"], a["cask"] = src, cask
        buckets[kind].append(a)

    real = buckets["covered"] + buckets["open"]
    tally = Counter(s.rstrip("*") for a in buckets["covered"] for s in a["sources"])

    print(f"Apps gefunden                    : {len(apps)}")
    print(f"  davon Shortcuts-Droplets/Muell : {len(buckets['noise'])}  (ignorieren)")
    print(f"  davon eigene Apps              : {len(buckets['own'])}  (Update-Quelle kontrollierst du selbst)")
    print(f"  -> relevante Fremd-Apps        : {len(real)}\n")

    print("Treffer pro Quelle (Mehrfachnennung moeglich):")
    for k, v in tally.most_common():
        print(f"  {k:<16} {v:3d}")
    print()

    pct = len(buckets["covered"]) * 100 // len(real)
    print(f"=> AUTOMATISCH ABDECKBAR: {len(buckets['covered']):3d} / {len(real)}  ({pct} %)")
    print(f"=> WIRKLICH OFFEN       : {len(buckets['open']):3d} / {len(real)}  ({100-pct} %)\n")

    print("Wirklich offen (braeuchte GitHub-Release-Regel o. eigenes Rezept):")
    for r in sorted(buckets["open"], key=lambda r: r["name"]):
        print(f"  - {r['name']:<40} {r['bundle_id']}")

    print("\nStichprobe abgedeckt:")
    for r in sorted(buckets["covered"], key=lambda r: r["name"])[:18]:
        print(f"  - {r['name']:<40} {r['version']:<12} {'+'.join(r['sources'])}")

    (HERE / "coverage2.json").write_text(json.dumps(buckets, indent=2))


main()
