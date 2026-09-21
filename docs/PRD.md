# Product Requirements Document: OpenFreshr

**Status:** Draft  
**Target platform:** macOS 14+, Apple Silicon  
**Primary user:** initially the developer themselves  
**Product idea:** An "App Store for the rest of the Mac" that detects installed GUI apps,
makes updates transparent, and can find and install new apps.

## Executive Summary

MacUpdater was discontinued on 1 January 2026. Its core value – making updates for
apps installed outside the Mac App Store visible and executable – remains relevant.
A pure clone would fall short, however: OpenFreshr should additionally offer a
searchable catalog and be able to install new apps.

OpenFreshr combines local detection that is independent of Homebrew with several
update sources. For execution it initially uses established package backends:
Homebrew Cask, Mac App Store and Microsoft AutoUpdate. Sparkle and other
self-update mechanisms are detected and shown transparently, but not triggered in
parallel without asking.

Measurement on the target system shows that a custom curated app database is not
needed: of 109 relevant third-party apps, the existing scan detects 100
automatically. Controlled fuzzy matching is expected to map four further candidates,
bringing the expected coverage to about 95 percent. The most important first benefit
is the safe adoption of already installed, Homebrew-known apps using
`brew install --cask --adopt`.

### Success criteria

- At least 100 of the 109 third-party apps relevant in the reference scan are mapped
  to one or more sources.
- Controlled fuzzy matching raises the verifiable mapping to at least 104 of 109
  apps, without automatically adopting a wrong cask.
- OpenFreshr works for detection and display even when Homebrew is not installed or
  temporarily unavailable.
- In phase 1 the user can individually review, select and adopt detected apps that
  are not yet managed by Homebrew, using `--adopt`.
- No installation or adoption happens solely because of an uncertain name match.
- Before every app replacement performed by OpenFreshr, the signature, Gatekeeper
  assessment and Team ID trust are checked.
- Every product phase delivers a standalone, launchable and demonstrable end-to-end
  benefit.

## Problem

macOS distributes GUI apps through several mutually independent channels:

- Mac App Store
- directly downloaded apps with Sparkle or a proprietary self-updater
- Homebrew Casks
- Microsoft AutoUpdate
- Apple Software Update
- manual downloads without update infrastructure

As a result there is no shared view of installed versions, available updates and
sources. Self-updating apps notify at different times, manually installed apps are
easily forgotten, and discovering new apps happens separately from the update
process.

MacUpdater solved part of this with a large curated database. That database is
neither realistic to rebuild nor necessary for the personal use case. The existing
research shows that open metadata and local bundle properties cover the majority of
installed apps.

## Target audience

### Primary

A technically experienced macOS user with many apps from different sources, who
weights control, transparency and security checks higher than fully unattended
automation.

### Later

Advanced macOS users who want to discover, install and keep up to date apps outside
the Mac App Store in one place, without having to operate the underlying package
managers themselves.

## Solution

OpenFreshr is a native SwiftUI app with two primary areas:

- **Installed:** detected apps, installed and available version, source, trust status
  and possible actions.
- **Catalog:** a searchable GUI app selection from the Homebrew Cask catalog,
  sortable by popularity.

Local detection scans app bundles and merges information from `Info.plist`, MAS
receipts, Sparkle metadata, bundle structure and known sources into a normalized app
model. It does not depend on Homebrew.

Executable actions run through interchangeable package backends. Version 1 uses
Homebrew Cask, `mas` and Microsoft AutoUpdate. A later native download/installation
engine can be added without rebuilding scan, matching, UI or the trust model.

## Decisions & Assumptions

All of the following decisions are **provisional, confirmed by: —**. They are
deliberately documented in isolation so that individual decisions can be changed
later without rebuilding the entire product concept.

### 1. Homebrew for execution, not for detection

**Decision:** Homebrew is an allowed hard dependency for cask installation,
adoption, update and uninstallation. App scan, source mapping and version display
work without Homebrew. Execution paths are encapsulated behind a `PackageBackend`
with initially `HomebrewBackend`, `MASBackend` and `MAUBackend`.

**Rationale:** Homebrew already solves download, checksum verification, DMG/PKG/ZIP
handling, quarantine and uninstallation. A custom engine would be the product's
largest attack surface. At the same time, the backend boundary prevents a permanent
architectural lock-in.

**Rejected alternative:** A native installation engine from phase 1. It would be
considerably more expensive, more security-critical, and would delay the first
useful value.

### 2. Direct distribution without a privileged helper in v1

**Decision:** OpenFreshr is signed with Developer ID, notarized and distributed
directly as a DMG. Self-updates are done via Sparkle. An `SMAppService` helper is
not part of v1. If a cask requires elevated privileges, Homebrew is responsible for
the visible `sudo` prompt.

**Rationale:** The app must write to `/Applications` and therefore cannot sensibly
run in the Mac App Store sandbox. For most app bundles no permanently privileged
process is needed. With Sparkle, OpenFreshr itself uses a mechanism that it detects
in other apps.

**Rejected alternative:** A privileged helper from v1. It increases attack surface,
signing effort and operational risk before its need has been measured.

### 3. Main window first, menu bar later

**Decision:** The main window uses SwiftUI and `NavigationSplitView`. "Installed"
and "Catalog" are the primary areas. A `MenuBarExtra` follows later as a compact
status and entry layer.

**Rationale:** A catalog of about 7,715 casks needs search, filters, details and
comparison space. This discovery path is a key differentiator from MacUpdater.

**Rejected alternative:** A pure menu bar app. It is suitable for update notices but
not for serious catalog browsing.

### 4. Signature verification and Team ID trust

**Decision:** Before every replacement of an app bundle initiated by OpenFreshr,
`codesign --verify --strict`, Gatekeeper via `spctl --assess --type execute` and the
Team ID are checked. The Team ID found in the first scan is stored per bundle ID as
trust on first use. A Team ID change stops the automatic action and requires a
prominent warning as well as an explicit opt-in.

**Rationale:** A validly signed package can still come from a different developer.
Comparing the Team ID reduces the risk of a supply-chain takeover or a wrong cask
mapping and makes trust visible.

**Rejected alternative:** Relying solely on Homebrew checksums and Gatekeeper. That
does not detect an unexpected change of the signing publisher.

### 5. Show self-updaters, do not trigger them in parallel

**Decision:** Sparkle- and Electron/Squirrel-based apps are labeled "updates
itself". OpenFreshr does not secretly trigger their own updater. The user can
explicitly choose, per app, to update via OpenFreshr. Microsoft AutoUpdate may be
triggered via `msupdate`.

**Rationale:** Two competing update paths can damage running apps or bundles.
`msupdate`, by contrast, is the intended central MAU interface.

**Rejected alternative:** Automatically triggering every detected self-updater. That
would be hard to predict, poorly observable and potentially prone to collisions.

### 6. v1 covers GUI apps only

**Decision:** v1 manages app bundles and associated GUI applications. Homebrew
formulae and general CLI tools are not part of v1.

**Rationale:** CLI software has a different detection, versioning and usage model.
Homebrew already covers it well in the terminal. The restriction keeps the product
model understandable and the first delivery scope focused.

**Rejected alternative:** Managing GUI apps and CLI tools together from the start.
That would broaden navigation, models and security checks without better solving
the primary need.

## User Stories

1. As a user, I want to scan all relevant GUI apps in my usual Applications folders,
   so that I get a complete inventory.
2. As a user, I want to be able to hide Shortcuts droplets and known artifacts, so
   that the list is not distorted by irrelevant bundles.
3. As a user, I want to see name, bundle ID, installed version and path for each
   app, so that I can understand a match.
4. As a user, I want to see whether an app comes from the Mac App Store, so that the
   right update path is used.
5. As a user, I want Sparkle metadata and existing Sparkle frameworks to be
   detected, so that self-updating apps become visible.
6. As a user, I want Electron/Squirrel apps to be detected, so that competing update
   paths are avoided.
7. As a user, I want Microsoft apps managed by MAU to be detected, so that they can
   be updated centrally via `msupdate`.
8. As a user, I want to receive cask candidates based on app name, artifact name,
   bundle ID and controlled fuzzy matching, so that as many apps as possible are
   mapped.
9. As a user, I want to see the reasoning and confidence of a match, so that I can
   assess uncertain mappings.
10. As a user, I want to be able to reject wrong matches and save a correct mapping,
    so that future scans become more stable.
11. As a user, I want uncertain matches never to be adopted or updated
    automatically, so that similarly named but unrelated apps are not replaced.
12. As a user, I want to still see scan and update information without Homebrew
    installed, so that the app does not become worthless.
13. As a user, I want to see which detected apps are already managed by Homebrew, so
    that I understand their state.
14. As a user, I want to see a preview of all adoptable apps, so that no package
    manager change happens unexpectedly.
15. As a user, I want to select adoptable apps individually, so that I keep control
    over the Homebrew state.
16. As a user, I want to adopt a selected app with `brew install --cask --adopt`, so
    that it can be updated normally in the future.
17. As a user, I want to see the executed command, status and error for each
    adoption, so that the action remains verifiable.
18. As a user, I want missing or broken Homebrew to be displayed clearly, so that I
    can fix the problem in a targeted way.
19. As a user, I want to see available versions from the respective sources, so that
    I can recognize outdated apps.
20. As a user, I want to see source conflicts when several mechanisms cover the same
    app, so that no hidden update path is chosen.
21. As a user, I want self-updating apps to be labeled, so that I know why
    OpenFreshr does not intervene automatically.
22. As a user, I want to be able to explicitly choose Homebrew as the preferred path
    for each self-updating app, so that I control exceptions deliberately.
23. As a user, I want to be able to run Mac App Store updates via `mas`, so that the
    installed view bundles multiple sources.
24. As a user, I want to be able to run Microsoft updates via `msupdate`, so that
    Office and related apps are updated consistently.
25. As a user, I want to be able to run Homebrew Cask updates, including
    `auto_updates` and `latest` casks, so that known updates are not skipped.
26. As a user, I want to see a summary of the affected apps and sources before an
    update, so that I can approve the operation.
27. As a user, I want to be able to re-run failed actions without repeating
    successful ones, so that batch updates remain manageable.
28. As a user, I want the signature of a new app version to be verified, so that
    damaged or tampered bundles are rejected.
29. As a user, I want to see a Gatekeeper rejection as a hard error, so that
    untrusted software is not launched.
30. As a user, I want to receive an update stop and an understandable warning when
    the Team ID has changed, so that I can deliberately review a publisher change.
31. As a user, I want to be able to explicitly confirm a legitimate Team ID change,
    so that a verified change of ownership is not blocked permanently.
32. As a user, I want to see when and why a trust decision was made, so that
    security decisions are auditable.
33. As a user, I want to search the cask catalog, so that I find new apps outside
    the Mac App Store.
34. As a user, I want to sort catalog entries by popularity, so that widely used and
    probably maintained apps are easier to find.
35. As a user, I want to see name, description, homepage, version and installation
    type of a catalog entry, so that I am informed before installing.
36. As a user, I want to recognize installed apps in the catalog, so that I do not
    install duplicates.
37. As a user, I want to install a new GUI app via the appropriate backend, so that
    discovering and installing happen in one flow.
38. As a user, I want to see which backend and package identifier will be used
    before installation, so that the action is transparent.
39. As a user, I want to recognize outdated or unreachable catalog data, so that I
    can interpret search results correctly.
40. As a user, I want to see my last known app inventory even offline, so that a
    network error does not make the whole app unusable.
41. As a user, I want to be able to restart the scan manually, so that changes are
    visible immediately.
42. As a user, I want to see the number of available updates in the menu bar later,
    so that I am informed without the main window open.
43. As a user, I want to jump from the menu bar directly to the filtered update
    view, so that notices are action-oriented.
44. As a user, I want to update OpenFreshr via Sparkle, so that the tool itself uses
    the same secure direct-distribution path.
45. As a developer, I want to be able to test scan, matching, version comparison,
    trust and package execution as separate modules, so that sources or backends
    remain interchangeable.
46. As a developer, I want to launch external processes with structured arguments
    and without shell interpolation, so that app names or package identifiers cannot
    inject commands.
47. As a developer, I want to check source responses and appcasts against fixed test
    fixtures, so that format changes are detected early.
48. As a developer, I want to build, sign, notarize and publish releases
    reproducibly as a DMG, so that users can verify origin and integrity.

## Functional requirements

### App detection

- Scan of `/Applications`, `~/Applications` and `/Applications/Utilities`.
- Reading `CFBundleIdentifier`, `CFBundleShortVersionString`,
  `CFBundleVersion`, `SUFeedURL` and relevant bundle structures.
- Detection of MAS receipt, Sparkle framework and Electron framework.
- Deduplication of bundles found multiple times based on stable identity and path.
- Local detection must not require a Homebrew installation.
- The scan must not conceal unreadable or damaged bundles; it shows a diagnosable
  state.

### Sources and matching

- Ingestion of the Homebrew Cask catalog with token, names, description, homepage,
  version and artifacts.
- Consideration of app artifact names as well as bundle IDs from uninstall and zap
  metadata.
- Detection of Mac App Store apps via receipt and mapping to `mas`.
- Detection of MAU-capable apps and querying via `msupdate`.
- Parsing explicit Sparkle appcasts; an embedded framework without a feed URL is
  treated as a runtime self-updater, not as a reliably queryable source.
- Normalization of names and versions before comparison.
- Fuzzy matching produces suggestions only. Automatic actions require strong proof of
  identity or a confirmed mapping.
- Multiple possible sources remain visible; a priority rule must not conceal
  conflicts.

### Installed view

- Display of app, installed version, available version, source, management status,
  match confidence and trust status.
- Filters for at least "Updates", "Adoptable", "Self-updating", "Unmatched" and
  "Errors".
- Detail view with match reasoning, alternative sources and possible actions.

### Adoption

- Preview of apps that are not yet managed by Homebrew but are safely mapped.
- Individual selection before every batch adoption.
- Exclusion of uncertain or contradictory matches from the preselection.
- Execution via structured process arguments, not via a shell string.
- Progress and result per app; an error does not necessarily stop independent
  follow-up actions, but is made visible and repeatable.
- No automatic deletion or replacement outside the flow provided by Homebrew.

### Updates

- Homebrew casks are considered including `auto_updates` and `latest`.
- Mac App Store apps are updated via `mas`.
- Microsoft apps can be updated via `msupdate`.
- Self-updating apps are by default only displayed.
- User approval before an update group and visible status per app.
- After every action a fresh local scan is performed instead of an optimistic
  assumption of success.
- Major upgrades are labeled separately and not mixed with regular updates, since
  they can change licensing, file formats or system requirements. They require their
  own confirmation with a visible rationale.
- Check results are cached with a timestamp so that restarting the app does not
  trigger a full network check. The cache age is visible and can be invalidated
  manually.

### Ignore lists

- Apple's own apps and apps managed via MDM are on a system ignore list and do not
  appear as suggested actions.
- The user can ignore an app permanently or skip a single version.
- Ignored entries remain viewable and revocable; they are not silently hidden.

### Catalog and new installation

- Local cache of the cask catalog and the 365-day installation statistics.
- Search across token, display name and description.
- Sorting by popularity and name; further filters may follow later.
- Detail view with source, homepage, version and relevant artifacts.
- Installation only after preview and explicit confirmation.

### Trust store

- Persistence of the observed Team ID per bundle ID with timestamp and origin.
- Log of explicitly confirmed Team ID changes.
- Ability to delete or reset stored trust decisions.
- No automatic approval on a missing signature, Gatekeeper rejection or unexpected
  Team ID change.

## Non-functional requirements

- Native macOS app in Swift and SwiftUI; initial target macOS 14+ on Apple Silicon.
- Swift 6-compatible, concurrency-safe core.
- Long scans, network requests and package processes do not block the main thread.
- An aborted or failed process leaves a traceable state and no success message.
- Network responses are handled with time limits, size limits and explicit errors.
- External commands are launched only with fixed executable paths or validated tool
  resolution and separate argument lists.
- Core logic stays separate from SwiftUI and is testable headless.
- Catalog and analysis responses are cached locally; origin and fetch time are
  visible.
- Diagnostic logs contain no unnecessary personal data and no secret values.
- Accessibility, keyboard navigation and VoiceOver labels are considered for all
  primary actions.

## Security requirements

- No privileged, permanently running helper in v1.
- No shell interpolation for tool invocations.
- No automatic action based on a mere fuzzy name match.
- Signature and Gatekeeper verification before a replacement performed by
  OpenFreshr.
- A Team ID change is a blocking trust conflict with explicit opt-in.
- Homebrew performs its own checksum, quarantine and installer checks; OpenFreshr
  does not present their result as its own security proof.
- Appcast and catalog data are treated as untrusted input and parsed defensively.
- URLs may only be fetched via supported secure protocols; redirects and unexpected
  hosts must remain traceable.
- Before an action, the app shows the actual backend identifier and the affected
  local app.
- Missing or ambiguous bundle identity leads to manual resolution, not to a silent
  fallback.
- Release artifacts are signed with Developer ID, notarized and stapled.
- The release process should follow the existing pattern of the other apps:
  secretless build and preflight, separate signing with human approval via the
  notarization broker.

## Data model and modules

The architecture should form a few deep, independently testable modules:

- **Inventory:** scans app bundles and delivers normalized installed apps, without
  package manager knowledge.
- **Source Catalog:** loads and normalizes cask, MAS, MAU and Sparkle metadata.
- **Resolver:** produces traceable source candidates including match type,
  confidence and conflicts.
- **Versioning:** conservatively compares vendor-specific version representations.
- **Trust:** determines signature, Team ID and Gatekeeper status and manages
  trust on first use.
- **Package Operations:** provides a uniform backend interface for preview,
  installation, adoption and update.
- **Application Model:** orchestrates scan, refresh, actions and error states for
  the UI.
- **Catalog Experience:** search, popularity, details and installation flow.

These boundaries matter more than concrete file names. In particular,
`PackageBackend` and the local scanner must not merge with each other.

## Acceptance criteria

- [ ] OpenFreshr starts as a native macOS app and shows an installed view.
- [ ] A scan finds app bundles in all defined directories and stays functional when
      a bundle is unreadable.
- [ ] The reference data yield at least 100 automatically mapped third-party apps.
- [ ] Fuzzy suggestions can raise the reference coverage to at least 104 apps.
- [ ] A deliberately similarly named but wrong cask is not adopted automatically.
- [ ] Without Homebrew the app shows inventory, sources and version information;
      only Homebrew actions are disabled, with a stated reason.
- [ ] Safely mapped, unmanaged casks appear in an adoption preview.
- [ ] The user can select apps individually and trace adoptions individually.
- [ ] Every adoption is verified by a fresh scan after completion.
- [ ] MAS, MAU, Sparkle and Homebrew sources can be visible on one app at the same
      time.
- [ ] Self-updating apps are by default not updated by OpenFreshr.
- [ ] An invalidly signed bundle, or one rejected by Gatekeeper, is blocked.
- [ ] A Team ID change is blocked, explained and accepted only after explicit
      confirmation.
- [ ] The catalog is searchable and can be sorted by 365-day popularity.
- [ ] A catalog installation shows backend and token before confirmation.
- [ ] OpenFreshr can update itself via a signed Sparkle feed.

## Test decisions

Tests verify observable behavior at stable module boundaries, not private
implementation details.

- **Inventory:** temporary bundle fixtures with complete, missing and damaged
  plists; MAS, Sparkle and Electron markers.
- **Resolver:** fixed cask and app fixtures for exact names, bundle ID hits, fuzzy
  suggestions, ambiguity and known mis-mappings.
- **Versioning:** real version forms from the reference scan, including multi-part
  and non-purely-numeric versions.
- **Trust:** signed test fixtures or abstracted check results for identical, changed
  and missing Team IDs.
- **Package Operations:** fake backends for preview, success, partial failure, abort
  and retry; no tests may modify real system apps.
- **Source Catalog:** stored API and appcast fixtures so that tests are reproducible
  without a network.
- **End-to-end smoke test:** scan of a controlled fixture structure through to UI
  presentation and simulated adoption.

The existing pattern of the comparison projects is adopted: core logic is kept in a
separately testable Swift package or core module; tests run headless. The Xcode
project is generated from a declarative `project.yml` and checked in for the
reproducible release build.

## State of the art

Two active open-source projects pursue a similar purpose. Both were reviewed on
29.08.2026 to avoid duplicated effort.

### chenasraf/OpenUpdater

Swift, MIT, active. Covers GitHub Releases, Sparkle appcasts and direct downloads
via **hand-maintained, crowdsourced YAML recipes**.

Measured against the same 109 third-party apps of the reference system:

| Approach | Apps covered |
|---|---|
| OpenUpdater: 53 recipes | 9 |
| OpenUpdater: recipes + automatic Sparkle detection | 24 (22 %) |
| OpenFreshr: four existing sources | 100 (91 %) |

OpenUpdater's coverage on the reference system is a **true subset**: there is no
app that OpenUpdater covers and OpenFreshr does not.

The cause is structural, not qualitative. A recipe-based approach reproduces the
scaling problem on which MacUpdater failed: every supported app requires permanent
manual maintenance. OpenFreshr shifts this maintenance to parties that already
perform it anyway — Homebrew, Apple, Microsoft and the vendors themselves.

**Insights adopted:**

- The declarative recipe schema (`check` with JSON path or HTML pattern, `download`,
  `arch`, `channels`) is a good solution for apps without any automatic source and
  serves as a template for the fallback recipes in OpenFreshr.
- The source abstraction (`AppStoreSource`, `GitHubReleaseSource`, `SparkleSource`,
  `HTTPVersionSource` behind a common manager) independently confirms the backend
  protocol chosen here.
- `XPCAuditToken` shows the correct validation of the calling client in a privileged
  helper — a reference for the later hardening phase.
- Three concepts are adopted: separate handling of major upgrades, a cache for check
  results and a system ignore list.

### jakejarvis/versioneer

TypeScript, MIT, early alpha. Also a native macOS app updater, but without
installing new apps and without signature verification as a security feature.

### Differentiation

Neither of the two projects offers two features, and they remain the core
differentiators of OpenFreshr: **installing new apps from a searchable catalog** and
the **Team ID check before replacing an app**.

## Non-goals for v1

- Managing Homebrew formulae and general CLI tools.
- A custom native download, unpack, DMG, PKG and uninstallation engine.
- A curated database modeled on MacUpdater.
- Fully unattended updates without user oversight.
- A permanently privileged helper.
- Mac App Store distribution.
- iOS, iPadOS, Windows or Linux support.
- Enterprise-wide device management, policies or central telemetry.
- Automatically updating discontinued or not reliably mappable apps.

Formulae/CLI tools and a native installation engine remain possible later
extensions, provided their benefit justifies the additional complexity.

## Risks and open items

- **Wrong mapping:** The raw scan already contains a plausible false candidate
  (`Copilot.app` to `copilot-money`). Fuzzy matching must therefore be explainable,
  conservative and, by default, insufficient for actions.
- **Cask drift:** Tokens, artifacts and maintainer decisions can change. Stored
  mappings need renewed plausibility checks.
- **Version semantics:** Vendors use inconsistent version formats. "Unknown" is
  better than a wrong update verdict.
- **Homebrew behavior:** `--adopt`, `--greedy` or JSON structures can change. Tool
  version and capabilities must be detected.
- **MAS dependency:** `mas` is a separate tool and cannot fully control
  authentication or App Store state.
- **MAU coverage:** Not every app with a Microsoft bundle ID is necessarily managed
  by MAU. Detection must be confirmed against `msupdate`.
- **Sparkle feeds:** Feeds can be generated dynamically, architecture-dependent or
  non-public. An embedded framework alone does not guarantee a readable appcast.
- **Running apps:** Replacing active bundles can fail or become inconsistent. v1
  needs clear preconditions and hints for quitting the app.
- **TOFU limit:** An already compromised first installation is stored as the initial
  trust. The UI must state this semantics clearly.
- **Team ID change:** Legitimate takeovers or new signing certificates can produce
  warnings. The exception flow must not be trivialized.
- **Apple apps:** `softwareupdate` initially remains a detection source; concrete
  execution and UX must be validated separately.
- **License:** MIT, see [LICENSE](../LICENSE). Decided on 29.08.2026.
- **Product name:** Checked on 29.08.2026. The original working title `OpenUpdatr`
  collided with [chenasraf/OpenUpdater](https://github.com/chenasraf/OpenUpdater)
  (Swift, MIT, active, same purpose) and was therefore changed to `OpenFreshr`.
  GitHub and npm are free for the new name. A trademark review is still pending
  before any commercial use.

## Rollout

Implementation follows vertical tracer bullets. The first phase already delivers the
central aha moment: existing apps are detected and can be adopted into Homebrew
management in a controlled way. Later phases add real updates, security enforcement,
catalog installation, additional convenience features and finally the hardened
direct distribution.

Details are in [Implementation plan](PLAN.md).
