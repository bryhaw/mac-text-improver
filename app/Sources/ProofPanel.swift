import AppKit

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Button that fires its handler closure.
private final class ActionButton: NSButton {
    private var handler: (() -> Void)?

    convenience init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [], primary: Bool = false, handler: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        self.handler = handler
        bezelStyle = .rounded
        controlSize = .regular
        keyEquivalent = key
        keyEquivalentModifierMask = modifiers
        if primary { bezelColor = .controlAccentColor }
        target = self
        action = #selector(fire)
    }

    @objc private func fire() { handler?() }
}

/// The floating panel that shows progress, the suggested changes, and results.
final class ProofPanel {
    private let panel: HUDPanel
    private var escMonitor: Any?
    private var dismissWork: DispatchWorkItem?
    private var anchor: NSRect?
    private var onEscape: (() -> Void)?

    init() {
        panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 80),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    var isVisible: Bool { panel.isVisible }

    func setAnchor(_ rect: NSRect?) { anchor = rect }

    // MARK: - States

    func showLoading(_ message: String, onCancel: @escaping () -> Void) {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)

        let title = label(message, size: 13, weight: .semibold)
        let hint = label("esc to cancel", size: 11, color: .tertiaryLabelColor)
        let row = hstack([spinner, title, spacer(), hint], spacing: 10)
        row.widthAnchor.constraint(equalToConstant: 300).isActive = true
        present(row, interactive: false, onEscape: onCancel)
    }

    func showPreview(original: String, corrected: String, detail: String, note: String?, polishAvailable: Bool,
                     onReplace: @escaping () -> Void, onCopy: @escaping () -> Void,
                     onPolish: @escaping () -> Void, onCancel: @escaping () -> Void) {
        let ops = TextDiff.diff(original, corrected)
        let count = TextDiff.changeCount(ops)
        let width: CGFloat = 520

        let icon = symbol("checkmark.seal.fill", color: .controlAccentColor)
        let title = label(count == 1 ? "1 suggested change" : "\(count) suggested changes", size: 13, weight: .semibold)
        let meta = label(detail, size: 11, color: .secondaryLabelColor)
        let header = hstack([icon, title, spacer(), meta], spacing: 8)

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.textStorage?.setAttributedString(TextDiff.attributed(ops, font: .systemFont(ofSize: 13.5)))
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: width - 8, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 40
        let height = min(max(used + 14, 36), 300)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: width),
            scroll.heightAnchor.constraint(equalToConstant: height),
        ])

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.55).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: box.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])

        var rows: [NSView] = [header, box]
        if let note { rows.append(label(note, size: 11, color: .secondaryLabelColor)) }

        let cancel = ActionButton("Cancel", key: "\u{1b}", handler: onCancel)
        let copy = ActionButton("Copy", key: "c", modifiers: .command, handler: onCopy)
        let replace = ActionButton("Replace", key: "\r", primary: true, handler: onReplace)
        var buttons: [NSView] = [label("↩ replace  ·  ⌘C copy  ·  esc cancel", size: 11, color: .tertiaryLabelColor), spacer(), cancel]
        if polishAvailable {
            buttons.append(ActionButton("Improve Wording", key: "p", modifiers: .command, handler: onPolish))
        }
        buttons += [copy, replace]
        rows.append(hstack(buttons, spacing: 8))

        let stack = vstack(rows, spacing: 10)
        present(stack, interactive: true, onEscape: onCancel)
        panel.makeFirstResponder(replace)
    }

    func showToast(_ message: String, symbolName: String = "checkmark.circle.fill", color: NSColor = .systemGreen,
                   detail: NSAttributedString? = nil, duration: TimeInterval = 1.8) {
        let icon = symbol(symbolName, color: color)
        let title = label(message, size: 13, weight: .semibold)
        var rows: [NSView] = [hstack([icon, title], spacing: 8)]
        if let detail {
            let text = NSTextField(labelWithAttributedString: detail)
            text.maximumNumberOfLines = 6
            text.lineBreakMode = .byTruncatingTail
            text.preferredMaxLayoutWidth = 440
            rows.append(text)
        }
        present(vstack(rows, spacing: 8), interactive: false, onEscape: { [weak self] in self?.close() })
        scheduleDismiss(after: duration)
    }

    func showError(_ message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        let icon = symbol("exclamationmark.triangle.fill", color: .systemOrange)
        let text = label(message, size: 13)
        text.preferredMaxLayoutWidth = 360
        text.maximumNumberOfLines = 0
        text.lineBreakMode = .byWordWrapping
        var buttons: [NSView] = [spacer(), ActionButton("Dismiss") { [weak self] in self?.close() }]
        if let actionTitle, let action {
            buttons.append(ActionButton(actionTitle, primary: true) { [weak self] in
                self?.close()
                action()
            })
        }
        let stack = vstack([hstack([icon, text], spacing: 10, alignment: .top), hstack(buttons, spacing: 8)], spacing: 12)
        stack.widthAnchor.constraint(equalToConstant: 400).isActive = true
        present(stack, interactive: false, onEscape: { [weak self] in self?.close() })
        scheduleDismiss(after: 10)
    }

    func close() {
        dismissWork?.cancel()
        dismissWork = nil
        removeEscMonitor()
        onEscape = nil
        panel.orderOut(nil)
    }

    // MARK: - Presentation

    private func present(_ content: NSView, interactive: Bool, onEscape: @escaping () -> Void) {
        dismissWork?.cancel()
        dismissWork = nil
        self.onEscape = onEscape

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true

        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -14),
        ])
        panel.contentView = effect
        effect.layoutSubtreeIfNeeded()
        let size = effect.fittingSize
        panel.setFrame(NSRect(origin: origin(for: size), size: size), display: true)

        if interactive {
            removeEscMonitor()
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
            installEscMonitor()
        }
    }

    private func origin(for size: NSSize) -> NSPoint {
        let gap: CGFloat = 10
        if let anchor, let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) {
            let visible = screen.visibleFrame
            var y = anchor.minY - gap - size.height
            if y < visible.minY { y = anchor.maxY + gap }
            if y + size.height > visible.maxY { y = visible.maxY - size.height - gap }
            let x = min(max(anchor.minX, visible.minX + gap), visible.maxX - size.width - gap)
            return NSPoint(x: x, y: max(y, visible.minY + gap))
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        return NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - visible.height * 0.18)
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in self?.close() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func installEscMonitor() {
        removeEscMonitor()
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            DispatchQueue.main.async { self?.onEscape?() }
        }
    }

    private func removeEscMonitor() {
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
    }

    // MARK: - View helpers

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func symbol(_ name: String, color: NSColor) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        view.contentTintColor = color
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }

    private func hstack(_ views: [NSView], spacing: CGFloat, alignment: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = spacing
        stack.alignment = alignment
        return stack
    }

    private func vstack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = spacing
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views where view is NSStackView {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }
}
