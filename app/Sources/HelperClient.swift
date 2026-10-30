import Foundation

struct HelperModel: Decodable {
    let id: String
    let name: String
}

enum HelperState: Equatable {
    case starting
    case ready(login: String?)
    case signedOut(message: String?)
    case needsKey(message: String?)
    case failed(message: String)
}

struct HelperError: Error {
    let code: String?
    let message: String
    var isAuth: Bool { code == "auth" }
}

struct CheckResult {
    let text: String
    let model: String
    let milliseconds: Int
}

/// Owns the Node helper process that sends text to the selected provider:
/// GitHub Copilot (through the Copilot SDK) or OpenAI / Anthropic (with the user's API key).
final class HelperClient {
    private(set) var state: HelperState = .starting
    private(set) var models: [HelperModel] = []
    private(set) var provider: Provider = Settings.provider
    private(set) var model: String = Settings.model(for: Settings.provider) ?? ""

    var onStateChange: (() -> Void)?
    var onLoginURL: ((URL) -> Void)?
    var onLoginFinished: ((HelperError?) -> Void)?

    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var pending: [Int: (Result<CheckResult, HelperError>) -> Void] = [:]
    private var nextID = 1
    private var stopping = false
    private var restartDelay: TimeInterval = 1
    private var stderrTail = ""

    func start() {
        stopping = false
        launch()
    }

    func stop() {
        stopping = true
        try? stdin?.close()
        if let process, process.isRunning {
            process.terminate()
        }
    }

    func restart() {
        stopping = true
        process?.terminationHandler = nil
        if let process, process.isRunning { process.terminate() }
        failPending(HelperError(code: "failed", message: "The proofreading helper restarted."))
        stopping = false
        launch()
    }

    @discardableResult
    func check(_ text: String, mode: Mode, completion: @escaping (Result<CheckResult, HelperError>) -> Void) -> Int {
        let id = nextID
        nextID += 1
        pending[id] = completion
        write(["type": "check", "id": id, "text": text, "mode": mode.rawValue])
        return id
    }

    func cancel(_ id: Int) {
        guard pending.removeValue(forKey: id) != nil else { return }
        write(["type": "cancel", "id": id])
    }

    func setModel(_ id: String) {
        model = id
        Settings.setModel(id, for: provider)
        write(["type": "set_model", "model": id])
        onStateChange?()
    }

    func setProvider(_ newProvider: Provider) {
        provider = newProvider
        Settings.provider = newProvider
        model = Settings.model(for: newProvider) ?? ""
        models = []
        setState(.starting)
        sendConfiguration()
    }

    /// Re-sends the provider settings, e.g. after the user saves or removes an API key.
    func reloadConfiguration() {
        setState(.starting)
        sendConfiguration()
    }

    /// The API key travels to the helper over its private stdin pipe, never via arguments or environment.
    private func sendConfiguration() {
        var message: [String: Any] = [
            "type": "configure",
            "provider": provider.rawValue,
            "model": Settings.model(for: provider) ?? NSNull(),
        ]
        if provider.usesAPIKey {
            message["apiKey"] = Keychain.apiKey(for: provider) ?? NSNull()
        }
        write(message)
    }

    func login() {
        write(["type": "login"])
    }

    func refreshStatus() {
        write(["type": "status"])
    }

    // MARK: - Process management

    private func launch() {
        guard let node = Self.findNode() else {
            setState(.failed(message: "Node.js wasn't found. Install Node 22+ (e.g. `brew install node`) and restart Copilot Proofreader."))
            return
        }
        guard let script = Bundle.main.url(forResource: "proofread-helper", withExtension: "mjs", subdirectory: "helper") else {
            setState(.failed(message: "The app bundle is missing its helper. Rebuild it with build.sh."))
            return
        }

        let process = Process()
        process.executableURL = node
        process.arguments = [script.path]
        process.currentDirectoryURL = script.deletingLastPathComponent()
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [node.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        env["PROOFREADER_PROVIDER"] = provider.rawValue
        if let model = Settings.model(for: provider) { env["PROOFREADER_MODEL"] = model } else { env.removeValue(forKey: "PROOFREADER_MODEL") }
        process.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.consume(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.stderrTail = String((self.stderrTail + text).suffix(2000))
            }
        }
        process.terminationHandler = { [weak self] proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { self?.handleExit(proc) }
        }

        do {
            try process.run()
            self.process = process
            self.stdin = inPipe.fileHandleForWriting
            buffer.removeAll()
            setState(.starting)
            sendConfiguration()
        } catch {
            setState(.failed(message: "Couldn't start the proofreading helper: \(error.localizedDescription)"))
        }
    }

    private func handleExit(_ proc: Process) {
        guard proc === process else { return }
        process = nil
        stdin = nil
        failPending(HelperError(code: "failed", message: "The proofreading helper stopped unexpectedly."))
        guard !stopping else { return }
        let detail = stderrTail.split(separator: "\n").last.map(String.init) ?? "exit code \(proc.terminationStatus)"
        setState(.failed(message: "Proofreading helper stopped (\(detail)). Restarting…"))
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopping, self.process == nil else { return }
            self.launch()
        }
    }

    private func failPending(_ error: HelperError) {
        let callbacks = pending
        pending.removeAll()
        for callback in callbacks.values { callback(.failure(error)) }
    }

    private func write(_ message: [String: Any]) {
        guard let stdin, let data = try? JSONSerialization.data(withJSONObject: message) else {
            if message["type"] as? String == "check", let id = message["id"] as? Int,
               let callback = pending.removeValue(forKey: id) {
                callback(.failure(HelperError(code: "failed", message: "The proofreading helper isn't running yet. Try again in a moment.")))
            }
            return
        }
        do {
            try stdin.write(contentsOf: data + Data([0x0A]))
        } catch {
            if message["type"] as? String == "check", let id = message["id"] as? Int,
               let callback = pending.removeValue(forKey: id) {
                callback(.failure(HelperError(code: "failed", message: "Couldn't reach the proofreading helper. Try again in a moment.")))
            }
        }
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                handle(object)
            }
        }
    }

    private func handle(_ msg: [String: Any]) {
        switch msg["type"] as? String {
        case "status":
            // Ignore late status from a provider the user has since switched away from.
            if let reported = msg["provider"] as? String, reported != provider.rawValue { return }
            if let list = msg["models"] as? [[String: Any]] {
                models = list.compactMap { item in
                    guard let id = item["id"] as? String else { return nil }
                    return HelperModel(id: id, name: item["name"] as? String ?? id)
                }
            }
            if let current = msg["model"] as? String { model = current }
            switch msg["state"] as? String {
            case "ready":
                restartDelay = 1
                setState(.ready(login: msg["login"] as? String))
            case "signed_out":
                setState(.signedOut(message: msg["message"] as? String))
            case "needs_key":
                setState(.needsKey(message: msg["message"] as? String))
            case "error":
                setState(.failed(message: msg["message"] as? String ?? "Unknown error"))
            default:
                setState(.starting)
            }
        case "model":
            if let current = msg["model"] as? String { model = current }
            onStateChange?()
        case "result":
            guard let id = msg["id"] as? Int, let callback = pending.removeValue(forKey: id) else { return }
            callback(.success(CheckResult(
                text: msg["text"] as? String ?? "",
                model: msg["model"] as? String ?? model,
                milliseconds: msg["ms"] as? Int ?? 0)))
        case "error":
            let error = HelperError(code: msg["code"] as? String, message: msg["message"] as? String ?? "Unknown error")
            if let id = msg["id"] as? Int {
                pending.removeValue(forKey: id)?(.failure(error))
            } else if error.code == "login" {
                onLoginFinished?(error)
            }
        case "login_url":
            if let raw = msg["url"] as? String, let url = URL(string: raw) { onLoginURL?(url) }
        case "login_done":
            onLoginFinished?(nil)
        default:
            break
        }
    }

    private func setState(_ newState: HelperState) {
        state = newState
        onStateChange?()
    }

    static func findNode() -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let configured = Bundle.main.object(forInfoDictionaryKey: "ProofreaderNodePath") as? String {
            candidates.append(configured)
        }
        let home = fm.homeDirectoryForCurrentUser.path
        candidates += [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "\(home)/.local/bin/node",
            "\(home)/.volta/bin/node",
        ]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvm) {
            candidates += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { "\(nvm)/\($0)/bin/node" }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}
