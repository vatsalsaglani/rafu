import Foundation

/// Parses `git diff --numstat -z` output into per-path line-change counts.
///
/// With `-z`, each ordinary record is a single NUL-terminated field shaped
/// `<added>\t<deleted>\t<path>`. Binary files report `-\t-\t<path>`. Renames
/// split across three NUL-terminated fields: `<added>\t<deleted>\t` (empty
/// path, since the "old => new" text form is unavailable in `-z` mode),
/// followed by the old path and then the new path as their own records. The
/// new path is what the parser keys results by, matching `GitChange.path`.
nonisolated enum GitNumstatParser {
    static func parse(_ data: Data) -> [String: GitLineStats] {
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
        var result: [String: GitLineStats] = [:]
        var index = 0
        while index < records.count {
            let record = String(decoding: records[index], as: UTF8.self)
            let fields = record.split(
                separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else {
                index += 1
                continue
            }
            let stats = lineStats(added: fields[0], deleted: fields[1])
            if fields[2].isEmpty {
                // Rename record: the next two NUL-delimited records are the
                // old and new paths. Attribute counts to the new path.
                guard records.indices.contains(index + 2) else { break }
                let newPath = String(decoding: records[index + 2], as: UTF8.self)
                if !newPath.isEmpty {
                    result[newPath] = GitLineStats.merge(result[newPath], stats)
                }
                index += 3
            } else {
                let path = String(fields[2])
                result[path] = GitLineStats.merge(result[path], stats)
                index += 1
            }
        }
        return result
    }

    private static func lineStats(added: Substring, deleted: Substring) -> GitLineStats {
        guard added != "-", deleted != "-",
            let addedCount = Int(added), let deletedCount = Int(deleted)
        else {
            return GitLineStats(isBinary: true)
        }
        return GitLineStats(added: addedCount, deleted: deletedCount)
    }
}
