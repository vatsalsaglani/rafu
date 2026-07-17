import Darwin
import Foundation

/// A path could not be encoded into a `sockaddr_un` — never a partial or
/// truncated address is returned instead.
public enum LauncherSocketAddressError: Error, Equatable, Sendable {
    case pathTooLong(byteCount: Int, limit: Int)
}

/// Pure `sockaddr_un` construction for the launcher IPC socket path
/// (`LauncherIPCSocketPath.resolve()`). No `socket`/`bind`/`connect`
/// syscalls live here — those belong to the I2 listener actor and the I5
/// CLI client, which both call `make(path:)` first.
public enum LauncherSocketAddress {
    /// `sockaddr_un.sun_path` is a fixed 104-byte buffer on Darwin and must
    /// hold a trailing NUL, so the largest encodable path is 103 bytes.
    /// `LauncherIPCSocketPath.resolve()` stays far under this for any real
    /// home directory; a relocated/exotic home is the documented failure
    /// mode this guard turns into a typed error instead of undefined
    /// behavior or a silently truncated path.
    public static let maxPathBytes = 103

    /// Builds a `sockaddr_un` for `path`. Throws `pathTooLong` rather than
    /// truncating when `path`'s UTF-8 encoding would overflow `sun_path`.
    public static func make(path: String) throws -> sockaddr_un {
        let pathBytes = Array(path.utf8)
        guard pathBytes.count <= maxPathBytes else {
            throw LauncherSocketAddressError.pathTooLong(
                byteCount: pathBytes.count, limit: maxPathBytes)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            let buffer = rawBuffer.bindMemory(to: CChar.self)
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = CChar(bitPattern: byte)
            }
            buffer[pathBytes.count] = 0
        }
        return address
    }
}
