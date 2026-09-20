# AGENTS.md — OpenFreshr conventions

Guidance for any agent or contributor touching this repository. Keep it short;
change it when the code changes.

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

- `make build` — `swift build` (core).
- `make test` — `swift test` (core, fixtures only).
- `make generate` — XcodeGen → `OpenFreshr.xcodeproj`.
- `make app` — compile the SwiftUI shell (signing disabled).

## Releases are notarized by the broker, never locally

**Do not run `xcrun notarytool`, do not ask for an app-specific password, and do
not suggest creating a `notarytool` keychain profile.** Apple credentials
deliberately do not exist on this machine — this is a security decision, not an
oversight.

Notarization goes through **[trsdn/macos-notarization-broker](https://github.com/trsdn/macos-notarization-broker)**,
a manual GitHub Actions workflow that builds, signs, notarizes and staples in
isolated jobs so that source-repository code never touches the signing secrets.

To cut a release:

1. Set `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`, run
   `make generate`, and **commit** the regenerated `OpenFreshr.xcodeproj` with the
   source. The broker builds the committed project; it cannot run XcodeGen.
2. Tag the commit `vX.Y.Z` and push the tag.
3. From a checkout of the broker: `scripts/request.sh openfreshr vX.Y.Z`
   (or **Actions → Notarize macOS release → Run workflow** from `main`).

`request.sh` correlates the exact run, downloads only that artifact, and verifies
`provenance.json` plus the release digests.

### OpenFreshr must first be allowlisted as the `openfreshr` profile

The broker only signs applications listed in its `profiles/apps.json`, and runs a
per-app build adapter. **Neither exists for OpenFreshr yet.** The full,
ready-to-paste material — the profile block (real `repository_id`, `team_id`
`G69Z5BNY97`, `com.openfreshr.app`, arm64, min macOS 14, zip+dmg), the broker-owned
entitlements plist, and the `openfreshr-xcode` adapter with its three `broker.py`
edit sites — is prepared in [`docs/release/`](docs/release/README.md), which also
lists the two remaining one-line edits (`request.sh` allowlist and the
`notarize.yml` dispatch options). The broker's `CONTRIBUTING.md` requires an
**issue first** for any profile or script change, then a reviewed PR.

Consequences for this repository:

- `OpenFreshr.xcodeproj` is committed on purpose. The broker's build job uses only
  the preinstalled runner toolchain, so it cannot fetch `xcodegen`. Regenerate
  **and commit** the project after changing `project.yml`.
- The repository must stay readable by the broker workflow, which authenticates
  with its own `github.token`.

### The app ships hardened, non-sandboxed, with zero entitlements

`ENABLE_HARDENED_RUNTIME=YES`, `ENABLE_APP_SANDBOX=NO`. It is not sandboxed because
it must write to `/Applications` to replace apps in place; App Store distribution
is an explicit non-goal. A non-sandboxed hardened app needs **no** entitlement to
spawn `brew`/`mas`/`msupdate`/`codesign`/`spctl`, reach the network, register a
login item, or post notifications, so `Sources/OpenFreshrApp/OpenFreshr.entitlements`
is an empty `<dict/>` with the reasoning spelled out. Keep it in sync with the
broker copy `docs/release/entitlements/openfreshr.plist`.

### Self-update is AppUpdater, like the other apps

OpenFreshr updates itself with mxcl/AppUpdater 4.1.2 from its own GitHub Releases,
the same as OpenWritr and OpenSwitchr. `SelfUpdateController` (app target) drives
it; `SelfUpdateState` and `SelfUpdateSchedule` in `OpenFreshrCore` hold the
testable state and cadence. It is kept distinct from the managed-app "Jetzt
prüfen" flow: the "Nach OpenFreshr-Updates suchen …" items and the Settings toggle
only ever affect OpenFreshr. The updater accepts only an asset named
`OpenFreshr-<semver>.dmg` whose app has the same Team ID, signing identifier and
bundle identifier. There is no EdDSA key and no appcast. The package is pinned in
`project.yml` and the committed `Package.resolved`; the broker holds a byte-equal
lock, so a dependency change needs the broker's lock refreshed first. See
[`docs/release/README.md`](docs/release/README.md).
