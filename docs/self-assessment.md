# Self-assessment

Evidence for `.github/conformance.yml`. Assessed against version **1.15.0** of
the [trsdn Repository Quality Standard](https://github.com/trsdn/.github/blob/main/docs/repository-quality-standard.md)
on **2026-09-20**. Overall state: **Needs work**. Thirteen criteria fail and
thirteen are partial; none of the critical criteria (`B04`, `D01`-`D04`, `D06`)
fails.

Every line below was read from the tree, the GitHub API, or a command run for
this assessment. The profiles that apply are Baseline, Public, Software,
Package And Release (`R01`, `R02`), Agent Readiness, Language, Accessibility and
Privacy. This is the first assessment of the repository, which became public on
2026-09-20 and has not yet published a release.

## Facts the results rest on

| Fact | Observed |
|---|---|
| Visibility, licence | Public, MIT (GitHub detects `MIT`) |
| Topics, homepage | `homebrew`, `macos`, `menu-bar-app`, `swift`, `trsdn-standard`; homepage empty |
| Releases and tags | None. `CHANGELOG.md` nevertheless has a dated `[1.0.0]` heading |
| Default branch | `main`; no ruleset, no branch protection (`branches/main/protection` returns 404, `rulesets` is empty) |
| Repository security settings | Secret scanning, push protection and Dependabot security updates disabled; private vulnerability reporting disabled |
| Local run | `swift test`: 265 tests in 31 suites passed on 2026-09-20 |
| Markdown | `npx markdownlint-cli2@0.18.1`: 0 errors |
| CI on the open pull request | Secret Scan and Markdown green. CI is red because the `xcodegen generate` drift check fails: the committed `project.pbxproj` names its local-package group `updater`, the worktree directory it was generated in, where CI's checkout is `OpenFreshr`. Conformance was red because no record existed until this one |

## Results that are not `pass`

### `fail`

| ID | What was observed | What would make it pass |
|---|---|---|
| `B16` | Neither a ruleset nor protection covers `main`, so force pushes and deletion are allowed | Add a ruleset with `deletion` and `non_fast_forward` rules |
| `S09` | No required check on `main`, although CI, Markdown and Secret Scan exist | Require pull requests and the CI matrix, Markdown and Secret Scan checks in the same ruleset |
| `P08` | README carries no badges | Add the licence, platform, CI and conformance badges in the order the standard gives |
| `P09` | Workflows exist, but no generated activity card is shown | Add the shared `repo-stats` workflow and reference its card from the README |
| `G07` | `AGENTS.md`, the README and the inherited contributing guide state no trailer, label or review rule for agent-authored changes | Add a review-expectation paragraph to `AGENTS.md` |
| `L01` | The README does not declare a primary language, and the interface is German | Declare the language, and either move the UI to English with a German catalog or state a documented exception |
| `L02` | User-facing strings in `Sources/OpenFreshrApp/*.swift` are hardcoded German literals ("Alle Updates", "Hintergrundprüfung", ...), with no string catalog | Same fix as `L01`: English base strings plus a `.xcstrings` catalog |
| `L03` | Localization support is not declared and no catalog exists | One README sentence, ideally with the `L01` statement |
| `X05` | No statement of accessibility limitations anywhere | An accessibility note stating the gaps under `X02` and that no assistive-technology audit has been done |
| `Y01` | The README says nothing about what the app collects, stores or transmits | A Privacy section stating that nothing is collected and listing what is stored locally and fetched |
| `Y02` | The code contacts `formulae.brew.sh` (cask catalogue and install analytics), GitHub Releases (AppUpdater) and vendor Sparkle feeds, and none is documented | List each destination with its purpose in the Privacy section |
| `Y04` | The app writes `~/Library/Application Support/OpenFreshr/` (`CatalogCache`, `trust-store.json`, `last-check.json`) and `UserDefaults`; the paths appear only in source comments | Document the paths and how to delete them in the README |
| `Y06` | The catalogue cache, trust store and last-check file outlive a session and no retention or deletion behaviour is stated | State retention and deletion beside `Y04` |

### `partial`

| ID | What was observed | What would make it pass |
|---|---|---|
| `B02` | The README gives purpose, build instructions, links and a status, but names no audience, and the status ("noch nicht veröffentlicht ... öffentlicher Repository-Status fehlt") is now stale | State the audience and update the status |
| `B09` | Visibility, topics and archive state are set; but the README still says the public repository status is missing while the repository is public | Correct the README status sentence |
| `B13` | The release procedure is restated in `AGENTS.md` and `docs/release/README.md`, and the build commands appear in the README, `AGENTS.md` and the `Makefile` comments. They agree today | Keep each in one home and link from the others |
| `P03` | The inherited `SECURITY.md` routes reports through "Report a vulnerability" on the Security tab, but private vulnerability reporting is disabled here | Enable private vulnerability reporting |
| `P05` | The README covers build and status. It has no configuration, examples, compatibility (macOS 14, Apple Silicon appear only in `docs/PRD.md`), security-reporting or support-status statement | Add a sentence or link for each topic |
| `S03` | Compilation with `-warnings-as-errors` is the type check and runs in CI. `.swift-format` exists but no CI step or `make` target runs `swift format lint` | Add `swift format lint --strict` to CI and to the `B05` command |
| `R01` | Name and version have homes (`Info.plist`, `project.yml`). Description, licence identifier and repository URL are in neither `Package.swift` nor `Info.plist`; `NSHumanReadableCopyright` is "OpenFreshr", not a holder | Add licence, copyright holder and repository and issue-tracker URL keys to `Info.plist` |
| `G02` | `AGENTS.md` gives layout and commands but never says what the project is for | Add a purpose paragraph |
| `G03` | `AGENTS.md` forbids local notarization, credential requests and writing to `/Applications` from tests, but does not name history rewriting or force pushes | Add those to the forbidden operations |
| `G05` | `make all` is the validation command (`Makefile`, `.github/github-app.yml`), but `AGENTS.md` lists `make build` and `make test` separately and never names one complete command | Name `make all` as the pre-proposal check |
| `G06` | `.gitattributes` marks the generated Xcode project and the badge and stats paths. `Sources/OpenFreshrApp/Resources/casks-snapshot.json` (produced by `scripts/build-catalog-snapshot.py`) and the `Package.resolved` lockfile are marked nowhere | Mark both in `.gitattributes` or `AGENTS.md` |
| `L07` | Commit messages, code comments and identifiers are English. `README.md`, `CHANGELOG.md` entries, `docs/PRD.md` and `docs/PLAN.md` are German | Translate the contributor-facing documents |
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
  there is nothing to assess. The `[1.0.0]` heading in `CHANGELOG.md` records a
  release that did not happen and should be reconciled with the first real
  one.
- **`I01`-`I06`**: the repository ships no artifact yet. The gaps `R01` and the
  missing icon (no asset catalog, no `CFBundleIconFile`) will fail these on the
  first release unless fixed before it.
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
| `B03`, `P01` | `LICENSE` is MIT; GitHub reports `MIT` |
| `B04` | `.gitignore` covers `.build/`, `.swiftpm/`, `DerivedData/`, `xcuserdata`, `.DS_Store`. `OpenFreshr.xcodeproj` is tracked on purpose and documented with its regeneration command (`make generate`); `git ls-files` lists no credential file. The `secret-scan` job passed on the pull request |
| `B05` | `make all` (`swift build` and `swift test`) is documented in the README and `AGENTS.md`. Run locally on 2026-09-20: 265 tests passed. No green run on `main` exists yet, and the pull-request CI is red for the unrelated reason given above |
| `B06` | A single maintainer, and no alerts to read: Dependabot alerts and secret scanning are disabled and no code-scanning analysis exists, so no source has an open alert. Read with the three `gh api` calls the standard gives. Merge policy is met by the single-maintainer rule (all three methods enabled, no ruleset) |
| `B07` | `Package.swift` sets `.macOS(.v14)` and Swift 6; `project.yml` pins AppUpdater `exactVersion: 4.1.2`; `Package.resolved` is committed |
| `B08` | `CHANGELOG.md` follows Keep a Changelog with an `Unreleased` section covering the latest change |
| `B10` | `.github/CODEOWNERS` assigns every path to `@trsdn`; the latest commit to `main` is 2026-08-29. The CODEOWNERS comment points to a "Support and maintenance" README section that does not exist; fix it when `B02` is fixed |
| `B11`, `B12` | This record, and the `trsdn-standard` topic |
| `B15` | `THIRD_PARTY_NOTICES.txt` carries AppUpdater 4.1.2 and Version 2.2.1 licence texts verbatim and is copied into the bundle as a resource (`project.yml`); `Package.resolved` lists exactly those two packages |

### Public

| ID | Evidence |
|---|---|
| `P02`, `P06` | Community profile lists the README, licence, contributing guide and code of conduct (inherited from `trsdn/.github`) |
| `P04`, `P10`, `P11` | `.github/ISSUE_TEMPLATE/bug_report.yml` asks for area, expected and actual result, reproduction, OpenFreshr version, macOS version and Mac, and logs; `feature_request.yml` exists; `.github/pull_request_template.md` covers what changed, validation, risk and related issues |
| `P07` | Description and five topics are set. There is no website, so no homepage is required |

### Software

| ID | Evidence |
|---|---|
| `S01` | `Package.resolved` and the pinned `project.yml` dependency are committed; the setup commands are in the README |
| `S02` | 265 tests in 31 suites cover scanning, matching, adoption, update resolution, the trust gate and scheduling without any view; failure paths are asserted (`throws`, `FailClosedEligibilityTests`, `TrustEnforcementTests`, rejected-signature cases). The SwiftUI views and real `brew` are covered by no test |
| `S04` | The README claims no platform and the manifest claims macOS 14 or later, a range covered by the newest runner. CI runs `macos-15` and `macos-latest` |
| `S05` | `secret-scan.yml` runs on pull requests and on pushes to `main` and passed on the pull request. GitHub secret scanning is disabled, so the workflow is the only layer |
| `S07` | The one `Logger` (`SelfUpdateController`) logs operation names, versions and error descriptions; no environment, token, header or body is logged, and error text names the failed operation |
| `S08` | `.github/dependabot.yml` covers the `swift` and `github-actions` ecosystems monthly and states why |
| `S10` | `AGENTS.md` documents the UI-free core, the protocol boundaries, the trust model, the committed generated project and the broker constraint |
| `S11` | Every workflow declares `permissions: contents: read` at workflow level |
| `S12` | `actions/checkout` and the reusable conformance workflow are pinned to full commit SHAs with the tag in a comment |

### Other profiles

| ID | Evidence |
|---|---|
| `R02` | `CHANGELOG.md` states that the project aims to follow Semantic Versioning |
| `G01` | `AGENTS.md` at the root |
| `G04` | No tool-specific instruction file exists, so nothing can diverge |
| `G08` | `.github/github-app.yml` points at `AGENTS.md` and declares `make all` |
| `L05` | Displayed dates and counts use `.formatted(...)` (`TrustManagementView`, `CatalogView`); sorts of displayed text are not hand-built |
| `X01` | Read: the interface uses standard SwiftUI controls, `keyboardShortcut` on the sheet actions, and no gesture-only interaction (no `onTapGesture`). Source review only; the product was not operated |
| `X03` | Read: no fixed font sizes, semantic text styles and system colours only; status is carried by a distinct symbol or text alongside any colour. Not verified with the real system accessibility settings |
| `Y03` | Source and dependencies contain no telemetry, analytics or crash reporting. The install-analytics endpoint is a read-only fetch of Homebrew's public counts, not a report about the user |
| `Y05` | The code sends no user content to any third party or AI provider: requests are `GET`s for public catalogue, appcast and release data. The absence is not stated in the README; `Y01` and `Y02` should say so |

## What to do next

In order of how much each moves:

1. Protect `main` with a ruleset (`B16`, `S09`); repository settings, no code.
2. Fix the failing CI step by regenerating `OpenFreshr.xcodeproj` from a
   directory named `OpenFreshr`, so the pull request goes green.
3. Write the Privacy section (`Y01`, `Y02`, `Y04`, `Y06`, and the `Y05` sentence).
4. Decide the language question (`L01`-`L03`, `L07`): English base strings with
   a German catalog is the route that also earns `L04` and `L06`.
5. Add the badges and the activity card (`P08`, `P09`), enable private
   vulnerability reporting (`P03`), and wire `swift format lint` into CI (`S03`).
6. Before the first release, add the `Info.plist` identity keys and an app icon,
   so that `R01` and `I01`-`I06` pass when they start to apply.
