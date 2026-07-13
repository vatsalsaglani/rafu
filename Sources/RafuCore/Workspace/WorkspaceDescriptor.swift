import Foundation

public struct WorkspaceDescriptor: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let displayName: String
    public let location: WorkspaceLocation

    public init(
        id: UUID = UUID(),
        displayName: String,
        location: WorkspaceLocation
    ) {
        self.id = id
        self.displayName = displayName
        self.location = location
    }
}
