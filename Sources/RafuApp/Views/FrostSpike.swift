// SPIKE — NOT FOR MERGE AS-IS.
//
// Step 0 of the optional frosted window base. Every behaviour here is behind
// the debug default `RafuFrostSpike`; with it unset Rafu paints exactly as
// before. Read with `defaults write dev.vatsalsaglani.rafu.lightning <key>`:
//
//   RafuFrostSpike          visualEffect | glass | glassClear | swiftUIGlass | container
//   RafuFrostSpikeMaterial  underWindowBackground | sidebar | hudWindow | windowBackground
//                           | fullScreenUI | headerView | menu | popover | contentBackground
//   RafuFrostSpikeState     active | follows                       (visual effect only)
//   RafuFrostSpikeTint      0.0 … 1.0 (frame tint opacity of appBackground, default 0.74)
//   RafuFrostSpikeWedge     masked | clip | flat                   (deck corners)
//   RafuFrostSpikeClear     true | false (window isOpaque = false + clear background)

import AppKit
import SwiftUI

nonisolated struct FrostSpikeConfig: Equatable, Sendable {
    enum Mechanism: String, Sendable {
        case visualEffect, glass, glassClear, swiftUIGlass, container
    }

    enum Wedge: String, Sendable { case masked, clip, flat }

    var mechanism: Mechanism
    var material: String
    var followsActiveState: Bool
    var tint: Double
    var wedge: Wedge
    var clearWindow: Bool

    static func resolve(
        mechanism: String, material: String, state: String, tint: Double, wedge: String,
        clearWindow: Bool
    ) -> FrostSpikeConfig? {
        guard let mechanism = Mechanism(rawValue: mechanism) else { return nil }
        return FrostSpikeConfig(
            mechanism: mechanism,
            material: material,
            followsActiveState: state == "follows",
            tint: tint <= 0 ? 0.74 : min(tint, 1),
            wedge: Wedge(rawValue: wedge) ?? .masked,
            clearWindow: clearWindow
        )
    }

    var nsMaterial: NSVisualEffectView.Material {
        switch material {
        case "sidebar": .sidebar
        case "hudWindow": .hudWindow
        case "windowBackground": .windowBackground
        case "fullScreenUI": .fullScreenUI
        case "headerView": .headerView
        case "menu": .menu
        case "popover": .popover
        case "contentBackground": .contentBackground
        default: .underWindowBackground
        }
    }

    var effectState: NSVisualEffectView.State {
        followsActiveState ? .followsWindowActiveState : .active
    }

    /// The deck corners need a behind-window view of their own only when the
    /// frame is see-through and the card is not clipped.
    var needsMaskedWedges: Bool { wedge == .masked }
}

extension EnvironmentValues {
    @Entry var rafuFrostSpike: FrostSpikeConfig?
}

/// Frame paint site: the token when the spike is off, nothing when it is on.
struct FrostSpikeFrameFill: ViewModifier {
    let color: Color
    @Environment(\.rafuFrostSpike) private var spike

    func body(content: Content) -> some View {
        content.background(spike == nil ? color : Color.clear)
    }
}

extension View {
    func frostSpikeFrame(_ color: Color) -> some View {
        modifier(FrostSpikeFrameFill(color: color))
    }
}

/// The window-wide base: blur (or glass) lowest, then one theme tint.
struct FrostSpikeBackdrop: View {
    let config: FrostSpikeConfig
    let tint: Color

    var body: some View {
        ZStack {
            switch config.mechanism {
            case .visualEffect:
                FrostSpikeEffectView(config: config, mask: nil)
                tint.opacity(config.tint)
            case .glass, .glassClear:
                FrostSpikeGlassView(config: config, tint: tint)
            case .swiftUIGlass:
                if #available(macOS 26.0, *) {
                    Color.clear
                        .glassEffect(
                            .regular.tint(tint.opacity(config.tint)), in: Rectangle())
                } else {
                    tint
                }
            case .container:
                tint.opacity(config.tint)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// An effect view that never takes a click.
final class FrostSpikePassthroughEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class FrostSpikePassthroughGlassView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct FrostSpikeEffectView: NSViewRepresentable {
    let config: FrostSpikeConfig
    /// A corner mask image (wedge use); nil for the full backdrop.
    let mask: NSImage?

    func makeNSView(context: Context) -> FrostSpikePassthroughEffectView {
        let view = FrostSpikePassthroughEffectView()
        view.blendingMode = .behindWindow
        view.isEmphasized = false
        update(view)
        return view
    }

    func updateNSView(_ view: FrostSpikePassthroughEffectView, context: Context) {
        update(view)
    }

    private func update(_ view: FrostSpikePassthroughEffectView) {
        if view.material != config.nsMaterial { view.material = config.nsMaterial }
        if view.state != config.effectState { view.state = config.effectState }
        if view.maskImage !== mask { view.maskImage = mask }
        if let window = view.window { FrostSpikeWindowOpacity.apply(config, to: window) }
    }
}

/// `NSGlassEffectView` (macOS 26+). Glass samples the content behind it; the
/// spike checks whether, as a window base, that includes the desktop.
struct FrostSpikeGlassView: NSViewRepresentable {
    let config: FrostSpikeConfig
    let tint: Color

    func makeNSView(context: Context) -> NSView {
        let host = FrostSpikePassthroughGlassView()
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(glass)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                glass.topAnchor.constraint(equalTo: host.topAnchor),
                glass.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
        }
        updateNSView(host, context: context)
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        if #available(macOS 26.0, *), let glass = host.subviews.first as? NSGlassEffectView {
            glass.style = config.mechanism == .glassClear ? .clear : .regular
            glass.cornerRadius = 0
            glass.tintColor = NSColor(tint).withAlphaComponent(config.tint)
        }
        if let window = host.window { FrostSpikeWindowOpacity.apply(config, to: window) }
    }
}

/// Optional `isOpaque = false` for the glass checks (glass may sample only
/// the window's own backing).
@MainActor enum FrostSpikeWindowOpacity {
    static func apply(_ config: FrostSpikeConfig, to window: NSWindow) {
        let wantsOpaque = !config.clearWindow
        if window.isOpaque != wantsOpaque { window.isOpaque = wantsOpaque }
    }
}

/// Four small behind-window effect views at the deck's corners, each masked
/// (`maskImage`) to the region outside the rounded outline. They sit in the
/// deck's overlay, above the AppKit editor/terminal.
struct FrostSpikeWedgeBackdrops: View {
    let config: FrostSpikeConfig
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
    private var tile: CGFloat { radius * 2 }

    private func corner(_ alignment: Alignment) -> some View {
        FrostSpikeEffectView(config: config, mask: Self.mask(alignment, radius: radius))
            .frame(width: tile, height: tile)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    /// Opaque where the wedge shows (outside the continuous rounded corner).
    static func mask(_ alignment: Alignment, radius: CGFloat) -> NSImage {
        let tile = radius * 2
        let big = tile * 3
        return NSImage(size: NSSize(width: tile, height: tile), flipped: true) { rect in
            let x: CGFloat =
                (alignment == .topLeading || alignment == .bottomLeading) ? 0 : tile - big
            let y: CGFloat =
                (alignment == .topLeading || alignment == .topTrailing) ? 0 : tile - big
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
    }
}

/// `.containerBackground(_:for: .window)` variant (macOS 15+).
struct FrostSpikeContainerBackground: ViewModifier {
    let config: FrostSpikeConfig?

    func body(content: Content) -> some View {
        if config?.mechanism == .container {
            content.containerBackground(.ultraThinMaterial, for: .window)
        } else {
            content
        }
    }
}

/// The "clip" wedge mode: round the deck by clipping it (no wedges).
struct FrostSpikeDeckClip: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.clipShape(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusWorkbenchDeck, style: .continuous))
        } else {
            content
        }
    }
}
