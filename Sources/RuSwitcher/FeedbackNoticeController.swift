import AppKit

@MainActor
final class FeedbackNoticeController {
    final class NoticePanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class NoticeButton: NSButton {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private var panel: NSPanel?
    private var dismissal: DispatchWorkItem?
    private var undoAction: (() -> Void)?

    func show(message: String, undo: (() -> Void)? = nil) {
        dismiss()
        undoAction = undo
        let content = makeContent(message: message, offersUndo: undo != nil)
        let panel = Self.makePanel(content: content)
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 16,
                                         y: visible.maxY - panel.frame.height - 12))
        }
        self.panel = panel
        panel.orderFrontRegardless()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (undo == nil ? 3 : 7), execute: work)
    }

    static func makePanel(content: NSView) -> NoticePanel {
        let panel = NoticePanel(contentRect: NSRect(origin: .zero, size: content.frame.size),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = content
        content.layoutSubtreeIfNeeded()
        panel.invalidateShadow()
        return panel
    }

    func makeContent(message: String, offersUndo: Bool) -> NSView {
        let content = NSView()

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(labelWithString: ProductIdentity.displayName)
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = .secondaryLabelColor
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 13)
        label.preferredMaxLayoutWidth = 256
        let stack = NSStackView(views: [title, label])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        if offersUndo {
            let button = NoticeButton(title: L10n.noticeUndo, target: self, action: #selector(undoLearning))
            button.isBordered = false
            button.attributedTitle = NSAttributedString(string: L10n.noticeUndo, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.controlAccentColor,
            ])
            button.contentTintColor = .controlAccentColor
            button.setAccessibilityLabel(L10n.learningUndo)
            button.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.identifier = NSUserInterfaceItemIdentifier("notice.undo")
            stack.setCustomSpacing(8, after: label)
            stack.addArrangedSubview(button)
        }
        let close = NoticeButton(title: "", target: self, action: #selector(closeNotice))
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.setAccessibilityLabel(L10n.noticeClose)
        close.identifier = NSUserInterfaceItemIdentifier("notice.close")
        close.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(icon)
        content.addSubview(stack)
        content.addSubview(close)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 356),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor),
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            icon.topAnchor.constraint(equalTo: stack.topAnchor, constant: 2),
            stack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -38),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            label.widthAnchor.constraint(equalTo: stack.widthAnchor),
            close.widthAnchor.constraint(equalToConstant: 24),
            close.heightAnchor.constraint(equalTo: close.widthAnchor),
            close.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
        ])
        content.setFrameSize(content.fittingSize)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: content.frame)
            glass.style = .regular
            glass.cornerRadius = Self.cornerRadius
            glass.contentView = content
            return glass
        }
        let background = Self.makeLegacyBackground(frame: content.frame)
        content.autoresizingMask = [.width, .height]
        background.addSubview(content)
        return background
    }

    private static let cornerRadius: CGFloat = 26

    static func makeLegacyBackground(frame: NSRect) -> NSVisualEffectView {
        let background = NSVisualEffectView(frame: frame)
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        // maskImage shapes both the compositor material and the window shadow.
        // A CALayer cornerRadius alone leaves the backdrop rectangular.
        let size = NSSize(width: cornerRadius * 2 + 1, height: cornerRadius * 2 + 1)
        let mask = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius,
                                    bottom: cornerRadius, right: cornerRadius)
        mask.resizingMode = .stretch
        background.maskImage = mask
        return background
    }

    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        panel?.orderOut(nil)
        panel = nil
        undoAction = nil
    }

    @objc private func undoLearning() {
        let action = undoAction
        dismiss()
        action?()
    }

    @objc private func closeNotice() { dismiss() }
}
