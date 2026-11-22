// RafuMeetingsWorker: the Meetings speech helper, staged into
// Contents/Helpers. This is the stub that the shared contracts package lands.
// The speech worker package replaces it with the three modes (live text,
// final text, speakers) and the bounded JSON-lines protocol.
//
// Rules that hold from this stub on:
// - No network use. No URLSession, no model download, no Hugging Face call.
//   The app downloads models; the helper only gets a folder path.
// - The process is started by the app with an executable and an argument
//   array, never a shell string.
import FluidAudio
import Foundation
import RafuCore
import SpeakerKit
import WhisperKit

/// The version line printed for `--version`.
let workerVersionLine = #"{"worker":"stub","protocol":1}"#

/// `EX_USAGE` from sysexits(3).
let usageExitCode: Int32 = 64

if CommandLine.arguments.count > 1_000_000 {
    // Never taken. Keeps one type from each speech module in the binary so
    // the link of both packages into this helper (and not the app) is proven.
    let fluidType: Nemotron3Models.Type = Nemotron3Models.self
    let speakerType: PyannoteConfig.Type = PyannoteConfig.self
    let whisperType: WhisperKitConfig.Type = WhisperKitConfig.self
    let contractsType: MeetingID.Type = MeetingID.self
    print("\(fluidType) \(speakerType) \(whisperType) \(contractsType)")
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--version"] {
    print(workerVersionLine)
    exit(0)
}
exit(usageExitCode)
