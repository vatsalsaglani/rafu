public enum LauncherActivationPolicy: String, Codable, Hashable, Sendable {
    case automatic
    case newWindow
    case reuseWindow
}

public struct SourceLocation: Codable, Hashable, Sendable {
    public let line: Int
    public let column: Int?

    public init(line: Int, column: Int? = nil) {
        self.line = line
        self.column = column
    }
}

public enum LauncherTarget: Codable, Hashable, Sendable {
    case local(path: String)
    case ssh(hostAlias: String, path: String)
}

public struct LauncherOpenRequest: Codable, Hashable, Sendable {
    public let target: LauncherTarget
    public let sourceLocation: SourceLocation?
    public let activationPolicy: LauncherActivationPolicy
    public let wait: Bool

    public init(
        target: LauncherTarget,
        sourceLocation: SourceLocation? = nil,
        activationPolicy: LauncherActivationPolicy = .automatic,
        wait: Bool = false
    ) {
        self.target = target
        self.sourceLocation = sourceLocation
        self.activationPolicy = activationPolicy
        self.wait = wait
    }
}

public enum LauncherInvocation: Hashable, Sendable {
    case help
    case version
    case status
    case listSSHHosts
    case open(LauncherOpenRequest)
}
