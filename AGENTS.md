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
every control. In phase 1 there is deliberately **no on-disk cache** for the
catalog for exactly this reason (`AppViewModel.loadCatalog()` loads only the
bundled snapshot); a phase-2 live fetch must re-ingest via the API form.

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
