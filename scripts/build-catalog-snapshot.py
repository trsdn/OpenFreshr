#!/usr/bin/env python3
"""Build the bundled Homebrew cask catalog snapshot shipped with the app.

OpenFreshr's ``loadCatalog()`` falls back to this snapshot when no fresh cache is
present (live fetching is phase 2), so the app matches and classifies real apps
out of the box, with no network and even with Homebrew absent.

The snapshot keeps the **real Homebrew cask API shape** (``cask.json``) so it is
ingested at runtime by the *production* ``CaskCatalogIngestion`` — the same code
path a live fetch will use. It is reduced two ways to stay small:

* only the fields ingestion reads are kept
  (``token``/``name``/``old_tokens``/``version``/``auto_updates``/``homepage`` and
  the ``artifacts`` array, itself trimmed to the ``app``/``suite``/``pkg``/
  ``installer``/``binary``/``uninstall``/``zap`` stanzas + ``target``), and
* only casks that can actually participate in phase-1 matching are kept: a cask
  is dropped when it neither ships a moved (``app``/``suite``) artifact nor
  declares any ``uninstall``/``zap`` identity stanza, because such a cask can
  never be an adoption target nor supply a veto/corroboration identity.

Run from the repository root (offline snapshot preferred, else live download):

    python3 scripts/build-catalog-snapshot.py
    OPENFRESHR_CASK_JSON=/path/to/cask.json python3 scripts/build-catalog-snapshot.py
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, ".."))
OUT_PATH = os.path.join(REPO_ROOT, "Sources", "OpenFreshrApp", "Resources", "casks-snapshot.json")
CASK_API_URL = "https://formulae.brew.sh/api/cask.json"

# Top-level cask fields the production ingestion reads.
CASK_FIELDS = ("token", "name", "old_tokens", "version", "auto_updates", "homepage")
# Artifact keys ingestion reads: the moved/installer kinds, the identity stanzas,
# and the sibling `target` app/suite install location.
ARTIFACT_KEYS = ("app", "suite", "pkg", "installer", "binary", "uninstall", "zap", "target")


def load_cask_api():
    override = os.environ.get("OPENFRESHR_CASK_JSON")
    if override:
        with open(override, encoding="utf-8") as handle:
            return json.load(handle)
    import urllib.request

    req = urllib.request.Request(CASK_API_URL, headers={"Accept-Encoding": "gzip"})
    with urllib.request.urlopen(req) as resp:  # noqa: S310 (trusted URL)
        payload = resp.read()
        if resp.headers.get("Content-Encoding") == "gzip":
            import gzip

            payload = gzip.decompress(payload)
        return json.loads(payload)


def reduce_artifact(artifact):
    if not isinstance(artifact, dict):
        return None
    reduced = {k: v for k, v in artifact.items() if k in ARTIFACT_KEYS}
    return reduced or None


def reduce_cask(cask):
    reduced = {k: cask.get(k) for k in CASK_FIELDS if cask.get(k) is not None}
    artifacts = [reduce_artifact(a) for a in cask.get("artifacts", [])]
    reduced["artifacts"] = [a for a in artifacts if a]
    return reduced


def has_phase1_signal(cask):
    ships_moved = False
    has_identity = False
    for artifact in cask.get("artifacts", []):
        if not isinstance(artifact, dict):
            continue
        if any(key in ("app", "suite") for key in artifact):
            ships_moved = True
        if any(key in ("uninstall", "zap") for key in artifact):
            has_identity = True
    return ships_moved or has_identity


def main():
    raw = load_cask_api()
    kept = [reduce_cask(c) for c in raw if has_phase1_signal(c)]
    # Deterministic, reviewable order.
    kept.sort(key=lambda c: c["token"])
    with open(OUT_PATH, "w", encoding="utf-8") as handle:
        json.dump(kept, handle, ensure_ascii=False, separators=(",", ":"))
        handle.write("\n")
    size = os.path.getsize(OUT_PATH)
    print(
        "wrote %d of %d casks -> %s (%.2f MB)"
        % (len(kept), len(raw), OUT_PATH, size / 1_000_000),
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
