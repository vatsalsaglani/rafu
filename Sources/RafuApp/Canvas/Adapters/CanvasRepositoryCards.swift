import AppKit
import SwiftUI

struct CanvasFilePreview: View {
    let path: String
    let session: WorkspaceSession
    @State private var preview = ""
    @State private var notice: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(path, systemImage: "doc.text").lineLimit(2)
                Spacer()
                Button("Open File") { session.openCanvasFile(path) }
            }
            Text("Read-only preview · first 8 KiB").font(.caption).foregroundStyle(.secondary)
            if let notice { Text(notice).foregroundStyle(.secondary) }
            ScrollView {
                Text(preview).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(20)
        .task(id: path) {
            guard let root = session.rootURL else { return }
            // Prefer the existing native editor's dirty text. It remains the
            // only source-file owner; this view keeps only a bounded prefix.
            if let document = session.openDocuments.first(where: {
                session.relativePath(for: $0.url) == path
            }),
                let snapshot = document.textSnapshotProvider
            {
                preview = String(decoding: snapshot().utf8.prefix(8 * 1_024), as: UTF8.self)
                notice = document.isDirty ? "This preview includes unsaved file changes." : nil
                return
            }
            do { preview = try await CanvasPreviewLoader.text(path: path, root: root) } catch {
                notice = error.localizedDescription
            }
        }
    }
}

struct CanvasImagePreview: View {
    let path: String
    let session: WorkspaceSession
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label(path, systemImage: "photo").lineLimit(2)
                Spacer()
                Button("Open Image") { session.openCanvasFile(path) }
            }
            CanvasImageContent(path: path, session: session, pixels: 1_024)
        }.padding(20)
    }
}

struct CanvasImageContent: View {
    let path: String
    let session: WorkspaceSession
    var pixels = 128
    @State private var retry = 0
    @State private var lease: CanvasImagePool.Lease?
    @State private var notice: String?
    var body: some View {
        Group {
            if let lease {
                Image(nsImage: lease.image).resizable().scaledToFit().accessibilityLabel(path)
            } else if let notice {
                VStack {
                    Label(notice, systemImage: "photo").font(.caption).foregroundStyle(.secondary)
                    Button("Retry Image") { retry += 1 }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: "\(path)#\(retry)") {
            await Task.yield()
            guard let root = session.rootURL else { return }
            do {
                lease = try await session.canvasImages.load(path: path, root: root, pixels: pixels)
            } catch is CancellationError {} catch { notice = error.localizedDescription }
        }
        .onDisappear { lease = nil }
    }
}
