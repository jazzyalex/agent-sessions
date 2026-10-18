// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "notch-spike",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "NotchSpikeCore"),
        .executableTarget(name: "notch-spike", dependencies: ["NotchSpikeCore"],
                          resources: [.copy("Resources")]),
        .testTarget(name: "NotchSpikeCoreTests", dependencies: ["NotchSpikeCore"],
                    swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")]),
    ],
    swiftLanguageModes: [.v5]
)
