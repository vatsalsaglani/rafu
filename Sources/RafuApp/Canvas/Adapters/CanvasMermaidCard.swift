import AppKit
import SwiftUI

/// `.task(id:)` key: re-render only when the source, the theme or the raster
/// scale changes, never on an unrelated re-body.
private struct CanvasMermaidRenderKey: Equatable {
    let source: String
    let theme: MermaidThemeSpec
    let scale: CGFloat
}

/// A Mermaid diagram card. It renders through the shared native
/// `MermaidRenderService` (ADR 0020): parsing, layout and rasterization run
/// off the main actor, and only the `Sendable` raster comes back. Edit mode is
/// a TextKit source editor; the diagram re-renders when the source is
/// committed (Command-Return or Render). Failures show inline with the
/// Rafu-authored reason and the source, never a blank card.
struct CanvasMermaidCard: View {
    @Environment(\.rafuTheme) private var theme
    @Environment(\.displayScale) private var displayScale
    let card: CanvasCard
    let board: CanvasBoardState
    @State private var isEditing = false
    @State private var raster: MermaidRenderService.Raster?
    @State private var failure: String?
    @State private var handle = CanvasTextEditorHandle()

    private var source: String {
        if case .mermaid(let source) = card.content { return source }
        return ""
    }

    /// The board is scaled with `scaleEffect`, so above 125% zoom the raster is
    /// made at twice the display scale to stay sharp. Two steps only, so
    /// zooming does not re-render on every frame.
    private var rasterScale: CGFloat {
        displayScale * (board.viewport.scale > 1.25 ? 2 : 1)
    }

    var body: some View {
        Group {
            if isEditing {
                editor
            } else if let failure {
                failureView(failure)
            } else if let raster {
                Image(decorative: raster.image, scale: raster.scale)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(raster.accessibilityLabel)
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Rendering diagram")
            }
        }
        .contentShape(.rect)
        .simultaneousGesture(TapGesture(count: 2).onEnded { beginEditing() })
        .canvasWhiteboardEditTrigger(card: card, board: board, isEditing: $isEditing)
        .task(
            id: CanvasMermaidRenderKey(
                source: source, theme: MermaidThemeSpec(theme: theme), scale: rasterScale)
        ) {
            await render()
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            CanvasWhiteboardTextEditor(
                initialText: source, monospaced: true, fontSize: 12,
                textColor: NSColor(theme.palette.textPrimary),
                byteLimit: CanvasLimits.mermaidSourceBytes, handle: handle,
                accessibilityLabel: "Mermaid source", onCommit: commit, onCancel: cancel)
            Divider()
            HStack(spacing: 8) {
                Text("Command-Return renders. Escape cancels.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("Cancel", action: cancel)
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                Button("Render") { commit(handle.text) }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                    .help("Render the diagram (Command-Return)")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .background(theme.palette.fieldBackground)
    }

    private func failureView(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Diagram not rendered", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.palette.warning)
            Text(reason)
                .font(.system(size: 12))
                .foregroundStyle(theme.palette.textSecondary)
            ScrollView {
                Text(source)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            Button("Edit Source", action: beginEditing)
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    private func render() async {
        let spec = MermaidThemeSpec(theme: theme)
        switch MarkdownParser().parseMermaid(source) {
        case .unsupported:
            raster = nil
            failure = "diagram type not supported in native preview"
        case .malformed(_, _, let reason):
            raster = nil
            failure = "diagram type not supported in native preview — \(reason)"
        case .diagram(let diagram):
            do {
                let result = try await MermaidRenderService.shared.raster(
                    for: diagram, theme: spec, scale: rasterScale)
                raster = result
                failure = nil
            } catch is CancellationError {
                // A newer render superseded this one.
            } catch let error as MermaidRenderService.Failure {
                raster = nil
                failure = MermaidRenderService.reason(for: error)
            } catch {
                raster = nil
                failure = "this diagram could not be rendered"
            }
        }
    }

    private func beginEditing() {
        guard !isEditing else { return }
        board.focus(card.id)
        isEditing = true
    }

    private func commit(_ text: String) {
        isEditing = false
        guard CanvasStyleDecoding.validMermaidSource(text), text != source else {
            board.backToBoard()
            return
        }
        CanvasWhiteboardEdit.replace(card.id, in: board, with: .mermaid(source: text))
    }

    private func cancel() {
        isEditing = false
        board.backToBoard()
    }
}
