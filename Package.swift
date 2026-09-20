// swift-tools-version: 6.0
import PackageDescription

// The package contains only the UI-free core and its test target. The SwiftUI
// application shell is described separately in `project.yml` (XcodeGen) so that
// `swift build` / `swift test` stay fast, signing-free and reproducible on a
// clean checkout, while the app bundle is produced through Xcode.
let package = Package(
    name: "OpenFreshr",
    platforms: [
        // macOS 14 is the deployment target for the whole product. The core only
        // needs Foundation, but the app shell that consumes it relies on the
        // Observation and SwiftUI features introduced in macOS 14.
        .macOS(.v14)
    ],
    products: [
        .library(name: "OpenFreshrCore", targets: ["OpenFreshrCore"])
    ],
    targets: [
        .target(
            name: "OpenFreshrCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OpenFreshrCoreTests",
            dependencies: ["OpenFreshrCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
