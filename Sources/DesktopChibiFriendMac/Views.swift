import AppKit

final class TransparentPanel: NSPanel {
    init(frame: CGRect, level: NSWindow.Level = .floating) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class PetView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var facesRight = true { didSet { needsDisplay = true } }
    var onPoke: (() -> Void)?
    var onRightClick: (() -> Void)?
    var onDragBegan: ((NSEvent) -> Void)?
    var onDragged: ((NSEvent) -> Void)?
    var onDragEnded: ((NSEvent) -> Void)?
    var onPetting: (() -> Void)?
    private var downPoint = NSPoint.zero
    private var lastPoint = NSPoint.zero
    private var moved = false
    private var petDistance: CGFloat = 0
    private var directionChanges = 0
    private var lastHorizontalSign: CGFloat = 0

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        NSGraphicsContext.saveGraphicsState()
        if !facesRight {
            let transform = NSAffineTransform()
            transform.translateX(by: bounds.maxX, yBy: 0)
            transform.scaleX(by: -1, yBy: 1)
            transform.concat()
        }
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
        lastPoint = downPoint
        moved = false
        petDistance = 0
        directionChanges = 0
        lastHorizontalSign = 0
        onDragBegan?(event)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = event.locationInWindow
        let delta = point.x - lastPoint.x
        petDistance += abs(delta)
        let sign: CGFloat = delta == 0 ? 0 : (delta > 0 ? 1 : -1)
        if sign != 0, lastHorizontalSign != 0, sign != lastHorizontalSign { directionChanges += 1 }
        if sign != 0 { lastHorizontalSign = sign }
        lastPoint = point
        moved = moved || hypot(point.x - downPoint.x, point.y - downPoint.y) > 5
        if downPoint.y > bounds.height * 0.56, directionChanges >= 3, petDistance < bounds.width * 1.5 {
            onPetting?()
            petDistance = 0
            directionChanges = 0
        } else {
            onDragged?(event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if moved { onDragEnded?(event) } else { onPoke?() }
    }

    override func rightMouseUp(with event: NSEvent) { onRightClick?() }
}

final class BubbleView: NSView {
    let label = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.88, green: 0.97, blue: 0.99, alpha: 0.97).cgColor
        layer?.borderColor = NSColor(calibratedRed: 0.24, green: 0.71, blue: 0.83, alpha: 1).cgColor
        layer?.borderWidth = 2
        layer?.cornerRadius = 14
        label.alignment = .center
        label.textColor = NSColor(calibratedRed: 0.10, green: 0.25, blue: 0.31, alpha: 1)
        label.font = .systemFont(ofSize: 14)
        label.maximumNumberOfLines = 2
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }
    override func layout() { label.frame = bounds.insetBy(dx: 12, dy: 7) }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

final class ObjectView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var onDrag: ((NSEvent.Phase, NSEvent) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) { image?.draw(in: bounds) }
    override func mouseDown(with event: NSEvent) { onDrag?(.began, event) }
    override func mouseDragged(with event: NSEvent) { onDrag?(.changed, event) }
    override func mouseUp(with event: NSEvent) { onDrag?(.ended, event) }
}

final class CaveView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let body = NSBezierPath(ovalIn: bounds.insetBy(dx: bounds.width * 0.08, dy: bounds.height * 0.05))
        NSColor(calibratedRed: 0.72, green: 0.58, blue: 0.70, alpha: 0.96).setFill()
        body.fill()
        let crystals = NSBezierPath()
        for i in 0..<7 {
            let x = bounds.width * (0.18 + CGFloat(i) * 0.105)
            crystals.move(to: NSPoint(x: x, y: bounds.height * 0.84))
            crystals.line(to: NSPoint(x: x - 8, y: bounds.height * 0.62))
            crystals.line(to: NSPoint(x: x + 8, y: bounds.height * 0.62))
            crystals.close()
        }
        NSColor(calibratedRed: 0.96, green: 0.74, blue: 0.79, alpha: 1).setFill()
        crystals.fill()
        let entrance = NSBezierPath(roundedRect: NSRect(x: bounds.width * 0.26, y: 0, width: bounds.width * 0.48, height: bounds.height * 0.68), xRadius: bounds.width * 0.22, yRadius: bounds.width * 0.22)
        NSColor(calibratedRed: 0.18, green: 0.14, blue: 0.25, alpha: 1).setFill()
        entrance.fill()
    }
}
