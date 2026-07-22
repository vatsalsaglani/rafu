// Adapted from CodexBar/SweetCookieKit's SafariCookieImporter, MIT License.
// This version keeps the public surface domain-scoped, adds hard bounds, and
// maps TCC permission denial to a typed Full Disk Access result without any
// prompting or retry loop.

import Foundation

nonisolated struct SafariCookieReader: Sendable {
    typealias DataLoader = @Sendable (URL) throws -> Data

    private static let maximumFileBytes = 64 * 1_024 * 1_024
    private static let maximumPages = 4_096
    private static let maximumCookiesPerPage = 65_536
    private static let maximumRecordBytes = 1 * 1_024 * 1_024

    private let candidateFiles: [URL]
    private let dataLoader: DataLoader

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        candidateFiles: [URL]? = nil,
        dataLoader: @escaping DataLoader = { try Data(contentsOf: $0, options: .mappedIfSafe) }
    ) {
        self.candidateFiles =
            candidateFiles ?? [
                homeDirectory.appending(path: "Library/Cookies/Cookies.binarycookies"),
                homeDirectory.appending(
                    path:
                        "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"
                ),
            ]
        self.dataLoader = dataLoader
    }

    func readCookies(request: CookieReadRequest) throws -> [BrowserCookieRecord] {
        var sawPermissionDenial = false
        var sawInvalidStore = false
        var sawValidStore = false

        for url in candidateFiles.prefix(8) {
            guard !Task.isCancelled else { throw CancellationError() }
            do {
                let data = try dataLoader(url)
                guard data.count <= Self.maximumFileBytes else {
                    sawInvalidStore = true
                    continue
                }
                let records = try Self.parseBinaryCookies(data, request: request)
                sawValidStore = true
                if !records.isEmpty { return records }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CocoaError {
                switch error.code {
                case .fileReadNoPermission:
                    sawPermissionDenial = true
                case .fileReadNoSuchFile:
                    continue
                default:
                    sawInvalidStore = true
                }
            } catch let error as BrowserCookieReadError {
                if error == .invalidStore { sawInvalidStore = true }
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSPOSIXErrorDomain,
                    nsError.code == Int(EACCES) || nsError.code == Int(EPERM)
                {
                    sawPermissionDenial = true
                } else {
                    sawInvalidStore = true
                }
            }
        }

        if sawPermissionDenial { throw BrowserCookieReadError.needsFullDiskAccess }
        if sawInvalidStore { throw BrowserCookieReadError.invalidStore }
        if sawValidStore { return [] }
        throw BrowserCookieReadError.noStore
    }

    static func parseBinaryCookies(
        _ data: Data, request: CookieReadRequest
    ) throws -> [BrowserCookieRecord] {
        var reader = BinaryCookieReader(data: data)
        guard reader.readASCII(count: 4) == "cook", let rawPageCount = reader.readUInt32BE()
        else { throw BrowserCookieReadError.invalidStore }
        let pageCount = Int(rawPageCount)
        guard pageCount <= maximumPages,
            pageCount <= reader.remaining / MemoryLayout<UInt32>.size
        else { throw BrowserCookieReadError.invalidStore }

        var pageSizes: [Int] = []
        pageSizes.reserveCapacity(pageCount)
        for _ in 0..<pageCount {
            guard let rawSize = reader.readUInt32BE() else {
                throw BrowserCookieReadError.invalidStore
            }
            pageSizes.append(Int(rawSize))
        }

        var records: [BrowserCookieRecord] = []
        var pageOffset = reader.offset
        for pageSize in pageSizes {
            guard !Task.isCancelled else { throw CancellationError() }
            guard pageSize >= 8, pageOffset <= data.count,
                pageSize <= data.count - pageOffset
            else { throw BrowserCookieReadError.invalidStore }
            let page = data.subdata(in: pageOffset..<(pageOffset + pageSize))
            try parsePage(page, request: request, records: &records)
            guard records.count <= CookieReadRequest.maximumRecords else {
                throw BrowserCookieReadError.invalidStore
            }
            pageOffset += pageSize
        }
        return records
    }

    private static func parsePage(
        _ data: Data,
        request: CookieReadRequest,
        records: inout [BrowserCookieRecord]
    ) throws {
        var reader = BinaryCookieReader(data: data)
        guard reader.readUInt32LE() != nil, let rawCookieCount = reader.readUInt32LE()
        else { throw BrowserCookieReadError.invalidStore }
        let cookieCount = Int(rawCookieCount)
        guard cookieCount <= maximumCookiesPerPage,
            cookieCount <= reader.remaining / MemoryLayout<UInt32>.size
        else { throw BrowserCookieReadError.invalidStore }

        var offsets: [Int] = []
        offsets.reserveCapacity(cookieCount)
        for _ in 0..<cookieCount {
            guard let rawOffset = reader.readUInt32LE() else {
                throw BrowserCookieReadError.invalidStore
            }
            offsets.append(Int(rawOffset))
        }

        for offset in offsets {
            guard !Task.isCancelled else { throw CancellationError() }
            if let record = parseCookieRecord(data, offset: offset, request: request) {
                records.append(record)
            }
        }
    }

    private static func parseCookieRecord(
        _ data: Data,
        offset: Int,
        request: CookieReadRequest
    ) -> BrowserCookieRecord? {
        guard offset >= 0, offset <= data.count - min(data.count, 56) else { return nil }
        var reader = BinaryCookieReader(data: data, offset: offset)
        guard let rawSize = reader.readUInt32LE() else { return nil }
        let recordSize = Int(rawSize)
        guard recordSize >= 56, recordSize <= maximumRecordBytes,
            recordSize <= data.count - offset
        else { return nil }

        guard reader.readUInt32LE() != nil,
            let flags = reader.readUInt32LE(),
            reader.readUInt32LE() != nil,
            let rawDomainOffset = reader.readUInt32LE(),
            let rawNameOffset = reader.readUInt32LE(),
            let rawPathOffset = reader.readUInt32LE(),
            let rawValueOffset = reader.readUInt32LE(),
            reader.readUInt32LE() != nil,
            reader.readUInt32LE() != nil,
            let expiresReferenceDate = reader.readDoubleLE(),
            reader.readDoubleLE() != nil
        else { return nil }

        let limit = offset + recordSize
        guard
            let domain = readCString(
                data, base: offset, relativeOffset: Int(rawDomainOffset), limit: limit),
            let name = readCString(
                data, base: offset, relativeOffset: Int(rawNameOffset), limit: limit),
            let value = readCString(
                data, base: offset, relativeOffset: Int(rawValueOffset), limit: limit),
            request.matches(domain: domain), request.matches(name: name)
        else { return nil }
        let path =
            readCString(
                data, base: offset, relativeOffset: Int(rawPathOffset), limit: limit) ?? "/"
        let expires =
            expiresReferenceDate > 0
            ? Date(timeIntervalSinceReferenceDate: expiresReferenceDate)
            : nil
        guard expires.map({ $0 >= request.referenceDate }) ?? true else { return nil }

        return BrowserCookieRecord(
            domain: domain,
            name: name,
            path: path,
            value: value,
            expires: expires,
            isSecure: flags & 0x1 != 0,
            isHTTPOnly: flags & 0x4 != 0)
    }

    private static func readCString(
        _ data: Data, base: Int, relativeOffset: Int, limit: Int
    ) -> String? {
        guard base >= 0, base <= limit, limit <= data.count,
            relativeOffset >= 0, relativeOffset < limit - base
        else { return nil }
        let start = base + relativeOffset
        let end = data[start..<limit].firstIndex(of: 0) ?? limit
        guard end > start else { return nil }
        return String(data: data.subdata(in: start..<end), encoding: .utf8)
    }
}

private nonisolated struct BinaryCookieReader {
    private let data: Data
    private(set) var offset: Int

    init(data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    var remaining: Int { data.count - offset }

    mutating func readASCII(count: Int) -> String? {
        read(count: count).flatMap { String(data: $0, encoding: .ascii) }
    }

    mutating func readUInt32BE() -> UInt32? {
        read(count: MemoryLayout<UInt32>.size)?.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    mutating func readUInt32LE() -> UInt32? {
        read(count: MemoryLayout<UInt32>.size)?.enumerated().reduce(0) { value, element in
            value | UInt32(element.element) << UInt32(element.offset * 8)
        }
    }

    mutating func readDoubleLE() -> Double? {
        guard let bytes = read(count: MemoryLayout<UInt64>.size) else { return nil }
        let raw = bytes.enumerated().reduce(UInt64(0)) { value, element in
            value | UInt64(element.element) << UInt64(element.offset * 8)
        }
        return Double(bitPattern: raw)
    }

    private mutating func read(count: Int) -> Data? {
        guard count >= 0, offset >= 0, offset <= data.count,
            count <= data.count - offset
        else { return nil }
        let end = offset + count
        let result = data.subdata(in: offset..<end)
        offset = end
        return result
    }
}
