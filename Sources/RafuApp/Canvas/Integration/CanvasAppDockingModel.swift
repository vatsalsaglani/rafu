import Foundation
import RafuCore

// Pure value logic for native app docking. Nothing here touches AppKit or the
// Accessibility API, so every rule can be tested without a window or a
// permission. `CanvasAppDocking` applies these decisions to real windows.

/// The coordinate chain for a docked window:
/// board units → board surface (top-left) → hosting view (top-left) →
/// window (bottom-left) → AppKit screen (bottom-left, global) →
/// Accessibility screen (top-left of the primary display, global).
nonisolated enum CanvasDockGeometry {
    /// The card header (32 pt) plus its 1 pt hairline, in board units.
    static let headerHeight = 33.0
    /// AX frames that differ by no more than this are the same frame.
    static let positionTolerance = 4.0
    /// Apps such as terminals round their size to whole cells. A size change
    /// at or below this is the app adjusting our request, not the user.
    static let sizeTolerance = 40.0

    /// The card body in board-surface coordinates (top-left origin, points).
    static func bodyRect(
        card: CGRect, translationX: Double, translationY: Double, scale: Double
    ) -> CGRect {
        let x = Double(card.minX) * scale + translationX
        let y = (Double(card.minY) + headerHeight) * scale + translationY
        let width = Double(card.width) * scale
        let height = max(0, Double(card.height) - headerHeight) * scale
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The visible board in the same space as `global`. SwiftUI reports the
    /// body frame both globally and in the board's named space; the difference
    /// is the board's origin.
    static func visibleBoard(global: CGRect, inBoard: CGRect, boardSize: CGSize) -> CGRect {
        CGRect(
            x: Double(global.minX) - Double(inBoard.minX),
            y: Double(global.minY) - Double(inBoard.minY),
            width: Double(boardSize.width), height: Double(boardSize.height))
    }

    /// A top-left rect in a view of `height` points, expressed bottom-left.
    /// Use it only for an unflipped view; a flipped view already uses top-left.
    static func flipped(_ rect: CGRect, inHeight height: Double) -> CGRect {
        CGRect(
            x: Double(rect.minX), y: height - Double(rect.maxY),
            width: Double(rect.width), height: Double(rect.height))
    }

    /// A window-coordinate rect (bottom-left) in AppKit screen coordinates.
    static func screenRect(window rect: CGRect, windowOrigin: CGPoint) -> CGRect {
        rect.offsetBy(dx: windowOrigin.x, dy: windowOrigin.y)
    }

    /// AppKit's global screen space has its origin at the bottom-left of the
    /// primary display and y grows upward. The Accessibility API uses the
    /// top-left of the same primary display with y growing downward. Every
    /// display shares this one flip, so a secondary display above the primary
    /// gets a negative AX y and one to the left keeps its negative x.
    static func axRect(screen rect: CGRect, primaryScreenHeight: Double) -> CGRect {
        flipped(rect, inHeight: primaryScreenHeight)
    }

    /// The inverse of `axRect`; the flip is its own inverse.
    static func screenRect(ax rect: CGRect, primaryScreenHeight: Double) -> CGRect {
        flipped(rect, inHeight: primaryScreenHeight)
    }

    /// True when `current` is still the frame Rafu placed, allowing for apps
    /// that round their size.
    static func isRafuPlacement(_ current: CGRect, expected: CGRect) -> Bool {
        abs(Double(current.minX) - Double(expected.minX)) <= positionTolerance
            && abs(Double(current.minY) - Double(expected.minY)) <= positionTolerance
            && abs(Double(current.width) - Double(expected.width)) <= sizeTolerance
            && abs(Double(current.height) - Double(expected.height)) <= sizeTolerance
    }

    /// An app can refuse a requested size or position. Never leave its real
    /// window outside the visible card body, apart from pixel rounding.
    static func fits(_ frame: CGRect, inside body: CGRect) -> Bool {
        body.insetBy(dx: -positionTolerance, dy: -positionTolerance).contains(frame)
    }
}

/// Why a docked window is out of the way for now. It returns by itself when
/// the reason ends.
nonisolated enum CanvasDockPauseReason: Equatable, Sendable {
    /// The card is not on screen: scrolled out, culled, or its board hidden.
    case notMounted
    /// The board zoom is below `CanvasDockVisibility.minimumZoom`.
    case zoomedOut
    /// Too little of the card body is inside the visible board.
    case offBoard
    /// The app's minimum size or placement rules prevent it fitting the body.
    case windowDoesNotFit
    /// Another card lies over this card's body.
    case covered
    /// The Rafu window is minimised, hidden, or fully covered.
    case windowHidden
    /// The user switched to an app other than Rafu or a docked app.
    case otherAppActive
    /// The Ensemble that holds the card is hidden or closed.
    case ensembleHidden
}

nonisolated enum CanvasDockPlacement: Equatable, Sendable {
    /// Put the window over this rect (same space as the inputs).
    case place(CGRect)
    case pause(CanvasDockPauseReason)
}

/// The inputs of one placement decision. Rects share one coordinate space.
nonisolated struct CanvasDockConditions: Equatable, Sendable {
    var isLive = true
    var isMounted = true
    var scale = 1.0
    var body: CGRect = .zero
    var visibleBoard: CGRect = .zero
    var isCovered = false
    var isHostWindowVisible = true
    var isFrontmostRafuOrDocked = true

    init(
        isLive: Bool = true, isMounted: Bool = true, scale: Double = 1,
        body: CGRect = .zero, visibleBoard: CGRect = .zero, isCovered: Bool = false,
        isHostWindowVisible: Bool = true, isFrontmostRafuOrDocked: Bool = true
    ) {
        self.isLive = isLive
        self.isMounted = isMounted
        self.scale = scale
        self.body = body
        self.visibleBoard = visibleBoard
        self.isCovered = isCovered
        self.isHostWindowVisible = isHostWindowVisible
        self.isFrontmostRafuOrDocked = isFrontmostRafuOrDocked
    }
}

nonisolated enum CanvasDockVisibility {
    /// Window text cannot scale with the board, so docking needs 75% or more.
    static let minimumZoom = 0.75
    /// The smallest visible body a window is placed over, in screen points.
    static let minimumVisibleWidth = 120.0
    static let minimumVisibleHeight = 80.0

    /// Ordered from the most to the least lasting reason, so the card shows
    /// the reason the user can act on.
    static func placement(_ conditions: CanvasDockConditions) -> CanvasDockPlacement {
        guard conditions.isLive else { return .pause(.ensembleHidden) }
        guard conditions.isHostWindowVisible else { return .pause(.windowHidden) }
        guard conditions.isFrontmostRafuOrDocked else { return .pause(.otherAppActive) }
        guard conditions.isMounted else { return .pause(.notMounted) }
        guard conditions.scale >= minimumZoom else { return .pause(.zoomedOut) }
        guard !conditions.isCovered else { return .pause(.covered) }
        let visible = conditions.body.intersection(conditions.visibleBoard)
        guard !visible.isNull, Double(visible.width) >= minimumVisibleWidth,
            Double(visible.height) >= minimumVisibleHeight
        else { return .pause(.offBoard) }
        return .place(visible.integral)
    }

    /// True when a card later in `cards` (drawn on top) overlaps `index`'s body.
    static func isCovered(index: Int, in cards: [CGRect]) -> Bool {
        guard cards.indices.contains(index) else { return false }
        let card = cards[index]
        let body = CGRect(
            x: Double(card.minX), y: Double(card.minY) + CanvasDockGeometry.headerHeight,
            width: Double(card.width),
            height: max(0, Double(card.height) - CanvasDockGeometry.headerHeight))
        return cards[(index + 1)...].contains { other in
            let overlap = other.intersection(body)
            return !overlap.isNull && overlap.width > 1 && overlap.height > 1
        }
    }
}

/// At most one window update per display frame. A burst of geometry changes
/// moves the window once now and once at the end of the frame interval.
nonisolated struct CanvasDockThrottle: Equatable, Sendable {
    var interval: Double
    private(set) var lastApply: Double?

    init(framesPerSecond: Int) {
        interval = 1 / Double(min(120, max(30, framesPerSecond)))
    }

    /// Seconds to wait before applying at `now`; zero means apply now.
    func delay(at now: Double) -> Double {
        guard let lastApply else { return 0 }
        return max(0, lastApply + interval - now)
    }

    mutating func recordApply(at now: Double) { lastApply = now }
}

nonisolated enum CanvasDockState: Equatable, Sendable {
    case notDocked
    case docking
    case docked
    case paused(CanvasDockPauseReason)
    /// The user moved, resized, minimised, or closed the window, or the app quit.
    case undocked(String)
    case needsPermission
    case failed(String)

    /// The short state word for headers and VoiceOver.
    var label: String {
        switch self {
        case .notDocked: "Not docked"
        case .docking: "Docking"
        case .docked, .paused: "Docked"
        case .undocked: "Undocked"
        case .needsPermission: "Needs permission"
        case .failed: "Not docked"
        }
    }

    var isDocked: Bool {
        switch self {
        case .docked, .paused: true
        default: false
        }
    }

    /// One plain sentence for the card body, or nil.
    func detail(appName: String, identity: RafuAppIdentity = .current) -> String? {
        switch self {
        case .notDocked, .docked: nil
        case .docking: "Opening \(appName) and finding its window…"
        case .paused(let reason):
            switch reason {
            case .zoomedOut:
                "Zoom to 75% or more to use \(appName) here."
            case .covered:
                "Another card covers this one. Move it to show \(appName)."
            case .offBoard:
                "Scroll this card into view to show \(appName)."
            case .windowDoesNotFit:
                "\(appName) cannot fit in this card. Make the card larger and keep it fully in view."
            case .otherAppActive, .windowHidden, .notMounted, .ensembleHidden:
                "\(appName) is put away until this card is visible."
            }
        case .undocked(let reason), .failed(let reason): reason
        case .needsPermission:
            "Allow app control for \(identity.displayName) in System Settings ▸ Privacy & Security."
        }
    }
}

/// One node of an Accessibility tree, reduced to the fields a summary reads.
nonisolated protocol CanvasAXSummaryNode {
    var role: String? { get }
    var subrole: String? { get }
    var title: String? { get }
    /// A text or number value. Never read for a secure text field.
    var value: String? { get }
    var frame: CGRect? { get }
    func children(limit: Int) -> [Self]
}

/// A bounded, read-only, plain-text summary of a window's Accessibility tree.
nonisolated enum CanvasAXSummary {
    static let maximumBytes = 16 * 1_024
    static let maximumDepth = 8
    static let maximumNodes = 1_500
    static let maximumChildren = 200
    static let maximumFieldCharacters = 200
    static let secureRole = "AXSecureTextField"
    static let truncationMarker = "… (summary truncated)"

    static func isSecure(role: String?, subrole: String?) -> Bool {
        role == secureRole || subrole == secureRole
    }

    /// One line of user-visible text: no control characters, bounded length.
    static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let scalars = text.unicodeScalars.prefix(maximumFieldCharacters * 4).map {
            CharacterSet.controlCharacters.contains($0) ? " " : Character($0)
        }
        let line = String(scalars).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        guard line.count > maximumFieldCharacters else { return line }
        return String(line.prefix(maximumFieldCharacters)) + "…"
    }

    /// Depth-first, depth- node- and byte-bounded. A node whose frame lies
    /// outside `visibleRect` is skipped with its subtree. A secure text field
    /// contributes its role and title only: its value and children are never read.
    static func summarize<Node: CanvasAXSummaryNode>(
        root: Node, header: String, visibleRect: CGRect? = nil,
        shouldContinue: () -> Bool = { true }
    ) -> String {
        var output = ""
        var bytes = 0
        let budget = maximumBytes - truncationMarker.utf8.count - 1
        func append(_ line: String) -> Bool {
            let size = line.utf8.count + 1
            guard bytes + size <= budget else { return false }
            output += line + "\n"
            bytes += size
            return true
        }
        guard append(clean(header) ?? "Accessibility summary") else { return truncationMarker }
        var stack: [(Node, Int)] = [(root, 0)]
        var visited = 0
        while let entry = stack.popLast() {
            let (node, depth) = entry
            guard visited < maximumNodes, shouldContinue() else {
                output += truncationMarker
                return output
            }
            visited += 1
            if let visibleRect, let frame = node.frame, !frame.isEmpty,
                !frame.intersects(visibleRect)
            {
                continue
            }
            let role = node.role
            let subrole = node.subrole
            let secure = isSecure(role: role, subrole: subrole)
            var line = String(repeating: "  ", count: depth)
            line += clean(secure ? secureRole : role) ?? "AXUnknown"
            if let title = clean(node.title) { line += " \"\(title)\"" }
            if secure {
                line += " (value hidden)"
            } else if let value = clean(node.value) {
                line += " = \"\(value)\""
            }
            guard append(line) else {
                output += truncationMarker
                return output
            }
            guard !secure, depth < maximumDepth else { continue }
            // Reverse so the stack visits children in their on-screen order.
            for child in node.children(limit: maximumChildren).reversed() {
                stack.append((child, depth + 1))
            }
        }
        return output
    }
}
