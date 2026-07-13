import Foundation

public struct LocalWorkspaceReference: Codable, Hashable, Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }
}

public struct SSHWorkspaceReference: Codable, Hashable, Sendable {
    public let hostAlias: String
    public let rootPath: String

    public init(hostAlias: String, rootPath: String) {
        self.hostAlias = hostAlias
        self.rootPath = rootPath
    }
}

public enum WorkspaceLocation: Codable, Hashable, Sendable {
    case local(LocalWorkspaceReference)
    case ssh(SSHWorkspaceReference)
}
