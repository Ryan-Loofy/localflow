import AppKit

enum PillState {
    case recordingHeld
    case recordingHandsFree
    case transcribing
    case error(String)
}

@MainActor
final class FloatingPillController {
    private let panel: NSPanel
    private let pillView: PillView
    private var hideTask: Task<Void, Never>?

    init() {
        let frame = NSRect(x: 0, y: 0, width: 188, height: 38)
        pillView = PillView(frame: frame)
        panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = pillView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    func show(_ state: PillState) {
        hideTask?.cancel()
        pillView.state = state
        positionPanel()
        panel.orderFrontRegardless()
        if case .error = state {
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel.orderOut(nil)
    }

    private func positionPanel() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.minY + 56
        )
        panel.setFrameOrigin(origin)
    }
}

private final class PillView: NSView {
    var state: PillState = .recordingHeld { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 18, yRadius: 18)
        NSColor(calibratedWhite: 0.08, alpha: 0.93).setFill()
        background.fill()

        let (color, title): (NSColor, String) = {
            switch state {
            case .recordingHeld: return (.systemRed, "Recording · hold")
            case .recordingHandsFree: return (.systemOrange, "Recording · hands-free")
            case .transcribing: return (.systemBlue, "Transcribing…")
            case .error(let message): return (.systemRed, String(message.prefix(28)))
            }
        }()

        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 14, y: bounds.midY - 4, width: 8, height: 8)).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let text = NSAttributedString(string: title, attributes: attributes)
        let textSize = text.size()
        text.draw(at: NSPoint(x: 30, y: bounds.midY - textSize.height / 2))
    }
}
