# OpenFreshr

[![License](https://raw.githubusercontent.com/trsdn/OpenFreshr/stats/.github/badges-generated/license.svg)](LICENSE)
[![Minimum macOS version](https://raw.githubusercontent.com/trsdn/OpenFreshr/stats/.github/badges-generated/platform.svg)](#compatibility)
[![CI](https://github.com/trsdn/OpenFreshr/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/trsdn/OpenFreshr/actions/workflows/ci.yml)
[![Conformance](.github/badges/conformance.svg)](.github/conformance.yml)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/trsdn/OpenFreshr/stats/.github/stats/repo-card-dark.svg">
  <img alt="Repository statistics" src="https://raw.githubusercontent.com/trsdn/OpenFreshr/stats/.github/stats/repo-card.svg">
</picture>

A replacement for [MacUpdater](https://www.corecode.io/macupdater/) (discontinued
on 2026-01-01) — with the difference that OpenFreshr does not only **update**
apps, it also **finds and installs** them. It is a native macOS menu bar app for
anyone who wants the apps on their Mac kept current without a curated database,
a subscription or an account.

## Idea

MacUpdater lived on a curated database of about 100,000 apps. That cannot be
rebuilt, and it does not need to be. Four sources that are already maintained
cover a real Mac almost completely:

| Source | Who maintains it |
|---|---|
| Homebrew Cask | The Homebrew community |
| Mac App Store | Apple |
| Microsoft AutoUpdate | Microsoft |
| Sparkle appcast | The app vendors themselves |

Measured on a real developer Mac: **91% of 109 third-party apps** with no curation
at all, about 95% with conservative name matching. The measurement is
reproducible in [`docs/research/`](docs/research/).

## What it does

| | |
|---|---|
| **Detect** | Scans the application folders and marks each app with its source. Works fully without Homebrew. |
| **Update** | One button per app. If Homebrew does not know the app, the same button adopts it first. |
| **Discover** | Searchable catalogue of more than 7,700 casks with a popularity ranking and installation. |
| **Protect** | Signature, Gatekeeper and Team ID checks before every app replacement. |
| **Watch** | Menu bar item with an update count, and a background check on a schedule. |

## Scope and limits

- **Detection** works without Homebrew. Without brew you still see what is out
  of date.
- **Execution** is delegated to the responsible tool instead of building a
  download-and-install routine of its own.
- **The Team ID check** blocks an update when an app is suddenly signed by a
  different developer, which protects against a hijacked update channel.
- **Nothing runs unattended.** Every action shows the exact command first, and
  a success counts only when a fresh scan confirms the version on disk.

## Status

Public and functionally complete, but **no release has been published yet**.
Builds are not yet notarized, so for now OpenFreshr is used by
[building it from source](#build). The release procedure is in
[`docs/release/`](docs/release/README.md).

- [Product Requirements Document](docs/PRD.md)
- [Implementation plan](docs/PLAN.md)
- [Release preparation](docs/release/README.md)
- [Changelog](CHANGELOG.md)
- [Conformance record](docs/self-assessment.md) against the
  [trsdn Repository Quality Standard](https://github.com/trsdn/.github/blob/main/docs/repository-quality-standard.md)

## Compatibility

macOS 14 (Sonoma) or later, on Apple silicon. The Homebrew, Mac App Store
(`mas`) and Microsoft AutoUpdate sources are used when their tools are present
and skipped when they are not.

## Build

```bash
make all      # the complete check: build the UI-free core and run its tests
make build    # UI-free core only
make test     # test suite; needs no Xcode, no network and no brew
make app      # app shell, unsigned; runs on any machine
make run      # build signed and launch
```

`make app` produces an ad-hoc signed app without a stable code identity, so macOS
asks for permissions again on every launch. Use `make run` to actually use it.
The Xcode project is generated from `project.yml` with `make generate`.

## Configuration and usage

OpenFreshr has no configuration file. Everything is in **Settings** (`⌘,`):

- how often the background check runs (it only checks, it never installs);
- whether to notify on new updates (off by default);
- whether to show a Dock icon or live in the menu bar only;
- launch at login;
- whether OpenFreshr updates itself (checked at most once a day, installed only
  after you confirm);
- the stored trust decisions per app, which you can reset.

A typical session:

1. Open OpenFreshr from the menu bar. It scans and lists the installed apps with
   the source that keeps each one current.
2. Pick an app with an update and press its update button. The exact command is
   shown first, for example `brew upgrade --cask --greedy -- <token>`.
3. Once the update ran, OpenFreshr rescans and reports success only if the new
   version is on disk.
4. To adopt an app Homebrew does not know yet, use the same button; it runs
   `brew install --cask --adopt -- <token>` first, after you confirm.
5. To find new software, open the catalogue, search, and install a cask from
   there.

## Security

- The trust chain (code signature, Gatekeeper, expected Team ID) gates every app
  replacement and fails closed.
- OpenFreshr trusts the integrity of the Homebrew cask catalogue; the matching
  rules guard against accidental mismatches, not against a compromised catalogue.
  Catalogue data enters only through one hardened ingestion path. Details are in
  [`AGENTS.md`](AGENTS.md).
- The app is hardened and non-sandboxed with zero entitlements, because it must
  write to `/Applications`. It never runs a shell line; commands use argument
  arrays.
- Releases are signed and notarized only by the
  [notarization broker](https://github.com/trsdn/macos-notarization-broker); no
  Apple credential exists on the development machine or in this repository.
- To report a vulnerability, use **Report a vulnerability** on the repository's
  [Security tab](https://github.com/trsdn/OpenFreshr/security/advisories/new);
  see the [security policy](https://github.com/trsdn/.github/blob/main/SECURITY.md).

## Privacy

OpenFreshr has no account, no telemetry, no analytics and no crash reporting,
and it sends none of your data to any service. Everything below is what it reads,
stores and contacts.

**What it reads.** The list of installed apps: the app bundles in `/Applications`,
`/Applications/Utilities`, `/System/Applications` and `~/Applications`, with each
bundle's name, bundle identifier, version, code signature and Team ID, and an
update feed address if the app declares one. It also asks `brew`, `mas` and
`msupdate` what they have installed and what is outdated. The inventory stays on
your Mac.

**What it stores, and where.**

| What | Where | Kept |
|---|---|---|
| Homebrew cask catalogue and install counts (cache) | `~/Library/Application Support/OpenFreshr/CatalogCache/` (`cask.json`, `analytics.json`, `meta.json`) | Replaced when refreshed (about once a day); otherwise until you delete it |
| Trust decisions: per app, the trusted Team ID and the changes you confirmed | `~/Library/Application Support/OpenFreshr/trust-store.json` | Until you reset it in Settings or delete the file |
| Time of the last successful background check | `~/Library/Application Support/OpenFreshr/last-check.json` | Overwritten on each check |
| Preferences (check interval, notifications, Dock icon, last known update count, self-update setting and last check time) | User defaults of `com.openfreshr.app`, in `~/Library/Preferences/com.openfreshr.app.plist` | Until you delete them |

**How to delete it.** Quit OpenFreshr, then run:

```bash
rm -r ~/Library/Application\ Support/OpenFreshr
defaults delete com.openfreshr.app
```

Trust decisions can also be reset in Settings. The app bundle includes a
catalogue snapshot as a fallback; it contains only public Homebrew data.

**What it contacts, and why.** Only these destinations, all by reading public
data:

| Destination | Purpose |
|---|---|
| `formulae.brew.sh` | The cask catalogue and the public 365-day cask install counts (popularity ranking) |
| `github.com` and `api.github.com` (GitHub Releases of `trsdn/OpenFreshr`) | Checking for and downloading OpenFreshr's own updates, at most once a day and only if you leave the setting on |
| The update feed address (`SUFeedURL`) each installed Sparkle app declares, on that vendor's own host | Finding the newest version of that app |
| Whatever `brew`, `mas` and `msupdate` contact | Running the updates you start; those tools decide, not OpenFreshr |

Requests carry no identifier and no inventory: they are plain requests for public
files. OpenFreshr sends no user content to any third party or AI provider.

## Localization

The user interface is in English, with a German translation. The language follows
the macOS system language. The documentation is in English.

## Accessibility

OpenFreshr uses standard SwiftUI controls, semantic text styles and system
colours, offers keyboard shortcuts for the sheet actions and needs no gesture-only
interaction; status is shown with a symbol or text as well as colour. These limits
are known:

- No audit with VoiceOver, Switch Control or other assistive technology has been
  done. The claims above come from reading the source, not from operating the app
  with them.
- Some icon-only controls have no accessibility label; the search clear button in
  the catalogue is one. Only the menu bar item is labelled explicitly.
- Contrast, larger text sizes and Reduce Motion were not checked against the
  real system settings.

Reports of accessibility problems are welcome as issues.

## Support and maintenance

OpenFreshr is maintained by one person on a best-effort basis, with no support
commitment or response time. Ask questions and report bugs as
[GitHub issues](https://github.com/trsdn/OpenFreshr/issues); only the latest
release, once there is one, is supported. Security reports go through the private
route above.

## Related projects

- [chenasraf/OpenUpdater](https://github.com/chenasraf/OpenUpdater) — pursues the
  same purpose through hand-maintained recipes. Its declarative YAML schema is the
  model for possible fallback recipes in OpenFreshr.
- [jakejarvis/versioneer](https://github.com/jakejarvis/versioneer) — a native
  macOS app updater, early alpha.

## Licence

[MIT](LICENSE)
