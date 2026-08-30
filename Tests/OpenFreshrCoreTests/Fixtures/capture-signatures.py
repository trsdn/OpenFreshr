#!/usr/bin/env python3
"""Capture REAL code-signing facts for the reference apps → ``code-signatures.json``.

This is the trust-layer analogue of ``generate.py``: a one-time capture tool that
runs the actual macOS signing tools over the reference machine's apps and freezes
the result into a fixture the Swift test target consumes **offline**. The tests
themselves never shell out — exactly as the spec requires ("no test may check
real signatures").

For every bundle path in ``installed-apps.json`` it records, keyed by bundlePath:

* ``present``        — whether the bundle currently exists on disk.
* ``teamIdentifier`` — the ``TeamIdentifier=`` value from ``codesign -dv``
  (stderr), normalised to ``null`` for Apple's own ``not set`` apps.
* ``verification``   — ``verified`` / ``unsigned`` / ``invalid`` from
  ``codesign --verify --strict``.
* ``gatekeeper``     — ``accepted`` / ``rejected`` from
  ``spctl --assess --type execute``.

The Team IDs captured here are **public** Apple Developer Team identifiers (the
same ten-character codes Apple prints in every notarised app); they are not
secrets. Absent apps (the reference set is a superset of what is installed at any
moment) are recorded ``present: false`` with null signature facts.

Run from the repository root, on the reference machine:

    python3 Tests/OpenFreshrCoreTests/Fixtures/capture-signatures.py
"""

import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CODESIGN = "/usr/bin/codesign"
SPCTL = "/usr/sbin/spctl"


def _run(argv):
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=60)
        return proc.returncode, proc.stdout, proc.stderr
    except Exception as exc:  # pragma: no cover - capture-time diagnostics only
        return 255, "", str(exc)


def team_identifier(path):
    code, out, err = _run([CODESIGN, "-dv", "--", path])
    for line in (err + "\n" + out).splitlines():
        line = line.strip()
        if line.startswith("TeamIdentifier="):
            value = line[len("TeamIdentifier="):].strip()
            if not value or value.lower() == "not set":
                return None
            return value
    return None


def verification(path):
    code, out, err = _run([CODESIGN, "--verify", "--strict", "--", path])
    if code == 0:
        return "verified"
    blob = (err + out).lower()
    if "not signed at all" in blob or "is not signed" in blob:
        return "unsigned"
    return "invalid"


def gatekeeper(path):
    code, _out, _err = _run([SPCTL, "--assess", "--type", "execute", "--", path])
    return "accepted" if code == 0 else "rejected"


def main():
    with open(os.path.join(HERE, "installed-apps.json")) as handle:
        apps = json.load(handle)

    result = {}
    present = 0
    readable_team = 0
    verified = 0
    for app in apps:
        path = app["bundlePath"]
        if not os.path.isdir(path):
            result[path] = {
                "present": False,
                "teamIdentifier": None,
                "verification": "unsigned",
                "gatekeeper": "rejected",
            }
            continue
        present += 1
        team = team_identifier(path)
        verdict = verification(path)
        gate = gatekeeper(path)
        if team:
            readable_team += 1
        if verdict == "verified":
            verified += 1
        result[path] = {
            "present": True,
            "teamIdentifier": team,
            "verification": verdict,
            "gatekeeper": gate,
        }

    out_path = os.path.join(HERE, "code-signatures.json")
    with open(out_path, "w") as handle:
        json.dump(result, handle, indent=2, sort_keys=True)
        handle.write("\n")

    print(f"apps={len(apps)} present={present} readableTeamID={readable_team} verified={verified}")
    print(f"wrote {out_path}")


if __name__ == "__main__":
    sys.exit(main())
