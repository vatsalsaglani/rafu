import Foundation

/// Words shown in card headers and bodies (review 7.1, 7.3). Pure so the
/// glossary stays testable: "Running", "Not running", "Exited (code)".
nonisolated enum CanvasCardPresentation {
    /// `exitCode` is the controller's reported code when the shell has quit.
    static func terminalState(status: TerminalPaneStatus, exitCode: Int32?) -> String {
        switch status {
        case .live, .idle: "Running"
        case .stopped: "Not running"
        case .unavailable: "Unavailable"
        case .exited:
            if let exitCode { "Exited (\(exitCode))" } else { "Exited" }
        }
    }

    /// A web card made from the default title shows `host:port`.
    static func displayTitle(title: String, content: CanvasCardContent) -> String {
        guard case .web(let destination) = content, title == destination.address,
            let url = destination.url, let host = url.host(percentEncoded: false)
        else { return title }
        let name = host.contains(":") ? "[\(host)]" : host
        if let port = url.port { return "\(name):\(port)" }
        return name
    }

    static func shellName(_ shell: TerminalPaneShellChoice) -> String {
        switch shell {
        case .preferredShell: "Default shell"
        case .approvedShellPath(let path): URL(fileURLWithPath: path).lastPathComponent
        }
    }

    static func folderName(_ relativePath: String) -> String {
        relativePath.isEmpty || relativePath == "." ? "Workspace folder" : relativePath
    }

    static func previewCaption(appName: String) -> String {
        "This is a picture of a \(appName) window. Keyboard and pointer input go to \(appName)."
    }

    /// One line for the 25-50% summary face.
    static func summaryLine(for content: CanvasCardContent, terminalTitle: String?) -> String {
        switch content {
        case .note(let text):
            let tasks = CanvasCardSummaryText.taskCount(in: text)
            let first = CanvasCardSummaryText.firstLine(of: text, limit: 60)
            if let tasks { return first.isEmpty ? "\(tasks) tasks" : "\(tasks) tasks · \(first)" }
            return first
        case .file(let path), .image(let path): URL(fileURLWithPath: path).lastPathComponent
        case .terminal: terminalTitle ?? ""
        case .web(let destination): displayTitle(title: destination.address, content: content)
        case .nativeApp(let bundleID): bundleID
        }
    }
}
