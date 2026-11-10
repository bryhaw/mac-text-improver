import AppKit
import ServiceManagement

/// Runs the app as a per-user launch agent (Contents/Library/LaunchAgents) so it starts at login
/// and launchd relaunches it if it crashes. Quitting from the menu exits with status 0, which launchd leaves alone.
enum KeepAlive {
    static let label = "com.bryhaw.copilot-proofreader.agent"
    private static let takeoverArgument = "--takeover"
    private static var service: SMAppService { .agent(plistName: "\(label).plist") }

    /// True when launchd started this process from the agent plist.
    static var isAgentProcess: Bool { ProcessInfo.processInfo.environment["PROOFREADER_AGENT"] == "1" }
    static var isEnabled: Bool { service.status == .enabled }

    /// Decides whether this process should keep running. Returns false when it should exit
    /// because the launch agent is (or will be) the running copy.
    static func claimInstance() -> Bool {
        // Layout demos run as a separate, short-lived copy alongside the normal one.
        if ProcessInfo.processInfo.environment["PROOFREADER_DEMO"] != nil { return true }
        let takeover = CommandLine.arguments.contains(takeoverArgument)
        if !Settings.keepRunningConfigured {
            Settings.keepRunningConfigured = true
            if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
            do {
                try service.register()
                Log.info("keepalive registered status=\(describe(service.status))")
            } catch {
                Log.info("keepalive register failed: \(error.localizedDescription)")
            }
        }

        if isAgentProcess || takeover {
            // Give a copy that is handing over a moment to exit.
            if waitForOtherInstances(timeout: takeover ? 10 : 3) { return true }
            Log.now("launch skipped: another copy is running")
            return false
        }
        if isEnabled, kickstart() {
            Log.now("launch handed off to launch agent")
            return false
        }
        if !otherInstances().isEmpty {
            Log.now("launch skipped: another copy is running")
            return false
        }
        return true
    }

    /// Turns Open at Login on or off. Turning it off stops the agent copy, so a plain copy takes over first.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
            try service.register()
            Log.info("keepalive enabled status=\(describe(service.status))")
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } else {
            if isAgentProcess {
                let config = NSWorkspace.OpenConfiguration()
                config.createsNewApplicationInstance = true
                config.arguments = [takeoverArgument]
                NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in }
            }
            try service.unregister()
            Log.info("keepalive disabled")
        }
    }

    static var requiresApproval: Bool { service.status == .requiresApproval }

    private static func otherInstances() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != getpid() }
    }

    private static func waitForOtherInstances(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !otherInstances().isEmpty {
            if Date() > deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return true
    }

    /// Starts the agent if it isn't running. Returns false if launchd couldn't do it.
    private static func kickstart() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "gui/\(getuid())/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        return process.terminationStatus == 0
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notRegistered: return "notRegistered"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }
}
