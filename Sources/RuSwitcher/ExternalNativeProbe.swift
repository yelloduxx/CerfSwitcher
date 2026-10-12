import AppKit
import ApplicationServices
import RuSwitcherAppSupport

@MainActor
enum ExternalNativeProbe {
    private static var retained: ProbeDelegate?

    static func run() -> Never {
        guard let index = CommandLine.arguments.firstIndex(of: "--external-native-probe"),
              CommandLine.arguments.indices.contains(index + 2),
              let runID = UUID(uuidString: CommandLine.arguments[index + 1]) else { exit(64) }
        let sessionURL = URL(fileURLWithPath: CommandLine.arguments[index + 2])
        guard let hostIndex = CommandLine.arguments.firstIndex(of: "--host-pid"),
              CommandLine.arguments.indices.contains(hostIndex + 1),
              let hostPID = Int32(CommandLine.arguments[hostIndex + 1]), hostPID > 0,
              let config = try? ExternalNativeProbeConfiguration.load(from: sessionURL), config.runID == runID,
              config.replacementMarker == kRuSwitcherEventMarker,
              RuntimePreferencesDomain.isolatedSuiteName(arguments: CommandLine.arguments) == config.preferencesDomain else { exit(64) }
        if CommandLine.arguments.contains("--request-access") {
            let options = ["AXTrustedCheckOptionPrompt" as CFString: true as CFBoolean] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
            if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
        }
        let accessibility = AXIsProcessTrusted()
        let listening = CGPreflightListenEventAccess()
        let posting = CGPreflightPostEventAccess()
        if CommandLine.arguments.contains("--preflight") || CommandLine.arguments.contains("--request-access") {
            print("accessibility=\(accessibility) listening=\(listening) posting=\(posting); no event tap started")
            exit(accessibility && listening && posting ? 0 : 77)
        }
        guard ProcessInfo.processInfo.environment["RUSWITCH_ALLOW_FOCUS_STEALING"] == "1" else { exit(77) }
        guard accessibility, listening, posting else { exit(77) }
        let delegate = ProbeDelegate(config: config, root: sessionURL.deletingLastPathComponent(), hostPID: hostPID)
        retained = delegate
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
        exit(0)
    }
}

@MainActor
private final class ProbeDelegate: NSObject, NSApplicationDelegate {
    private let config: ExternalNativeProbeConfiguration
    private let root: URL
    private let production = AppDelegate()
    private let started = ProcessInfo.processInfo.systemUptime
    private var timer: Timer?
    private var callbackTimings: [[String: Any]] = []
    private var callbackTimingOverflow = false
    private var phaseMarks: [[String: Any]] = []

    init(config: ExternalNativeProbeConfiguration, root: URL, hostPID: pid_t) {
        self.config = config
        self.root = root
        production.probeTargetProcessID = hostPID
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = SettingsManager.shared
        settings.layout1ID = config.layoutIDs[0]
        settings.layout2ID = config.layoutIDs[1]
        settings.autoSwitchEnabled = true
        settings.autoConvert = config.automaticConversion
        settings.axlessConversion = false
        settings.perAppLayout = false
        settings.caretFlag = false
        settings.keySound = false
        settings.debugLogEnabled = false
        settings.remoteDesktopMode = false
        production.observeProbeCallbacks { [weak self] timing in
            MainActor.assumeIsolated { self?.recordCallback(timing) }
        }
        CallbackPhaseProbe.recorder = { [weak self] phase, at in
            MainActor.assumeIsolated {
                guard let self, self.phaseMarks.count < 4_096 else { return }
                self.phaseMarks.append(["phase": "\(phase)", "atNanoseconds": at])
            }
        }
        production.startHIDProbeMonitoring()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    private func recordCallback(_ timing: KeyboardCallbackTiming) {
        guard timing.eventType == .keyDown,
              let index = config.inputActionIndex(eventMarker: timing.marker) else { return }
        guard callbackTimings.count < ExternalNativeProbeConfiguration.maximumActions else {
            callbackTimingOverflow = true
            return
        }
        callbackTimings.append([
            "actionIndex": index, "keyCode": timing.keyCode,
            "startedNanoseconds": timing.startedNanoseconds,
            "finishedNanoseconds": timing.finishedNanoseconds,
            "consumed": timing.consumed,
            "sourceLayoutID": timing.sourceLayoutID ?? "",
        ])
    }

    private func tick() {
        let requestedStop = FileManager.default.fileExists(atPath: root.appendingPathComponent("stop").path)
        let timedOut = ProcessInfo.processInfo.systemUptime - started >= config.timeoutSeconds
        let stopping = requestedStop || timedOut || callbackTimingOverflow
        let snapshot: [String: Any] = [
            "schemaVersion": 2, "runID": config.runID.uuidString,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "bundleID": Bundle.main.bundleIdentifier ?? "",
            "status": callbackTimingOverflow || timedOut ? "interrupted" : requestedStop ? "complete" : "running",
            "atNanoseconds": DispatchTime.now().uptimeNanoseconds,
            "tapEnabled": production.probeEventTapEnabled,
            "modelAvailable": production.probeModelAvailable,
            "automaticConversion": config.automaticConversion,
            "posted": production.postedAutomaticReplacementCount,
            "verified": production.verifiedAutomaticReplacementCount,
            "preferencesDomain": config.preferencesDomain,
            "targetProcessID": production.probeTargetProcessID ?? 0,
            // Export the detailed trace once, after input has stopped. Rewriting
            // a growing timing trace on every poll would distort the measurement.
            "callbackTimings": stopping ? callbackTimings : [],
            "callbackTimingSampleCount": callbackTimings.count,
            "callbackTimingOverflow": callbackTimingOverflow,
            "phaseMarks": stopping ? phaseMarks : [],
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
            try data.write(to: root.appendingPathComponent("app-state.json"), options: .atomic)
            if stopping {
                try data.write(to: root.appendingPathComponent("app-result.json"), options: .atomic)
                timer?.invalidate()
                UserDefaults(suiteName: config.preferencesDomain)?.removePersistentDomain(forName: config.preferencesDomain)
                NSApp.terminate(nil)
            }
        } catch { exit(74) }
    }
}
