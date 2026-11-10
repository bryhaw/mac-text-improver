import AppKit

signal(SIGPIPE, SIG_IGN)
Log.installCrashHandlers()

let app = NSApplication.shared
guard KeepAlive.claimInstance() else { exit(0) }
Log.info("launch pid=\(getpid()) agent=\(KeepAlive.isAgentProcess) version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-")")

// launchd sends SIGTERM to stop the agent; quit cleanly so the helper is shut down too.
signal(SIGTERM, SIG_IGN)
let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminationSource.setEventHandler {
    Log.now("quit: SIGTERM")
    NSApp.terminate(nil)
}
terminationSource.resume()

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
