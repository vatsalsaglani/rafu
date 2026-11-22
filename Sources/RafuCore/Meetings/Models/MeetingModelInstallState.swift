import Foundation

/// Why a model install failed. A short, stable code, never user text.
public enum MeetingModelInstallFailure: String, Hashable, Codable, Sendable, CaseIterable {
    /// The transfer failed (no network, a server error, a removed repository).
    case downloadFailed
    /// A file was larger than the catalog size; the transfer was stopped.
    case tooLarge
    /// A file had a wrong SHA-256.
    case checksumMismatch
    /// A file had a wrong size.
    case wrongSize
    /// A catalog file was missing.
    case missingFile
    /// The staged folder held a file not in the catalog, a symbolic link, or
    /// an unsafe path.
    case unexpectedContent
    /// Rafu could not write the folder (for example, the disk is full).
    case diskWrite

    /// The user-facing sentence for a failed row.
    public var message: String {
        switch self {
        case .downloadFailed: "The download failed. Check the connection and try again."
        case .tooLarge, .checksumMismatch, .wrongSize, .missingFile, .unexpectedContent:
            "The downloaded files did not pass the check, so Rafu removed them."
        case .diskWrite: "Rafu could not write the model folder. Check the free disk space."
        }
    }
}

/// The install state of one model, for the first-use sheet and Settings.
public enum MeetingModelInstallState: Hashable, Sendable {
    /// Not installed; `bytes` is the download size to show.
    case notInstalled(bytes: Int64)
    /// `fraction` is 0...1 of the download bytes.
    case downloading(fraction: Double)
    /// Each file is checked (size and SHA-256).
    case verifying
    /// Installed and checked at this pinned revision.
    case installed(revision: String)
    case failed(MeetingModelInstallFailure)

    public var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }

    /// True while a download or a check runs.
    public var isBusy: Bool {
        switch self {
        case .downloading, .verifying: true
        case .notInstalled, .installed, .failed: false
        }
    }
}
