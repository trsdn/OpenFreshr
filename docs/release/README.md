# Releasing OpenFreshr

OpenFreshr is distributed as a **direct-download Developer ID app** (not the App
Store — it must write to `/Applications` to replace apps in place). Every release
is **built, signed, notarized and stapled by the notarization broker**, never on
a developer machine.

> **Apple credentials deliberately do not exist on the dev machine.** Do **not**
> run `xcrun notarytool`, do **not** create an app-specific password, and do
> **not** create a `notarytool` keychain profile. This is a security decision,
> not an oversight.

Notarization runs only through
**[trsdn/macos-notarization-broker](https://github.com/trsdn/macos-notarization-broker)**,
a manual GitHub Actions workflow that builds, signs, notarizes and staples in
isolated jobs so that source-repository code never touches the signing secrets.

---

## Cutting a release (once the broker knows OpenFreshr)

1. Make sure `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`
   are correct, run `make generate`, and **commit** the regenerated
   `OpenFreshr.xcodeproj` together with the source. (The broker builds the
   committed project; it cannot run XcodeGen — see below.)
2. Tag that commit `vX.Y.Z` and push the tag:

   ```bash
   git tag v1.0.0 && git push origin v1.0.0
   ```

3. From a checkout of the broker:

   ```bash
   scripts/request.sh openfreshr v1.0.0
   ```

   (or **Actions → Notarize macOS release → Run workflow** from `main`, with
   `app = openfreshr`, `tag = v1.0.0`).

   `request.sh` correlates the exact run, downloads only that artifact, and verifies
   `provenance.json` plus the release digests. It emits
   `OpenFreshr-vX.Y.Z-macOS-arm64.zip`, `…-arm64.dmg` and `OpenFreshr-X.Y.Z.dmg`
   (a copy of the DMG under the exact name the in-app updater accepts).

4. Attach the broker's artifacts to the GitHub release for the tag. Do not upload
   anything built locally. Installed copies find the release through
   [§ Self-update](#self-update).

---

## One-time broker setup (required before the first release)

**OpenFreshr is not yet allowlisted in the broker.** The broker only signs apps
listed in its `profiles/apps.json`, and its build job runs a per-app adapter that
does not exist for OpenFreshr yet. This must be added in the broker repo.

Per the broker's `CONTRIBUTING.md`, **open an issue first** for any profile or
script change, then a reviewed PR. Never attach Apple credentials or certificates
to the issue/PR.

The PR makes **six** edits. Everything needed is prepared in this directory:

| # | Broker file | Change | Prepared here |
|---|-------------|--------|---------------|
| 1 | `profiles/apps.json` | Add the `openfreshr` profile object to `profiles`. | [`broker/apps.json`](broker/apps.json) — paste the inner object under key `openfreshr`. |
| 2 | `profiles/entitlements/openfreshr.plist` | Add the app's entitlements (empty, justified). | [`entitlements/openfreshr.plist`](entitlements/openfreshr.plist) — copy verbatim. |
| 3 | `scripts/broker.py` | Add the `openfreshr-xcode` adapter (3 sub-edits). | [`broker/adapter-openfreshr.py`](broker/adapter-openfreshr.py) — the function + the two list edits. |
| 4 | `scripts/request.sh` | Add `openfreshr` to the `case "$app" in …` allowlist. | one word. |
| 5 | `.github/workflows/notarize.yml` | Add `- openfreshr` to the `workflow_dispatch` `app` `options:`. | one line. |
| 6 | `profiles/locks/openfreshr-Package.resolved` | Byte-for-byte copy of this repo's `OpenFreshr.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (pins AppUpdater 4.1.2). | the file itself; the profile's `dependency_lock` points at it. |

Notes that make the review easy:

- **`repository_id` is real:** `1350716134` (`gh api repos/trsdn/OpenFreshr --jq .id`).
  The broker requires a positive integer and checks it against the dispatch.
- **`team_id: G69Z5BNY97`** is declared in the profile. A Team ID is public and is
  **not** a signing credential; the broker injects it as `DEVELOPMENT_TEAM` so
  nested helpers compile with the right client requirement. This is the same team
  already used by the `openlens` profile.
- **The committed `.xcodeproj` is intentional.** OpenFreshr generates it with
  XcodeGen from `project.yml`, but the broker's untrusted build job uses only the
  preinstalled runner toolchain and cannot fetch `xcodegen`. So the adapter drives
  the committed `OpenFreshr.xcodeproj` directly with `xcodebuild -scheme OpenFreshr`
  — exactly like the existing `openlens-xcode` adapter. Regenerate **and commit**
  the project after any `project.yml` change.
- **The repo must be public** (or readable by the broker workflow, which
  authenticates with its own `github.token`). The in-app updater also reads the
  repository's Releases without a token, so a private repo could not update
  itself either.
- **`dependency_lock` and `nested_resource_bundles`.** The app links AppUpdater,
  which SwiftPM builds as a data-only `Contents/Resources/AppUpdater_AppUpdater.bundle`;
  the profile declares it because the broker's preflight rejects any undeclared
  bundle. There is still no `nested_executables`: the app is a single Mach-O
  (`Contents/MacOS/OpenFreshr`), and the Debug-only `*.debug.dylib` /
  `__preview.dylib` do not appear in the Release build the broker makes.
- **The lock is tied to `project.yml`.** Its `originHash` covers the package
  section, so any change to the dependencies needs the broker's lock refreshed
  first, or the release fails.

`xcodebuild_settings()` in the broker already forces `ENABLE_HARDENED_RUNTIME=YES`
and `CODE_SIGNING_ALLOWED=NO` for every xcode adapter, so the hardened runtime is
guaranteed by the broker regardless of local settings.

---

## Entitlements: none, on purpose

OpenFreshr requests **zero entitlements**. It is non-sandboxed
(`ENABLE_APP_SANDBOX=NO`) under the hardened runtime
(`ENABLE_HARDENED_RUNTIME=YES`), and a non-sandboxed hardened app needs no
entitlement for anything it does:

| Capability OpenFreshr uses | Why no entitlement is needed |
|---|---|
| Spawning `brew`, `mas`, `msupdate`, `codesign`, `spctl` | The hardened runtime does not gate spawning separate, independently-signed processes. |
| Outbound network (`URLSession`) | `com.apple.security.network.client` is a **sandbox** entitlement; unsandboxed network access needs none. |
| Launch-at-login (`SMAppService.mainApp`) | The modern login-item API needs no entitlement for a non-sandboxed app. |
| User notifications | None required. |
| Apple events | The app sends none, so `…automation.apple-events` is deliberately **not** requested. |
| Loading third-party code | The app loads no external dylibs/plug-ins. AppUpdater is compiled into the executable and its only resource is a data bundle, so nothing extra is loaded and library validation needs no exception. |

The shipping entitlements file is an empty `<dict/>` with these justifications as
comments: [`Sources/OpenFreshrApp/OpenFreshr.entitlements`](../../Sources/OpenFreshrApp/OpenFreshr.entitlements).
The broker signs with its own copy,
[`profiles/entitlements/openfreshr.plist`](https://github.com/trsdn/macos-notarization-broker/blob/main/profiles/entitlements/openfreshr.plist),
never the repository's. [`entitlements/openfreshr.plist`](entitlements/openfreshr.plist)
here is that file, without comments. Both must hold the same (empty) dictionary.

If a future capability genuinely needs an entitlement, add it to the app's file
and to the broker's profile in the same release cycle, and update this copy.

---

## Self-update

OpenFreshr updates itself the way OpenWritr and OpenSwitchr do: with
[AppUpdater](https://github.com/mxcl/AppUpdater) 4.1.2, pinned in `project.yml`
and in the committed `Package.resolved`. It reads OpenFreshr's own GitHub Releases
and accepts only:

- a release asset named exactly `OpenFreshr-<semver>.dmg` (the broker publishes
  it as a copy of the notarized DMG), and
- an app inside it that carries the **same Team ID, signing identifier and bundle
  identifier** as the running one, so a swapped asset does not install.

There is no key to generate and no appcast to maintain: the trust anchor is the
Developer ID signature the broker applies. GitHub artifact attestation is
deliberately not required. The broker builds a release in its own repository, so
there is no provenance from `trsdn/OpenFreshr` to check, and AppUpdater's Sigstore
trust roots come from SwiftPM's `Bundle.module`, which an app bundle does not
carry.

Things that follow from this and are worth knowing before a release:

1. **The signature must stay stable across updates.** Every release is signed by
   the broker under Team ID `G69Z5BNY97`; a different identity would be refused by
   the updater on installed copies.
2. **The updater refuses an app whose path contains a symlink**, such as one run
   from `/tmp`. Test an update from a normal folder such as `/Applications`.
3. **Builds from before the first updater release have no updater**, so anyone
   still running one installs a newer release by hand once.
4. **OpenFreshr's own updates are separate from the managed-app updates.** The
   self-update menu items and the Settings toggle only ever
   affect OpenFreshr; the managed apps go through the window's trust gate.

`OpenFreshrCore` still reads *other* apps' Sparkle appcasts to find their updates
(`SparkleAppcast`); that is unrelated to how OpenFreshr updates itself.
