// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "wispr-screen-share-paste-fix",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "wispr-screen-share-paste-fix",
            targets: ["WisprScreenSharePasteFix"]
        )
    ],
    targets: [
        .executableTarget(
            name: "WisprScreenSharePasteFix",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedLibrary("sqlite3"),
            ]
        )
    ]
)
