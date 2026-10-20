import Foundation
import RafuCore

/// Finding the Git repositories of a workspace and deciding which ones a
/// file-system change touches. Pure or off the main actor; no Git process.
nonisolated enum WorkspaceGitRepositories {
    /// Source Control lists at most this many repositories.
    static let maximumRepositories = 16

    /// One workspace root as discovery sees it.
    struct RootInput: Sendable {
        let id: UUID
        let url: URL
        let label: String
    }

    /// Each root that is inside a Git work tree, followed by the direct
    /// child folders of the root that hold a `.git` entry (nested
    /// repositories), in root order and then by name. One directory listing
    /// per root; deeper nesting is not searched. At most
    /// `maximumRepositories`.
    @concurrent
    static func discover(_ roots: [RootInput]) async -> [GitRepositoryRef] {
        let fileManager = FileManager.default
        var result: [GitRepositoryRef] = []
        var seen: Set<String> = []
        func append(_ ref: GitRepositoryRef) {
            guard result.count < maximumRepositories, seen.insert(ref.id).inserted else { return }
            result.append(ref)
        }
        for root in roots {
            guard !Task.isCancelled else { return [] }
            if WorkspaceRootList.isInsideGitWorkTree(
                path: root.url.path, fileExists: { fileManager.fileExists(atPath: $0) })
            {
                append(GitRepositoryRef(rootID: root.id, url: root.url, displayName: root.label))
            }
            let children =
                (try? fileManager.contentsOfDirectory(
                    at: root.url, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles])) ?? []
            let names =
                children
                .filter { child in
                    !WorkspaceFileService.excludedDirectories.contains(child.lastPathComponent)
                        && (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
                            == true
                        && fileManager.fileExists(atPath: child.appending(path: ".git").path)
                }
                .map(\.lastPathComponent)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            for name in names {
                append(
                    GitRepositoryRef(
                        rootID: root.id,
                        url: root.url.appending(path: name, directoryHint: .isDirectory),
                        displayName: name, relativePath: name))
            }
        }
        return result
    }

    /// The repository whose folder is the longest prefix of `path` (a
    /// standardized absolute path), or nil.
    static func repository(
        containing path: String, in repositories: [GitRepositoryRef]
    ) -> GitRepositoryRef? {
        var best: GitRepositoryRef?
        for repository in repositories
        where path == repository.id || path.hasPrefix(repository.id + "/") {
            if repository.id.count > best?.id.count ?? -1 { best = repository }
        }
        return best
    }

    /// Which repositories one root's change batch touches. `repositories`
    /// are the repositories of that root. `state` holds those whose branch,
    /// stage, or refs changed; `tree` holds those whose working tree
    /// changed. A storm has no directory list, so it touches the working
    /// tree of every repository of the root.
    static func impact(
        of changes: WorkspaceChangeSet, repositories: [GitRepositoryRef]
    ) -> (state: Set<String>, tree: Set<String>) {
        var state: Set<String> = []
        var tree: Set<String> = []
        for repository in repositories {
            if repository.isNested {
                let folder = repository.relativePath
                if changes.nestedGitChangedDirectories.contains(folder) {
                    state.insert(repository.id)
                } else if changes.isStorm
                    || changes.changedDirectoryRelativePaths.contains(where: {
                        $0 == folder || $0.hasPrefix(folder + "/")
                    })
                {
                    tree.insert(repository.id)
                }
            } else if changes.gitChanged {
                state.insert(repository.id)
            } else if changes.treeChanged || changes.isStorm {
                tree.insert(repository.id)
            }
        }
        return (state, tree)
    }
}
