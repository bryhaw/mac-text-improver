import AppKit
import Carbon.HIToolbox

enum Mode: String {
    case fix
    case polish
}

struct HotkeyPreset: Equatable {
    let id: String
    let keyCode: UInt32
    let keyLabel: String
    /// Carbon modifier mask for the fix shortcut; Improve Wording adds Shift.
    let carbonModifiers: UInt32
    let modifierFlags: NSEvent.ModifierFlags
    let modifierSymbols: String

    private static let controlCommand = (UInt32(controlKey | cmdKey), NSEvent.ModifierFlags([.control, .command]), "⌃⌘")
    private static let controlOption = (UInt32(controlKey | optionKey), NSEvent.ModifierFlags([.control, .option]), "⌃⌥")

    private init(_ id: String, _ keyCode: Int, _ keyLabel: String, _ mods: (UInt32, NSEvent.ModifierFlags, String)) {
        self.id = id
        self.keyCode = UInt32(keyCode)
        self.keyLabel = keyLabel
        carbonModifiers = mods.0
        modifierFlags = mods.1
        modifierSymbols = mods.2
    }

    // Left-hand-only combos first. Avoids ⌃⌘D (Look Up), ⌃⌘F (full screen), ⌃⌘Q (lock), ⌃⌘Space (emoji).
    static let all: [HotkeyPreset] = [
        HotkeyPreset("ctrl-cmd-s", kVK_ANSI_S, "S", controlCommand),
        HotkeyPreset("ctrl-opt-s", kVK_ANSI_S, "S", controlOption),
        HotkeyPreset("ctrl-cmd-e", kVK_ANSI_E, "E", controlCommand),
        HotkeyPreset("ctrl-opt-g", kVK_ANSI_G, "G", controlOption),
    ]

    var fixLabel: String { "\(modifierSymbols)\(keyLabel)" }
    var polishLabel: String {
        let symbols = modifierSymbols.hasSuffix("⌘") ? modifierSymbols.dropLast() + "⇧⌘" : modifierSymbols + "⇧"
        return "\(symbols)\(keyLabel)"
    }

    var keyEquivalent: String { keyLabel.lowercased() }
}

struct ModelChoice {
    let id: String
    let label: String

    static let curated: [ModelChoice] = [
        ModelChoice(id: "gpt-6-luna", label: "GPT-6 Luna — fast, low cost (recommended)"),
        ModelChoice(id: "mai-code-2-flash", label: "MAI Code 2 Flash — fast, free"),
        ModelChoice(id: "gpt-5.6-luna", label: "GPT-5.6 Luna — fast"),
        ModelChoice(id: "claude-haiku-5.5", label: "Claude Haiku 5.5"),
        ModelChoice(id: "claude-sonnet-5.5", label: "Claude Sonnet 5.5 — highest quality, slower"),
    ]
}

enum Settings {
    private static let defaults = UserDefaults.standard

    static var model: String? {
        get { defaults.string(forKey: "model") }
        set { defaults.set(newValue, forKey: "model") }
    }

    static var previewBeforeReplace: Bool {
        get { defaults.object(forKey: "previewBeforeReplace") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "previewBeforeReplace") }
    }

    static var hotkey: HotkeyPreset {
        get {
            let id = defaults.string(forKey: "hotkey")
            return HotkeyPreset.all.first { $0.id == id } ?? HotkeyPreset.all[0]
        }
        set { defaults.set(newValue.id, forKey: "hotkey") }
    }
}
