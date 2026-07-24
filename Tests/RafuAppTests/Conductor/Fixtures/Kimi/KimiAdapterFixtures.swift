/// Upstream-documented Kimi CLI 1.49.0 shape captured on 2026-07-24.
/// This is deliberately NOT described as a local transcript: no `kimi`
/// executable was installed in the implementation environment.
nonisolated enum KimiAdapterFixtures {
    static let documentedVersion = "1.49.0\n"

    static let documentedHelp = """
        DOCUMENTED-UPSTREAM-NOT-RECORDED-LOCALLY
        Usage: kimi [OPTIONS]
          --version
          --help
          --print
          -p, --prompt <prompt>
          -m, --model <model>
          --output-format <format>
          --plan
          --yolo
        """

    static func named(_ name: String) -> String? {
        switch name {
        case "documented-version-1.49.0.txt": documentedVersion
        case "documented-help-1.49.0.txt": documentedHelp
        default: nil
        }
    }
}
