# AGENTS.md — OpenFreshr conventions

Guidance for any agent or contributor touching this repository. Keep it short;
change it when the code changes.

## Purpose

OpenFreshr is a native macOS menu bar app that keeps the apps on a Mac up to
date. It finds installed apps, matches them to Homebrew Cask, the Mac App Store,
Microsoft AutoUpdate and Sparkle feeds, delegates each update to the tool that
owns it, and verifies the code signature and Team ID before it replaces
anything. It also discovers and installs apps from the Cask catalogue. What it
does and why is in [`README.md`](README.md) and [`docs/PRD.md`](docs/PRD.md).

## Architecture

- **`OpenFreshrCore` is UI-free.** No `import SwiftUI`, no `import AppKit`. It
  depends only on `Foundation`. All logic (scan, catalog, matching, adoption)
  lives here so it is testable without a window server.
- **`OpenFreshrApp` is a thin SwiftUI shell.** It owns no product logic beyond
  view state; it drives `AdoptionCoordinator` from the core.
- The end-to-end sequence **scan → match → adopt → rescan → confirm** lives in
  `AdoptionCoordinator`, never in a view.

## Boundaries are protocols

Filesystem, process execution and network access sit behind `FileSystemReading`,
`ProcessRunning` and `HTTPFetching`. Tests inject fakes. **No test may write to
`/Applications` or invoke the real `brew`.** Scan directories are injected, never
hard-coded in testable code.

## Safety rules (security-critical)

- Process calls use **separated argument arrays**, never an interpolated shell
  line.
- `brew` is located by probing `/opt/homebrew/bin/brew` and `/usr/local/bin/brew`
  explicitly. A GUI process does not inherit the shell `PATH`.
- Missing Homebrew **degrades**, never blocks: inventory and source attribution
  work without it.
- `--force` is never a silent fallback.
- Adoption success is asserted **only by a fresh rescan**. A `CaskError`
  hard-fail must stay distinguishable from "nothing happened".
- Matching: an exact app-artifact is a **strong** signal; bundle IDs harvested
  from `uninstall`/`zap` and name similarity are **weak** (suggestion only) and
  never authorise adoption alone. A strong artifact match is only adoptable when
  it is **positively corroborated** (the app's bundle id is the cask's strong
  identity) or the cask has `autoUpdates == false`. Two identifier buckets are
  kept apart on purpose (`CaskCatalogIngestion`, `Cask`):
  - **`primaryBundleIdentifiers`** — the cask's *strong* identity, from the
    `quit`, `signal`, `launchctl`, `login_item` and `pkgutil` fields. Only these
    corroborate — **unless** the cask declares no strong identity at all, in
    which case the cleanup bucket may corroborate as a fallback.
  - **`cleanupBundleIdentifiers`** — ids recovered from `trash`/`delete` cleanup
    *paths*. A cleanup path routinely references *foreign* debris, so it is never
    proof of identity. It may still raise a **veto** (a contradiction is a
    contradiction regardless of source), and the veto reasons over **both**
    buckets (`MatchResolver`, the `Copilot`/`copilot-money` regression:
    `copilot-money` names `com.copilot.production` only in a `trash` path, and
    that must still veto `com.microsoft.copilot-mac`).

## Threat model (trust boundary)

OpenFreshr **trusts the integrity of the Homebrew cask catalog.** The
corroboration and veto mechanics exist to stop **accidental** mismatches — the
real, verified case where `Copilot.app` (Microsoft Copilot) collides with the
`copilot-money` finance cask — not to defend against a **compromised catalog**.

No content-based heuristic can defend against a hostile catalog: an attacker who
can place or edit a cask simply writes the victim's bundle id into a *strong*
field (`quit: com.target.app`) instead of a `trash` path, manufacturing
corroboration. Variant A (strong fields only) does not raise this bar — it only
discards a third of the legitimate corroborations — so the split above keeps
path ids out of the *identity* proof while still using them for the *veto*, where
extra contradiction data is always safe.

Corollary for **catalog data flow**: external catalog data must only ever enter
through the **API-shape ingestion** (`CaskCatalogIngestion`), which decides which
bucket each id belongs to. It must **never** be decoded straight into the
internal `Cask` `Codable` form, because that would let an outside source set
`primaryBundleIdentifiers`, `autoUpdates` and `artifacts` directly and bypass
every control. The **on-disk refresh cache is held to exactly this rule**: it is
re-ingested through `CaskCatalogIngestion` (the API form) on every read, never
decoded into the internal `Cask` form, so a hand-crafted cache file is as inert
as a hostile network response — it cannot set `primaryBundleIdentifiers`,
`autoUpdates` or `artifacts`. This is the lesson that retired the earlier
`~/Library/Application Support/OpenFreshr/casks.json` cache, now encoded as an
invariant across `CaskCatalogProvider`, `FileCatalogCacheStore` and
`AppViewModel.loadBundledSnapshot()` (all catalog sources — live fetch, cache and
bundled snapshot — share the one ingestion path).

## Style

- Swift 6 language mode; value types with explicit `public init`; `Sendable`
  everywhere it is free.
- Doc comments (`///`) explain *why*, not *what*. Match the tone of the sibling
  project OpenZonr.
- Tests use `swift-testing` (`import Testing`, `@Test`, `#expect`). Fixtures are
  checked in under `Tests/OpenFreshrCoreTests/Fixtures/` and derive from
  `docs/research/coverage-result.json`.

## Commands

The build commands live in one place, the [README](README.md#build), and the
`Makefile` is their source.

**`make all` is the complete check.** It builds the core and runs the whole test
suite; run it and get a pass before proposing any change. CI runs the same steps.

## Forbidden and high-risk operations

- **No history rewriting.** Never force-push (`--force`, `--force-with-lease`),
  never amend or rebase commits that are already pushed, and never delete or
  move a tag. `main` is protected by a ruleset that refuses force pushes and
  deletion, but do not rely on it; propose changes through pull requests.
- **No secrets.** Never commit, print or log a credential, and never ask for one.
  The repository holds none; the workflows use only the per-run `GITHUB_TOKEN`.
- **No local notarization or releases.** See the next section.
- **No destructive commands** against `/Applications`, the user's Homebrew, or
  `~/Library/Application Support/OpenFreshr`. Tests inject fakes for all of them.
- **Do not hand-edit generated paths**: `OpenFreshr.xcodeproj/**` (regenerate
  with `make generate`), `Sources/OpenFreshrApp/Resources/casks-snapshot.json`
  (`scripts/build-catalog-snapshot.py`) and `Package.resolved`. They are marked
  in `.gitattributes`.

## Agent-authored changes

A change written by an agent is reviewed by a human before it merges, like any
other. Agents work on a branch and open a pull request; they do not push to
`main`. Every commit an agent makes ends with a `Co-Authored-By:` trailer naming
the model, and a pull request an agent opens says so in its description. The
reviewer reads the diff and the `make all` result, not the agent's summary.

## Releases are notarized by the broker, never locally

**Do not run `xcrun notarytool`, do not ask for an app-specific password, and do
not suggest creating a `notarytool` keychain profile.** Apple credentials
deliberately do not exist on this machine — this is a security decision, not an
oversight. Notarization goes through
**[trsdn/macos-notarization-broker](https://github.com/trsdn/macos-notarization-broker)**,
a manual GitHub Actions workflow that builds, signs, notarizes and staples in
isolated jobs so that source-repository code never touches the signing secrets.

The release procedure, the one-time broker profile, the entitlements reasoning
and the self-update details are in [`docs/release/README.md`](docs/release/README.md),
which is their only home. Two rules bind every change:

- `OpenFreshr.xcodeproj` is committed on purpose because the broker cannot run
  XcodeGen. Regenerate **and commit** it after changing `project.yml`.
- The app ships hardened, non-sandboxed, with zero entitlements. Keep
  `Sources/OpenFreshrApp/OpenFreshr.entitlements` in sync with the broker copy
  `docs/release/entitlements/openfreshr.plist`.

OpenFreshr updates itself with mxcl/AppUpdater from its own GitHub Releases.
`SelfUpdateController` (app target) drives it; `SelfUpdateState` and
`SelfUpdateSchedule` in `OpenFreshrCore` hold the testable state and cadence. It
stays distinct from the managed-app update check: the self-update menu items and
the Settings toggle only ever affect OpenFreshr. The package is pinned in
`project.yml` and the committed `Package.resolved`; the broker holds a byte-equal
lock, so a dependency change needs the broker's lock refreshed first.
