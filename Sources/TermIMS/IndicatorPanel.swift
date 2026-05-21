import Cocoa

class IndicatorPanel: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private var hideTimer: Timer?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 180, height: 44),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .transient]

        let bg = NSView(frame: contentView!.bounds)
        bg.autoresizingMask = [.width, .height]
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.9).cgColor
        bg.layer?.cornerRadius = 10
        bg.layer?.masksToBounds = true
        contentView?.addSubview(bg)

        label.alignment = .center
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: bg.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: bg.trailingAnchor, constant: -12),
        ])
    }

    func show(text: String, position: IndicatorPosition) {
        label.stringValue = text
        label.sizeToFit()
        let w = max(label.frame.width + 40, 100)
        let h: CGFloat = 44
        setContentSize(NSSize(width: w, height: h))

        guard let s = NSScreen.main else { return }
        let mx: CGFloat = 60
        let my: CGFloat = 60
        let pt: NSPoint
        switch position {
        case .screenCenter:
            pt = NSPoint(x: s.frame.midX - w / 2, y: s.frame.midY - h / 2)
        case .centerBottom:
            pt = NSPoint(x: s.frame.midX - w / 2, y: s.frame.minY + my)
        case .topLeft:
            pt = NSPoint(x: s.frame.minX + mx, y: s.frame.maxY - h - my)
        case .topRight:
            pt = NSPoint(x: s.frame.maxX - w - mx, y: s.frame.maxY - h - my)
        case .bottomLeft:
            pt = NSPoint(x: s.frame.minX + mx, y: s.frame.minY + my)
        case .bottomRight:
            pt = NSPoint(x: s.frame.maxX - w - mx, y: s.frame.minY + my)
        }
        setFrameOrigin(pt)
        alphaValue = 1
        orderFrontRegardless()

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                self?.animator().alphaValue = 0
            }, completionHandler: { self?.orderOut(nil) })
        }
    }
}
