// Throw-away spike code. Not a real tool — exists only so one binary links
// both FluidAudio (the Nemotron 3 speaker model package) and SpeakerKit
// (from argmax-oss-swift) at once, for the "both" release binary-size
// measurement item 6 of 6 left "not measured". See
// .rafu/plans/meeting-speech-spike-results.md, "CPU-only and binary-size
// comparison (item 6 of 6)". References one symbol from each package in an
// unreachable branch so the linker cannot drop either.
import FluidAudio
import Foundation
import SpeakerKit

if CommandLine.arguments.count > 1_000_000 {
    // Never taken. Keeps the compiler/linker from treating either import
    // as unused and stripping its code out of this binary.
    let fluidType: Nemotron3Models.Type = Nemotron3Models.self
    let argmaxType: PyannoteConfig.Type = PyannoteConfig.self
    print("\(fluidType) \(argmaxType)")
}

print("spike-both-libs: links FluidAudio and SpeakerKit (argmax-oss-swift) in one binary")
