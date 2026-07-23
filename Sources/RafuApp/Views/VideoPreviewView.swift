import AVKit
import SwiftUI

/// Native preview for video documents (mp4/mov/m4v). Mirrors
/// `ImagePreviewView`'s structure — bounded content plus a native info bar —
/// but plays through AVKit's `VideoPlayer` instead of decoding a bitmap.
///
/// The WKWebView ban (ADR 0008) does not apply to AVKit: this is a system
/// media-playback control, not a per-document web view.
struct VideoPreviewView: View {
    let url: URL
    @Environment(\.rafuTheme) private var theme
    @State private var player: AVPlayer?
    @State private var fileBytes: Int?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .background(Color.black)
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .bottom) { infoBar }
        .background(theme.palette.editorBackground)
        .task(id: url) {
            player = AVPlayer(url: url)
            fileBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        .onDisappear {
            // Pause and release the player so a hibernated/closed video tab
            // never keeps decoding or holding playback resources — the
            // ~150MB idle-memory budget applies here just as it does to a
            // dismounted `NSTextStorage`.
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
        }
    }

    private var infoBar: some View {
        HStack(spacing: 10) {
            let icon = FileIconProvider.fileIcon(named: url.lastPathComponent)
            FileIconView(icon: icon, size: 10)
            Text(url.lastPathComponent)
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(1)
            Spacer()
            if let fileBytes {
                Text(ByteCountFormatter.string(fromByteCount: Int64(fileBytes), countStyle: .file))
                    .foregroundStyle(theme.palette.textMuted)
            }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(theme.palette.tabBarBackground.opacity(0.92))
        .overlay(alignment: .top) { Divider().overlay(theme.palette.borderSubtle) }
    }
}
