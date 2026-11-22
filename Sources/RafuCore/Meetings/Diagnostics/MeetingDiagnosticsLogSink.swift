import Foundation

/// Receives each event that the recorder writes, for the `Logger` mirror.
/// The app's implementation is `MeetingDiagnosticsLogger`; tests inject a
/// capture. A sink gets the event name and fields only.
public protocol MeetingDiagnosticsLogSink: Sendable {
    func log(_ description: MeetingDiagnosticDescription, meeting: MeetingID?)
}

/// The text that the `Logger` mirror writes, split by privacy: numbers,
/// booleans and fixed labels are public; each `MeetingDiagnosticString`
/// value (a device name, a bundle id) is private.
public struct MeetingDiagnosticLogText: Hashable, Sendable {
    public var publicText: String
    public var privateText: String

    public init(_ description: MeetingDiagnosticDescription) {
        var publicParts: [String] = []
        var privateParts: [String] = []
        for field in description.fields.sorted(by: { $0.key < $1.key }) {
            switch field.value {
            case .integer(let value): publicParts.append("\(field.key)=\(value)")
            case .number(let value): publicParts.append("\(field.key)=\(value)")
            case .flag(let value): publicParts.append("\(field.key)=\(value)")
            case .label(let value): publicParts.append("\(field.key)=\(value)")
            case .text(let value): privateParts.append("\(field.key)=\(value)")
            case .texts(let values):
                privateParts.append("\(field.key)=\(values.joined(separator: ","))")
            }
        }
        self.publicText = publicParts.joined(separator: " ")
        self.privateText = privateParts.joined(separator: " ")
    }
}
