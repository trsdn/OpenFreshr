# Changelog

All notable changes to OpenFreshr are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and OpenFreshr aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Selbst-Update über AppUpdater statt Sparkle.** OpenFreshr aktualisiert sich wie
  OpenWritr und OpenSwitchr aus den eigenen GitHub-Releases. Angenommen wird nur
  `OpenFreshr-<version>.dmg`, dessen App dieselbe Team-ID, Signing-Identifier und
  Bundle-ID trägt. Es gibt keinen EdDSA-Schlüssel und keinen Appcast mehr.
- Das Release-Profil für den Notarisierungs-Broker deklariert jetzt die
  AppUpdater-Sperrdatei und das Ressourcenbündel.

### Added

- Einstellung „OpenFreshr automatisch aktualisieren“; geprüft wird höchstens einmal
  täglich, installiert wird erst nach Bestätigung.

## [1.0.0] — 2025-09-01

First release. OpenFreshr replaces the discontinued MacUpdater: it discovers the
macOS apps you already have, keeps them current across three backends, installs
new apps from the Homebrew Cask catalog, verifies the trust chain before it ever
replaces an app, and lives in the menu bar.

### Added

- **Bestandserkennung & Adoption (Phase 1).** Scans `/Applications` (and per-user
  apps), matches each installed app to a Cask-catalog entry by bundle identifier,
  and adopts the installed version as the baseline.
- **Update-Erkennung (Phase 2).** Determines the newest available version per app,
  including apps that publish through their own **Sparkle** appcast, and shows a
  clear, de-duplicated "update available" state with robust version comparison.
- **Updates über drei Backends (Phase 3).** Performs updates through **Homebrew**,
  the **Mac App Store** (`mas`), and **Microsoft AutoUpdate** (`msupdate`),
  choosing the right backend per app.
- **Vertrauenskette vor App-Ersatz (Phase 4).** Before any in-place replacement,
  enforces code-signature validity, **Gatekeeper** assessment (`spctl`), and an
  expected **Team ID** — a failed check blocks the replacement (fail-closed).
- **Katalog-Entdeckung & Installation (Phase 5).** Browses the Cask catalog to
  discover and install apps the user does not have yet. All catalog data (live
  fetch, on-disk cache, and bundled snapshot) is ingested through a single
  hardened path so an outside source can never inject bundle identifiers, the
  auto-update flag, or artifacts.
- **Menüleiste & Hintergrundstatus (Phase 6).** A `MenuBarExtra` surfaces the
  count of pending updates and quick actions; the main window shows detail and
  runs a scan on appear. Optional launch-at-login via `SMAppService`.

### Added — delivery hardening & self-update (Phase 7)

- **Gehärteter Direktvertrieb.** The Xcode target enables the **hardened runtime**
  and ships **non-sandboxed** (App Store distribution is an explicit non-goal,
  because OpenFreshr must write to `/Applications`). Entitlements are an empty,
  fully-justified `<dict/>` — OpenFreshr requests **zero** entitlements.
- **Einheitliche Versionierung.** `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`
  in `project.yml` are the single source of truth; `Info.plist` references them so
  release scripts and the app agree on the version.
- **Selbst-Update (Sparkle, Dogfooding).** A UI-free `SelfUpdateChecker` in
  `OpenFreshrCore` reuses the same appcast/version logic OpenFreshr applies to
  other apps, and a "Nach OpenFreshr-Updates suchen …" command (in the app menu
  and the menu bar, kept clearly separate from the managed-app check) drives it.
  The Sparkle framework is integrated behind `#if canImport(Sparkle)` with an
  `NSAlert`/releases-page fallback; enabling the binary dependency is documented
  in `docs/release/README.md`.
- **Release-Dokumentation.** `AGENTS.md` and `docs/release/` document that
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
