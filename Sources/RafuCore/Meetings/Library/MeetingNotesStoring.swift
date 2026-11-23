import Foundation

/// The meeting notes that the hidden agent writes after processing (a title
/// and a summary), beside the library. `MeetingStore` conforms. Code that
/// holds the registered `any MeetingStoring` reaches it with
/// `store as? any MeetingNotesStoring`.
public protocol MeetingNotesStoring: MeetingLibraryServicing {
    /// The text revision of the meeting. It goes up each time the whole
    /// transcript is replaced (the text is made again). A meeting from
    /// before the revision existed has revision 0.
    func textRevision(of meeting: MeetingID) async throws -> Int
    /// The saved notes, or nil when there are none (or the file has another
    /// schema).
    func summaryNotes(of meeting: MeetingID) async throws -> MeetingSummaryNotes?
    /// Saves the notes. Returns false and writes nothing when the notes are
    /// for an older text revision than the meeting has now.
    @discardableResult
    func saveSummaryNotes(_ notes: MeetingSummaryNotes, for meeting: MeetingID) async throws
        -> Bool
    /// Sets a title that the agent wrote. Returns false and writes nothing
    /// when the user named the meeting.
    @discardableResult
    func applyGeneratedTitle(_ title: String, to meeting: MeetingID) async throws -> Bool
}
