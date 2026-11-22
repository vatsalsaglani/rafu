// Downloads pinned files with URLSession into a folder; prints bytes,
// seconds and SHA-256 for each file. Also used for the quarantine check
// (plan Answer 6). Throw-away spike code; see
// .rafu/plans/meeting-speech-spike.md.
import CryptoKit
import Foundation

struct FetchTarget {
    var url: URL
    var destination: URL
}

@main
struct SpikeFetch {
    static func main() async {
        // (url, relativeDestination): relativeDestination defaults to the
        // URL's last path component (flat layout) unless a `--dest` follows
        // its `--url`, which lets a caller lay out a multi-file bundle
        // (e.g. a compiled `.mlmodelc`, which has nested `analytics/` and
        // `weights/` subdirectories that would otherwise collide on the
        // shared name `coremldata.bin`).
        var targets: [(url: String, dest: String?)] = []
        var outputDirectory: String?

        var args = Array(CommandLine.arguments.dropFirst())
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--url":
                guard !args.isEmpty else { fail("--url needs a value") }
                targets.append((url: args.removeFirst(), dest: nil))
            case "--dest":
                guard !args.isEmpty else { fail("--dest needs a value") }
                guard !targets.isEmpty else { fail("--dest must follow a --url") }
                targets[targets.count - 1].dest = args.removeFirst()
            case "--out-dir":
                guard !args.isEmpty else { fail("--out-dir needs a value") }
                outputDirectory = args.removeFirst()
            default:
                fail("unknown argument \(arg)")
            }
        }

        guard let outputDirectory, !targets.isEmpty else {
            fail(
                "usage: spike-fetch --url <https://...> [--dest <relative/path>] "
                    + "[--url <https://...> [--dest <relative/path>] ...] --out-dir <path>"
            )
        }

        let outputURL = URL(fileURLWithPath: outputDirectory)
        try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        var results: [[String: Any]] = []
        for target in targets {
            let urlString = target.url
            guard let url = URL(string: urlString) else {
                print("skip: not a URL: \(urlString)")
                continue
            }
            let destination = outputURL.appendingPathComponent(target.dest ?? url.lastPathComponent)
            try? FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let clock = ContinuousClock.now
            do {
                let (tempURL, response) = try await URLSession.shared.download(from: url)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: tempURL, to: destination)
                let elapsed = ContinuousClock.now - clock
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
                let bytes = (attributes?[.size] as? Int) ?? 0
                let sha256 = try sha256Hex(of: destination)
                let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
                results.append([
                    "url": urlString, "destination": destination.path,
                    "bytes": bytes, "seconds": seconds, "sha256": sha256, "httpStatus": httpStatus,
                ])
                print("fetched \(url.lastPathComponent): \(bytes) bytes in \(String(format: "%.2f", seconds))s sha256=\(sha256)")
            } catch {
                print("failed: \(urlString): \(error)")
                results.append(["url": urlString, "error": "\(error)"])
            }
        }

        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    static func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write("spike-fetch: \(message)\n".data(using: .utf8)!)
        exit(1)
    }
}
