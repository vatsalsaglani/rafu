import Foundation
import Testing

@testable import RafuApp

@Suite("Terminal shell picker presentation")
struct TerminalShellPickerPresentationTests {
    @Test("Opening starts on the default shell without producing an action")
    func deterministicDefaultFocusHasNoEffect() {
        let shells = Self.shells()
        let state = TerminalShellPickerState(shells: shells)

        #expect(state.shells == shells)
        #expect(state.focusedShellID == "/opt/homebrew/bin/fish")
    }

    @Test("Arrow and boundary navigation clamp in stable input order and never select")
    func keyboardNavigationDoesNotSelect() {
        var state = TerminalShellPickerState(shells: Self.shells())

        #expect(state.handle(.previous) == .none)
        #expect(state.focusedShellID == "/bin/zsh")
        #expect(state.handle(.previous) == .none)
        #expect(state.focusedShellID == "/bin/zsh")
        #expect(state.handle(.last) == .none)
        #expect(state.focusedShellID == "/usr/local/bin/nu")
        #expect(state.handle(.next) == .none)
        #expect(state.focusedShellID == "/usr/local/bin/nu")
        #expect(state.handle(.first) == .none)
        #expect(state.focusedShellID == "/bin/zsh")
        #expect(state.handle(.next) == .none)
        #expect(state.focusedShellID == "/opt/homebrew/bin/fish")
    }

    @Test("Return selects the exact focused shell once and Escape only cancels")
    func activationAndCancelEffectsAreExplicit() throws {
        var state = TerminalShellPickerState(shells: Self.shells())
        var selected: [TerminalShell] = []
        var cancelCount = 0

        dispatch(state.handle(.next), selected: &selected, cancelCount: &cancelCount)
        #expect(selected.isEmpty)
        #expect(cancelCount == 0)

        dispatch(state.handle(.activate), selected: &selected, cancelCount: &cancelCount)
        #expect(selected == [Self.shells()[2]])
        #expect(cancelCount == 0)

        dispatch(state.handle(.cancel), selected: &selected, cancelCount: &cancelCount)
        #expect(selected == [Self.shells()[2]])
        #expect(cancelCount == 1)
    }

    @Test("Empty input stays inert for every activation and movement command")
    func emptyInputIsInert() {
        var state = TerminalShellPickerState(shells: [])

        #expect(state.focusedShellID == nil)
        #expect(state.handle(.next) == .none)
        #expect(state.handle(.previous) == .none)
        #expect(state.handle(.first) == .none)
        #expect(state.handle(.last) == .none)
        #expect(state.handle(.activate) == .none)
        #expect(state.handle(.cancel) == .cancel)
    }

    @Test("Shell identity is the exact path and accessibility keeps long-path truth")
    func pathIdentityAndAccessibilityTruth() {
        let longPath =
            "/Volumes/Developer Tools/Managed Shells/Company Distribution/bin/custom-zsh"
        let shell = TerminalShell(path: longPath, name: "custom-zsh", isDefault: true)

        #expect(shell.id == longPath)
        #expect(
            TerminalShellPickerAccessibility.label(for: shell, index: 1, count: 8)
                == "custom-zsh, \(longPath), Default shell, 2 of 8"
        )
    }

    @Test("One, two, and eight shell layouts grow but remain bounded")
    func boundedLargerTextGeometry() {
        #expect(TerminalShellPickerGeometry.width(for: 300) == 360)
        #expect(TerminalShellPickerGeometry.width(for: 440) == 440)
        #expect(TerminalShellPickerGeometry.width(for: 700) == 520)
        #expect(TerminalShellPickerGeometry.height(shellCount: 1, rowHeight: 44) == 112)
        #expect(TerminalShellPickerGeometry.height(shellCount: 2, rowHeight: 44) == 140)
        #expect(TerminalShellPickerGeometry.height(shellCount: 8, rowHeight: 44) == 404)
        #expect(TerminalShellPickerGeometry.height(shellCount: 8, rowHeight: 72) == 420)
    }

    @Test("The view is value-only, focusable, accessible, and process-free")
    func sourceContract() throws {
        let source = try Self.source("Sources/RafuApp/Views/TerminalShellPickerView.swift")

        #expect(source.contains("let shells: [TerminalShell]"))
        #expect(source.contains("let onSelect: (TerminalShell) -> Void"))
        #expect(source.contains("@FocusState private var focusedShellID"))
        #expect(source.contains(".defaultFocus($focusedShellID, pickerState.focusedShellID)"))
        #expect(source.contains("ForEach(Array(shells.enumerated()), id: \\.element.path)"))
        #expect(source.contains("Text(shell.name)"))
        #expect(source.contains("Text(verbatim: shell.path)"))
        #expect(source.contains(".truncationMode(.middle)"))
        #expect(source.contains("RafuChip(text: \"Default\")"))
        #expect(source.contains(".help(shell.path)"))
        #expect(source.contains(".onKeyPress(.downArrow)"))
        #expect(source.contains(".onKeyPress(.upArrow)"))
        #expect(source.contains(".onKeyPress(.home)"))
        #expect(source.contains(".onKeyPress(.end)"))
        #expect(source.contains(".onKeyPress(.return)"))
        #expect(source.contains(".onKeyPress(.escape)"))
        #expect(source.contains(".accessibilityHint(\"Open a new terminal with this shell\")"))
        #expect(source.contains("@ScaledMetric(relativeTo: .body)"))
        #expect(!source.contains("TerminalShellCatalog"))
        #expect(!source.contains("WorkspaceTerminalController"))
        #expect(!source.contains("newTerminalTab"))
        #expect(!source.contains("Process("))
    }

    private static func shells() -> [TerminalShell] {
        [
            TerminalShell(path: "/bin/zsh", name: "zsh", isDefault: false),
            TerminalShell(
                path: "/opt/homebrew/bin/fish",
                name: "Default (fish)",
                isDefault: true
            ),
            TerminalShell(path: "/usr/local/bin/nu", name: "nu", isDefault: false),
        ]
    }

    private func dispatch(
        _ effect: TerminalShellPickerEffect,
        selected: inout [TerminalShell],
        cancelCount: inout Int
    ) {
        switch effect {
        case .none:
            break
        case .select(let shell):
            selected.append(shell)
        case .cancel:
            cancelCount += 1
        }
    }

    private static func source(_ path: String, file: StaticString = #filePath) throws -> String {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path
            ) {
                return try String(
                    contentsOf: directory.appending(path: path),
                    encoding: .utf8
                )
            }
            directory = directory.deletingLastPathComponent()
        }
        throw TerminalShellPickerPresentationError.repositoryRootNotFound
    }

    private enum TerminalShellPickerPresentationError: Error {
        case repositoryRootNotFound
    }
}
