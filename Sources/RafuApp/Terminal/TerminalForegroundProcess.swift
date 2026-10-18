import Foundation
import Darwin

// Which program runs in the foreground of a terminal? This answers "is an
// agent CLI running here?" for a shell where the person typed `claude` or
// `codex` themselves. The terminal title alone cannot: the shell sets it to
// the command, then the agent overwrites it with its own text or clears it.
//
// The answer comes from the PTY's foreground process group (`tcgetpgrp` on
// the primary side SwiftTerm holds, the same call tmux uses on macOS) and
// that group leader's name, executable path, and first arguments. The
// controller samples it only while the terminal runs, and only on a title
// change, an output burst, or a slow tick while a program other than the
// shell is in the foreground. Nothing here logs a name, a path, or argv.

/// One foreground process, reduced to what identification needs. The values
/// stay in memory for one classification and are never stored or logged.
nonisolated struct TerminalProcessDescription: Equatable, Sendable {
    /// The kernel's process name (`proc_name`), for example `node` or `claude`.
    var name: String
    /// The executable path (`proc_pidpath`), when readable.
    var executablePath: String?
    /// At most `TerminalForegroundClassifier.maximumArguments` leading argv
    /// entries, `argv[0]` first. Empty when argv is not readable.
    var arguments: [String]

    init(name: String, executablePath: String? = nil, arguments: [String] = []) {
        self.name = name
        self.executablePath = executablePath
        self.arguments = arguments
    }
}

/// What runs in a terminal's foreground, as far as agent identity cares.
nonisolated enum TerminalForegroundState: Equatable, Sendable {
    /// The terminal's own shell (or another interactive shell) waits for input.
    case shell
    /// A recognised agent CLI owns the terminal.
    case agent(ConductorCLIID)
    /// Some other program (an editor, a build, an unrecognised CLI).
    case other
}

/// The Darwin calls, behind a protocol so tests use a fake.
nonisolated protocol TerminalProcessInspecting: Sendable {
    /// The foreground process group of the PTY whose primary side is
    /// `descriptor`, or `nil` when the call fails. One `ioctl`; never blocks.
    func foregroundProcessGroup(ptyDescriptor descriptor: Int32) -> Int32?
    /// Name, path, and leading argv of `processID`, or `nil` when the
    /// process is gone or not readable. Can allocate a large argv buffer:
    /// call it off the main actor.
    func describe(processID: Int32) -> TerminalProcessDescription?
}

/// Pure mapping from a process description to a foreground state.
nonisolated enum TerminalForegroundClassifier {
    /// How many leading argv entries a description keeps.
    static let maximumArguments = 4

    /// Interactive shells. A shell with no script argument waits for input.
    static let shellNames: Set<String> = [
        "zsh", "bash", "fish", "sh", "dash", "ksh", "mksh", "tcsh", "csh", "nu", "elvish",
        "xonsh", "pwsh", "login",
    ]

    static func classify(_ description: TerminalProcessDescription?) -> TerminalForegroundState {
        guard let description else { return .other }
        if let cli = AgentIdentityMatcher.match(
            processName: description.name, executablePath: description.executablePath,
            arguments: description.arguments)
        {
            return .agent(cli)
        }
        let names = [description.name, description.executablePath.map(lastComponent)]
            .compactMap(\.self).map(AgentIdentityMatcher.normalizedProcessWord)
        let isShell = names.contains { shellNames.contains($0) }
        if isShell, AgentIdentityMatcher.firstOperand(in: description.arguments) == nil {
            return .shell
        }
        return .other
    }

    private static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

/// The one off-main-actor step of a sample.
nonisolated enum TerminalForegroundProbe {
    @concurrent
    static func classify(
        processID: Int32, inspector: any TerminalProcessInspecting
    ) async -> TerminalForegroundState {
        TerminalForegroundClassifier.classify(inspector.describe(processID: processID))
    }
}

/// When the controller samples the foreground process.
nonisolated enum TerminalForegroundSampling {
    /// A title change or an output burst samples after this delay, so one
    /// burst costs one sample and the shell's `preexec` title has time to
    /// become a running process.
    static let debounce: Duration = .milliseconds(600)
    /// The slow tick while a program other than the shell is in front.
    static let pollInterval: Duration = .seconds(3)
    /// A hidden terminal keeps the slow tick only this long after its last
    /// output.
    static let recentActivity: TimeInterval = 30

    /// Whether the slow tick continues after a sample.
    static func continuesPolling(
        after state: TerminalForegroundState, isVisible: Bool, secondsSinceOutput: TimeInterval?
    ) -> Bool {
        guard state != .shell else { return false }
        if isVisible { return true }
        guard let secondsSinceOutput else { return false }
        return secondsSinceOutput <= recentActivity
    }
}

/// The agent identity a terminal has observed by itself: the foreground
/// process (strong) and a sticky title match (fallback). A pure value, so the
/// rules have headless tests.
///
/// - A title that names an agent ("claude", "✳ Claude Code") is remembered.
///   A later title change does not clear it: agent CLIs replace their title
///   with a task name or clear it while they still run.
/// - The memory clears when the foreground returns to the shell, or when the
///   process exits (`reset()`).
/// - A known shell foreground also hides a stale title: when the agent has
///   exited, a title that still says "claude" no longer counts.
nonisolated struct TerminalAgentIdentityState: Equatable, Sendable {
    /// The last foreground sample; `nil` before the first one, or when the
    /// PTY cannot be inspected.
    private(set) var foreground: TerminalForegroundState?
    /// The agent the title last named, kept until the shell is in front again.
    private(set) var stickyTitleProvider: ConductorCLIID?

    init(foreground: TerminalForegroundState? = nil, stickyTitleProvider: ConductorCLIID? = nil) {
        self.foreground = foreground
        self.stickyTitleProvider = stickyTitleProvider
    }

    /// Records a title report. Only a title that names an agent changes state.
    mutating func noteTitle(_ title: String?) {
        guard let title, let cli = ConductorCLIID.detect(command: nil, title: title) else { return }
        stickyTitleProvider = cli
    }

    mutating func noteForeground(_ state: TerminalForegroundState) {
        foreground = state
        if state == .shell { stickyTitleProvider = nil }
    }

    mutating func reset() {
        foreground = nil
        stickyTitleProvider = nil
    }

    /// The observed agent, with `currentTitle` as the last fallback.
    func provider(currentTitle: String?) -> ConductorCLIID? {
        switch foreground {
        case .agent(let cli): return cli
        case .shell: return nil
        case .other, nil:
            return stickyTitleProvider
                ?? currentTitle.flatMap { ConductorCLIID.detect(command: nil, title: $0) }
        }
    }
}

/// Resolution order for a terminal's agent identity.
nonisolated enum TerminalAgentResolution {
    /// Rafu launched it → hook session → foreground process → sticky title →
    /// current title → `nil`. `observed` carries the last three.
    static func resolve(
        launched: ConductorCLIID?, hook: ConductorCLIID?,
        observed: TerminalAgentIdentityState, currentTitle: String?
    ) -> ConductorCLIID? {
        launched ?? hook ?? observed.provider(currentTitle: currentTitle)
    }
}

/// The production inspector. Reads only the foreground process group,
/// the process name and path, and the first few argv strings; the
/// environment block that follows argv is never parsed.
nonisolated struct DarwinTerminalProcessInspector: TerminalProcessInspecting {
    /// Upper bound for one argv read, whatever `kern.argmax` says.
    static let maximumArgumentBytes = 4 * 1024 * 1024

    func foregroundProcessGroup(ptyDescriptor descriptor: Int32) -> Int32? {
        guard descriptor >= 0 else { return nil }
        let group = tcgetpgrp(descriptor)
        return group > 0 ? Int32(group) : nil
    }

    func describe(processID: Int32) -> TerminalProcessDescription? {
        guard processID > 1 else { return nil }
        var nameBuffer = [CChar](repeating: 0, count: 256)
        let nameLength = proc_name(processID, &nameBuffer, UInt32(nameBuffer.count))
        guard nameLength > 0 else { return nil }
        let name = String(decoding: nameBuffer.prefix(Int(nameLength)).map(UInt8.init(bitPattern:)), as: UTF8.self)

        // PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN.
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(processID, &pathBuffer, UInt32(pathBuffer.count))
        let path =
            pathLength > 0
            ? String(
                decoding: pathBuffer.prefix(Int(pathLength)).map(UInt8.init(bitPattern:)),
                as: UTF8.self)
            : nil

        return TerminalProcessDescription(
            name: name, executablePath: path, arguments: Self.arguments(of: processID))
    }

    /// `KERN_PROCARGS2` is `argc` (Int32), the exec path, NUL padding,
    /// then `argc` NUL-terminated argv strings, then the environment.
    private static func arguments(of processID: Int32) -> [String] {
        var argumentMaximum: Int32 = 0
        var argumentMaximumSize = MemoryLayout<Int32>.size
        var argmaxMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard
            sysctl(&argmaxMIB, 2, &argumentMaximum, &argumentMaximumSize, nil, 0) == 0,
            argumentMaximum > 0
        else { return [] }
        var size = min(Int(argumentMaximum), maximumArgumentBytes)
        var buffer = [UInt8](repeating: 0, count: size)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, processID]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        return TerminalProcessArguments.parse(buffer.prefix(size))
    }
}

/// Bounded `KERN_PROCARGS2` parsing, separate so it has tests.
nonisolated enum TerminalProcessArguments {
    static func parse<Bytes: Collection>(
        _ bytes: Bytes, limit: Int = TerminalForegroundClassifier.maximumArguments
    ) -> [String] where Bytes.Element == UInt8, Bytes.Index == Int {
        let count = bytes.count
        guard count > 4, limit > 0 else { return [] }
        let start = bytes.startIndex
        var argc: Int32 = 0
        for offset in 0..<4 {
            argc |= Int32(bytes[start + offset]) << (8 * offset)
        }
        guard argc > 0 else { return [] }
        var index = start + 4
        let end = start + count
        // Skip the exec path, then the NUL padding after it.
        while index < end, bytes[index] != 0 { index += 1 }
        while index < end, bytes[index] == 0 { index += 1 }
        var result: [String] = []
        let wanted = min(Int(argc), limit)
        while index < end, result.count < wanted {
            let wordStart = index
            while index < end, bytes[index] != 0 { index += 1 }
            result.append(String(decoding: bytes[wordStart..<index], as: UTF8.self))
            index += 1
        }
        return result
    }
}
