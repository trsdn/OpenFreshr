#!/usr/bin/env python3
"""Derive OpenFreshrCore test fixtures from REAL Homebrew cask data.

Reads two sources and emits two fixtures consumed by the Swift test target:

* ``docs/research/coverage-result.json`` — the foreign, update-relevant apps of
  the reference machine (the ``covered`` + ``open`` buckets) → ``installed-apps.json``.
* the real Homebrew cask catalog (``https://formulae.brew.sh/api/cask.json``) →
  the reduced ``casks.json`` fixture, restricted to the tokens the reference
  apps are actually attributed to.

Crucially, the cask fixtures are **not** synthesised any more. The bundle-id
buckets are derived from the real cask stanzas with exactly the same ingestion
algorithm the production ``CaskCatalogIngestion`` uses (see
``Sources/OpenFreshrCore/Catalog``), and the two buckets are kept **separate**:

* ``primaryBundleIdentifiers`` — strong identity fields ``quit`` / ``signal`` /
  ``launchctl`` / ``login_item`` / ``pkgutil`` of the ``uninstall`` / ``zap``
  stanzas; and
* ``cleanupBundleIdentifiers`` — bundle ids embedded in ``trash`` / ``delete``
  *paths* (``~/Library/Preferences/<id>.plist``, ``~/Library/Containers/<id>``,
  …), which reference foreign debris and are not proof of identity.

This means the veto in the regression test now fires against real data:
``copilot-money`` really does declare ``com.copilot.production`` (its own finance
app) in a ``trash`` path, which contradicts the installed Microsoft Copilot's
``com.microsoft.copilot-mac`` — so the strong artifact match is correctly revoked
(the veto reasons over *both* buckets) without any invented identity.

Run from the repository root (uses a local cached snapshot when provided, else
downloads the live catalog once):

    python3 Tests/OpenFreshrCoreTests/Fixtures/generate.py
    OPENFRESHR_CASK_JSON=/path/to/cask.json python3 Tests/OpenFreshrCoreTests/Fixtures/generate.py
"""

import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
COVERAGE = os.path.join(REPO_ROOT, "docs", "research", "coverage-result.json")
CASK_API_URL = "https://formulae.brew.sh/api/cask.json"

# ---------------------------------------------------------------------------
# Ingestion — a faithful Python port of Sources/OpenFreshrCore/Catalog/
# CaskCatalogIngestion.swift. Keep the two in lock-step: any change to the
# extraction rules must land in both so fixtures mirror production behaviour.
# ---------------------------------------------------------------------------

BUNDLE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)+$")
TEAMID_RE = re.compile(r"^[A-Z0-9]{10}$")
IDENTITY_FIELDS = ("quit", "signal", "launchctl", "login_item", "pkgutil")
PATH_FIELDS = ("trash", "delete")
PATH_STRIP_SUFFIXES = (".plist", ".savedstate", ".sfl", ".json", ".binarycookies", ".log")
# A path segment ending in one of these is a file/bundle *name* (e.g.
# `OneDrive.app`) — unless it is a reverse-DNS id that merely ends in one of the
# words (e.g. `com.cmuxterm.app`). We therefore only reject a folder-suffix
# token when it has <= 1 dot separators; real ids have >= 2 components.
FOLDER_SUFFIXES = (".app", ".pkg", ".bundle", ".framework", ".kext", ".plugin",
                   ".qlgenerator", ".prefpane", ".mdimporter", ".xpc")


def canonical_id(tok):
    """Return a clean bundle id for `tok`, or None when it is not an identity."""
    if not tok:
        return None
    tok = tok.strip()
    low = tok.lower()
    for suf in FOLDER_SUFFIXES:
        if low.endswith(suf) and tok.count(".") <= 1:
            return None
    parts = tok.split(".")
    if len(parts) >= 2 and TEAMID_RE.match(parts[0]):
        parts = parts[1:]
    cand = ".".join(parts)
    if not BUNDLE_ID_RE.match(cand):
        return None
    lowc = cand.lower()
    if lowc.startswith("com.apple.") or lowc.startswith("group."):
        return None
    return cand


def ids_from_value(value, out):
    """Collect bundle-id-shaped strings from a str or (nested) list."""
    if isinstance(value, str):
        cid = canonical_id(value)
        if cid:
            out.add(cid)
    elif isinstance(value, list):
        for item in value:
            ids_from_value(item, out)


def ids_from_path(path, out):
    if not isinstance(path, str):
        return
    for seg in path.split("/"):
        seg = seg.strip()
        if seg.endswith("*"):
            seg = seg[:-1]
        changed = True
        while changed:
            changed = False
            for suf in PATH_STRIP_SUFFIXES:
                if seg.lower().endswith(suf):
                    seg = seg[: -len(suf)]
                    changed = True
        cid = canonical_id(seg)
        if cid:
            out.add(cid)


def paths_from_value(value, out):
    if isinstance(value, str):
        ids_from_path(value, out)
    elif isinstance(value, list):
        for item in value:
            paths_from_value(item, out)


def extract_identity(stanza_lists):
    """Split recovered identity into (primary, cleanup) exactly like Swift.

    Strong identity fields → primary; ids embedded in cleanup paths → cleanup.
    """
    primary = set()
    cleanup = set()
    for stanza_list in stanza_lists:
        if not isinstance(stanza_list, list):
            continue
        for stanza in stanza_list:
            if not isinstance(stanza, dict):
                continue
            for field in IDENTITY_FIELDS:
                if field in stanza:
                    ids_from_value(stanza[field], primary)
            for field in PATH_FIELDS:
                if field in stanza:
                    paths_from_value(stanza[field], cleanup)
    return primary, cleanup


def app_target_name(art):
    tgt = art.get("target")
    if isinstance(tgt, str) and tgt:
        return os.path.basename(tgt.rstrip("/"))
    val = art.get("app") or art.get("suite")
    if isinstance(val, list):
        for item in val:
            if isinstance(item, dict) and "target" in item:
                return os.path.basename(str(item["target"]).rstrip("/"))
        for item in val:
            if isinstance(item, str):
                return item
    return None


def ingest(cask):
    """Map one real cask.json record onto the reduced Cask Codable shape."""
    zap_uninstall = []
    artifacts = []
    for art in cask.get("artifacts", []):
        if not isinstance(art, dict):
            continue
        keys = [k for k in art.keys() if k != "target"]
        if not keys:
            continue
        k = keys[0]
        if k in ("app", "suite"):
            target = app_target_name(art)
            entry = {"kind": k}
            if target is not None:
                entry["target"] = target
            artifacts.append(entry)
        elif k in ("pkg", "installer"):
            artifacts.append({"kind": k})
        elif k in ("uninstall", "zap"):
            zap_uninstall.append(art[k])
            artifacts.append({"kind": k})
        elif k == "binary":
            artifacts.append({"kind": "binary"})
    primary, cleanup = extract_identity(zap_uninstall)
    # A path-derived id that is also a strong identity belongs to the cask
    # proper — keep it only in primary; cleanup is strictly path-only.
    cleanup -= primary
    result = {
        "token": cask["token"],
        "names": list(cask.get("name") or []),
        "oldTokens": list(cask.get("old_tokens") or []),
        "autoUpdates": bool(cask.get("auto_updates")),
        "artifacts": artifacts,
        "primaryBundleIdentifiers": sorted(primary),
        # Path-derived ids: kept apart so a trash path cannot forge a
        # corroboration. They may still veto, and corroborate only as a fallback
        # when the cask declares no strong identity at all.
        "cleanupBundleIdentifiers": sorted(cleanup),
    }
    version = cask.get("version")
    if version:
        result["version"] = version
    homepage = cask.get("homepage")
    if homepage:
        result["homepage"] = homepage
    return result


# ---------------------------------------------------------------------------
# Fixture assembly
# ---------------------------------------------------------------------------


def load_apps():
    with open(COVERAGE, encoding="utf-8") as handle:
        data = json.load(handle)
    # The foreign, update-relevant universe: covered + open.
    return data["covered"] + data["open"]


def load_cask_api():
    """Return the real cask catalog as a {token: record} map.

    Prefers a local snapshot (``OPENFRESHR_CASK_JSON``) so the generator is
    reproducible offline; otherwise downloads the live catalog once.
    """
    override = os.environ.get("OPENFRESHR_CASK_JSON")
    if override:
        with open(override, encoding="utf-8") as handle:
            raw = json.load(handle)
    else:
        import urllib.request

        req = urllib.request.Request(CASK_API_URL, headers={"Accept-Encoding": "gzip"})
        with urllib.request.urlopen(req) as resp:  # noqa: S310 (trusted URL)
            payload = resp.read()
            if resp.headers.get("Content-Encoding") == "gzip":
                import gzip

                payload = gzip.decompress(payload)
            raw = json.loads(payload)
    return {c["token"]: c for c in raw}


def installed_app(entry):
    """Map a coverage entry onto the InstalledApp Codable shape."""
    name = entry["name"]
    bundle_id = entry.get("bundle_id") or None
    version = entry.get("version") or None
    feed = entry.get("sparkle_feed") or None
    app = {
        "bundlePath": "/Applications/" + name,
        "hasMacAppStoreReceipt": bool(entry.get("mas")),
        "hasSparkleFramework": bool(entry.get("sparkle_fw")),
        "isElectron": bool(entry.get("electron")),
    }
    # Optionals are omitted when nil so the JSON mirrors Swift's encoding.
    if bundle_id:
        app["bundleIdentifier"] = bundle_id
    if version:
        # Coverage's single version is CFBundleShortVersionString; mirror it into
        # bundleVersion too so both adopt-relevant fields are populated.
        app["shortVersion"] = version
        app["bundleVersion"] = version
    if feed:
        app["sparkleFeedURL"] = feed
    return app


def build_casks(apps, cask_api):
    """Ingest the real casks the reference apps are attributed to."""
    tokens = sorted({entry["cask"] for entry in apps if entry.get("cask")})
    missing = [token for token in tokens if token not in cask_api]
    if missing:
        print(
            "warning: %d attributed token(s) absent from the cask API: %s"
            % (len(missing), ", ".join(missing)),
            file=sys.stderr,
        )
    return [ingest(cask_api[token]) for token in tokens if token in cask_api]


def main():
    apps = load_apps()
    cask_api = load_cask_api()

    installed = [installed_app(entry) for entry in apps]
    casks = build_casks(apps, cask_api)

    installed_path = os.path.join(HERE, "installed-apps.json")
    casks_path = os.path.join(HERE, "casks.json")
    with open(installed_path, "w", encoding="utf-8") as handle:
        json.dump(installed, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    with open(casks_path, "w", encoding="utf-8") as handle:
        json.dump(casks, handle, indent=2, ensure_ascii=False)
        handle.write("\n")

    print(f"wrote {len(installed)} apps -> {installed_path}")
    print(f"wrote {len(casks)} casks -> {casks_path}")

    copilot = next((c for c in casks if c["token"] == "copilot-money"), None)
    if copilot is not None:
        print("copilot-money primaryBundleIdentifiers:", copilot["primaryBundleIdentifiers"])
        print("copilot-money cleanupBundleIdentifiers:", copilot["cleanupBundleIdentifiers"])


if __name__ == "__main__":
    main()
