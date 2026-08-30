# Reference: the `openfreshr-xcode` build adapter for the notarization broker.
#
# This file is NOT executed here. It is a copy-paste reference for the maintainer
# of trsdn/macos-notarization-broker, to be added to `scripts/broker.py` behind an
# issue + reviewed PR (the broker's CONTRIBUTING.md requires an issue before any
# profile/adapter change). See ../README.md for the full checklist.
#
# OpenFreshr generates its .xcodeproj with XcodeGen from a committed project.yml,
# and the generated project is committed too. The broker's untrusted build job runs
# only the preinstalled runner toolchain and cannot fetch xcodegen, so this adapter
# drives the committed OpenFreshr.xcodeproj directly with xcodebuild — exactly like
# the existing `build_openlens` / `build_spacemender` adapters. A committed project
# that disagrees with the manifest cannot smuggle anything through, because the
# broker's preflight validates the produced bundle against the `openfreshr` profile
# (identity, architecture, entitlements, and every nested Mach-O).

# ---------------------------------------------------------------------------
# EDIT SITE 1 — add the adapter name to `allowed_adapters` in load_profiles():
#
#     allowed_adapters = {
#         ...
#         "openfreshr-xcode",
#         ...
#     }
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# EDIT SITE 2 — add a dispatch branch in the build command (next to the other
# `elif adapter == "...":` lines):
#
#     elif adapter == "openfreshr-xcode":
#         built_app = build_openfreshr(source, work, profile, version, args.build_number)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# EDIT SITE 3 — add this function next to build_openlens():
# ---------------------------------------------------------------------------

def build_openfreshr(
    source: Path, work: Path, profile: dict[str, Any], version: str, build_number: str
) -> Path:
    # Built from the committed project for the same reason as build_openlens:
    # OpenFreshr generates its .xcodeproj with XcodeGen, which is not on the runner
    # image, so the project is committed and this adapter drives it directly.
    # xcodebuild_settings() already forces ENABLE_HARDENED_RUNTIME=YES and
    # CODE_SIGNING_ALLOWED=NO and injects DEVELOPMENT_TEAM from the profile's
    # team_id, so the produced bundle is hardened and ad-hoc-signed; the broker's
    # later stage re-signs it with the real Developer ID in an isolated job.
    ensure_source_file(source, "OpenFreshr.xcodeproj/project.pbxproj")
    derived_data = work / "DerivedData"
    run(
        [
            "xcodebuild",
            "-project",
            "OpenFreshr.xcodeproj",
            "-scheme",
            "OpenFreshr",
            "-configuration",
            "Release",
            "-destination",
            "platform=macOS",
            "-derivedDataPath",
            str(derived_data),
            "clean",
            "build",
        ]
        + xcodebuild_settings(profile, version, build_number),
        cwd=source,
    )
    return derived_data / "Build" / "Products" / "Release" / profile["bundle_name"]


# ---------------------------------------------------------------------------
# SPARKLE VARIANT — use THIS body instead, once OpenFreshr embeds Sparkle.
#
# When the app gains the Sparkle SwiftPM dependency (see ../README.md §"Enabling
# Sparkle"), the build must be pinned to a committed Package.resolved so the
# untrusted job resolves the exact same Sparkle commit every time — the pattern
# already used by build_md2loop. Steps that change:
#
#   1. Add `"dependency_lock": "locks/openfreshr-Package.resolved"` to the profile,
#      and commit that resolved file into the broker under profiles/locks/.
#   2. Declare EVERY nested Sparkle Mach-O in the profile's `nested_executables`
#      (Autoupdate, Updater.app [APPL], Downloader.xpc + Installer.xpc, and the
#      Sparkle.framework binary) — the broker's preflight REJECTS any undeclared
#      nested bundle or Mach-O. Enumerate them from a local Release build with:
#        find OpenFreshr.app -type f -perm -111 -o -name '*.xpc' -o -name '*.framework'
#   3. Swap the function body for:
#
#     def build_openfreshr(source, work, profile, version, build_number):
#         ensure_source_file(source, "OpenFreshr.xcodeproj/project.pbxproj")
#         lock = safe_profile_path(profile["dependency_lock"])
#         workspace_lock = (
#             source / "OpenFreshr.xcodeproj" / "project.xcworkspace"
#             / "xcshareddata" / "swiftpm" / "Package.resolved"
#         )
#         workspace_lock.parent.mkdir(parents=True, exist_ok=True)
#         shutil.copy2(lock, workspace_lock)
#         derived_data = work / "DerivedData"
#         packages = work / "SourcePackages"
#         common = [
#             "xcodebuild", "-project", "OpenFreshr.xcodeproj", "-scheme", "OpenFreshr",
#             "-clonedSourcePackagesDirPath", str(packages),
#             "-onlyUsePackageVersionsFromResolvedFile",
#         ]
#         run(common + ["-resolvePackageDependencies"], cwd=source)
#         run(
#             common + ["-configuration", "Release", "-destination", "platform=macOS",
#                       "-derivedDataPath", str(derived_data), "clean", "build"]
#             + xcodebuild_settings(profile, version, build_number),
#             cwd=source,
#         )
#         return derived_data / "Build" / "Products" / "Release" / profile["bundle_name"]
# ---------------------------------------------------------------------------
