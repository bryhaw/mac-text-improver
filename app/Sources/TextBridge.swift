import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Captures and restores everything on the general pasteboard so borrowing it is invisible to the user.
struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture() -> PasteboardSnapshot {
        let items = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            return entry
        }
        return PasteboardSnapshot(items: items)
    }

    func restore() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}

struct GrabbedText {
    let text: String
    /// True when nothing was selected and the whole field was selected for the user.
    let selectedAll: Bool
    /// Formatted copy of the same content (HTML or RTF), used to keep images, links, and styling on replace.
    let rich: RichSource?
}

enum TextBridge {
    /// Clipboard-manager convention for "don't record this entry".
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Waits for the user to let go of the hotkey's modifiers so synthesized ⌘C/⌘V aren't mixed with ⌃⌥.
    static func waitForModifierRelease(timeout: TimeInterval = 1.5) async {
        let deadline = Date().addingTimeInterval(timeout)
        let held: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        while Date() < deadline {
            if CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Copies the current selection. If nothing is selected, selects the whole focused field first.
    static func grabSelection() async -> GrabbedText? {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var baseline = pasteboard.changeCount

        sendShortcut(UInt16(kVK_ANSI_C))
        if let (text, rich) = await waitForText(after: baseline), !text.isEmpty {
            return GrabbedText(text: text, selectedAll: false, rich: rich)
        }

        baseline = pasteboard.changeCount
        sendShortcut(UInt16(kVK_ANSI_A))
        try? await Task.sleep(nanoseconds: 80_000_000)
        sendShortcut(UInt16(kVK_ANSI_C))
        if let (text, rich) = await waitForText(after: baseline), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return GrabbedText(text: text, selectedAll: true, rich: rich)
        }
        return nil
    }

    /// Pastes `text` over the current selection in the frontmost app, then puts the user's clipboard back.
    /// When `rich` is given, apps that accept formatted paste get it, so images and links survive.
    static func paste(_ text: String, rich: RichPayload? = nil, restoring snapshot: PasteboardSnapshot) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, transientType], owner: nil)
        rich?.write(to: pasteboard)
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: transientType)
        let ours = pasteboard.changeCount

        sendShortcut(UInt16(kVK_ANSI_V))
        // Give the target app time to read the pasteboard before we swap the user's content back.
        try? await Task.sleep(nanoseconds: 700_000_000)
        if pasteboard.changeCount == ours { snapshot.restore() }
    }

    static func copyToClipboard(_ text: String, rich: RichPayload? = nil) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        rich?.write(to: pasteboard)
        pasteboard.setString(text, forType: .string)
    }

    private static func waitForText(after baseline: Int, timeout: TimeInterval = 0.6) async -> (String, RichSource?)? {
        let deadline = Date().addingTimeInterval(timeout)
        let pasteboard = NSPasteboard.general
        while Date() < deadline {
            if pasteboard.changeCount != baseline {
                // Some apps publish the change before the string is readable.
                try? await Task.sleep(nanoseconds: 30_000_000)
                guard let text = pasteboard.string(forType: .string) else { return nil }
                return (text, RichSource.fromPasteboard(pasteboard))
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return nil
    }

    /// Deselects text we selected with ⌘A, leaving the caret at the end so typing won't replace the message.
    static func collapseSelection() {
        sendKey(UInt16(kVK_RightArrow), flags: [])
    }

    private static func sendShortcut(_ key: CGKeyCode) {
        sendKey(key, flags: .maskCommand)
    }

    private static func sendKey(_ key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Screen rect (Cocoa coordinates) of the focused text element, used to place the panel near it.
    static func focusedElementFrame() -> NSRect? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement

        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }

        // AX uses a top-left origin anchored to the primary screen.
        guard let primary = NSScreen.screens.first else { return nil }
        let rect = NSRect(x: point.x, y: primary.frame.maxY - point.y - size.height, width: size.width, height: size.height)
        // Ignore giant elements (e.g. a whole web area) that aren't a useful anchor.
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }),
              rect.height < screen.frame.height * 0.7 else { return nil }
        return rect
    }
}
