import AppKit
import RafuCore
import UniformTypeIdentifiers

/// The two user actions of the Markdown export: Copy, and Export… through a
/// save panel. Rafu never picks the place by itself: nothing is written
/// until the user chooses a file in the panel. The Meetings window package
/// calls these from its buttons and menu items.
@MainActor
enum MeetingExportActions {
    /// Puts the Markdown of one meeting on the general pasteboard.
    @discardableResult
    static func copyMarkdown(
        of meeting: MeetingID, using feature: MeetingsFeature,
        options: MeetingExportOptions = MeetingExportOptions()
    ) async -> Bool {
        guard let markdown = await markdown(of: meeting, using: feature, options: options)
        else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
        feature.diagnostics.record(.exportDone(kind: .markdown), meeting: meeting)
        return true
    }

    /// Shows a save panel and writes the Markdown to the chosen file.
    /// Returns false when the user cancels or the write fails.
    @discardableResult
    static func saveMarkdown(
        of meeting: MeetingID, using feature: MeetingsFeature,
        options: MeetingExportOptions = MeetingExportOptions()
    ) async -> Bool {
        guard let store = feature.store,
            let summary = try? await store.summary(of: meeting),
            let markdown = await markdown(of: meeting, using: feature, options: options)
        else { return false }
        let panel = NSSavePanel()
        panel.title = "Export Meeting"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = MeetingMarkdownExporter.suggestedFileName(
            title: summary.title, startDate: summary.startDate)
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try Data(markdown.utf8).write(to: url, options: .atomic)
        } catch {
            feature.diagnostics.record(
                .userFacingError(
                    place: .export, domain: MeetingDiagnosticString((error as NSError).domain),
                    code: (error as NSError).code),
                meeting: meeting)
            return false
        }
        feature.diagnostics.record(.exportDone(kind: .markdown), meeting: meeting)
        return true
    }

    private static func markdown(
        of meeting: MeetingID, using feature: MeetingsFeature, options: MeetingExportOptions
    ) async -> String? {
        guard let store = feature.store else { return nil }
        do {
            if let servicing = store as? any MeetingLibraryServicing {
                return try await servicing.exportMarkdown(of: meeting, options: options)
            }
            return try await store.exportMarkdown(of: meeting)
        } catch {
            feature.diagnostics.record(
                .userFacingError(
                    place: .export, domain: MeetingDiagnosticString((error as NSError).domain),
                    code: (error as NSError).code),
                meeting: meeting)
            return nil
        }
    }
}
