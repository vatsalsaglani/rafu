// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Rafu",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "RafuCore", targets: ["RafuCore"]),
        .executable(name: "RafuApp", targets: ["RafuApp"]),
        .executable(name: "rafu", targets: ["RafuCLI"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/gonzalezreal/swift-markdown-ui.git",
            exact: "2.4.1"
        ),
        .package(
            url: "https://github.com/ChimeHQ/Neon.git",
            exact: "0.6.0"
        ),
        // Neon 0.6.0 declares `from: 0.8.0`, which permits API-breaking 0.x
        // releases. Keep its verified compatible SwiftTreeSitter line explicit.
        .package(
            url: "https://github.com/ChimeHQ/SwiftTreeSitter",
            exact: "0.8.0"
        ),
        // Terminal emulation (ADR 0004). MIT license.
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm.git",
            exact: "1.14.0"
        ),
    ],
    targets: [
        .target(name: "RafuCore"),
        .executableTarget(
            name: "RafuApp",
            dependencies: [
                "RafuCore",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "Neon", package: "Neon"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self)
            ]
        ),
        .executableTarget(
            name: "RafuCLI",
            dependencies: ["RafuCore"]
        ),
        .testTarget(
            name: "RafuCoreTests",
            dependencies: ["RafuCore"]
        ),
        .testTarget(
            name: "RafuAppTests",
            dependencies: ["RafuApp"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
