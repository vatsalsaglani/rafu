import AppKit
import SwiftUI

/// Export…: choose what (board, selection, a frame), the format (PNG at
/// 1x/2x/3x, PDF, animated GIF) and, for a GIF, its length and frame rate.
/// The file goes to the workspace `exports` folder and is shown in Finder.
struct CanvasDiagramExportSheet: View {
    enum Kind: String, CaseIterable, Identifiable {
        case png, pdf, gif
        var id: Self { self }
        var title: String {
            switch self {
            case .png: "PNG"
            case .pdf: "PDF"
            case .gif: "Animated GIF"
            }
        }
    }

    @Environment(\.rafuTheme) private var theme
    let board: CanvasBoardState
    let session: WorkspaceSession
    let initialTarget: CanvasDiagramExportTarget
    let dismiss: () -> Void
    @State private var target: CanvasDiagramExportTarget = .board
    @State private var kind: Kind = .png
    @State private var scale = 2
    @State private var seconds = 3
    @State private var fps = 15
    @State private var isExporting = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export")
                .font(.headline)
                .foregroundStyle(theme.palette.textPrimary)
            Form {
                targetPicker
                Picker("Format", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.title).tag($0) }
                }
                options
            }
            .formStyle(.grouped)
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(theme.palette.textSecondary)
            }
            Spacer(minLength: 0)
            buttons
        }
        .padding(20)
        .frame(minWidth: 400, minHeight: 340, alignment: .top)
        .onAppear { target = initialTarget }
    }

    private var frames: [CanvasCard] {
        board.cards.filter { $0.content.diagramFrame != nil }
    }

    private var targetPicker: some View {
        Picker("Export", selection: $target) {
            Text("Whole Ensemble").tag(CanvasDiagramExportTarget.board)
            if !board.selection.isEmpty {
                Text("Selection").tag(CanvasDiagramExportTarget.selection)
            }
            ForEach(frames) { frame in
                Text("Frame “\(frame.title)”").tag(CanvasDiagramExportTarget.frame(frame.id))
            }
        }
    }

    @ViewBuilder private var options: some View {
        switch kind {
        case .png:
            LabeledContent("Scale") {
                RafuSegmentedPicker(items: [1, 2, 3], selection: $scale) { "\($0)×" }
            }
        case .pdf:
            Text("Vector PDF, one page.")
                .foregroundStyle(theme.palette.textSecondary)
        case .gif:
            Stepper("Length: \(seconds) s", value: $seconds, in: 1...10)
            Picker("Frame Rate", selection: $fps) {
                Text("10 fps").tag(10)
                Text("15 fps").tag(15)
                Text("24 fps").tag(24)
            }
            Text(
                "A dot travels along each link in its direction; message links carry dots both ways. At most 120 frames and 1,600 pixels wide."
            )
            .font(.caption)
            .foregroundStyle(theme.palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        HStack {
            if isExporting {
                ProgressView().controlSize(.small)
                Text("Exporting…").font(.callout)
            }
            Spacer()
            Button("Cancel", action: dismiss)
                .keyboardShortcut(.cancelAction)
            Button("Export", action: export)
                .keyboardShortcut(.defaultAction)
                .disabled(isExporting)
        }
    }

    private var format: CanvasDiagramExportFormat {
        switch kind {
        case .png: .png(scale: Double(scale))
        case .pdf: .pdf
        case .gif: .gif(seconds: Double(seconds), fps: fps)
        }
    }

    private func export() {
        isExporting = true
        errorText = nil
        let theme = theme
        Task {
            defer { isExporting = false }
            do {
                let url = try await CanvasDiagramService.export(
                    boardID: board.id, target: target, format: format, session: session,
                    theme: theme)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
