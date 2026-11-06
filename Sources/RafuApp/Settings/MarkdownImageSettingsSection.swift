import SwiftUI

/// Settings › General › Markdown: where a pasted or dropped image is stored,
/// relative to the Markdown document. Read at paste time by
/// `CodeEditorView.Coordinator` through `MarkdownImageFolder.storedTemplate()`.
struct MarkdownImageSettingsSection: View {
    @AppStorage(MarkdownImageFolder.defaultsKey) private var folderTemplate =
        MarkdownImageFolder.defaultTemplate

    var body: some View {
        Section {
            TextField("Image folder", text: $folderTemplate, prompt: Text("assets"))
                .help(
                    "Folder for pasted and dropped images, relative to the Markdown file. ${name} is the file name without its extension."
                )
        } header: {
            Text("Markdown")
        } footer: {
            footer
        }
    }

    @ViewBuilder
    private var footer: some View {
        if MarkdownImageFolder.isValid(template: folderTemplate)
            || folderTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            Text(
                "Paste or drop an image into a saved Markdown file to store it in this folder beside the file and insert a link. Use ${name}.assets for one folder per file."
            )
        } else {
            Label(
                "Use a relative folder without “..”, for example assets or ${name}.assets.",
                systemImage: "exclamationmark.triangle"
            )
        }
    }
}
