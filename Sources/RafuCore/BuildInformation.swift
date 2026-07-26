public enum RafuBuildInformation {
    public static var identity: RafuAppIdentity { .current }
    public static var appName: String { identity.displayName }
    public static var cliName: String { identity.cliName }
    public static let version = "0.1.0-dev"
    public static let launcherProtocolVersion = 1
    public static var provisionalBundleIdentifier: String { identity.bundleIdentifier }
}
