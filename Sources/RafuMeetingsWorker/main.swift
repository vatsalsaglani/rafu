// RafuMeetingsWorker: the Meetings speech helper, staged into
// Contents/Helpers. One process does one job and exits:
//
//   RafuMeetingsWorker --mode <live-text|final-text|speakers> --protocol 1
//
// The request is the first line of standard input (JSON, at most 16 KB).
// Results are JSON lines on standard output (`MeetingWorkerEvent`). The wire
// is in `Sources/RafuCore/Meetings/Worker/`; the reference note is
// `docs/references/meeting-speech-worker.md`.
//
// Rules:
// - No network use. No URL session, no model download, no Hugging Face
//   call; each library is configured with "download: false" or a local
//   folder load. The app downloads models; the helper gets a folder path.
// - No file write. No speaker embedding and no audio is written to disk.
// - The process is started by the app with an executable and an argument
//   array, never a shell string. Standard error is discarded by the app.
// - It exits when its job ends, when standard input closes (in the file
//   modes that means "cancel"), and when the app that started it ends.
import Foundation
import RafuCore

let workerArguments = Array(CommandLine.arguments.dropFirst())
if workerArguments == ["--version"] {
    print(#"{"worker":"RafuMeetingsWorker","protocol":\#(MeetingWorkerProtocol.version)}"#)
    exit(0)
}

let workerMode: MeetingWorkerMode
do {
    workerMode = try MeetingWorkerArguments.parse(workerArguments)
} catch {
    exitWorker(.usage)
}

let workerOutput = WorkerOutput()
let parentWatch = exitWhenParentEnds()

guard let requestInput = readRequestLine() else {
    workerOutput.fail(
        .request, code: MeetingWorkerRequestError.tooLarge.wireCode, exit: .badRequest)
}

let workerRequest: MeetingWorkerRequest
do {
    let decoded = try MeetingWorkerRequest.decode(line: requestInput.line)
    try decoded.validate(for: workerMode)
    workerRequest = decoded
} catch {
    workerOutput.fail(
        error == .modelMissing ? .model : .request, code: error.wireCode, exit: error.exitCode)
}

let exitCode: MeetingWorkerExitCode
switch (workerMode, workerRequest.engine, workerRequest.audioFile) {
case (.liveText, .nemotronEnglish, _):
    exitCode = await runLiveText(workerRequest, leftover: requestInput.rest, output: workerOutput)
case (.finalText, .nemotronEnglish, let audioFile?):
    exitWhenInputCloses(workerOutput)
    exitCode = await runNemotronFinalText(workerRequest, audioFile: audioFile, output: workerOutput)
case (.finalText, .whisperKit, let audioFile?):
    exitWhenInputCloses(workerOutput)
    exitCode = await runWhisperKitFinalText(
        workerRequest, audioFile: audioFile, output: workerOutput)
case (.speakers, .nemotron3, let audioFile?):
    exitWhenInputCloses(workerOutput)
    exitCode = await runNemotron3Speakers(workerRequest, audioFile: audioFile, output: workerOutput)
case (.speakers, .speakerKit, let audioFile?):
    exitWhenInputCloses(workerOutput)
    exitCode = await runSpeakerKitSpeakers(
        workerRequest, audioFile: audioFile, output: workerOutput)
default:
    workerOutput.fail(
        .request, code: MeetingWorkerRequestError.engineNotForMode.wireCode, exit: .badRequest)
}
withExtendedLifetime(parentWatch) {}
exitWorker(exitCode)
