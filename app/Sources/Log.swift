import Foundation

/// Step log at ~/Library/Logs/Copilot Proofreader.log. Never records the text being checked.
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Copilot Proofreader.log")
    private static let queue = DispatchQueue(label: "proofreader.log")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async { append(line) }
    }

    /// Writes before returning; use when the process is about to exit.
    static func now(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.sync { append(line) }
    }

    private static func append(_ line: String) {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           (attrs[.size] as? Int ?? 0) > 1_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    // MARK: - Crash logging

    private static var crashFD: Int32 = -1
    private static var crashMessages: [Int32: [UInt8]] = [:]

    /// Records uncaught exceptions and fatal signals so an unexpected exit leaves a trace in the log.
    static func installCrashHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            Log.now("crash exception=\(exception.name.rawValue) reason=\(exception.reason ?? "-")")
        }
        crashFD = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        let fatal: [(Int32, String)] = [(SIGSEGV, "SIGSEGV"), (SIGBUS, "SIGBUS"), (SIGILL, "SIGILL"),
                                        (SIGTRAP, "SIGTRAP"), (SIGABRT, "SIGABRT"), (SIGFPE, "SIGFPE")]
        for (sig, name) in fatal {
            // Prebuilt so the handler only calls async-signal-safe write().
            crashMessages[sig] = Array("crash signal=\(name)\n".utf8)
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { sig in
                if Log.crashFD >= 0, let bytes = Log.crashMessages[sig] {
                    bytes.withUnsafeBufferPointer { _ = write(Log.crashFD, $0.baseAddress, $0.count) }
                }
                signal(sig, SIG_DFL)
                raise(sig)
            }
            action.sa_flags = SA_RESETHAND
            sigaction(sig, &action, nil)
        }
    }
}
