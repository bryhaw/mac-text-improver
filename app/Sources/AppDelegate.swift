import AppKit
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let helper = HelperClient()
    private let panel = ProofPanel()
    private var statusItem: NSStatusItem!
    private var previousApp: NSRunningApplication?
    private var busy = false
    private var activeRequest: Int?
    private var accessibilityTimer: Timer?
    private var awaitingLogin = false

    /// State of one check, from grabbing text to replacing it.
    private struct Job {
        let original: String
        let selectedAll: Bool
        let snapshot: PasteboardSnapshot
        let targetApp: NSRunningApplication?
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        previousApp = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0 }

        helper.onStateChange = { [weak self] in self?.helperStateChanged() }
        helper.onLoginURL = { [weak self] url in
            NSWorkspace.shared.open(url)
            self?.panel.setAnchor(nil)
            self?.panel.showToast("Finish signing in to GitHub in your browser", symbolName: "person.badge.key.fill",
                                  color: .controlAccentColor, duration: 6)
        }
        helper.onLoginFinished = { [weak self] error in
            guard let self else { return }
            self.awaitingLogin = false
            self.panel.setAnchor(nil)
            if let error {
                self.panel.showError("Sign-in didn't finish: \(error.message)", actionTitle: "Try Again") { [weak self] in
                    self?.signIn()
                }
            } else {
                self.panel.showToast("Signed in to GitHub Copilot")
            }
        }
        helper.start()

        // Layout check: PROOFREADER_DEMO=preview shows a sample preview without touching any app.
        if ProcessInfo.processInfo.environment["PROOFREADER_DEMO"] == "preview" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.panel.showPreview(
                    original: "i dont think their going to finsh the report by friday, can you let me no if we should push the meeting. also i was thinking we could of done a better job on the slides",
                    corrected: "I don't think they're going to finish the report by Friday. Can you let me know if we should push the meeting? Also, I was thinking we could have done a better job on the slides.",
                    detail: "GPT-6 Luna · 1.9s", note: "Checked the whole field because no text was selected.", polishAvailable: true,
                    onReplace: {}, onCopy: {}, onPolish: {}, onCancel: { [weak self] in self?.panel.close() })
            }
        }

        registerHotkeys()
        if !TextBridge.hasAccessibilityPermission {
            TextBridge.requestAccessibilityPermission()
            watchForAccessibilityPermission()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        helper.stop()
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app != .current else { return }
        previousApp = app
    }

    private var hasPromptedSignIn = false

    private func helperStateChanged() {
        Log.info("helper state=\(helper.state)")
        updateIcon()
        if case .signedOut = helper.state, !hasPromptedSignIn, !awaitingLogin {
            hasPromptedSignIn = true
            panel.setAnchor(nil)
            panel.showError("Copilot Proofreader needs to sign in to GitHub Copilot once.", actionTitle: "Sign In") { [weak self] in
                self?.signIn()
            }
        }
    }

    private func updateIcon() {
        let name: String
        switch helper.state {
        case .ready: name = "text.badge.checkmark"
        case .starting: name = "text.badge.checkmark"
        case .signedOut, .failed: name = "text.badge.xmark"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Copilot Proofreader")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = helper.state == .starting
    }

    // MARK: - Hotkeys & permissions

    private func registerHotkeys() {
        HotKeyCenter.shared.unregisterAll()
        let preset = Settings.hotkey
        let fix = HotKeyCenter.shared.register(keyCode: preset.keyCode, modifiers: preset.carbonModifiers) { [weak self] in
            self?.startCheck(mode: .fix)
        }
        let polish = HotKeyCenter.shared.register(
            keyCode: preset.keyCode, modifiers: preset.carbonModifiers | UInt32(shiftKey)) { [weak self] in
            self?.startCheck(mode: .polish)
        }
        Log.info("hotkeys \(preset.fixLabel) fix=\(fix != nil) polish=\(polish != nil)")
        if fix == nil || polish == nil {
            panel.setAnchor(nil)
            panel.showError("\(preset.fixLabel) is already used by another app. Pick a different shortcut from the menu bar icon.")
        }
    }

    private func watchForAccessibilityPermission() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard TextBridge.hasAccessibilityPermission else { return }
            timer.invalidate()
            self?.accessibilityTimer = nil
            self?.panel.setAnchor(nil)
            self?.panel.showToast("Ready — select text and press \(Settings.hotkey.fixLabel)", duration: 3)
        }
    }

    private func signIn() {
        awaitingLogin = true
        helper.login()
    }

    // MARK: - Check flow

    private func startCheck(mode: Mode) {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        Log.info("hotkey mode=\(mode.rawValue) busy=\(busy) front=\(front) state=\(helper.state) ax=\(TextBridge.hasAccessibilityPermission)")
        guard !busy else { return }
        guard TextBridge.hasAccessibilityPermission else {
            panel.setAnchor(nil)
            panel.showError("Copilot Proofreader needs Accessibility access to read and replace the text you're typing.",
                            actionTitle: "Open Settings") { [weak self] in
                TextBridge.requestAccessibilityPermission()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                self?.watchForAccessibilityPermission()
            }
            return
        }
        switch helper.state {
        case .signedOut:
            panel.setAnchor(nil)
            panel.showError("Sign in to GitHub Copilot to start proofreading.", actionTitle: "Sign In") { [weak self] in
                self?.signIn()
            }
            return
        case .failed(let message):
            panel.setAnchor(nil)
            panel.showError(message, actionTitle: "Restart Helper") { [weak self] in self?.helper.restart() }
            return
        case .starting, .ready:
            break
        }

        busy = true
        let target = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? previousApp : $0 }
        Task { @MainActor in
            let snapshot = PasteboardSnapshot.capture()
            await TextBridge.waitForModifierRelease()
            self.panel.setAnchor(TextBridge.focusedElementFrame())
            let grabbed = await TextBridge.grabSelection()
            snapshot.restore()
            Log.info("grab chars=\(grabbed?.text.count ?? -1) selectedAll=\(grabbed?.selectedAll ?? false)")
            guard let grabbed else {
                self.busy = false
                self.panel.showError("Couldn't read any text. Click into a text field (or select some text) and try again. Password fields can't be read.")
                return
            }
            let job = Job(original: grabbed.text, selectedAll: grabbed.selectedAll, snapshot: snapshot, targetApp: target)
            self.runCheck(job, mode: mode)
        }
    }

    private func runCheck(_ job: Job, mode: Mode) {
        let text = job.original
        if text.count > 12_000 {
            finish(job, collapse: true)
            panel.showError("That's \(text.count.formatted()) characters — select a shorter passage (up to 12,000).")
            return
        }
        panel.showLoading(mode == .fix ? "Checking spelling & grammar…" : "Improving wording…") { [weak self] in
            guard let self, let id = self.activeRequest else { return }
            self.helper.cancel(id)
            self.activeRequest = nil
            self.panel.close()
            self.finish(job, collapse: true)
        }
        activeRequest = helper.check(text, mode: mode) { [weak self] result in
            guard let self else { return }
            self.activeRequest = nil
            switch result {
            case .failure(let error):
                Log.info("check failed code=\(error.code ?? "-") message=\(error.message)")
                self.finish(job, collapse: true)
                if error.isAuth {
                    self.panel.showError(error.message, actionTitle: "Sign In") { [weak self] in self?.signIn() }
                } else {
                    self.panel.showError(error.message)
                }
            case .success(let result):
                self.handle(result, for: job, mode: mode)
            }
        }
    }

    private func handle(_ result: CheckResult, for job: Job, mode: Mode) {
        let corrected = result.text
        if corrected == job.original {
            finish(job, collapse: true)
            panel.showToast(mode == .fix ? "Looks good — no changes needed" : "No wording changes suggested")
            return
        }
        let ops = TextDiff.diff(job.original, corrected)
        let count = TextDiff.changeCount(ops)
        Log.info("result model=\(result.model) ms=\(result.milliseconds) changes=\(count) preview=\(Settings.previewBeforeReplace)")
        let seconds = String(format: "%.1fs", Double(result.milliseconds) / 1000)
        let detail = "\(Self.modelLabel(result.model)) · \(seconds)"

        guard Settings.previewBeforeReplace else {
            Task { @MainActor in
                self.panel.close()
                await TextBridge.paste(corrected, restoring: job.snapshot)
                self.busy = false
                self.panel.showToast(count == 1 ? "Fixed 1 issue" : "Fixed \(count) issues",
                                     detail: TextDiff.attributed(ops, font: .systemFont(ofSize: 12)), duration: 3)
            }
            return
        }

        let note = job.selectedAll ? "Checked the whole field because no text was selected." : nil
        panel.showPreview(
            original: job.original, corrected: corrected, detail: detail, note: note, polishAvailable: mode == .fix,
            onReplace: { [weak self] in self?.replace(job, with: corrected) },
            onCopy: { [weak self] in
                guard let self else { return }
                TextBridge.copyToClipboard(corrected)
                self.panel.close()
                self.returnFocus(to: job) {
                    self.panel.showToast("Copied corrected text")
                }
            },
            onPolish: { [weak self] in
                guard let self else { return }
                self.returnFocus(to: job, collapse: false) {
                    self.runCheck(job, mode: .polish)
                }
            },
            onCancel: { [weak self] in
                guard let self else { return }
                self.panel.close()
                self.returnFocus(to: job) {}
            })
    }

    private func replace(_ job: Job, with text: String) {
        panel.close()
        returnFocus(to: job, collapse: false) {
            Task { @MainActor in
                Log.info("replace front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")
                await TextBridge.paste(text, restoring: job.snapshot)
                self.busy = false
            }
        }
    }

    /// Re-activates the app the text came from, then runs `then` once it's frontmost.
    private func returnFocus(to job: Job, collapse: Bool = true, then: @escaping () -> Void) {
        Task { @MainActor in
            if let app = job.targetApp, NSWorkspace.shared.frontmostApplication != app {
                app.activate(options: [])
                let deadline = Date().addingTimeInterval(1.5)
                while NSWorkspace.shared.frontmostApplication != app, Date() < deadline {
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            } else if job.targetApp == nil {
                NSApp.hide(nil)
            }
            if collapse { self.finish(job, collapse: true) }
            then()
        }
    }

    private func finish(_ job: Job, collapse: Bool) {
        busy = false
        if collapse, job.selectedAll, NSWorkspace.shared.frontmostApplication == job.targetApp {
            TextBridge.collapseSelection()
        }
    }

    private static func modelLabel(_ id: String) -> String {
        ModelChoice.curated.first { $0.id == id }.map { String($0.label.split(separator: "—")[0]).trimmingCharacters(in: .whitespaces) } ?? id
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let preset = Settings.hotkey

        menu.addItem(item("Check Spelling & Grammar", key: preset.keyEquivalent, modifiers: preset.modifierFlags) { [weak self] in
            self?.checkFromMenu(.fix)
        })
        menu.addItem(item("Improve Wording", key: preset.keyEquivalent, modifiers: preset.modifierFlags.union(.shift)) { [weak self] in
            self?.checkFromMenu(.polish)
        })
        menu.addItem(.separator())

        switch helper.state {
        case .ready(let login):
            menu.addItem(disabled(login.map { "Copilot: signed in as \($0)" } ?? "Copilot: ready"))
        case .starting:
            menu.addItem(disabled("Copilot: starting…"))
        case .signedOut:
            menu.addItem(disabled("Copilot: not signed in"))
            menu.addItem(item("Sign In to GitHub…") { [weak self] in self?.signIn() })
        case .failed(let message):
            menu.addItem(disabled("Copilot: \(message.prefix(60))"))
        }
        if !TextBridge.hasAccessibilityPermission {
            menu.addItem(item("Grant Accessibility Access…") { [weak self] in
                TextBridge.requestAccessibilityPermission()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                self?.watchForAccessibilityPermission()
            })
        }
        menu.addItem(.separator())

        let modelMenu = NSMenu()
        let available = Set(helper.models.map(\.id))
        let choices = ModelChoice.curated.filter { available.isEmpty || available.contains($0.id) }
        for choice in choices {
            let entry = item(choice.label) { [weak self] in self?.helper.setModel(choice.id) }
            entry.state = helper.model == choice.id ? .on : .off
            modelMenu.addItem(entry)
        }
        if !choices.contains(where: { $0.id == helper.model }) {
            let entry = disabled(helper.model)
            entry.state = .on
            modelMenu.addItem(entry)
        }
        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        let shortcutMenu = NSMenu()
        for option in HotkeyPreset.all {
            let entry = item("\(option.fixLabel)   (\(option.polishLabel) to improve wording)") { [weak self] in
                Settings.hotkey = option
                self?.registerHotkeys()
            }
            entry.state = option == preset ? .on : .off
            shortcutMenu.addItem(entry)
        }
        let shortcutItem = NSMenuItem(title: "Shortcut", action: nil, keyEquivalent: "")
        shortcutItem.submenu = shortcutMenu
        menu.addItem(shortcutItem)

        let preview = item("Show Changes Before Replacing") {
            Settings.previewBeforeReplace.toggle()
        }
        preview.state = Settings.previewBeforeReplace ? .on : .off
        menu.addItem(preview)

        let login = item("Open at Login") { [weak self] in self?.toggleLoginItem() }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("Restart Copilot Helper") { [weak self] in self?.helper.restart() })
        menu.addItem(item("Quit Copilot Proofreader", key: "q") { NSApp.terminate(nil) })
    }

    private func checkFromMenu(_ mode: Mode) {
        // Let the menu close and focus return to the previous app first.
        let target = previousApp
        Task { @MainActor in
            if let target, NSWorkspace.shared.frontmostApplication != target {
                target.activate(options: [])
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            self.startCheck(mode: mode)
        }
    }

    private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            panel.setAnchor(nil)
            panel.showError("Couldn't change Open at Login: \(error.localizedDescription)")
        }
    }

    private func item(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command,
                      action: @escaping () -> Void) -> NSMenuItem {
        let entry = ClosureMenuItem(title: title, action: action)
        entry.keyEquivalent = key
        entry.keyEquivalentModifierMask = modifiers
        return entry
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private var handler: (() -> Void)?

    convenience init(title: String, action: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        handler = action
        target = self
    }

    @objc private func fire() { handler?() }
}
