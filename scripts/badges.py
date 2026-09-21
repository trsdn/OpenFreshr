#!/usr/bin/env python3
"""Render the license and platform README badges as self-contained SVGs.

Every value is read from its authority (the app's Info.plist and Package.swift), so
no badge value is typed by hand. Standard library only, and the output references
no external resource.

    python3 scripts/badges.py --out DIR      write license.svg and platform.svg
    python3 scripts/badges.py --print NAME   print one value (license, platform)
"""

from __future__ import annotations

import argparse
import plistlib
import re
import sys
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent.parent

LABEL_COLOR = "#555"
COLORS = {"license": "#2e7d32", "platform": "#1565c0"}


def read_license(root: Path = ROOT) -> str:
    with (root / "Sources/OpenFreshrApp/Info.plist").open("rb") as handle:
        return str(plistlib.load(handle)["OFRLicenseIdentifier"])


def read_platform(root: Path = ROOT) -> str:
    manifest = (root / "Package.swift").read_text(encoding="utf-8")
    match = re.search(r"\.macOS\(\.v(\d+)\)", manifest)
    if not match:
        raise SystemExit("Package.swift declares no .macOS(.vN) platform")
    return f"macOS {match.group(1)}+"


def text_width(text: str) -> int:
    return int(len(text) * 6.6) + 10


def render_badge(label: str, value: str, color: str) -> str:
    left, right = text_width(label), text_width(value)
    total = left + right
    description = escape(f"{label}: {value}", {'"': "&quot;"})
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{total}" height="20" '
        f'role="img" aria-label="{description}">'
        f"<title>{escape(label)}: {escape(value)}</title>"
        f'<rect width="{left}" height="20" fill="{LABEL_COLOR}"/>'
        f'<rect x="{left}" width="{right}" height="20" fill="{color}"/>'
        '<g fill="#fff" font-family="Verdana,DejaVu Sans,sans-serif" font-size="11" '
        'text-anchor="middle">'
        f'<text x="{left / 2:.1f}" y="14">{escape(label)}</text>'
        f'<text x="{left + right / 2:.1f}" y="14">{escape(value)}</text>'
        "</g></svg>\n"
    )


READERS = {"license": read_license, "platform": read_platform}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--out", type=Path, help="directory to write the SVG files into")
    group.add_argument("--print", dest="show", choices=sorted(READERS), help="print one value")
    args = parser.parse_args()

    if args.show:
        print(READERS[args.show]())
        return 0

    args.out.mkdir(parents=True, exist_ok=True)
    for name, reader in READERS.items():
        svg = render_badge(name, reader(), COLORS[name])
        (args.out / f"{name}.svg").write_text(svg, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
