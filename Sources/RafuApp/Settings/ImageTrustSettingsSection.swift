import SwiftUI

/// What the Add field shows for the text typed so far. Pure, so a test can
/// pin the enabled state of the Add button.
nonisolated enum ImageTrustAddState: Equatable, Sendable {
    case empty
    /// The Public Suffix List has not loaded yet.
    case loading
    case invalid(String)
    case duplicate
    case valid(HostPattern)

    var canAdd: Bool {
        if case .valid = self { return true }
        return false
    }

    /// The line under the field, or nil when there is nothing to say.
    var message: String? {
        switch self {
        case .empty, .valid, .loading: nil
        case .invalid(let reason): reason
        case .duplicate: "This host is already on the list"
        }
    }

    static func evaluate(
        _ text: String, suffixes: (any PublicSuffixProviding)?, existing: [ImageTrustEntry]
    ) -> ImageTrustAddState {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        guard let suffixes else { return .loading }
        do {
            let pattern = try HostPattern.parse(text, suffixes: suffixes)
            return existing.contains(where: { $0.pattern == pattern.text })
                ? .duplicate : .valid(pattern)
        } catch {
            return .invalid(error.message)
        }
    }
}

/// Settings ▸ Ensemble ▸ Images from the web: the global switch (Off, Ask,
/// Always allow) and the trust list of image hosts. Building the view does no
/// file I/O; the list loads when the section appears.
struct ImageTrustSettingsSection: View {
    let model: RemoteImageTrustModel
    @State private var newPattern = ""
    @State private var isConfirmingRemoveAll = false

    init(model: RemoteImageTrustModel = .shared) {
        self.model = model
    }

    var body: some View {
        let addState = ImageTrustAddState.evaluate(
            newPattern, suffixes: model.suffixes, existing: model.entries)
        Section {
            Picker(
                "Images from the web",
                selection: Binding(get: { model.mode }, set: { model.setMode($0) })
            ) {
                ForEach(CanvasRemoteImageMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .accessibilityHint("Off loads nothing. Ask asks once for each Ensemble.")
        } header: {
            Text("Images from the web")
        } footer: {
            Text(Self.footer(for: model.mode))
        }
        .task { await model.ensureLoaded() }

        Section {
            HStack(spacing: 8) {
                TextField(
                    "Host", text: $newPattern, prompt: Text("images.example.com or *.example.com")
                )
                .autocorrectionDisabled()
                .onSubmit { add(addState) }
                .accessibilityLabel("Image host to trust")
                Button("Add") { add(addState) }
                    .disabled(!addState.canAdd)
            }
            if let message = addState.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Cannot add: \(message)")
            }
            ForEach(model.entries) { entry in
                ImageTrustEntryRow(entry: entry) {
                    Task { await model.remove(entry.pattern) }
                }
            }
            if model.entries.isEmpty, model.isLoaded {
                Text("No trusted image hosts yet.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Undo") { Task { await model.undo() } }
                    .disabled(!model.canUndo)
                    .help("Undo the last change to this list in this session")
                Spacer()
                Button("Remove All…", role: .destructive) { isConfirmingRemoveAll = true }
                    .disabled(model.entries.isEmpty)
            }
        } header: {
            Text("Trusted image hosts")
        } footer: {
            Text(
                model.writeProblem ?? model.loadNote
                    ?? "Images from a trusted host load without asking. A host is exact (images.example.com) or one wildcard on a domain (*.example.com). Only https loads."
            )
        }
        .sheet(isPresented: $isConfirmingRemoveAll) {
            RafuConfirmPopup(
                title: "Remove all trusted image hosts?",
                message:
                    "Images from these hosts will ask for consent again. You can undo this in Settings until you close it.",
                actions: [
                    .init("Remove All", isDestructive: true) {
                        isConfirmingRemoveAll = false
                        Task { await model.removeAll() }
                    }
                ]
            ) {
                isConfirmingRemoveAll = false
            }
        }
    }

    private func add(_ state: ImageTrustAddState) {
        guard case .valid(let pattern) = state else { return }
        newPattern = ""
        Task { await model.add(pattern, source: .settings) }
    }

    static func footer(for mode: CanvasRemoteImageMode) -> String {
        switch mode {
        case .off:
            "Generated views show a placeholder. Rafu sends no request for any image."
        case .ask:
            "Rafu asks once for each Ensemble before it loads an image, and loads from trusted hosts without asking. Only https loads."
        case .always:
            "Images load from any public https host without asking. Rafu still refuses IP addresses, local names and private networks."
        }
    }
}

private struct ImageTrustEntryRow: View {
    let entry: ImageTrustEntry
    let remove: () -> Void

    var body: some View {
        let pattern = HostPattern(
            kind: entry.pattern.hasPrefix("*.") ? .wildcard : .exact,
            base: entry.pattern.hasPrefix("*.") ? String(entry.pattern.dropFirst(2)) : entry.pattern
        )
        HStack(spacing: 10) {
            Text(entry.pattern)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(entry.addedAt.formatted(.dateTime.day().month().year()))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(entry.source == .confirm ? "From a prompt" : "Added here")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Remove", role: .destructive, action: remove)
                .accessibilityLabel("Remove \(pattern.spoken)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Trusted image host, \(pattern.spoken), added \(entry.addedAt.formatted(.dateTime.day().month(.wide)))"
        )
    }
}
