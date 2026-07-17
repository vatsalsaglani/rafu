/// The app-side listener for the CLI ↔ app IPC socket (ADR 0009,
/// `docs/plans/phases/cli-app-ipc.md`). `start()`/`stop()` are stubs — I0
/// only wires the lifecycle hooks (`RafuAppDelegate.applicationDidFinish
/// Launching`/`applicationWillTerminate`) so the eventual implementation
/// has a fixed call site. The I2 increment replaces this with a
/// non-MainActor actor that owns the `AF_UNIX` listening socket
/// (`LauncherIPCSocketPath.resolve()` / `LauncherSocketAddress.make(path:)`),
/// the accept loop, and per-connection same-user (`getpeereid`)
/// enforcement.
final class LauncherIPCServer {
    static let shared = LauncherIPCServer()

    private init() {}

    /// No-op until I2. Will bind, `chmod 0600`, and `listen` on the
    /// launcher IPC socket.
    func start() {}

    /// No-op until I2. Will close the listening fd and unlink the socket
    /// file.
    func stop() {}
}
