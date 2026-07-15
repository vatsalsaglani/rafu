import SwiftUI

/// The consent sheet shown before Rafu downloads and installs one server
/// (or, for a pack, every member). Every field is worded to be honest
/// about what will actually happen — this is the sole place a user
/// approves quarantine removal for the binaries it names, and it never
/// claims a checksum was verified when the catalog/user entry never
/// published one.
struct ServerInstallConsentView: View {
    let request: LanguageServersCatalogModel.ConsentRequest
    let onCancel: () -> Void
    let onInstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(descriptors, id: \.id) { descriptor in
                        ServerConsentDetailRow(descriptor: descriptor)
                    }
                }
            }
            .frame(maxHeight: 260)
            Text(
                "Rafu will remove the macOS quarantine flag on each downloaded binary above, "
                    + "once you approve, so it can run."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Install") { onInstall() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(minWidth: 420)
    }

    private var descriptors: [ServerDescriptor] {
        switch request.subject {
        case .server(let descriptor): return [descriptor]
        case .pack(_, let descriptors): return descriptors
        }
    }

    private var title: String {
        switch request.subject {
        case .server(let descriptor): return "Install \(descriptor.displayName)?"
        case .pack(let displayName, _): return "Install \(displayName)?"
        }
    }
}

private struct ServerConsentDetailRow: View {
    let descriptor: ServerDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(descriptor.displayName).font(.subheadline.weight(.semibold))
            if let source = descriptor.source {
                Text(
                    "Rafu will download \(descriptor.displayName) \(source.version) from "
                        + "\(source.url.absoluteString)."
                )
                LabeledContent("Size", value: sizeText(source.estimatedBytes))
                LabeledContent("License", value: source.license)
                Text(checksumText(source))
                    .foregroundStyle(source.checksum == nil ? .orange : .secondary)
            } else {
                Text("Uses a toolchain already installed on this Mac; nothing is downloaded.")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func sizeText(_ bytes: UInt64?) -> String {
        guard let bytes else { return "Unknown size" }
        return Int64(bytes).formatted(.byteCount(style: .file))
    }

    private func checksumText(_ source: ServerSource) -> String {
        source.checksum == nil
            ? "This download's checksum is not published by this project — Rafu cannot verify "
                + "this download's integrity."
            : "This download will be verified against the publisher's SHA-256 checksum before "
                + "it runs."
    }
}
