public enum EnsembleExitCode: Int32, Codable, Hashable, Sendable {
    case ok = 0
    case usage = 64
    case dataError = 65
    case unavailable = 69
    case tempFail = 75
    case noPermission = 77

    public var meaning: String {
        switch self {
        case .ok: "success"
        case .usage: "invalid command usage"
        case .dataError: "invalid or missing Ensemble data"
        case .unavailable: "Rafu is unavailable"
        case .tempFail: "temporary failure or timeout"
        case .noPermission: "operation is not permitted"
        }
    }
}
