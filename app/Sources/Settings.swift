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

/// Where proofreading requests go. Copilot uses your GitHub sign-in; the others use your own API key.
enum Provider: String, CaseIterable {
    case copilot
    case openai
    case anthropic

    var name: String {
        switch self {
        case .copilot: return "GitHub Copilot"
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        }
    }

    var menuTitle: String {
        switch self {
        case .copilot: return "GitHub Copilot (your subscription)"
        case .openai: return "OpenAI (API key)"
        case .anthropic: return "Anthropic Claude (API key)"
        }
    }

    var usesAPIKey: Bool { self != .copilot }

    var apiHost: String {
        switch self {
        case .copilot: return "GitHub Copilot"
        case .openai: return "api.openai.com"
        case .anthropic: return "api.anthropic.com"
        }
    }

    var keyPageURL: URL? {
        switch self {
        case .copilot: return nil
        case .openai: return URL(string: "https://platform.openai.com/api-keys")
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .copilot: return ""
        case .openai: return "sk-…"
        case .anthropic: return "sk-ant-…"
        }
    }
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

    // Only non-secret preferences live in UserDefaults. API keys are stored in the Keychain (see Keychain.swift).
    static var provider: Provider {
        get { Provider(rawValue: defaults.string(forKey: "provider") ?? "") ?? .copilot }
        set { defaults.set(newValue.rawValue, forKey: "provider") }
    }

    private static func modelKey(_ provider: Provider) -> String {
        provider == .copilot ? "model" : "model.\(provider.rawValue)"
    }

    static func model(for provider: Provider) -> String? {
        defaults.string(forKey: modelKey(provider))
    }

    static func setModel(_ id: String?, for provider: Provider) {
        defaults.set(id, forKey: modelKey(provider))
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

    /// Set once Open at Login has been turned on by default, so turning it off later sticks.
    static var keepRunningConfigured: Bool {
        get { defaults.bool(forKey: "keepRunningConfigured") }
        set { defaults.set(newValue, forKey: "keepRunningConfigured") }
    }
}
