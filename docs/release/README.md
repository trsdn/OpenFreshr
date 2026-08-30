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
`OpenFreshr-vX.Y.Z-macOS-arm64.zip` and `…-arm64.dmg`.

4. Attach the notarized `.zip` and `.dmg` to the GitHub release for the tag.
5. Update `docs/appcast.xml` with an `<item>` for the release (see
   [§ Appcast & self-update](#appcast--self-update)).

---

## One-time broker setup (required before the first release)

**OpenFreshr is not yet allowlisted in the broker.** The broker only signs apps
listed in its `profiles/apps.json`, and its build job runs a per-app adapter that
does not exist for OpenFreshr yet. This must be added in the broker repo.

Per the broker's `CONTRIBUTING.md`, **open an issue first** for any profile or
script change, then a reviewed PR. Never attach Apple credentials or certificates
to the issue/PR.

The PR makes **five** edits. Everything needed is prepared in this directory:

| # | Broker file | Change | Prepared here |
|---|-------------|--------|---------------|
| 1 | `profiles/apps.json` | Add the `openfreshr` profile object to `profiles`. | [`broker/apps.json`](broker/apps.json) — paste the inner object under key `openfreshr`. |
| 2 | `profiles/entitlements/openfreshr.plist` | Add the app's entitlements (empty, justified). | [`entitlements/openfreshr.plist`](entitlements/openfreshr.plist) — copy verbatim. |
| 3 | `scripts/broker.py` | Add the `openfreshr-xcode` adapter (3 sub-edits). | [`broker/adapter-openfreshr.py`](broker/adapter-openfreshr.py) — the function + the two list edits. |
| 4 | `scripts/request.sh` | Add `openfreshr` to the `case "$app" in …` allowlist. | one word. |
| 5 | `.github/workflows/notarize.yml` | Add `- openfreshr` to the `workflow_dispatch` `app` `options:`. | one line. |

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
- **The repo must stay readable by the broker workflow** (it authenticates with its
  own `github.token`). `trsdn/OpenFreshr` is currently private; grant the broker
  read access before dispatching, or the checkout step fails.
- **No `nested_executables` today.** The current app is a single Mach-O
  (`Contents/MacOS/OpenFreshr`); the Debug-only `*.debug.dylib`/`__preview.dylib`
  do not appear in the Release build the broker makes. The broker's preflight
  rejects any *undeclared* nested Mach-O or bundle — so this changes the day
  Sparkle is embedded (see below).

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
| Loading third-party code | The app loads no external dylibs/plug-ins. Sparkle (when linked) ships its framework and XPC services signed by the **same** Developer ID team, so library validation passes **without** `cs.disable-library-validation` (that exception is only for *sandboxed* Sparkle hosts). |

The shipping entitlements file is an empty `<dict/>` with these justifications as
comments: [`Sources/OpenFreshrApp/OpenFreshr.entitlements`](../../Sources/OpenFreshrApp/OpenFreshr.entitlements).
The broker copy [`entitlements/openfreshr.plist`](entitlements/openfreshr.plist)
must stay byte-for-byte identical.

If a future capability genuinely needs an entitlement, add it to **both** files
with a justification comment in the same release cycle.

---

## Appcast & self-update

OpenFreshr watches other apps' Sparkle feeds; it uses the same mechanism for
itself (honest dogfooding).

- **Feed URL** (baked into `Info.plist` as `SUFeedURL`):
  `https://trsdn.github.io/OpenFreshr/appcast.xml`
- **Serving it:** GitHub Pages, *Settings → Pages → Deploy from a branch →
  `main` / `/docs`*. The feed file lives at [`docs/appcast.xml`](../appcast.xml)
  and is **empty until a signed release exists** — it must only ever advertise a
  correctly signed build.
- After a release is notarized, generate the EdDSA signature for the exact `.zip`
  and add an `<item>` (template is in `docs/appcast.xml`).

### EdDSA signing key (Sparkle)

Sparkle authenticates updates with an Ed25519 key pair, **separate** from Apple
code-signing.

- **The private key must never enter this repository.** Generate it once with
  Sparkle's tool and store the private half in the broker's Actions secrets (or a
  password manager), the same trust boundary as the Apple secrets:
  ```bash
  # from a Sparkle checkout / the Sparkle release's bin/
  ./generate_keys                 # prints the public key; stores private in Keychain
  ./generate_keys -x private.pem  # export to move it into a secret store, then delete
  ```
- Put **only the public key** into `Info.plist` → `SUPublicEDKey`
  (in `project.yml` under the target's `info.properties`). It currently holds the
  placeholder `REPLACE_WITH_SPARKLE_ED25519_PUBLIC_KEY`.
- Sign each release artifact and paste the output into the appcast `<item>`:
  ```bash
  ./sign_update OpenFreshr-vX.Y.Z-macOS-arm64.zip
  ```

If you cannot generate the key without creating a secret on this machine, **stop**
and hand the step to whoever owns the broker secrets. Do not invent a key.

---

## Enabling Sparkle in the build (deferred)

The self-update **logic and UI are already wired** (`SelfUpdateChecker` in the
core, `SelfUpdateController` + the "Nach OpenFreshr-Updates suchen …" menu items),
but the **Sparkle binary dependency is intentionally not yet added**, because on
this machine SwiftPM package resolution fails during `xcodebuild`:

```
fatal: cannot use bare repository '…/SourcePackages/repositories/Sparkle-…'
(safe.bareRepository is 'explicit')
```

The global git hardening `safe.bareRepository=explicit` blocks SwiftPM's bare-repo
clone. Working around it would mean mutating a deliberate global git security
setting, so the dependency is deferred rather than forced — **a broken build is
worse than a missing self-update**. `SelfUpdateController` is guarded with
`#if canImport(Sparkle)`: without the framework it falls back to an `NSAlert` that
checks the feed and links to the releases page; with the framework linked it drives
the real `SPUStandardUpdaterController`.

To finish it (on a machine/runner without that git restriction, or with
`git config --global safe.bareRepository all` for the resolve step only):

1. In `project.yml`, add the package and the target dependency:
   ```yaml
   packages:
     Sparkle:
       url: https://github.com/sparkle-project/Sparkle
       from: 2.6.0
   targets:
     OpenFreshr:
       dependencies:
         - package: Sparkle
   ```
2. `make generate`, build, then **commit** `OpenFreshr.xcodeproj` **and** the
   generated `…/xcshareddata/swiftpm/Package.resolved`.
3. Replace the `SUPublicEDKey` placeholder with the real public key.
4. In the broker: add `dependency_lock: locks/openfreshr-Package.resolved`, commit
   that resolved file, switch `build_openfreshr` to the Sparkle variant in
   [`broker/adapter-openfreshr.py`](broker/adapter-openfreshr.py), and declare
   **every** nested Sparkle Mach-O in the profile's `nested_executables`
   (Autoupdate, `Updater.app` [APPL], the Downloader/Installer XPC services, and
   the `Sparkle.framework` binary) — the preflight rejects any undeclared one.
   Enumerate them from a local Release build:
   ```bash
   find OpenFreshr.app \( -name '*.xpc' -o -name '*.framework' -o -perm -111 \) -print
   ```

Until then, `make build`, `make test`, `make app` and `make run` all stay green
and the app self-checks via the fallback path.
