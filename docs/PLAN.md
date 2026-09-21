# Implementation plan: OpenFreshr

> Source: [PRD.md](PRD.md)  
> Principle: Each phase is a narrow, independently startable tracer bullet with
> visible end-to-end user value. No production code is part of this document yet.

## Lasting architecture decisions

- **Platform:** native macOS app, SwiftUI, macOS 14+, Apple Silicon first.
- **Project structure:** separately testable Swift 6 core plus a thin app shell.
  Declarative XcodeGen project; the generated Xcode project file is checked in for
  reproducible broker builds.
- **Primary UI:** main window with `NavigationSplitView`; "Installed" and
  "Catalog" are stable main sections.
- **Detection:** the local inventory scan is fully independent of Homebrew.
- **Source model:** an app can have several sources at the same time; conflicts
  are preserved rather than hidden by a global priority.
- **Execution:** swappable `PackageBackend`; the first backends are Homebrew,
  Mac App Store and Microsoft AutoUpdate.
- **Matching:** exact app artifacts and bundle IDs are strong signals.
  Fuzzy name matches are only suggestions until the user confirms them.
- **Security:** structured process invocations without shell interpolation;
  signature verification, Gatekeeper and Team ID trust before replacing an app.
- **Privileges:** no privileged helper in v1. Elevated rights stay with the
  executing backend and its visible system prompt.
- **Self-updaters:** show Sparkle/Electron apps by default, do not trigger them;
  `msupdate` may be run actively.
- **Persistence:** local cache for catalog and scan; local trust store for
  Team IDs and confirmed match exceptions.
- **Release:** Developer ID, notarization, stapling, DMG and Sparkle. Signing
  secrets stay in the existing notarization broker, not in this repository.

## Quality strategy for all phases

- Test external behavior at module boundaries, not private details.
- Abstract the file system, network and processes; tests do not modify real apps.
- Use real, checked-in fixtures from anonymized variants of the coverage scan,
  cask API responses and appcasts.
- Each phase has at least one automated end-to-end smoke test of its value path
  as well as targeted failure cases.
- After real package actions, only a fresh scan counts as proof of success.

---

## Phase 1: Detect the inventory and adopt apps

**User stories covered:** 1–18, 41, 45–47

### User value

The user starts OpenFreshr, sees their installed GUI apps with version and
source, and gets the central preview: which manually installed apps can be
safely taken over into Homebrew management right away? They select individual
apps and trigger `brew install --cask --adopt` in a controlled way.

### End-to-end scope

- Native app shell with the "Installed" section.
- Scan of `/Applications`, `~/Applications` and `/Applications/Utilities`.
- Normalized app model built from bundle metadata, MAS receipt, and Sparkle and
  Electron markers.
- Local cask catalog cache and matching via app artifact, bundle ID and
  conservative name similarity.
- Match explanation and confidence in the UI.
- Display of app, installed version, available version and source.
- Detection of the Homebrew management status, without making the scan depend
  on it.
- Adoption preview with individual selection; uncertain matches are not
  preselected and cannot be run directly.
- Execution through the Homebrew backend with separate process arguments.
- Progress, errors and a fresh scan per adoption.

### Key product rule

The coverage scan contains a known false candidate:
`Copilot.app` must not be assigned to the cask `copilot-money` or adopted by it
based on its name alone. This case becomes a fixed regression test for the
resolver.

### Acceptance criteria

- [ ] The app starts and shows a real scan of the reference system.
- [ ] At least 100 of 109 relevant third-party apps receive a traceable source
      assignment.
- [ ] Controlled suggestions enable at least 104 assignments, without
      automatically approving any fuzzy match.
- [ ] Without Homebrew, the inventory and source view remain usable.
- [ ] Confidently matched, unmanaged casks appear in the adoption preview.
- [ ] The user can include or exclude each adoption individually.
- [ ] The preview shows app path, cask token, match reason and the action to be
      executed.
- [ ] The known `Copilot`/`copilot-money` mismatch is blocked.
- [ ] A process error stays attached to the affected app and is repeatable.
- [ ] A successful adoption is shown as successful only after a fresh scan.

---

## Phase 2: Show available updates reliably

**User stories covered:** 19–22, 39–41, 45, 47

### User value

The installed view becomes the central update dashboard. It shows outdated
apps, source conflicts and self-updating apps, but does not yet run general
updates.

### End-to-end scope

- Make the refresh state and cache age visible for the cask catalog and
  analytics.
- Compare available cask versions against installed versions.
- Load explicit Sparkle appcasts defensively and select matching releases.
- Determine MAS and MAU availability through their respective tools.
- Present source, freshness, update state and uncertainty per app.
- Filters "Updates", "Self-updating", "Unmatched" and "Errors".
- Manual refresh of all metadata and a fresh scan.
- Offline fallback to the last successful inventory and catalog with a clear
  age indication.
- Persistent check cache with a timestamp, so an app restart does not force a
  full network check.
- System ignore list for Apple-owned and MDM-managed apps, as well as
  user-defined ignoring per app or per version.

### Acceptance criteria

- [ ] Each app can have several visible sources and their status.
- [ ] An unreachable service does not delete the last known data.
- [ ] Non-comparable versions are shown as "unknown" rather than as an update.
- [ ] Sparkle/Electron apps are marked as self-updating.
- [ ] An embedded Sparkle framework without a readable feed does not produce an
      invented available version.
- [ ] Stale cache data is clearly recognizable in the UI.
- [ ] Ignored apps and skipped versions remain viewable and can be undone.
- [ ] All parsers and version cases run reproducibly against local fixtures.

---

## Phase 3: Run updates through three backends

**User stories covered:** 20–27, 38, 41, 45–47

### User value

The user selects updates and runs Homebrew, Mac App Store and Microsoft
AutoUpdate actions in one consistent flow.

### End-to-end scope

- Unified preview for update actions, independent of the backend.
- Homebrew cask updates, including `auto_updates` and `latest`.
- Mac App Store updates through `mas`.
- Microsoft updates through `msupdate`.
- Self-updating Sparkle/Electron apps remain notice-only by default.
- Per-app exception "update via OpenFreshr anyway", provided a suitable
  executable backend exists.
- Batch progress with an independent result per app.
- Retry of failed actions without re-running successful apps.
- Fresh scan after each completed action.
- Major upgrades are detected, shown separately and confirmed separately.

### Acceptance criteria

- [ ] The preview names app, target version, backend and package identifier.
- [ ] No action starts without explicit user approval.
- [ ] Homebrew, MAS and MAU actions deliver the same understandable status
      model.
- [ ] Sparkle/Electron apps are not automatically updated in parallel.
- [ ] A major upgrade is never approved in a single step together with regular
      updates.
- [ ] An error in one backend does not produce a false success message for other
      or subsequent apps.
- [ ] Cancellation and retry are deterministic and tested.
- [ ] After the process, the local scan decides the actual state.

---

## Phase 4: Enforce the chain of trust before replacing an app

**User stories covered:** 28–32, 45–47

### User value

OpenFreshr actively protects against unexpected publisher changes and makes
security decisions understandable. This is a visible unique selling point
compared with a pure package manager frontend.

### End-to-end scope

- Capture the Team ID of installed apps at the first scan as trust on first use.
- Integrate signature verification and Gatekeeper assessment into the action
  flow.
- Compare the Team ID of the new version against the stored trust value.
- Blocking conflict view for an invalid signature, Gatekeeper rejection or
  Team ID change.
- Explicit, logged exception flow for a legitimate Team ID change.
- View for reviewing and resetting stored trust decisions.
- Clear separation between OpenFreshr's verification and the backend's security
  guarantees.

### Acceptance criteria

- [ ] An invalid signature blocks the app replacement.
- [ ] A Gatekeeper rejection blocks the app replacement.
- [ ] An unchanged Team ID allows the normal flow.
- [ ] A changed Team ID stops the action before the replacement.
- [ ] The warning shows the old and new Team ID as well as the affected bundle
      ID.
- [ ] An exception requires a separate explicit confirmation and is stored in a
      traceable way.
- [ ] A trust reset leads to a new first observation on the next scan, not to
      implicit trust.

---

## Phase 5: Discover and install new apps from the catalog

**User stories covered:** 33–41, 45–47

### User value

OpenFreshr turns from an updater into the "App Store for the rest of the Mac":
the user can browse the cask catalog, discover popular apps and install a
selected GUI app.

### End-to-end scope

- Second main section "Catalog" in the `NavigationSplitView`.
- Local cache of the cask catalog and the 365-day install statistics.
- Search by token, name and description.
- Sorting by popularity and name.
- Detail view with description, homepage, version, artifacts and install
  status.
- Marking of already installed apps and possible matching uncertainty.
- Install preview with the Homebrew token and the intended effect.
- Execution through `PackageBackend`, followed by a local scan and trust
  initialization.

### Acceptance criteria

- [ ] The full catalog of roughly 7,715 entries stays smoothly searchable.
- [ ] Popularity data influences sorting in a traceable way.
- [ ] Missing analytics prevent neither search nor alphabetical sorting.
- [ ] Already installed apps are not offered as an uncritical new installation.
- [ ] Before installation, backend, cask token and homepage are visible.
- [ ] After a successful installation, the app appears in "Installed".
- [ ] An installation is marked as successful only after a local scan.

---

## Phase 6: Background status and menu bar

**User stories covered:** 40–43

### User value

The user sees available updates without an open main window and reaches the
relevant list with one click.

### End-to-end scope

- Scheduled, resource-friendly background scan without automatic installation.
- `MenuBarExtra` with the number of available updates, last scan and error
  status.
- Direct jump to the filtered update view of the main window.
- User control over scan interval and launch behavior.
- Clear handling of the offline state and stale data.

### Acceptance criteria

- [ ] The menu bar shows the same update count as the main window.
- [ ] A click opens the matching filtered view.
- [ ] Background scans start no installation and no self-updater.
- [ ] Repeated scans cause no parallel package manager processes.
- [ ] Scan interval and background behavior can be disabled.
- [ ] Energy and runtime costs are measured on a real system and documented.

---

## Phase 7: Hardened direct distribution and self-update

**User stories covered:** 44, 48

### User value

OpenFreshr can be installed safely outside the development machine and updated
through Sparkle. This way the product dogfoods its own detection case.

### End-to-end scope

- Release-ready app configuration with Hardened Runtime and minimal
  entitlements.
- Sparkle feed and signed self-updates.
- DMG creation with Developer ID signature, notarization and stapling.
- Integration into the existing macOS notarization broker.
- Secretless build and preflight before the separate signing step.
- Documented installation, verification and release flow.
- Smoke test of an upgrade from the previously published version.

### Reference for later helper hardening

Should a privileged helper prove necessary, validating the calling XPC client is
the critical and easily misimplemented part. A solid reference implementation
lives in `OpenUpdaterHelper/XPCAuditToken.m` in
[chenasraf/OpenUpdater](https://github.com/chenasraf/OpenUpdater) (MIT). A helper
that does not check the client's audit token can be addressed by arbitrary local
processes and would be a privilege escalation with root rights.

### Acceptance criteria

- [ ] The DMG passes Gatekeeper and signature verification on a clean Mac.
- [ ] The app runs from `/Applications` without a permanently privileged helper.
- [ ] The Sparkle feed offers only correctly signed releases.
- [ ] An update from version N to N+1 preserves settings, match exceptions and
      the trust store.
- [ ] Build and preflight require no signing secrets.
- [ ] Signing and notarization happen exclusively in the broker with human
      approval.
- [ ] Release artifacts contain integrity and provenance information following
      the existing app pattern.

## Possible extensions after v1

- Declarative fallback recipes for apps without any automatic source, modeled on
  the schema of [chenasraf/OpenUpdater](https://github.com/chenasraf/OpenUpdater)
  (`check` via JSON path or HTML pattern, `download`, `arch`, `channels`). On the
  reference system this affects only about five apps, mostly discontinued
  products — so the benefit does not justify the maintenance effort in v1.
- Native download/installation engine as a further `PackageBackend`.
- Homebrew formulae and CLI tools in a separate product area.
- Apple `softwareupdate` actions, provided UX and the distinction from system
  updates are solid.
- Additional catalog sources and verified community matches.
- Optional privileged helper, but only with measured, recurring need.
- Policies for unattended updates on explicitly approved apps.
