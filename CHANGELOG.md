# Changelog

All notable changes to OpenFreshr are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and OpenFreshr aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Self-update through AppUpdater instead of Sparkle.** Like OpenWritr and
  OpenSwitchr, OpenFreshr now updates itself from its own GitHub Releases. Only
  `OpenFreshr-<version>.dmg` is accepted, and only when its app carries the same
  Team ID, signing identifier and bundle ID. There is no EdDSA key and no appcast
  any more.
- The release profile for the notarization broker now declares the AppUpdater
  lock file and the resource bundle.
- The documentation is in English. The UI is English with a German translation.

### Added

- Setting "Update OpenFreshr automatically"; the check runs at most once a day,
  and nothing is installed before you confirm.
- `Info.plist` carries the copyright holder, the licence identifier and the
  repository and issue-tracker URLs, and the repository has an app icon source
  (`scripts/make-app-icon.swift`).
- README sections on privacy, accessibility, compatibility and support.

## [1.0.0] — not yet released

The date of this entry is unknown because no tag or release exists yet; it is
dated when the first release is cut.

First release. OpenFreshr replaces the discontinued MacUpdater: it discovers the
macOS apps you already have, keeps them current across three backends, installs
new apps from the Homebrew Cask catalog, verifies the trust chain before it ever
replaces an app, and lives in the menu bar.

### Added

- **Inventory and adoption (phase 1).** Scans `/Applications` (and per-user
  apps), matches each installed app to a Cask-catalog entry by bundle identifier,
  and adopts the installed version as the baseline.
- **Update detection (phase 2).** Determines the newest available version per app,
  including apps that publish through their own **Sparkle** appcast, and shows a
  clear, de-duplicated "update available" state with robust version comparison.
- **Updates through three backends (phase 3).** Performs updates through
  **Homebrew**, the **Mac App Store** (`mas`), and **Microsoft AutoUpdate**
  (`msupdate`), choosing the right backend per app.
- **Trust chain before app replacement (phase 4).** Before any in-place
  replacement, enforces code-signature validity, **Gatekeeper** assessment
  (`spctl`), and an expected **Team ID** — a failed check blocks the replacement
  (fail-closed).
- **Catalog discovery and installation (phase 5).** Browses the Cask catalog to
  discover and install apps the user does not have yet. All catalog data (live
  fetch, on-disk cache, and bundled snapshot) is ingested through a single
  hardened path so an outside source can never inject bundle identifiers, the
  auto-update flag, or artifacts.
- **Menu bar and background status (phase 6).** A `MenuBarExtra` surfaces the
  count of pending updates and quick actions; the main window shows detail and
  runs a scan on appear. Optional launch-at-login via `SMAppService`.

### Added — delivery hardening & self-update (phase 7)

- **Hardened direct distribution.** The Xcode target enables the **hardened
  runtime** and ships **non-sandboxed** (App Store distribution is an explicit
  non-goal, because OpenFreshr must write to `/Applications`). Entitlements are an
  empty, fully-justified `<dict/>` — OpenFreshr requests **zero** entitlements.
- **Single version source.** `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in
  `project.yml` are the single source of truth; `Info.plist` references them so
  release scripts and the app agree on the version.
- **Self-update (Sparkle, dogfooding).** A UI-free `SelfUpdateChecker` in
  `OpenFreshrCore` reuses the same appcast/version logic OpenFreshr applies to
  other apps, and a command to check for OpenFreshr updates (in the app menu and
  the menu bar, kept clearly separate from the managed-app check) drives it. The
  Sparkle framework is integrated behind `#if canImport(Sparkle)` with an
  `NSAlert`/releases-page fallback; enabling the binary dependency is documented
  in `docs/release/README.md`. Superseded by AppUpdater, see `[Unreleased]`.
- **Release documentation.** `AGENTS.md` and `docs/release/` document that
  notarization runs **only** through
  [trsdn/macos-notarization-broker](https://github.com/trsdn/macos-notarization-broker)
  — never locally, no `notarytool`, no app-specific password — and ship the
  ready-to-paste broker profile, entitlements, and build-adapter reference.

### Security

- Catalog ingestion is one-way through the API-shape path; hand-crafted cache
  files are as inert as a hostile network response.
- The trust chain (signature + Gatekeeper + Team ID) gates every app replacement
  and fails closed.
- No Apple or Sparkle signing secrets live in the repository or on the dev
  machine; releases are signed and notarized in the broker's isolated jobs, and
  the Sparkle EdDSA private key is kept outside the repository.

[Unreleased]: https://github.com/trsdn/OpenFreshr/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/trsdn/OpenFreshr/releases/tag/v1.0.0
