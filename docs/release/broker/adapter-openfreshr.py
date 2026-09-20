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
    #
    # The one third-party dependency, AppUpdater, is pinned to the broker-held
    # lock (`dependency_lock`), which must equal OpenFreshr's committed
    # Package.resolved. The untrusted job therefore resolves exactly the reviewed
    # revision every time, and `-onlyUsePackageVersionsFromResolvedFile` refuses to
    # move it. The lock's originHash is tied to project.yml's package section, so a
    # dependency change needs the lock refreshed here first.
    ensure_source_file(source, "OpenFreshr.xcodeproj/project.pbxproj")
    lock = safe_profile_path(profile["dependency_lock"])
    workspace_lock = (
        source
        / "OpenFreshr.xcodeproj"
        / "project.xcworkspace"
        / "xcshareddata"
        / "swiftpm"
        / "Package.resolved"
    )
    workspace_lock.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(lock, workspace_lock)
    derived_data = work / "DerivedData"
    packages = work / "SourcePackages"
    common = [
        "xcodebuild",
        "-project",
        "OpenFreshr.xcodeproj",
        "-scheme",
        "OpenFreshr",
        "-clonedSourcePackagesDirPath",
        str(packages),
        "-onlyUsePackageVersionsFromResolvedFile",
    ]
    run(common + ["-resolvePackageDependencies"], cwd=source)
    run(
        common
        + [
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
