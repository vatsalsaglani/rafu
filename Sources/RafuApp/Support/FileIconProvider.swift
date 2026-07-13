import SwiftUI

/// Central symbol + tint mapping for the file tree and editor tabs.
/// Pure lookup tables — cheap enough to call from row bodies.
nonisolated enum FileIconProvider {
    nonisolated struct Icon: Sendable, Hashable {
        let symbol: String
        let tint: Tint
        /// Bundled SVG in `Resources/FileIcons` (basename without extension).
        /// When set, views render the asset instead of the SF Symbol; the
        /// symbol stays as a fallback if the asset fails to load.
        var assetName: String? = nil
        /// Monochrome assets drawn with `currentColor` render black unless
        /// treated as templates and tinted like a symbol.
        var assetIsTemplate: Bool = false
    }

    /// Tints are semantic (resolved against the active theme palette) or
    /// fixed brand colors chosen to read on both light and dark surfaces.
    nonisolated enum Tint: Sendable, Hashable {
        case secondary
        case muted
        case accent
        case info
        case success
        case warning
        case error
        case fixed(String)
    }

    static func icon(for url: URL, isDirectory: Bool) -> Icon {
        isDirectory
            ? directoryIcon(named: url.lastPathComponent)
            : fileIcon(named: url.lastPathComponent)
    }

    static func directoryIcon(named name: String) -> Icon {
        if let special = specialDirectories[name.lowercased()] {
            return special
        }
        return Icon(symbol: "folder", tint: .secondary)
    }

    static func fileIcon(named name: String) -> Icon {
        let lowered = name.lowercased()
        if let special = specialFiles[lowered] {
            return special
        }
        let ext = (lowered as NSString).pathExtension
        if let byExtension = extensions[ext] {
            return byExtension
        }
        if lowered.hasPrefix(".") {
            return Icon(symbol: "gearshape", tint: .muted)
        }
        return Icon(symbol: "doc.text", tint: .secondary)
    }

    // MARK: - Tables

    private static let claudeOrange = Tint.fixed("#D97757")
    private static let swiftOrange = Tint.fixed("#F05138")
    private static let dockerBlue = Tint.fixed("#2496ED")
    private static let pythonBlue = Tint.fixed("#4B8BBE")
    private static let npmRed = Tint.fixed("#CB3837")
    private static let jsYellow = Tint.fixed("#C7A400")
    private static let tsBlue = Tint.fixed("#3178C6")

    private static let specialDirectories: [String: Icon] = [
        ".agents": Icon(symbol: "cpu", tint: .info),
        ".claude": Icon(symbol: "sparkle", tint: claudeOrange, assetName: "claude"),
        ".codex": Icon(
            symbol: "terminal", tint: .success, assetName: "codex", assetIsTemplate: true),
        ".gemini": Icon(symbol: "sparkles", tint: .info, assetName: "gemini"),
        ".cursor": Icon(symbol: "cursorarrow", tint: .info),
        ".github": Icon(symbol: "shippingbox", tint: .muted),
        ".git": Icon(symbol: "arrow.triangle.branch", tint: .muted),
        ".vscode": Icon(symbol: "chevron.left.forwardslash.chevron.right", tint: .info),
        ".build": Icon(symbol: "hammer", tint: .muted),
        "node_modules": Icon(symbol: "shippingbox", tint: .muted),
        "dist": Icon(symbol: "shippingbox", tint: .muted),
        "build": Icon(symbol: "hammer", tint: .muted),
        "docs": Icon(symbol: "book", tint: .info),
        "doc": Icon(symbol: "book", tint: .info),
        "documentation": Icon(symbol: "book", tint: .info),
        "src": Icon(symbol: "chevron.left.forwardslash.chevron.right", tint: .accent),
        "source": Icon(symbol: "chevron.left.forwardslash.chevron.right", tint: .accent),
        "sources": Icon(symbol: "chevron.left.forwardslash.chevron.right", tint: .accent),
        "lib": Icon(symbol: "building.columns", tint: .secondary),
        "app": Icon(symbol: "macwindow", tint: .info),
        "apps": Icon(symbol: "macwindow", tint: .info),
        "test": Icon(symbol: "checkmark.seal", tint: .success),
        "tests": Icon(symbol: "checkmark.seal", tint: .success),
        "spec": Icon(symbol: "checkmark.seal", tint: .success),
        "__tests__": Icon(symbol: "checkmark.seal", tint: .success),
        "script": Icon(symbol: "terminal", tint: .warning),
        "scripts": Icon(symbol: "terminal", tint: .warning),
        "services": Icon(symbol: "gearshape.2", tint: .info),
        "service": Icon(symbol: "gearshape.2", tint: .info),
        "api": Icon(symbol: "point.3.connected.trianglepath.dotted", tint: .info),
        "assets": Icon(symbol: "photo.on.rectangle", tint: .success),
        "images": Icon(symbol: "photo.on.rectangle", tint: .success),
        "media": Icon(symbol: "photo.on.rectangle", tint: .success),
        "public": Icon(symbol: "globe", tint: .info),
        "static": Icon(symbol: "globe", tint: .info),
        "resources": Icon(symbol: "archivebox", tint: .secondary),
        "config": Icon(symbol: "gearshape", tint: .muted),
        "configs": Icon(symbol: "gearshape", tint: .muted),
        "vendor": Icon(symbol: "shippingbox", tint: .muted),
        "migrations": Icon(symbol: "arrow.up.arrow.down", tint: .warning),
        "models": Icon(symbol: "square.stack.3d.up", tint: .info),
        "views": Icon(symbol: "rectangle.on.rectangle", tint: .info),
        "controllers": Icon(symbol: "slider.horizontal.3", tint: .info),
        "components": Icon(symbol: "puzzlepiece", tint: .info),
        "utils": Icon(symbol: "wrench.and.screwdriver", tint: .secondary),
        "helpers": Icon(symbol: "wrench.and.screwdriver", tint: .secondary),
    ]

    private static let specialFiles: [String: Icon] = [
        "package.swift": Icon(symbol: "swift", tint: swiftOrange),
        "package.resolved": Icon(symbol: "lock", tint: .muted),
        "package.json": Icon(symbol: "shippingbox", tint: npmRed),
        "package-lock.json": Icon(symbol: "lock", tint: .muted),
        "yarn.lock": Icon(symbol: "lock", tint: .muted),
        "pnpm-lock.yaml": Icon(symbol: "lock", tint: .muted),
        "cargo.toml": Icon(symbol: "shippingbox", tint: .warning),
        "cargo.lock": Icon(symbol: "lock", tint: .muted),
        "requirements.txt": Icon(symbol: "shippingbox", tint: pythonBlue),
        "pyproject.toml": Icon(symbol: "shippingbox", tint: pythonBlue),
        "pipfile": Icon(symbol: "shippingbox", tint: pythonBlue),
        "gemfile": Icon(symbol: "shippingbox", tint: .error),
        "dockerfile": Icon(symbol: "shippingbox.fill", tint: dockerBlue),
        "docker-compose.yml": Icon(symbol: "shippingbox.fill", tint: dockerBlue),
        "docker-compose.yaml": Icon(symbol: "shippingbox.fill", tint: dockerBlue),
        "makefile": Icon(symbol: "hammer", tint: .warning),
        "justfile": Icon(symbol: "hammer", tint: .warning),
        "readme.md": Icon(symbol: "text.book.closed", tint: .accent),
        "license": Icon(symbol: "checkmark.seal", tint: .muted),
        "license.md": Icon(symbol: "checkmark.seal", tint: .muted),
        "changelog.md": Icon(symbol: "clock.arrow.circlepath", tint: .secondary),
        "contributing.md": Icon(symbol: "person.2", tint: .secondary),
        "security.md": Icon(symbol: "lock.shield", tint: .secondary),
        "agents.md": Icon(symbol: "cpu", tint: .info),
        "claude.md": Icon(symbol: "sparkle", tint: claudeOrange, assetName: "claude"),
        "gemini.md": Icon(symbol: "sparkles", tint: .info, assetName: "gemini"),
        ".gitignore": Icon(symbol: "eye.slash", tint: .muted),
        ".gitattributes": Icon(symbol: "gearshape", tint: .muted),
        ".env": Icon(symbol: "key", tint: .warning),
        ".env.example": Icon(symbol: "key", tint: .muted),
    ]

    private static let extensions: [String: Icon] = [
        "swift": Icon(symbol: "swift", tint: swiftOrange),
        "md": Icon(symbol: "doc.richtext", tint: .info),
        "markdown": Icon(symbol: "doc.richtext", tint: .info),
        "json": Icon(symbol: "curlybraces", tint: .warning),
        "yaml": Icon(symbol: "list.bullet.rectangle", tint: .secondary),
        "yml": Icon(symbol: "list.bullet.rectangle", tint: .secondary),
        "toml": Icon(symbol: "list.bullet.rectangle", tint: .secondary),
        "xml": Icon(symbol: "chevron.left.forwardslash.chevron.right", tint: .secondary),
        "plist": Icon(symbol: "list.bullet.rectangle", tint: .muted),
        "html": Icon(symbol: "chevron.left.forwardslash.chevron.right", tint: .error),
        "htm": Icon(symbol: "chevron.left.forwardslash.chevron.right", tint: .error),
        "css": Icon(symbol: "paintbrush", tint: .info),
        "scss": Icon(symbol: "paintbrush", tint: .error),
        "js": Icon(symbol: "curlybraces", tint: jsYellow),
        "jsx": Icon(symbol: "curlybraces", tint: jsYellow),
        "mjs": Icon(symbol: "curlybraces", tint: jsYellow),
        "ts": Icon(symbol: "curlybraces", tint: tsBlue),
        "tsx": Icon(symbol: "curlybraces", tint: tsBlue),
        "py": Icon(symbol: "chevron.left.forwardslash.chevron.right", tint: pythonBlue),
        "rb": Icon(symbol: "diamond", tint: .error),
        "go": Icon(symbol: "chevron.left.forwardslash.chevron.right", tint: .info),
        "rs": Icon(symbol: "gearshape.2", tint: .warning),
        "java": Icon(symbol: "cup.and.saucer", tint: .error),
        "kt": Icon(symbol: "chevron.left.forwardslash.chevron.right", tint: .accent),
        "c": Icon(symbol: "c.square", tint: .info),
        "h": Icon(symbol: "h.square", tint: .muted),
        "cpp": Icon(symbol: "plus.square", tint: .info),
        "sql": Icon(symbol: "cylinder.split.1x2", tint: .info),
        "sh": Icon(symbol: "terminal", tint: .success),
        "zsh": Icon(symbol: "terminal", tint: .success),
        "bash": Icon(symbol: "terminal", tint: .success),
        "png": Icon(symbol: "photo", tint: .success),
        "jpg": Icon(symbol: "photo", tint: .success),
        "jpeg": Icon(symbol: "photo", tint: .success),
        "gif": Icon(symbol: "photo", tint: .success),
        "svg": Icon(symbol: "square.on.circle", tint: .success),
        "pdf": Icon(symbol: "doc.richtext", tint: .error),
        "zip": Icon(symbol: "doc.zipper", tint: .muted),
        "lock": Icon(symbol: "lock", tint: .muted),
        "log": Icon(symbol: "text.alignleft", tint: .muted),
        "txt": Icon(symbol: "doc.plaintext", tint: .secondary),
        "csv": Icon(symbol: "tablecells", tint: .success),
    ]
}

extension RafuThemePalette {
    nonisolated func color(for tint: FileIconProvider.Tint) -> Color {
        switch tint {
        case .secondary: textSecondary
        case .muted: textMuted
        case .accent: accent
        case .info: info
        case .success: success
        case .warning: warning
        case .error: error
        case .fixed(let hex): Color(rafuHex: hex)
        }
    }
}

/// Loads and caches the bundled `Resources/FileIcons` SVGs. NSImage decodes
/// SVG natively on macOS 11+; the cache keeps one image per asset regardless
/// of how many rows render it.
@MainActor
enum FileIconAssets {
    private static var cache: [String: NSImage?] = [:]

    static func image(named name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        let candidates = [
            Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "FileIcons"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appending(path: "Resources/FileIcons/\(name).svg"),
        ]
        let image = candidates.compactMap { $0 }.compactMap(NSImage.init(contentsOf:)).first
        cache[name] = image
        return image
    }
}

/// Renders a `FileIconProvider.Icon`: the bundled asset when available
/// (template assets tinted like symbols), otherwise the SF Symbol.
struct FileIconView: View {
    let icon: FileIconProvider.Icon
    var size: CGFloat = 12
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        if let assetName = icon.assetName, let image = FileIconAssets.image(named: assetName) {
            if icon.assetIsTemplate {
                Image(nsImage: template(image))
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .foregroundStyle(theme.palette.color(for: icon.tint))
            } else {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            }
        } else {
            Image(systemName: icon.symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(theme.palette.color(for: icon.tint))
        }
    }

    private func template(_ image: NSImage) -> NSImage {
        image.isTemplate = true
        return image
    }
}
