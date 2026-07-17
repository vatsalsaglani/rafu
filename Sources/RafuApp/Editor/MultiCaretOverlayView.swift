import AppKit

/// Non-interactive drawing layer for zero-length carets AppKit drops from
/// `selectedRanges`. It sits above the text view's glyphs and never
/// participates in hit testing or accessibility navigation.
final class MultiCaretOverlayView: NSView {
    private(set) var caretRects: [NSRect] = []
    private(set) var isBlinking = false
    private(set) var caretsVisible = true

    private var caretColor = NSColor.textColor
    private var reduceMotion = false
    private var blinkTimer: Timer?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        blinkTimer?.invalidate()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restartBlinking()
    }

    func update(caretRects: [NSRect], color: NSColor, reduceMotion: Bool) {
        let geometryChanged = self.caretRects != caretRects
        let colorChanged = !caretColor.isEqual(color)
        let motionChanged = self.reduceMotion != reduceMotion
        self.caretRects = caretRects
        caretColor = color
        self.reduceMotion = reduceMotion
        if geometryChanged || motionChanged {
            restartBlinking()
        }
        if geometryChanged || colorChanged || motionChanged {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard caretsVisible else { return }
        caretColor.setFill()
        for caretRect in caretRects where caretRect.intersects(dirtyRect) {
            caretRect.intersection(dirtyRect).fill()
        }
    }

    private func restartBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        caretsVisible = true
        isBlinking = false
        needsDisplay = true

        guard window != nil, !caretRects.isEmpty, !reduceMotion else { return }
        isBlinking = true
        let timer = Timer(timeInterval: 0.53, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.caretsVisible.toggle()
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }
}
