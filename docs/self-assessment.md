# Self-assessment

Evidence for `.github/conformance.yml`. Assessed against version **1.15.0** of
the [trsdn Repository Quality Standard](https://github.com/trsdn/.github/blob/main/docs/repository-quality-standard.md).
First assessed on 2026-09-20; reassessed on **2026-09-21** after the gaps it named
were worked. Overall state: **Needs work**. Three criteria fail and four are
partial; none of the critical criteria (`B04`, `D01`-`D04`, `D06`) fails.

Every line below was read from the tree, the GitHub API, or a command run for
this assessment. The profiles that apply are Baseline, Public, Software,
Package And Release (`R01`, `R02`), Agent Readiness, Language, Accessibility and
Privacy. The repository became public on 2026-09-20 and has not yet published a
release.

## Facts the results rest on

| Fact | Observed |
|---|---|
| Visibility, licence | Public, MIT (GitHub detects `MIT`) |
| Topics, homepage | `homebrew`, `macos`, `menu-bar-app`, `swift`, `trsdn-standard`; homepage empty |
| Releases and tags | None. `CHANGELOG.md` has a `[1.0.0]` heading marked "not yet released" |
| Default branch | `main`, covered by the ruleset `main protection` (id 23756225, active): `deletion`, `non_fast_forward` and `required_status_checks` for `Build and test (macos-15)`, `Build and test (macos-latest)`, `Markdown lint`, `Secret Scan` and `conformance / Conformance record` (`gh api repos/trsdn/OpenFreshr/rulesets`) |
| Repository security settings | Secret scanning and push protection enabled; private vulnerability reporting enabled (`gh api repos/trsdn/OpenFreshr/private-vulnerability-reporting` returns `enabled: true`); Dependabot security updates disabled |
| Local run | `swift test`: 265 tests in 31 suites passed on 2026-09-20 |
| Markdown | `npx markdownlint-cli2@0.18.1 "**/*.md" "#node_modules" "#.build"`: 0 errors on 2026-09-21 |
| Formatting | `swift format lint --strict -r Sources Tests Package.swift` reports 914 violations in 64 files on 2026-09-21 (489 indentation, 290 missing line breaks, 78 line length, 36 spacing, 11 import order); it is therefore not wired into CI |

## Results that are not `pass`

### `fail`

| ID | What was observed | What would make it pass |
|---|---|---|
| `L01` | The README now declares English as the language of the documentation and the interface, but the interface in `Sources/OpenFreshrApp/*.swift` is still German at the time of this assessment | Land the interface translation, then the declaration is true |
| `L02` | User-facing strings are hardcoded German literals ("Alle Updates", "Hintergrundprüfung", ...), with no string catalog | English base strings plus a `.xcstrings` catalog |
| `L03` | The README states English with a German translation, but no catalog exists yet to back it | Ships with the catalog from `L02` |

### `partial`

| ID | What was observed | What would make it pass |
|---|---|---|
| `P08` | The README carries the badge block in the standard's order (licence, platform, CI, conformance). The licence and platform badges are rendered by `scripts/badges.py` from `Info.plist` and `Package.swift` and are served from the generated `stats` branch, which does not exist until the first run of `stats.yml`, so those two images do not render yet. There is no release badge because there is no release | Create the `stats` branch and run the workflow once; add the release badge with the first release |
| `P09` | `.github/workflows/stats.yml` calls the shared `repo-stats` workflow on a schedule, in light and dark variants, and the README references the card in a `<picture>` element. The workflow has not run, so no card exists | Create the `stats` branch and run the workflow once |
| `S03` | Compilation with `-warnings-as-errors` is the type check and runs in CI. `.swift-format` exists, but the code does not pass `swift format lint --strict` (914 violations in 64 files), so wiring it into CI and `make all` would turn both red | Format the code once with `swift format -i -r`, then add `swift format lint --strict` to CI and to the `B05` command |
| `X02` | Standard controls carry names. The catalogue search clear button (`CatalogView.swift`, `xmark.circle.fill`) is an icon-only button with no `accessibilityLabel`; only the menu bar item has one | Label the icon-only controls |

## Results that are `na`, and why

- **`B14`**: the repository holds no credential and none is configured for it.
  The workflows use only the per-run `GITHUB_TOKEN`; `AGENTS.md` records that
  the Apple signing credentials live in the notarization broker, not here.
- **`S06`**: nothing reads configuration. The only settings are user
  preferences in `UserDefaults`, and the `brew` locations are probed, not
  configured.
- **`S13`**: no workflow uses `pull_request_target` or `workflow_run`, and none
  reads a `secrets.*` context.
- **`D01`-`D06`**: nothing is deployed. The app runs on a user's Mac.
- **`R03`-`R08`**: no release has been published (no tag, no GitHub Release), so
  there is nothing to assess. The `[1.0.0]` heading in `CHANGELOG.md` is marked
  "not yet released" and is dated when the first release is cut.
- **`I01`-`I06`**: the repository ships no artifact yet. The `Info.plist`
  identity keys and the icon source now exist; the icon still has to be wired
  into the bundle (`CFBundleIconFile`, `project.yml`) before the first release.
- **`T01`-`T05`**: the product is an application, not documentation.
- **`W01`-`W09`**: there is no published site and no homepage. `W05` and `W06`
  are retired.
- **`L04`, `L06`**: the app ships no string catalog and no translation, so
  there are no localized builds and nothing to trace.
- **`X04`**: the product has no terminal output.
- **`A01`-`A04`**: actively developed, not archived.

## Notes on `pass` results

### Baseline

| ID | Evidence |
|---|---|
| `B01` | Description: "Keep macOS apps fresh — discover, install and update via Homebrew Cask, Mac App Store, Microsoft AutoUpdate and Sparkle" |
| `B02` | The README gives purpose, audience (Mac users who want their apps kept current without a curated database), status (public, no release yet), build and usage, and key links |
| `B03`, `P01` | `LICENSE` is MIT; GitHub reports `MIT` |
| `B04` | `.gitignore` covers `.build/`, `.swiftpm/`, `DerivedData/`, `xcuserdata`, `.DS_Store`. `OpenFreshr.xcodeproj` is tracked on purpose and documented with its regeneration command (`make generate`); `git ls-files` lists no credential file. The `secret-scan` job passes |
| `B05` | `make all` (`swift build` and `swift test`) is documented in the README and named as the complete check in `AGENTS.md`. Run locally on 2026-09-20: 265 tests passed |
| `B06` | A single maintainer. Secret scanning is enabled and push protection is on; Dependabot alerts and code scanning are not, so no source has an open alert. Merge policy is met by the single-maintainer rule |
| `B07` | `Package.swift` sets `.macOS(.v14)` and Swift 6; `project.yml` pins AppUpdater `exactVersion: 4.1.2`; `Package.resolved` is committed |
| `B08` | `CHANGELOG.md` follows Keep a Changelog with an `Unreleased` section covering the latest change |
| `B09` | Visibility, topics and archive state are set and the README's status ("public, no release yet") agrees with them |
| `B10` | `.github/CODEOWNERS` assigns every path to `@trsdn`; its comment points to the README's "Support and maintenance" section, which now exists |
| `B11`, `B12` | This record, and the `trsdn-standard` topic |
| `B13` | Each fact has one home: the build commands in the README (from the `Makefile`), the release procedure, broker profile, entitlements and self-update in `docs/release/README.md`, and the architecture and rules in `AGENTS.md`, which links to the others instead of restating them |
| `B15` | `THIRD_PARTY_NOTICES.txt` carries AppUpdater 4.1.2 and Version 2.2.1 licence texts verbatim and is copied into the bundle as a resource (`project.yml`); `Package.resolved` lists exactly those two packages |
| `B16` | The ruleset above refuses deletion and non-fast-forward updates of the default branch |

### Public

| ID | Evidence |
|---|---|
| `P02`, `P06` | Community profile lists the README, licence, contributing guide and code of conduct (inherited from `trsdn/.github`) |
| `P03` | The inherited `SECURITY.md` routes reports through "Report a vulnerability" on the Security tab, and private vulnerability reporting is enabled; the README's Security section says so |
| `P04`, `P10`, `P11` | `.github/ISSUE_TEMPLATE/bug_report.yml` asks for area, expected and actual result, reproduction, OpenFreshr version, macOS version and Mac, and logs; `feature_request.yml` exists; `.github/pull_request_template.md` covers what changed, validation, risk and related issues |
| `P05` | The README covers purpose, build, configuration and usage, compatibility (macOS 14 or later, Apple silicon), security reporting and support status |
| `P07` | Description and five topics are set. There is no website, so no homepage is required |

### Software

| ID | Evidence |
|---|---|
| `S01` | `Package.resolved` and the pinned `project.yml` dependency are committed; the setup commands are in the README |
| `S02` | 265 tests in 31 suites cover scanning, matching, adoption, update resolution, the trust gate and scheduling without any view; failure paths are asserted (`throws`, `FailClosedEligibilityTests`, `TrustEnforcementTests`, rejected-signature cases). The SwiftUI views and real `brew` are covered by no test |
| `S04` | The README claims macOS 14 or later and the manifest declares the same, a range covered by the newest runner. CI runs `macos-15` and `macos-latest` |
| `S05` | `secret-scan.yml` runs on pull requests and on pushes to `main`. GitHub secret scanning and push protection are enabled (`security_and_analysis`), a second layer |
| `S07` | The one `Logger` (`SelfUpdateController`) logs operation names, versions and error descriptions; no environment, token, header or body is logged, and error text names the failed operation |
| `S08` | `.github/dependabot.yml` covers the `swift` and `github-actions` ecosystems monthly and states why |
| `S09` | The ruleset requires the CI matrix, Markdown lint, Secret Scan and the conformance check, all of which exist |
| `S10` | `AGENTS.md` documents the UI-free core, the protocol boundaries, the trust model, the committed generated project and the broker constraint |
| `S11` | Every workflow declares `permissions: contents: read` at workflow level; `stats.yml` raises it to `contents: write` on the two jobs that push to the generated `stats` branch, which holds no secret and never reaches `main` |
| `S12` | `actions/checkout` and the reusable workflows are pinned to full commit SHAs with the tag in a comment |

### Package and release

| ID | Evidence |
|---|---|
| `R01` | SwiftPM has no field for a licence, repository URL or description, so under `R01` they live in the artifact's own metadata: `Sources/OpenFreshrApp/Info.plist` carries the product name, both version strings (expanded from `project.yml`), `NSHumanReadableCopyright` (holder and licence), `OFRLicenseIdentifier` (`MIT`), `OFRRepositoryURL` and `OFRIssueTrackerURL`. They agree with GitHub's licence and repository. `Package.swift` carries none of it, by the limits of the format. `scripts/badges.py` reads the licence from the plist |
| `R02` | `CHANGELOG.md` states that the project aims to follow Semantic Versioning |

### Agent readiness

| ID | Evidence |
|---|---|
| `G01` | `AGENTS.md` at the root |
| `G02` | `AGENTS.md` opens with a purpose paragraph, then layout, boundaries, rules and the commands |
| `G03` | `AGENTS.md` names history rewriting and force pushes, secrets, local notarization, destructive commands against `/Applications`, Homebrew and Application Support, and hand-edits of generated files |
| `G04` | No tool-specific instruction file exists, so nothing can diverge |
| `G05` | `AGENTS.md` names `make all` as the complete check to pass before proposing a change |
| `G06` | `.gitattributes` marks the generated Xcode project, the badge and stats paths, `casks-snapshot.json` and `Package.resolved`; `AGENTS.md` lists the same paths |
| `G07` | `AGENTS.md` states that agent changes are reviewed by a human before merge, carry a `Co-Authored-By:` trailer, and are described as agent-made in the pull request |
| `G08` | `.github/github-app.yml` points at `AGENTS.md` and declares `make all` |

### Language and accessibility

| ID | Evidence |
|---|---|
| `L05` | Displayed dates and counts use `.formatted(...)` (`TrustManagementView`, `CatalogView`); sorts of displayed text are not hand-built |
| `L07` | Commit messages, code comments, identifiers, `README.md`, `CHANGELOG.md`, `docs/PRD.md`, `docs/PLAN.md` and the release guide are in English; no German remains in the documents outside literal UI strings quoted here |
| `X01` | Read: the interface uses standard SwiftUI controls, `keyboardShortcut` on the sheet actions, and no gesture-only interaction (no `onTapGesture`). Source review only; the product was not operated |
| `X03` | Read: no fixed font sizes, semantic text styles and system colours only; status is carried by a distinct symbol or text alongside any colour. Not verified with the real system accessibility settings |
| `X05` | The README's Accessibility section states that no assistive-technology audit has been done, that some icon-only controls (the catalogue search clear button) lack a label, and that contrast, text size and Reduce Motion were not checked |

### Privacy

| ID | Evidence |
|---|---|
| `Y01` | The README's Privacy section states that nothing is collected or sent, and what is read (the installed-app inventory) and stored |
| `Y02` | The section lists every destination with its purpose, verified against the code: `formulae.brew.sh` (`CaskCatalogProvider.defaultCaskURL` and the analytics URL), GitHub Releases through AppUpdater, each Sparkle app's own `SUFeedURL` (`InventoryScanner`, `SparkleAppcast`), and whatever `brew`, `mas` and `msupdate` contact |
| `Y03` | Source and dependencies contain no telemetry, analytics or crash reporting. The install-analytics endpoint is a read-only fetch of Homebrew's public counts, not a report about the user |
| `Y04` | The section gives the paths (`~/Library/Application Support/OpenFreshr/CatalogCache`, `trust-store.json`, `last-check.json`, the `com.openfreshr.app` defaults) and the commands that delete them |
| `Y05` | The README states that no user content goes to any third party or AI provider; the code sends only `GET`s for public catalogue, appcast and release data |
| `Y06` | The section states what each store keeps, when it is replaced, and how to delete it |

## What remains

1. Create the `stats` branch from `main` and run the `Repository stats` workflow
   once, so the activity card and the licence and platform badges exist
   (`P08`, `P09`).
2. Land the interface translation, then `L01`-`L03` can pass (English base
   strings, a German catalog, and the README declaration).
3. Format the code once, then wire `swift format lint --strict` into CI and
   `make all` (`S03`).
4. Label the icon-only controls (`X02`).
5. Before the first release: mirror the `Info.plist` identity keys in
   `project.yml`, wire the icon into the bundle, and date the `[1.0.0]` entry.
