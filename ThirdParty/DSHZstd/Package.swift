// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DSHZstd",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "libzstd",
            type: .static,
            targets: ["libzstd"]
        ),
    ],
    targets: [
        .target(
            name: "libzstd",
            path: "Sources/libzstd",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("common"),
                .headerSearchPath("decompress"),
                .define("DEBUGLEVEL", to: "0"),
                .define("XXH_NAMESPACE", to: "ZSTD_"),
                .define("ZSTD_DISABLE_ASM"),
                .define("ZSTD_LEGACY_SUPPORT", to: "0"),
            ]
        ),
    ]
)
