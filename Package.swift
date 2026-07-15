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
        // Tree-sitter grammars (ADR 0005 §7.4). Pinned exact at ABI-14 tags
        // compatible with SwiftTreeSitter 0.8.0's vendored tree-sitter
        // runtime (TREE_SITTER_LANGUAGE_VERSION 14, MIN_COMPATIBLE 13).
        // Newer tags on several of these repos ship ABI-15 grammars and are
        // rejected by `Parser.setLanguage` — do not bump without re-checking.
        .package(
            url: "https://github.com/alex-pinkus/tree-sitter-swift",
            exact: "0.7.3-with-generated-files"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-python",
            exact: "0.23.6"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-javascript",
            exact: "0.23.1"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-typescript",
            exact: "0.23.2"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-json",
            exact: "0.24.8"
        ),
        .package(
            url: "https://github.com/tree-sitter-grammars/tree-sitter-yaml",
            exact: "0.7.0"
        ),
        .package(
            url: "https://github.com/tree-sitter-grammars/tree-sitter-toml",
            exact: "0.7.0"
        ),
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-bash",
            exact: "0.23.3"
        ),
        .package(
            url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown",
            exact: "0.4.1"
        ),
        .package(
            url: "https://github.com/camdencheek/tree-sitter-dockerfile",
            exact: "0.2.0"
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
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                // The upstream package exposes a single library product per
                // repo that bundles the primary grammar target with its
                // secondary injected-language target (TSX / MarkdownInline);
                // both `import` names become available once the product is
                // linked. There is no separate "TreeSitterTSX" or
                // "TreeSitterMarkdownInline" product to depend on.
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterYAML", package: "tree-sitter-yaml"),
                .product(name: "TreeSitterTOML", package: "tree-sitter-toml"),
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
                .product(name: "TreeSitterDockerfile", package: "tree-sitter-dockerfile"),
            ],
            resources: [
                // Vendored tree-sitter `highlights.scm` queries (lane-1
                // increment 8a). `.copy` (not `.process`) preserves the
                // per-grammar subdirectory layout so `Bundle.module` can
                // resolve `Grammars/<Name>/highlights.scm` under `swift test`,
                // `swift run`, and the staged `.app`. See
                // `Sources/RafuApp/Resources/Grammars/README.md`.
                .copy("Resources/Grammars")
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
