// swift-tools-version: 6.2
// Throw-away spike package. Not linked by the root Package.swift. See
// .rafu/plans/meeting-speech-spike.md in the primary checkout for the plan.
//
// Built in stages per the plan's implementation steps: the scorer library
// and its tests first (no model dependency needed), then SpikeSupport,
// then the model-backed executables once FluidAudio and argmax-oss-swift
// are added below.
import PackageDescription

let package = Package(
    name: "MeetingSpeechSpike",
    platforms: [.macOS(.v26)],
    products: [],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.18.4",
            traits: ["Diarizer"]
        ),
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift.git",
            exact: "1.1.1"
        ),
    ],
    targets: [
        .target(
            name: "SpikeScoring",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SpikeScoringTests",
            dependencies: ["SpikeScoring"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "SpikeSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "spike-fetch",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "spike-apple-asr",
            dependencies: ["SpikeSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "spike-fluid-diar",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                "SpikeScoring", "SpikeSupport",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "spike-fluid-asr",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                "SpikeScoring", "SpikeSupport",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "spike-argmax-diar",
            dependencies: [
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
                "SpikeSupport",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "spike-argmax-asr",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                "SpikeSupport",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "spike-score",
            dependencies: ["SpikeScoring"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "spike-live",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                "SpikeScoring", "SpikeSupport",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Added for the "both" release binary-size measurement (item 6 of
        // 6's open "both" link set) — see
        // .rafu/plans/meeting-speech-spike-results.md, "CPU-only and
        // binary-size comparison". Links both FluidAudio and an
        // argmax-oss-swift product in one binary; no other target changed.
        .executableTarget(
            name: "spike-both-libs",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
