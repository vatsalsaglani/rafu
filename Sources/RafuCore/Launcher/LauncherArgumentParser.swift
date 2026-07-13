import Foundation

public enum LauncherArgumentError: Error, Equatable, LocalizedError, Sendable {
    case conflictingWindowPolicies
    case invalidSourceLocation(String)
    case missingValue(String)
    case unexpectedArgument(String)
    case unknownOption(String)

    public var errorDescription: String? {
        switch self {
        case .conflictingWindowPolicies:
            "--new-window and --reuse-window cannot be used together."
        case .invalidSourceLocation(let value):
            "Invalid source location '\(value)'. Expected path:line or path:line:column."
        case .missingValue(let option):
            "Missing value for \(option)."
        case .unexpectedArgument(let argument):
            "Unexpected argument '\(argument)'."
        case .unknownOption(let option):
            "Unknown option '\(option)'."
        }
    }
}

public struct LauncherArgumentParser: Sendable {
    public init() {}

    public func parse(_ arguments: [String]) throws -> LauncherInvocation {
        guard !arguments.isEmpty else {
            return .help
        }

        if arguments.count == 1 {
            switch arguments[0] {
            case "--help", "-h":
                return .help
            case "--version", "-V":
                return .version
            case "--status":
                return .status
            case "--list-ssh-hosts":
                return .listSSHHosts
            default:
                break
            }
        }

        var activationPolicy = LauncherActivationPolicy.automatic
        var hostAlias: String?
        var path: String?
        var sourceLocation: SourceLocation?
        var waitsForClose = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]

            switch argument {
            case "--new-window":
                guard activationPolicy != .reuseWindow else {
                    throw LauncherArgumentError.conflictingWindowPolicies
                }
                activationPolicy = .newWindow

            case "--reuse-window":
                guard activationPolicy != .newWindow else {
                    throw LauncherArgumentError.conflictingWindowPolicies
                }
                activationPolicy = .reuseWindow

            case "--wait":
                waitsForClose = true

            case "--ssh":
                index += 1
                guard index < arguments.count,
                    !arguments[index].isEmpty,
                    !arguments[index].hasPrefix("-")
                else {
                    throw LauncherArgumentError.missingValue("--ssh")
                }
                hostAlias = arguments[index]

            case "--goto":
                index += 1
                guard index < arguments.count,
                    !arguments[index].isEmpty,
                    !arguments[index].hasPrefix("-")
                else {
                    throw LauncherArgumentError.missingValue("--goto")
                }
                guard path == nil else {
                    throw LauncherArgumentError.unexpectedArgument(arguments[index])
                }

                let parsed = try parseSourceLocation(arguments[index])
                path = parsed.path
                sourceLocation = parsed.location

            case "--help", "-h", "--version", "-V", "--status", "--list-ssh-hosts":
                throw LauncherArgumentError.unexpectedArgument(argument)

            default:
                if argument.hasPrefix("-") {
                    throw LauncherArgumentError.unknownOption(argument)
                }
                guard path == nil else {
                    throw LauncherArgumentError.unexpectedArgument(argument)
                }
                path = argument
            }

            index += 1
        }

        let requestedPath = path ?? "."
        let target: LauncherTarget

        if let hostAlias {
            target = .ssh(hostAlias: hostAlias, path: requestedPath)
        } else {
            target = .local(path: requestedPath)
        }

        return .open(
            LauncherOpenRequest(
                target: target,
                sourceLocation: sourceLocation,
                activationPolicy: activationPolicy,
                wait: waitsForClose
            )
        )
    }

    private func parseSourceLocation(_ value: String) throws -> (
        path: String, location: SourceLocation
    ) {
        let components = value.split(separator: ":", omittingEmptySubsequences: false)

        if components.count >= 3,
            let line = Int(components[components.count - 2]),
            let column = Int(components[components.count - 1])
        {
            let path = components.dropLast(2).joined(separator: ":")
            guard !path.isEmpty, line > 0, column > 0 else {
                throw LauncherArgumentError.invalidSourceLocation(value)
            }
            return (path, SourceLocation(line: line, column: column))
        }

        if components.count >= 2,
            let line = Int(components[components.count - 1])
        {
            let path = components.dropLast().joined(separator: ":")
            guard !path.isEmpty, line > 0 else {
                throw LauncherArgumentError.invalidSourceLocation(value)
            }
            return (path, SourceLocation(line: line))
        }

        throw LauncherArgumentError.invalidSourceLocation(value)
    }
}
