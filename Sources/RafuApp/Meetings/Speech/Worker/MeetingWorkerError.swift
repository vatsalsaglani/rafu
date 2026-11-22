import Foundation
import RafuCore

/// A typed failure of a helper job. The helper never changes the stored
/// audio, so each case keeps the audio: the user can try again.
nonisolated enum MeetingWorkerError: Error, Equatable, Sendable {
    /// `Contents/Helpers/RafuMeetingsWorker` is not in the app.
    case helperMissing
    /// The engine's model is not installed (or the folder is incomplete).
    case modelMissing(MeetingModelID)
    /// The helper could not start.
    case launchFailed
    /// The helper refused the request (exit 64 or 65).
    case badRequest
    /// The engine failed (exit 70), with the `error` line's domain and code.
    case engineFailed(domain: MeetingWorkerErrorDomain?, code: Int?)
    /// The job was cancelled.
    case cancelled
    /// Critical memory pressure stopped the job. The audio is kept.
    case memoryPressure
    /// The helper sent a line that is not in the protocol, or ended
    /// without `done`.
    case protocolViolation
    /// The helper ended with a signal (a crash).
    case crashed(signal: Int32)
    /// This engine gives no live text (WhisperKit).
    case liveTextNotSupported

    /// Always true: no helper failure deletes or changes recorded audio.
    var keepsAudio: Bool { true }

    /// A short message for the interface. It never holds a path or text.
    var userMessage: String {
        switch self {
        case .helperMissing: "The Meetings speech helper is missing. Reinstall Rafu."
        case .modelMissing: "The speech model is not installed. Download it in Settings ▸ Meetings."
        case .launchFailed: "The Meetings speech helper could not start. Your audio is kept."
        case .badRequest: "The Meetings speech helper refused the job. Your audio is kept."
        case .engineFailed: "The speech engine stopped with an error. Your audio is kept."
        case .cancelled: "Processing was cancelled. Your audio is kept."
        case .memoryPressure:
            "Processing stopped because the Mac is low on memory. Your audio is kept. Try again."
        case .protocolViolation:
            "The Meetings speech helper sent an unexpected reply. Your audio is kept."
        case .crashed: "The Meetings speech helper stopped. Your audio is kept. Try again."
        case .liveTextNotSupported: "This engine makes text after Stop only."
        }
    }

    /// A stable domain for diagnostics (never a path or text).
    var diagnosticDomain: String {
        switch self {
        case .helperMissing: "worker.helperMissing"
        case .modelMissing: "worker.modelMissing"
        case .launchFailed: "worker.launchFailed"
        case .badRequest: "worker.badRequest"
        case .engineFailed(let domain, _): "worker.engine.\(domain?.rawValue ?? "unknown")"
        case .cancelled: "worker.cancelled"
        case .memoryPressure: "worker.memoryPressure"
        case .protocolViolation: "worker.protocol"
        case .crashed: "worker.crashed"
        case .liveTextNotSupported: "worker.noLiveText"
        }
    }

    /// The error for a helper that ended without `done`.
    static func from(
        termination: MeetingWorkerTermination, lastError: (MeetingWorkerErrorDomain, Int)?,
        model: MeetingModelID
    ) -> MeetingWorkerError {
        switch termination {
        case .signalled(let signal):
            return .crashed(signal: signal)
        case .exited(let code):
            switch MeetingWorkerExitCode(rawValue: code) {
            case .done?: return .protocolViolation
            case .usage?, .badRequest?: return .badRequest
            case .modelMissing?: return .modelMissing(model)
            case .engineError?: return .engineFailed(domain: lastError?.0, code: lastError?.1)
            case .cancelled?: return .cancelled
            case nil: return .engineFailed(domain: lastError?.0, code: lastError?.1 ?? Int(code))
            }
        }
    }
}
