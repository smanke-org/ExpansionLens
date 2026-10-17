// swift-tools-version: 6.2
import PackageDescription

// The shared logic lives in ExpansionLensKit, a plain Swift package so `swift test` runs it
// without Xcode. The app is built by project.yml (XcodeGen), which links this package.
let package = Package(
    name: "ExpansionLensKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ExpansionLensKit", targets: ["ExpansionLensKit"]),
    ],
    targets: [
        .target(name: "ExpansionLensKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ExpansionLensKitTests", dependencies: ["ExpansionLensKit"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
