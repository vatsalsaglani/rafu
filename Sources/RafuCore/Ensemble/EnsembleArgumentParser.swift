import Foundation

public enum EnsembleArgumentError: Error, Equatable, LocalizedError, Sendable {
    case duplicateOption(String)
    case invalidValue(option: String, value: String)
    case missingArgument(String)
    case missingValue(String)
    case unexpectedArgument(String)
    case unknownOption(String)
    case unknownState(String)
    case unknownVerb(String)
    case valueTooLong(option: String, maximumCharacters: Int)

    public var errorDescription: String? {
        switch self {
        case .duplicateOption(let option):
            "Option \(option) may only be specified once."
        case .invalidValue(let option, let value):
            "Invalid value '\(value)' for \(option)."
        case .missingArgument(let argument):
            "Missing required argument \(argument)."
        case .missingValue(let option):
            "Missing value for \(option)."
        case .unexpectedArgument(let argument):
            "Unexpected argument '\(argument)'."
        case .unknownOption(let option):
            "Unknown option '\(option)'."
        case .unknownState(let state):
            "Unknown Ensemble state '\(state)'."
        case .unknownVerb(let verb):
            "Unknown Ensemble verb '\(verb)'."
        case .valueTooLong(let option, let maximumCharacters):
            "\(option) must be at most \(maximumCharacters) characters."
        }
    }
}

public enum EnsembleInvocation: Hashable, Sendable {
    case run(
        workflow: String,
        roleOverrides: [EnsembleRoleOverride],
        prompt: String?,
        artifacts: [String],
        baseReference: String?,
        label: String?,
        json: Bool
    )
    case status(runIDs: [String], tree: Bool, sinceCursor: UInt64?, json: Bool)
    case artifact(runID: String, stepIndex: Int, json: Bool)
    case await(
        runIDs: [String],
        states: [EnsembleRunState],
        any: Bool,
        timeout: TimeInterval?,
        json: Bool
    )
    case abort(runID: String)
    case note(runID: String, text: String)
    case grant(json: Bool)
    case help
}

public enum EnsembleSubcommandGateDecision: Equatable, Sendable {
    case subcommand
    case collision
    case path
}

public enum EnsembleSubcommandGate {
    public static func classify(
        firstArgument: String?,
        hasFilesystemEntry: Bool
    ) -> EnsembleSubcommandGateDecision {
        guard firstArgument == "ensemble" else { return .path }
        return hasFilesystemEntry ? .collision : .subcommand
    }
}

public struct EnsembleArgumentParser: Sendable {
    public init() {}

    public func parse(_ arguments: [String]) throws -> EnsembleInvocation {
        guard let verb = arguments.first else { return .help }
        let remainder = Array(arguments.dropFirst())
        switch verb {
        case "help", "--help", "-h":
            guard remainder.isEmpty else {
                throw EnsembleArgumentError.unexpectedArgument(remainder[0])
            }
            return .help
        case "status":
            return try parseStatus(remainder)
        case "run":
            return try parseRun(remainder)
        case "artifact":
            return try parseArtifact(remainder)
        case "await":
            return try parseAwait(remainder)
        case "abort":
            return try parseAbort(remainder)
        case "note":
            return try parseNote(remainder)
        case "grant":
            return try parseGrant(remainder)
        default:
            throw EnsembleArgumentError.unknownVerb(verb)
        }
    }

    private func parseRun(_ arguments: [String]) throws -> EnsembleInvocation {
        var workflow: String?
        var roleOverrides: [EnsembleRoleOverride] = []
        var prompt: String?
        var artifacts: [String] = []
        var baseReference: String?
        var label: String?
        var json = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--role":
                let raw = try value(after: argument, in: arguments, index: &index)
                roleOverrides.append(try parseRoleOverride(raw))
            case "--prompt":
                guard prompt == nil else {
                    throw EnsembleArgumentError.duplicateOption(argument)
                }
                prompt = try value(after: argument, in: arguments, index: &index)
            case "--artifact":
                artifacts.append(try value(after: argument, in: arguments, index: &index))
            case "--base":
                guard baseReference == nil else {
                    throw EnsembleArgumentError.duplicateOption(argument)
                }
                baseReference = try value(after: argument, in: arguments, index: &index)
            case "--label":
                guard label == nil else {
                    throw EnsembleArgumentError.duplicateOption(argument)
                }
                label = try value(after: argument, in: arguments, index: &index)
            case "--json":
                guard !json else { throw EnsembleArgumentError.duplicateOption(argument) }
                json = true
            default:
                if argument.hasPrefix("-") {
                    throw EnsembleArgumentError.unknownOption(argument)
                }
                guard workflow == nil else {
                    throw EnsembleArgumentError.unexpectedArgument(argument)
                }
                workflow = argument
            }
            index += 1
        }

        guard let workflow else {
            throw EnsembleArgumentError.missingArgument("<workflow>")
        }
        let names = roleOverrides.map(\.name)
        guard Set(names).count == names.count else {
            throw EnsembleArgumentError.invalidValue(option: "--role", value: "duplicate name")
        }
        return .run(
            workflow: workflow,
            roleOverrides: roleOverrides,
            prompt: prompt,
            artifacts: artifacts,
            baseReference: baseReference,
            label: label,
            json: json
        )
    }

    private func parseStatus(_ arguments: [String]) throws -> EnsembleInvocation {
        var runIDs: [String] = []
        var tree = false
        var sinceCursor: UInt64?
        var json = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--tree":
                guard !tree else { throw EnsembleArgumentError.duplicateOption(argument) }
                tree = true
            case "--json":
                guard !json else { throw EnsembleArgumentError.duplicateOption(argument) }
                json = true
            case "--since":
                guard sinceCursor == nil else {
                    throw EnsembleArgumentError.duplicateOption(argument)
                }
                let value = try value(after: argument, in: arguments, index: &index)
                guard let cursor = UInt64(value) else {
                    throw EnsembleArgumentError.invalidValue(option: argument, value: value)
                }
                sinceCursor = cursor
            default:
                if argument.hasPrefix("-") {
                    throw EnsembleArgumentError.unknownOption(argument)
                }
                runIDs.append(argument)
            }
            index += 1
        }

        return .status(runIDs: runIDs, tree: tree, sinceCursor: sinceCursor, json: json)
    }

    private func parseArtifact(_ arguments: [String]) throws -> EnsembleInvocation {
        var positionals: [String] = []
        var json = false
        for argument in arguments {
            switch argument {
            case "--json":
                guard !json else { throw EnsembleArgumentError.duplicateOption(argument) }
                json = true
            default:
                if argument.hasPrefix("-"), !(positionals.count == 1 && Int(argument) != nil) {
                    throw EnsembleArgumentError.unknownOption(argument)
                }
                positionals.append(argument)
            }
        }
        guard !positionals.isEmpty else {
            throw EnsembleArgumentError.missingArgument("<run>")
        }
        guard positionals.count >= 2 else {
            throw EnsembleArgumentError.missingArgument("<step>")
        }
        guard positionals.count == 2 else {
            throw EnsembleArgumentError.unexpectedArgument(positionals[2])
        }
        guard let stepIndex = Int(positionals[1]), stepIndex >= 0 else {
            throw EnsembleArgumentError.invalidValue(option: "<step>", value: positionals[1])
        }
        return .artifact(runID: positionals[0], stepIndex: stepIndex, json: json)
    }

    private func parseAwait(_ arguments: [String]) throws -> EnsembleInvocation {
        var runIDs: [String] = []
        var states: [EnsembleRunState] = []
        var any = false
        var timeout: TimeInterval?
        var json = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--state":
                let raw = try value(after: argument, in: arguments, index: &index)
                guard let state = EnsembleRunState(rawValue: raw) else {
                    throw EnsembleArgumentError.unknownState(raw)
                }
                states.append(state)
            case "--any":
                guard !any else { throw EnsembleArgumentError.duplicateOption(argument) }
                any = true
            case "--timeout":
                guard timeout == nil else {
                    throw EnsembleArgumentError.duplicateOption(argument)
                }
                let raw = try value(after: argument, in: arguments, index: &index)
                guard let seconds = TimeInterval(raw), seconds.isFinite, seconds > 0 else {
                    throw EnsembleArgumentError.invalidValue(option: argument, value: raw)
                }
                timeout = seconds
            case "--json":
                guard !json else { throw EnsembleArgumentError.duplicateOption(argument) }
                json = true
            default:
                if argument.hasPrefix("-") {
                    throw EnsembleArgumentError.unknownOption(argument)
                }
                runIDs.append(argument)
            }
            index += 1
        }

        guard !runIDs.isEmpty else {
            throw EnsembleArgumentError.missingArgument("<run>")
        }
        guard !states.isEmpty else {
            throw EnsembleArgumentError.missingValue("--state")
        }
        return .await(runIDs: runIDs, states: states, any: any, timeout: timeout, json: json)
    }

    private func parseAbort(_ arguments: [String]) throws -> EnsembleInvocation {
        guard let runID = arguments.first else {
            throw EnsembleArgumentError.missingArgument("<run>")
        }
        guard arguments.count == 1 else {
            throw EnsembleArgumentError.unexpectedArgument(arguments[1])
        }
        return .abort(runID: runID)
    }

    private func parseNote(_ arguments: [String]) throws -> EnsembleInvocation {
        guard let runID = arguments.first else {
            throw EnsembleArgumentError.missingArgument("<run>")
        }
        guard arguments.count >= 2 else {
            throw EnsembleArgumentError.missingArgument("<text>")
        }
        guard arguments.count == 2 else {
            throw EnsembleArgumentError.unexpectedArgument(arguments[2])
        }
        let text = arguments[1]
        guard text.count <= 1_000 else {
            throw EnsembleArgumentError.valueTooLong(
                option: "<text>",
                maximumCharacters: 1_000
            )
        }
        return .note(runID: runID, text: text)
    }

    private func parseGrant(_ arguments: [String]) throws -> EnsembleInvocation {
        switch arguments {
        case []:
            return .grant(json: false)
        case ["--json"]:
            return .grant(json: true)
        default:
            let argument = arguments[0]
            if argument == "--json" {
                throw EnsembleArgumentError.duplicateOption(argument)
            }
            if argument.hasPrefix("-") {
                throw EnsembleArgumentError.unknownOption(argument)
            }
            throw EnsembleArgumentError.unexpectedArgument(argument)
        }
    }

    private func parseRoleOverride(_ raw: String) throws -> EnsembleRoleOverride {
        guard let equals = raw.firstIndex(of: "=") else {
            throw EnsembleArgumentError.invalidValue(option: "--role", value: raw)
        }
        let name = String(raw[..<equals])
        let providerAndModel = String(raw[raw.index(after: equals)...])
        let pieces = providerAndModel.split(
            separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard !name.isEmpty, let providerPiece = pieces.first, !providerPiece.isEmpty else {
            throw EnsembleArgumentError.invalidValue(option: "--role", value: raw)
        }
        let model =
            pieces.count == 2 && !pieces[1].isEmpty
            ? String(pieces[1])
            : nil
        if pieces.count == 2, model == nil {
            throw EnsembleArgumentError.invalidValue(option: "--role", value: raw)
        }
        return EnsembleRoleOverride(
            name: name,
            provider: String(providerPiece),
            model: model
        )
    }

    private func value(
        after option: String,
        in arguments: [String],
        index: inout Int
    ) throws -> String {
        index += 1
        guard index < arguments.count,
            !arguments[index].isEmpty,
            !arguments[index].hasPrefix("-")
        else {
            throw EnsembleArgumentError.missingValue(option)
        }
        return arguments[index]
    }
}
