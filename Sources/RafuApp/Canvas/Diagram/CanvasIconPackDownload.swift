import CryptoKit
import Foundation

/// One pinned, official vendor download. Rafu fetches it only after the user
/// clicks Download and confirms; the file is checked and imported like a ZIP
/// the user chose.
nonisolated struct CanvasIconPackSource: Identifiable, Sendable {
    let vendor: CanvasIconPackVendor
    let url: URL
    /// Lowercase hex SHA-256 of the pinned file, when known.
    let sha256: String?
    let approximateBytes: Int64
    /// The vendor page that links the download and states its terms.
    let pageURL: URL

    var id: String { vendor.packID }
}

nonisolated enum CanvasIconPackDownloads {
    static let maximumBytes: Int64 = 200 * 1_024 * 1_024

    /// Pinned on 2026-10-18 from each vendor's icon page; hashes computed from
    /// the downloaded files. A vendor that moves its file breaks the hash or
    /// the URL, and the UI then points the user at Import Icon Pack….
    static let sources: [CanvasIconPackSource] = [
        source(
            .aws,
            "https://d1.awsstatic.com/onedam/marketing-channels/website/public/shared/architecture-icon-release/Icon-package_07312026.5846e92413caa21490223536cc97f1269e44fa92.zip",
            sha256: "d2d166c453526471749d520e0db022c459abef759d2946cf2dd1d1c992dc6526",
            bytes: 13_988_918, page: "https://aws.amazon.com/architecture/icons/"),
        source(
            .azure, "https://arch-center.azureedge.net/icons/Azure_Public_Service_Icons_V24.zip",
            sha256: "921594ccd1bf3d9c0a1bd7b6d924e050551a59342f2b353bb74bdcf761c35141",
            bytes: 1_033_184, page: "https://learn.microsoft.com/en-us/azure/architecture/icons/"),
        source(
            .googleCloud, "https://services.google.com/fh/files/misc/core-products-icons.zip",
            sha256: "6531a10f58bc599c24d9a455d81dd757c1a03c3c43da9cddf639b859c1c1eece",
            bytes: 318_678, page: "https://cloud.google.com/icons"),
    ].compactMap { $0 }

    /// The only hosts a download (and every redirect) may use, per vendor.
    static func allowedHosts(for vendor: CanvasIconPackVendor) -> Set<String> {
        switch vendor {
        case .aws: ["d1.awsstatic.com", "aws.amazon.com"]
        case .azure: ["arch-center.azureedge.net", "learn.microsoft.com"]
        case .googleCloud: ["services.google.com", "cloud.google.com"]
        case .common, .custom: []
        }
    }

    /// HTTPS on the default port, an allowlisted host, no credentials.
    static func isAllowed(_ url: URL, vendor: CanvasIconPackVendor) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.scheme?.lowercased() == "https", let host = parts.host?.lowercased(),
            parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443
        else { return false }
        return allowedHosts(for: vendor).contains(host)
    }

    static func source(for vendor: CanvasIconPackVendor) -> CanvasIconPackSource? {
        sources.first { $0.vendor == vendor }
    }

    /// "13 MB"
    static func approximateSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func failureMessage(for vendor: CanvasIconPackVendor) -> String {
        let page = vendor.downloadPage?.absoluteString ?? "the vendor's icon page"
        return "Download failed — use Import Icon Pack… with the file from \(page)."
    }

    private static func source(
        _ vendor: CanvasIconPackVendor, _ address: String, sha256: String?, bytes: Int64,
        page: String
    ) -> CanvasIconPackSource? {
        guard let url = URL(string: address), let pageURL = URL(string: page),
            isAllowed(url, vendor: vendor)
        else { return nil }
        return CanvasIconPackSource(
            vendor: vendor, url: url, sha256: sha256, approximateBytes: bytes, pageURL: pageURL)
    }

    // MARK: Download

    /// Streams the pinned file into `folder/<vendor>.zip`, enforcing the host
    /// allowlist (also after redirects), the size cap and the pinned hash.
    /// `progress` receives (received, expected) at most once per 256 KiB.
    @concurrent
    static func download(
        _ source: CanvasIconPackSource, into folder: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> URL {
        guard isAllowed(source.url, vendor: source.vendor) else {
            throw CanvasDiagramError.unsupportedSource
        }
        var request = URLRequest(url: source.url)
        request.timeoutInterval = 60
        request.httpShouldHandleCookies = false
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
            let final = http.url, isAllowed(final, vendor: source.vendor)
        else { throw CanvasDiagramError.unsupportedSource }
        let expected = http.expectedContentLength > 0 ? http.expectedContentLength : nil
        if let expected, expected > maximumBytes { throw CanvasDiagramError.archiveTooLarge }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "\(source.vendor.packID).zip")
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw CanvasDiagramError.renderFailed
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        var buffer = Data()
        buffer.reserveCapacity(256 * 1_024)
        var received: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 256 * 1_024 {
                received += Int64(buffer.count)
                guard received <= maximumBytes else { throw CanvasDiagramError.archiveTooLarge }
                hasher.update(data: buffer)
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                progress(received, expected)
            }
        }
        received += Int64(buffer.count)
        guard received <= maximumBytes else { throw CanvasDiagramError.archiveTooLarge }
        hasher.update(data: buffer)
        try handle.write(contentsOf: buffer)
        progress(received, expected)
        if let pinned = source.sha256 {
            guard hex(hasher.finalize()) == pinned else { throw CanvasDiagramError.unsafeArchive }
        }
        return file
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
