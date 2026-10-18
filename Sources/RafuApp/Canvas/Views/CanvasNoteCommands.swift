import SwiftUI

extension FocusedValues {
    /// The note that is in Edit mode in the focused window, if any.
    @Entry var canvasNoteEditing: CanvasNoteModel?
}

/// The Format menu for Canvas notes (review 7.8). Its items are live only while
/// a note is in Edit mode. The shortcuts shown here are handled by the note's
/// text view first (see `CanvasNoteBuffer.setKeyHandling`), because ⌘B and ⇧⌘L
/// also belong to workbench menus; they are attached to the menu items only
/// while a note is being edited, so they never shadow those menus otherwise.
struct CanvasNoteCommands: Commands {
    @FocusedValue(\.canvasNoteEditing) private var editing
    @FocusedValue(\.workspaceSession) private var session

    private var focusedNote: CanvasNoteModel? {
        guard let session, let board = session.selectedCanvas, let card = board.focusedCard,
            case .note = card.content
        else { return nil }
        return session.canvasNoteModel(boardID: board.id, card: card)
    }

    var body: some Commands {
        CommandMenu("Format") {
            let isEditing = editing != nil
            if let editing {
                Button("Done Editing") { editing.endEditing() }
                    .keyboardShortcut(.return, modifiers: .command)
            } else {
                Button("Edit Note") { focusedNote?.beginEditing() }
                    .disabled(focusedNote == nil)
            }
            Divider()
            item(.bold, key: "b", modifiers: .command, enabled: isEditing)
            item(.italic, key: "i", modifiers: .command, enabled: isEditing)
            item(.code, key: "e", modifiers: .command, enabled: isEditing)
            item(.link, key: "k", modifiers: .command, enabled: isEditing)
            Divider()
            item(.bullets, key: "7", modifiers: [.command, .shift], enabled: isEditing)
            item(.numbers, key: "9", modifiers: [.command, .shift], enabled: isEditing)
            item(.task, key: "l", modifiers: [.command, .shift], enabled: isEditing)
            Divider()
            item(.heading1, key: "1", modifiers: [.command, .option], enabled: isEditing)
            item(.heading2, key: "2", modifiers: [.command, .option], enabled: isEditing)
            item(.heading3, key: "3", modifiers: [.command, .option], enabled: isEditing)
            item(.body, key: "0", modifiers: [.command, .option], enabled: isEditing)
        }
    }

    private func item(
        _ command: CanvasNoteFormatCommand, key: KeyEquivalent, modifiers: EventModifiers,
        enabled: Bool
    ) -> some View {
        Button(command.title) { editing?.perform(command) }
            .disabled(!enabled)
            .modifier(
                CanvasNoteShortcutModifier(key: key, modifiers: modifiers, isEnabled: enabled))
    }
}

/// Adds a key equivalent only when `isEnabled`, so an inactive Format item
/// cannot claim a shortcut that another menu owns.
private struct CanvasNoteShortcutModifier: ViewModifier {
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.keyboardShortcut(key, modifiers: modifiers)
        } else {
            content
        }
    }
}

/// Five icon buttons (Bold, Italic, Code, Link, Task) when the card is at least
/// 320 pt wide, otherwise one "Aa" pull-down with every command. For the note
/// card's header (W6a) or, until then, the top of the note body.
struct CanvasNoteFormatBar: View {
    let model: CanvasNoteModel
    /// Card width in card points (not screen points).
    var availableWidth: CGFloat = 320
    var showsEditingLabel = false

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            if availableWidth >= 320 {
                ForEach(CanvasNoteFormatCommand.compactBar, id: \.self) { command in
                    Button {
                        model.perform(command)
                    } label: {
                        Image(systemName: command.symbol)
                    }
                    .buttonStyle(RafuIconButtonStyle(size: 24, iconSize: 12))
                    .help(command.title)
                    .accessibilityLabel(command.title)
                }
            } else {
                Menu {
                    ForEach(CanvasNoteFormatCommand.allCases, id: \.self) { command in
                        Button(command.title) { model.perform(command) }
                    }
                } label: {
                    Text("Aa").font(.system(size: 13, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Format")
                .accessibilityLabel("Format")
            }
            Spacer(minLength: 0)
            if showsEditingLabel {
                Text("Editing")
                    .font(.caption)
                    .foregroundStyle(theme.palette.textSecondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(theme.palette.editorBackground)
    }
}
