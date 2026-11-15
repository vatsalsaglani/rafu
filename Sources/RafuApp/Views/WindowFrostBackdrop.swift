import AppKit
import SwiftUI

// The optional frosted window base (Settings ▸ Appearance ▸ Window
// background). Rules live in `WindowSurfacePreference`; this file holds the
// AppKit views.
//
// Spike evidence (macOS 27.2): one behind-window `NSVisualEffectView` below
// the SwiftUI content, with the theme's `appBackground` tint above it, shows
// the desktop through an ordinary opaque window. Liquid Glass (the AppKit
// glass view and the SwiftUI glass effect) samples only the window's own
// content and gives no desktop blur, so it is not used. `state = .active` keeps the
// frost while the window is inactive; `.followsWindowActiveState` would turn
// the frame flat grey every time focus moves to the terminal beside Rafu.

extension EnvironmentValues {
    /// The resolved window surface for this workspace window. Solid by
    /// default, and always Solid for the welcome window.
    @Entry var rafuWindowSurface: WindowSurfacePreference.Resolved = .solid
}

extension WindowSurfacePreference.Resolved {
    /// `color` as a fill on `layer`: unchanged in Solid (clear for
    /// `frostedBase`), at the layer's paint opacity in Frosted. Only backgrounds go through this; text,
    /// icons, strokes, selection and focus rings stay at full opacity.
    func fill(_ color: Color, _ layer: WindowSurfacePreference.DeckLayer) -> Color {
        let opacity = paintOpacity(for: layer)
        return opacity == 1 ? color : color.opacity(opacity)
    }
}

/// Paints one deck fill (`rafuDeckFill`). Solid: the opaque colour, as
/// before. Frosted: the colour at the layer's paint opacity.
private struct DeckFillModifier: ViewModifier {
    let color: Color
    let layer: WindowSurfacePreference.DeckLayer

    @Environment(\.rafuWindowSurface) private var windowSurface

    func body(content: Content) -> some View {
        content.background(windowSurface.fill(color, layer))
    }
}

private struct DeckShapeFillModifier<S: Shape>: ViewModifier {
    let color: Color
    let layer: WindowSurfacePreference.DeckLayer
    let shape: S

    @Environment(\.rafuWindowSurface) private var windowSurface

    func body(content: Content) -> some View {
        content.background(windowSurface.fill(color, layer), in: shape)
    }
}

extension View {
    /// A background inside the deck card that follows the frosted window
    /// base (ADR 0038). Use it for every full-region fill in the deck and
    /// on the Ensemble board, so no two translucent fills stack.
    func rafuDeckFill(
        _ color: Color, _ layer: WindowSurfacePreference.DeckLayer
    ) -> some View {
        modifier(DeckFillModifier(color: color, layer: layer))
    }

    /// `rafuDeckFill` in a shape (a capsule or rounded board control).
    func rafuDeckFill<S: Shape>(
        _ color: Color, _ layer: WindowSurfacePreference.DeckLayer, in shape: S
    ) -> some View {
        modifier(DeckShapeFillModifier(color: color, layer: layer, shape: shape))
    }
}

/// The behind-window effect settings, shared by the backdrop and the deck's
/// corner wedges so the two match pixel for pixel.
enum WindowFrostMaterial {
    static let material: NSVisualEffectView.Material = .hudWindow
    static let state: NSVisualEffectView.State = .active
    static let blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
}

/// The window-wide base: the blur lowest, then one theme tint. Mounted once
/// per window, below the workbench content, only while the surface is
/// Frosted. Frame surfaces paint nothing in that mode, so this one tint is
/// the frame colour everywhere; nested sidebar paints never stack.
struct WindowFrostBackdrop: View {
    let tint: Color
    let tintOpacity: Double

    var body: some View {
        ZStack {
            WindowFrostEffectView(mask: nil)
            tint.opacity(tintOpacity)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// An effect view that never takes a click: the frame's controls, drag
/// surfaces and the split handle above it keep every event.
final class WindowFrostPassthroughEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct WindowFrostEffectView: NSViewRepresentable {
    /// A corner mask image (deck wedges); nil for the full backdrop.
    let mask: NSImage?

    func makeNSView(context: Context) -> WindowFrostPassthroughEffectView {
        let view = WindowFrostPassthroughEffectView()
        view.isEmphasized = false
        Self.apply(mask: mask, to: view)
        return view
    }

    func updateNSView(_ view: WindowFrostPassthroughEffectView, context: Context) {
        Self.apply(mask: mask, to: view)
    }

    /// Writes a property only when it differs, so a repeated update does no
    /// AppKit work (the same rule as `FlatWindowChrome.applyChrome`).
    static func apply(mask: NSImage?, to view: NSVisualEffectView) {
        if view.blendingMode != WindowFrostMaterial.blendingMode {
            view.blendingMode = WindowFrostMaterial.blendingMode
        }
        if view.material != WindowFrostMaterial.material {
            view.material = WindowFrostMaterial.material
        }
        if view.state != WindowFrostMaterial.state { view.state = WindowFrostMaterial.state }
        if view.maskImage !== mask { view.maskImage = mask }
    }
}

/// Four small behind-window effect views at the deck's corners, each masked
/// (`maskImage`) to the region outside the rounded outline. The deck may not
/// clip its AppKit content, so in Frosted mode its corners show the frost
/// this way, above the square-cornered editor or terminal. A behind-window
/// view shows the desktop at its own screen position, so a wedge matches the
/// base backdrop. `maskImage`, not a layer or SwiftUI mask: those are not
/// reliable on a behind-window effect view.
struct WindowFrostWedges: View {
    let radius: CGFloat

    var body: some View {
        ZStack {
            corner(.topLeading)
            corner(.topTrailing)
            corner(.bottomLeading)
            corner(.bottomTrailing)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Twice the radius: a continuous corner's curve runs past `radius`.
    static func tile(radius: CGFloat) -> CGFloat { radius * 2 }

    private func corner(_ corner: Corner) -> some View {
        WindowFrostEffectView(mask: Self.mask(corner, radius: radius))
            .frame(width: Self.tile(radius: radius), height: Self.tile(radius: radius))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
    }

    enum Corner: CaseIterable, Hashable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var alignment: Alignment {
            switch self {
            case .topLeading: .topLeading
            case .topTrailing: .topTrailing
            case .bottomLeading: .bottomLeading
            case .bottomTrailing: .bottomTrailing
            }
        }

        var isLeading: Bool { self == .topLeading || self == .bottomLeading }
        var isTop: Bool { self == .topLeading || self == .topTrailing }
    }

    private struct MaskKey: Hashable {
        let corner: Corner
        let radius: CGFloat
    }

    /// One image per corner and radius, made once: `updateNSView` compares
    /// by identity, so a fresh image per body would rewrite `maskImage` on
    /// every update.
    private static var maskCache: [MaskKey: NSImage] = [:]

    /// Opaque where the wedge shows (outside the continuous rounded corner).
    static func mask(_ corner: Corner, radius: CGFloat) -> NSImage {
        let key = MaskKey(corner: corner, radius: radius)
        if let cached = maskCache[key] { return cached }
        let tile = tile(radius: radius)
        let big = tile * 3
        let x: CGFloat = corner.isLeading ? 0 : tile - big
        let y: CGFloat = corner.isTop ? 0 : tile - big
        let image = NSImage(size: NSSize(width: tile, height: tile), flipped: true) { rect in
            let rounded = Path(
                roundedRect: CGRect(x: x, y: y, width: big, height: big),
                cornerRadius: radius, style: .continuous
            ).cgPath
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addRect(rect)
            context.addPath(rounded)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath(using: .evenOdd)
            return true
        }
        maskCache[key] = image
        return image
    }
}
