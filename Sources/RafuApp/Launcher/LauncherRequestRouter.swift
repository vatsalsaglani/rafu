import AppKit
import Foundation
import RafuCore

nonisolated struct OpenWorkspaceRoot: Equatable, Sendable {
    let windowID: UUID
    let rootURL: URL?
}

nonisolated enum RoutingDecision: Equatable, Sendable {
    case focus(windowID: UUID)
    case seedNewWindow(url: URL)
    case focusAndGoto(windowID: UUID, file: String, location: SourceLocation)
}

/// Pure request-to-window selection. `openRoots` is ordered key-window first,
/// then by registration order, so reuse behavior is deterministic.
nonisolated enum LauncherRequestRouting {
    static func route(
        request: LauncherOpenRequest,
        openRoots: [OpenWorkspaceRoot]
    ) -> RoutingDecision? {
        guard case .local(let rawPath) = request.target, rawPath.hasPrefix("/") else {
            return nil
        }

        let targetURL = normalizedURL(rawPath)
        let match = matchingRoot(
            for: targetURL, isGoto: request.sourceLocation != nil, in: openRoots)
        let workspaceURL: URL
        let gotoRelativePath: String?
        if request.sourceLocation != nil {
            workspaceURL = match?.rootURL ?? targetURL.deletingLastPathComponent()
            gotoRelativePath = relativePath(of: targetURL, in: workspaceURL)
        } else {
            workspaceURL = targetURL
            gotoRelativePath = nil
        }

        if request.activationPolicy == .newWindow {
            return .seedNewWindow(url: workspaceURL)
        }

        if let match {
            if let location = request.sourceLocation, let gotoRelativePath {
                return .focusAndGoto(
                    windowID: match.windowID,
                    file: gotoRelativePath,
                    location: location
                )
            }
            return .focus(windowID: match.windowID)
        }

        if let reusable = openRoots.first {
            return .focus(windowID: reusable.windowID)
        }
        return .seedNewWindow(url: workspaceURL)
    }

    static func workspaceURL(
        for request: LauncherOpenRequest,
        openRoots: [OpenWorkspaceRoot]
    ) -> URL? {
        guard case .local(let rawPath) = request.target, rawPath.hasPrefix("/") else {
            return nil
        }
        let targetURL = normalizedURL(rawPath)
        guard request.sourceLocation != nil else { return targetURL }
        return matchingRoot(for: targetURL, isGoto: true, in: openRoots)?.rootURL
            ?? targetURL.deletingLastPathComponent()
    }

    static func relativeGotoPath(
        for request: LauncherOpenRequest,
        workspaceURL: URL
    ) -> String? {
        guard case .local(let rawPath) = request.target else { return nil }
        return relativePath(of: normalizedURL(rawPath), in: workspaceURL)
    }

    static func workspaceMatched(
        request: LauncherOpenRequest,
        openRoots: [OpenWorkspaceRoot]
    ) -> Bool {
        guard case .local(let rawPath) = request.target else { return false }
        return matchingRoot(
            for: normalizedURL(rawPath),
            isGoto: request.sourceLocation != nil,
            in: openRoots
        ) != nil
    }

    private static func matchingRoot(
        for targetURL: URL,
        isGoto: Bool,
        in openRoots: [OpenWorkspaceRoot]
    ) -> OpenWorkspaceRoot? {
        let targetPath = targetURL.path
        return
            openRoots
            .enumerated()
            .compactMap { index, root -> (Int, OpenWorkspaceRoot, Int)? in
                guard let rootURL = root.rootURL else { return nil }
                let rootPath = normalizedURL(rootURL.path).path
                let matches =
                    isGoto
                    ? targetPath == rootPath
                        || targetPath.hasPrefix(rootPathWithSeparator(rootPath))
                    : targetPath == rootPath
                return matches ? (index, root, rootPath.count) : nil
            }
            .sorted { lhs, rhs in
                lhs.2 == rhs.2 ? lhs.0 < rhs.0 : lhs.2 > rhs.2
            }
            .first?.1
    }

    private static func relativePath(of fileURL: URL, in rootURL: URL) -> String? {
        let filePath = fileURL.path
        let rootPath = normalizedURL(rootURL.path).path
        guard filePath != rootPath, filePath.hasPrefix(rootPathWithSeparator(rootPath)) else {
            return nil
        }
        return String(filePath.dropFirst(rootPathWithSeparator(rootPath).count))
    }

    private static func normalizedURL(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func rootPathWithSeparator(_ path: String) -> String {
        path == "/" ? "/" : path + "/"
    }
}

/// MainActor bridge from pure routing decisions to SwiftUI/AppKit lifecycle
/// effects. Tests inject every effect, keeping the matrix headless.
@MainActor
final class LauncherRequestRouter {
    static let shared = LauncherRequestRouter()

    struct Dependencies {
        var snapshots: () -> [OpenWorkspaceRoot]
        var focus: (UUID) -> Bool
        var enqueueFolder: (URL) -> Void
        var openWindow: () -> Bool
        var goto: (UUID, String, SourceLocation) -> Bool
        var queueGoto: (UUID, URL, String, SourceLocation) -> Void
        var queueGotoForNextWindow: (URL, String, SourceLocation) -> Void
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    func handle(_ envelope: LauncherIPCEnvelope) -> LauncherIPCResponse {
        if envelope.kind == .handshake {
            return .accepted(
                workspaceMatched: false,
                windowFocused: false,
                waitSupported: false
            )
        }
        guard
            envelope.kind == .openFolder || envelope.kind == .goto,
            let request = envelope.payload,
            case .local = request.target,
            (envelope.kind == .goto) == (request.sourceLocation != nil)
        else {
            return .rejected(reason: "invalid request payload")
        }

        let roots = dependencies.snapshots()
        guard
            let decision = LauncherRequestRouting.route(request: request, openRoots: roots),
            let workspaceURL = LauncherRequestRouting.workspaceURL(
                for: request,
                openRoots: roots
            )
        else {
            return .rejected(reason: "unsupported target")
        }
        let workspaceMatched = LauncherRequestRouting.workspaceMatched(
            request: request,
            openRoots: roots
        )

        switch decision {
        case .focus(let windowID):
            guard dependencies.focus(windowID) else {
                return seedFallback(
                    request: request,
                    workspaceURL: workspaceURL,
                    workspaceMatched: false
                )
            }
            if !workspaceMatched {
                queueGotoIfNeeded(
                    request: request,
                    workspaceURL: workspaceURL,
                    targetWindowID: windowID
                )
                dependencies.enqueueFolder(workspaceURL)
            }
            return .accepted(
                workspaceMatched: workspaceMatched,
                windowFocused: true,
                waitSupported: false
            )

        case .focusAndGoto(let windowID, let file, let location):
            guard dependencies.goto(windowID, file, location) else {
                return seedFallback(
                    request: request,
                    workspaceURL: workspaceURL,
                    workspaceMatched: false
                )
            }
            return .accepted(
                workspaceMatched: true,
                windowFocused: true,
                waitSupported: false
            )

        case .seedNewWindow:
            return seedFallback(
                request: request,
                workspaceURL: workspaceURL,
                workspaceMatched: workspaceMatched
            )
        }
    }

    private func seedFallback(
        request: LauncherOpenRequest,
        workspaceURL: URL,
        workspaceMatched: Bool
    ) -> LauncherIPCResponse {
        queueGotoIfNeeded(request: request, workspaceURL: workspaceURL, targetWindowID: nil)
        dependencies.enqueueFolder(workspaceURL)
        guard dependencies.openWindow() else {
            return .rejected(reason: "workspace window unavailable")
        }
        return .accepted(
            workspaceMatched: workspaceMatched,
            windowFocused: false,
            waitSupported: false
        )
    }

    private func queueGotoIfNeeded(
        request: LauncherOpenRequest,
        workspaceURL: URL,
        targetWindowID: UUID?
    ) {
        guard
            let location = request.sourceLocation,
            let relativePath = LauncherRequestRouting.relativeGotoPath(
                for: request,
                workspaceURL: workspaceURL
            )
        else { return }
        if let targetWindowID {
            dependencies.queueGoto(targetWindowID, workspaceURL, relativePath, location)
        } else {
            dependencies.queueGotoForNextWindow(workspaceURL, relativePath, location)
        }
    }
}

extension LauncherRequestRouter.Dependencies {
    fileprivate static var live: Self {
        Self(
            snapshots: { WorkspaceWindowRegistry.shared.snapshots() },
            focus: { WorkspaceWindowRegistry.shared.focus(windowID: $0) },
            enqueueFolder: { ExternalOpenRequests.shared.enqueue([$0]) },
            openWindow: { WorkspaceWindowRegistry.shared.openWorkspaceWindow() },
            goto: {
                WorkspaceWindowRegistry.shared.goto(windowID: $0, relativePath: $1, location: $2)
            },
            queueGoto: {
                WorkspaceWindowRegistry.shared.queueGoto(
                    windowID: $0,
                    workspaceRoot: $1,
                    relativePath: $2,
                    location: $3
                )
            },
            queueGotoForNextWindow: {
                WorkspaceWindowRegistry.shared.queueGotoForNextWindow(
                    workspaceRoot: $0,
                    relativePath: $1,
                    location: $2
                )
            }
        )
    }
}
