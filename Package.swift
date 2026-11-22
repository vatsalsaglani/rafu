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
        // The agent hook helper (X11), staged into Contents/Helpers.
        .executable(name: "rafu-agent-events", targets: ["RafuAgentEventHelper"]),
        // The Meetings speech helper, staged into Contents/Helpers. It is the
        // only product that links FluidAudio and argmax-oss-swift; the app
        // binary links neither (the decision record about meeting capture
        // and on-device speech, ADR 0048).
        .executable(name: "RafuMeetingsWorker", targets: ["RafuMeetingsWorker"]),
        // SPIKE: the WidgetKit extension executable. build_and_run.sh wraps
        // it in Contents/PlugIns/RafuWidgets.appex.
        .executable(name: "RafuWidgets", targets: ["RafuWidgets"]),
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
        // Mermaid diagram layout and rendering (ADR 0020). MIT.
        .package(
            url: "https://github.com/lukilabs/beautiful-mermaid-swift",
            exact: "1.0.4"
        ),
        // Declarative generated views on the Ensemble board (ADR pending, wave 3).
        // Apache-2.0. Pre-release pin; move to the 0.22.0 release tag in wave 4.
        // Its macro target pulls swift-syntax (a longer cold build).
        .package(
            url: "https://github.com/vatsalsaglani/swift-json-render.git",
            exact: "0.22.0-alpha.3"
        ),
        // Meetings on-device speech, linked by RafuMeetingsWorker only.
        // FluidAudio 0.18.4 (commit e0c6103bc87a88d25276cad491c86e757f58c865),
        // Apache-2.0: Nemotron English text and Nemotron 3 speakers. The
        // Diarizer trait is required for the Nemotron 3 diarizer API.
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.18.4",
            traits: ["Diarizer"]
        ),
        // argmax-oss-swift 1.1.1 (commit 1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4),
        // MIT: WhisperKit text and SpeakerKit speakers.
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift.git",
            exact: "1.1.1"
        ),
        // NOTE: elk-swift (the ELK layout port) is a transitive dependency of
        // beautiful-mermaid-swift and is deliberately NOT declared here.
        // Declaring it produces "dependency 'elk-swift' is not used by any
        // target", because no Rafu target imports its product directly.
        // Its exact version is pinned by the checked-in Package.resolved, which
        // only moves on an explicit `swift package update`. See ADR 0020.
    ],
    targets: [
        .target(name: "RafuCore"),
        // SPIKE: credential-free widget snapshot model, shared by the app
        // and the sandboxed widget extension.
        .target(
            name: "RafuWidgetShared",
            swiftSettings: [.unsafeFlags(["-application-extension"])]
        ),
        .executableTarget(
            name: "RafuWidgets",
            dependencies: ["RafuWidgetShared"],
            swiftSettings: [
                // App extensions may use only extension-safe API.
                .unsafeFlags(["-application-extension"])
            ],
            linkerSettings: [
                // `-e _NSExtensionMain` is what Xcode's app-extension product
                // type adds. Without it the @main WidgetBundle entry traps in
                // `_EXRunningExtension` bootstrap instead of starting as an
                // extension XPC service.
                .unsafeFlags([
                    "-Xlinker", "-application_extension",
                    "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                ])
            ]
        ),
        .executableTarget(
            name: "RafuApp",
            dependencies: [
                "RafuCore",
                "RafuWidgetShared",
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
                .product(name: "BeautifulMermaid", package: "beautiful-mermaid-swift"),
                // Generated views (wave 3). JSONRenderClient carries the
                // `@JRComponent` macro for Rafu's own components. The
                // package's JSONRenderRemoteImages target is a placeholder at
                // 0.22.0-alpha.1; Rafu implements `JRRemoteImageProvider`
                // (from JSONRenderSwiftUI) itself.
                .product(name: "JSONRenderCore", package: "swift-json-render"),
                .product(name: "JSONRenderClient", package: "swift-json-render"),
                .product(name: "JSONRenderSwiftUI", package: "swift-json-render"),
                .product(name: "JSONRenderStandardCatalog", package: "swift-json-render"),
                .product(name: "JSONRenderCharts", package: "swift-json-render"),
                .product(name: "JSONRenderCompose", package: "swift-json-render"),
            ],
            resources: [
                // Vendored tree-sitter `highlights.scm` queries (lane-1
                // increment 8a). `.copy` (not `.process`) preserves the
                // per-grammar subdirectory layout so `Bundle.module` can
                // resolve `Grammars/<Name>/highlights.scm` under `swift test`,
                // `swift run`, and the staged `.app`. See
                // `Sources/RafuApp/Resources/Grammars/README.md`.
                .copy("Resources/Grammars"),
                // Built-in Common diagram icon pack manifest (SF Symbols only;
                // vendor packs are imported by the user, never bundled).
                .copy("Resources/DiagramPacks"),
                // The Rafu Ensemble agent skill (X4), installed from Settings.
                .copy("Resources/AgentSkills"),
                // Public Suffix List (MPL-2.0 data file) for the image host
                // trust list (wave 3); read lazily. See its README.md.
                .copy("Resources/PublicSuffix"),
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self)
            ]
        ),
        .executableTarget(
            name: "RafuCLI",
            dependencies: ["RafuCore"]
        ),
        .executableTarget(
            name: "RafuAgentEventHelper",
            dependencies: ["RafuCore"]
        ),
        // Meetings speech helper. No defaultIsolation (nonisolated by
        // default, like the other helpers). No other target may depend on
        // FluidAudio, SpeakerKit or WhisperKit.
        .executableTarget(
            name: "RafuMeetingsWorker",
            dependencies: [
                "RafuCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
        .testTarget(
            name: "RafuCoreTests",
            dependencies: ["RafuCore"]
        ),
        .testTarget(
            name: "RafuAppTests",
            dependencies: ["RafuApp", "RafuWidgetShared"],
            exclude: ["Fixtures/workbench-converged-surfaces.json"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
