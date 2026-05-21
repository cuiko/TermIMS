import Cocoa
import ApplicationServices

class PermissionWindowController: NSWindowController {
    private var pollTimer: Timer?
    var onGranted: (() -> Void)?

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "TermIMS"
        w.center()
        w.isReleasedWhenClosed = false
        self.init(window: w)
        buildUI()
    }

    private func buildUI() {
        guard let cv = window?.contentView else { return }

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 36, weight: .light)
        icon.contentTintColor = .secondaryLabelColor

        let title = NSTextField(labelWithString: "Accessibility Permission Required")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 16, weight: .semibold)

        let desc = NSTextField(wrappingLabelWithString:
            "TermIMS needs accessibility access to detect app switches and change input methods. Please enable it in System Settings > Privacy & Security > Accessibility.")
        desc.translatesAutoresizingMaskIntoConstraints = false
        desc.font = .systemFont(ofSize: 12)
        desc.textColor = .secondaryLabelColor

        let openBtn = NSButton(title: "Open System Settings", target: self, action: #selector(openSettings))
        openBtn.translatesAutoresizingMaskIntoConstraints = false
        openBtn.bezelStyle = .rounded
        openBtn.keyEquivalent = "\r"

        let quitBtn = NSButton(title: "Quit", target: self, action: #selector(quitApp))
        quitBtn.translatesAutoresizingMaskIntoConstraints = false
        quitBtn.bezelStyle = .rounded

        for sub in [icon, title, desc, openBtn, quitBtn] { cv.addSubview(sub) }
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: cv.topAnchor, constant: 24),
            icon.centerXAnchor.constraint(equalTo: cv.centerXAnchor),

            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
            title.centerXAnchor.constraint(equalTo: cv.centerXAnchor),

            desc.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            desc.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 32),
            desc.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -32),

            openBtn.topAnchor.constraint(equalTo: desc.bottomAnchor, constant: 16),
            openBtn.trailingAnchor.constraint(equalTo: cv.centerXAnchor, constant: -6),
            openBtn.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -16),

            quitBtn.topAnchor.constraint(equalTo: desc.bottomAnchor, constant: 16),
            quitBtn.leadingAnchor.constraint(equalTo: cv.centerXAnchor, constant: 6),
            quitBtn.widthAnchor.constraint(equalTo: openBtn.widthAnchor),
        ])
    }

    func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            if AXIsProcessTrusted() {
                self?.pollTimer?.invalidate()
                self?.pollTimer = nil
                self?.window?.close()
                self?.onGranted?()
            }
        }
    }

    @objc private func openSettings() {
        AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
