import Foundation

/// A typed failure of the meeting library. A version conflict is reported
/// with `MeetingVersionConflict` (the contract type), not with this enum.
public enum MeetingStoreError: Error, Hashable, Sendable {
    /// No meeting folder or no `meeting.json` for this id.
    case notFound(MeetingID)
    /// A file or folder of a meeting is a symbolic link. The library never
    /// follows one.
    case symbolicLinkRefused
    /// A meeting file is not a regular file.
    case notARegularFile
    /// A file is larger than its limit.
    case fileTooLarge(limit: Int)
    /// `meeting.json` cannot be read as a record.
    case corruptRecord(MeetingID)
    /// One turn is larger than the line limit and cannot be stored.
    case turnTooLarge(MeetingTurnID)
    /// One conversation entry is larger than the line limit.
    case entryTooLarge
    /// An edit names a turn that the meeting does not have.
    case turnNotFound(MeetingTurnID)
    /// A system call failed. The value is `errno`.
    case io(code: Int32)
}
