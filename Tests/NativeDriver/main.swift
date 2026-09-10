import AppKit
import Carbon
import CoreGraphics
import Foundation
import RuSwitcherAppSupport
import RuSwitcherCore
import RuSwitcherTestSupport

private func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else { return nil }
    return CommandLine.arguments[index + 1]
}

private func sourceID(_ source: TISInputSource) -> String? {
    guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
}

private func currentLayoutID() -> String {
    TISCopyCurrentKeyboardInputSource().map { sourceID($0.takeRetainedValue()) ?? "" } ?? ""
}

private func enabledSource(_ id: String) -> TISInputSource? {
    let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
    guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return nil }
    return sources.first { sourceID($0) == id }
}

private struct InputRecord: Codable {
    let actionIndex: Int
    let plannedNanoseconds: UInt64
    let postedNanoseconds: UInt64
    let layoutID: String
    let focusCheckNanoseconds: UInt64
    let layoutReadNanoseconds: UInt64
    let preparationNanoseconds: UInt64
    let postNanoseconds: UInt64
}

private struct DriverReport: Encodable {
    let schemaVersion = 1
    let runID: UUID
    let pid = ProcessInfo.processInfo.processIdentifier
    var status = "invalidRun"
    var reason: String?
    var originalLayoutID = ""
    var finalLayoutID = ""
    var restoredLayout = false
    var records: [InputRecord] = []
    var maximumLatenessMicroseconds: UInt64 = 0
}

private enum DriverError: Error, Equatable {
    case invalidFixture, unsupportedAction, blockedPermission, blockedLayout, interruptedFocus, eventAllocation, scheduleTooLate
}

private func validate(_ stimulus: PhysicalTypingStimulus, config: ExternalNativeProbeConfiguration) throws {
    guard stimulus.version == 1, !stimulus.actions.isEmpty,
          stimulus.actions.count <= ExternalNativeProbeConfiguration.maximumActions,
          stimulus.layoutIDs == config.layoutIDs, stimulus.layoutIDs.contains(stimulus.initialLayoutID),
          stimulus.timing == nil else { throw DriverError.invalidFixture }
    var time: UInt64 = 0
    var pressed: Set<UInt16> = []
    for action in stimulus.actions {
        guard action.atMicroseconds >= time,
              action.atMicroseconds < UInt64(config.timeoutSeconds * 1_000_000),
              !action.command, !action.control, !action.option, action.fieldID == nil else { throw DriverError.invalidFixture }
        if let code = action.keyCode,
           KeyMapping.keycodeToEN[code] == nil, ![36, 48, 49, 51, 123, 124].contains(code) {
            throw DriverError.unsupportedAction
        }
        time = action.atMicroseconds
        switch action.kind {
        case .selectLayout:
            guard let id = action.layoutID, stimulus.layoutIDs.contains(id), action.keyCode == nil,
                  !action.shift, !action.capsLock, !action.autorepeat else { throw DriverError.invalidFixture }
        case .keyDown:
            guard let code = action.keyCode, action.layoutID == nil, action.autorepeat == pressed.contains(code) else {
                throw DriverError.invalidFixture
            }
            pressed.insert(code)
        case .keyUp:
            guard let code = action.keyCode, action.layoutID == nil, !action.autorepeat, pressed.remove(code) != nil else {
                throw DriverError.invalidFixture
            }
        case .focusChange, .tapRecovery: throw DriverError.unsupportedAction
        }
    }
    guard pressed.isEmpty else { throw DriverError.invalidFixture }
}

private func wait(until time: UInt64, cancelled: () -> Bool) throws {
    while DispatchTime.now().uptimeNanoseconds < time {
        if cancelled() { throw DriverError.interruptedFocus }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < time else { return }
        let interval = min(0.01, Double(time - now) / 1_000_000_000)
        // NSWorkspace and input-source observations need the main run loop.
        // The absolute deadline still bounds timing; do not wait for conversion.
        if !RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: interval)) {
            Thread.sleep(forTimeInterval: interval)
        }
    }
}

private func checkWaitServicesRunLoop() throws {
    let callback = DispatchSemaphore(value: 0)
    let timer = Timer(timeInterval: 0.001, repeats: false) { _ in callback.signal() }
    RunLoop.current.add(timer, forMode: .default)
    defer { timer.invalidate() }
    do {
        try wait(until: DispatchTime.now().uptimeNanoseconds + 250_000_000) {
            callback.wait(timeout: .now()) == .success
        }
    } catch DriverError.interruptedFocus {
        return
    }
    throw DriverError.invalidFixture
}

private func prepareEvent(_ action: PhysicalTypingAction, index: Int, config: ExternalNativeProbeConfiguration,
                          source: CGEventSource, keyboardType: UInt32) throws -> CGEvent {
    guard let key = action.keyCode,
          let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: action.kind == .keyDown),
          let marker = config.inputEventMarker(actionIndex: index) else { throw DriverError.eventAllocation }
    var flags: CGEventFlags = []
    if action.shift { flags.insert(.maskShift) }
    if action.capsLock { flags.insert(.maskAlphaShift) }
    event.flags = flags
    event.setIntegerValueField(.eventSourceUserData, value: marker)
    event.setIntegerValueField(.keyboardEventAutorepeat, value: action.autorepeat ? 1 : 0)
    event.setIntegerValueField(.keyboardEventKeyboardType, value: Int64(keyboardType))
    return event
}

private func checkPreparationTiming(_ stimulus: PhysicalTypingStimulus, config: ExternalNativeProbeConfiguration) throws {
    guard let source = CGEventSource(stateID: .hidSystemState),
          let index = stimulus.actions.firstIndex(where: { $0.kind == .keyDown }) else { throw DriverError.invalidFixture }
    var samples: [[String: UInt64]] = []
    for _ in 0..<8 {
        let start = DispatchTime.now().uptimeNanoseconds
        _ = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focusRead = DispatchTime.now().uptimeNanoseconds
        _ = currentLayoutID()
        let layoutRead = DispatchTime.now().uptimeNanoseconds
        let event = try prepareEvent(stimulus.actions[index], index: index, config: config,
                                     source: source, keyboardType: stimulus.keyboardType)
        withExtendedLifetime(event) {}
        let prepared = DispatchTime.now().uptimeNanoseconds
        samples.append(["focusCheckNanoseconds": focusRead - start, "layoutReadNanoseconds": layoutRead - focusRead,
                        "preparationNanoseconds": prepared - layoutRead])
    }
    let data = try JSONSerialization.data(withJSONObject: ["eventsPosted": 0, "samples": samples], options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private func execute(_ stimulus: PhysicalTypingStimulus, config: ExternalNativeProbeConfiguration,
                     root: URL, hostPID: pid_t, report: inout DriverReport) throws {
    guard CGPreflightPostEventAccess() else { throw DriverError.blockedPermission }
    var sources: [String: TISInputSource] = [:]
    for id in stimulus.layoutIDs {
        guard let source = enabledSource(id) else { throw DriverError.blockedLayout }
        sources[id] = source
    }
    guard let initial = sources[stimulus.initialLayoutID] else { throw DriverError.blockedLayout }
    report.originalLayoutID = currentLayoutID()
    guard let original = enabledSource(report.originalLayoutID) else { throw DriverError.blockedLayout }
    defer {
        report.finalLayoutID = currentLayoutID()
        report.restoredLayout = TISSelectInputSource(original) == noErr
    }
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == hostPID else { throw DriverError.interruptedFocus }
    guard TISSelectInputSource(initial) == noErr else { throw DriverError.blockedLayout }
    guard let eventSource = CGEventSource(stateID: .hidSystemState) else { throw DriverError.eventAllocation }
    eventSource.userData = config.inputMarker
    let cancelled = {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("stop").path)
            || NSWorkspace.shared.frontmostApplication?.processIdentifier != hostPID
    }
    try wait(until: DispatchTime.now().uptimeNanoseconds + 100_000_000, cancelled: cancelled)
    guard currentLayoutID() == stimulus.initialLayoutID else { throw DriverError.blockedLayout }
    if let firstKey = stimulus.actions.firstIndex(where: { $0.kind == .keyDown }) {
        // Warm object construction without sending anything or freezing the
        // Unicode payloads of later keys before the layout actually changes.
        _ = try prepareEvent(stimulus.actions[firstKey], index: firstKey, config: config,
                             source: eventSource, keyboardType: stimulus.keyboardType)
    }
    let began = DispatchTime.now().uptimeNanoseconds
    for (index, action) in stimulus.actions.enumerated() {
        let planned = began + action.atMicroseconds * 1_000
        try wait(until: planned, cancelled: cancelled)
        let focusCheckStarted = DispatchTime.now().uptimeNanoseconds
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("stop").path),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == hostPID else { throw DriverError.interruptedFocus }
        let now = DispatchTime.now().uptimeNanoseconds
        let lateness = (now - planned) / 1_000
        report.maximumLatenessMicroseconds = max(report.maximumLatenessMicroseconds, lateness)
        // Report an invalid timing run instead of silently slowing down a
        // supposedly independent high-rate input stream.
        guard lateness <= 10_000 else { throw DriverError.scheduleTooLate }
        let layout = currentLayoutID()
        let layoutRead = DispatchTime.now().uptimeNanoseconds
        guard stimulus.layoutIDs.contains(layout) else { throw DriverError.blockedLayout }
        if index == 0, layout != stimulus.initialLayoutID { throw DriverError.blockedLayout }
        var prepared = layoutRead
        switch action.kind {
        case .selectLayout:
            guard let id = action.layoutID, let source = sources[id], TISSelectInputSource(source) == noErr else {
                throw DriverError.blockedLayout
            }
        case .keyDown, .keyUp:
            let event = try prepareEvent(action, index: index, config: config, source: eventSource,
                                         keyboardType: stimulus.keyboardType)
            prepared = DispatchTime.now().uptimeNanoseconds
            event.post(tap: .cghidEventTap)
        case .focusChange, .tapRecovery: throw DriverError.unsupportedAction
        }
        let posted = DispatchTime.now().uptimeNanoseconds
        report.records.append(.init(actionIndex: index, plannedNanoseconds: planned,
                                    postedNanoseconds: posted, layoutID: layout,
                                    focusCheckNanoseconds: now - focusCheckStarted,
                                    layoutReadNanoseconds: layoutRead - now,
                                    preparationNanoseconds: prepared - layoutRead,
                                    postNanoseconds: posted - prepared))
        let postLateness = (posted - planned) / 1_000
        report.maximumLatenessMicroseconds = max(report.maximumLatenessMicroseconds, postLateness)
        guard postLateness <= 10_000 else { throw DriverError.scheduleTooLate }
    }
    // Only the end of the continuous phrase waits for observation, never a
    // word boundary or a decoder verdict.
    try wait(until: DispatchTime.now().uptimeNanoseconds + 300_000_000, cancelled: cancelled)
}

do {
    guard let sessionPath = argument("--session"), let stimulusPath = argument("--stimulus") else { exit(64) }
    let sessionURL = URL(fileURLWithPath: sessionPath)
    let config = try ExternalNativeProbeConfiguration.load(from: sessionURL)
    let data = try Data(contentsOf: URL(fileURLWithPath: stimulusPath))
    guard data.count <= 2_000_000 else { exit(64) }
    // Input-only file: no oracle or expected decision enters the driver.
    let stimulus = try JSONDecoder().decode(PhysicalTypingStimulus.self, from: data)
    try validate(stimulus, config: config)
    if CommandLine.arguments.contains("--self-check") {
        try checkWaitServicesRunLoop()
        print("PASS: input/config valid; no application, window or events created")
        exit(0)
    }
    if CommandLine.arguments.contains("--timing-check") {
        try checkPreparationTiming(stimulus, config: config)
        exit(0)
    }
    if CommandLine.arguments.contains("--request-access"), !CGPreflightPostEventAccess() {
        _ = CGRequestPostEventAccess()
    }
    if CommandLine.arguments.contains("--preflight") || CommandLine.arguments.contains("--request-access") {
        let available = config.layoutIDs.allSatisfy { enabledSource($0) != nil }
        let access = CGPreflightPostEventAccess()
        print("postingAccess=\(access) enabledLayouts=\(available); no events posted")
        exit(access && available ? 0 : 77)
    }
    guard ProcessInfo.processInfo.environment["RUSWITCH_ALLOW_FOCUS_STEALING"] == "1" else { exit(77) }
    guard let pidText = argument("--host-pid"), let hostPID = Int32(pidText), hostPID > 0 else { exit(64) }
    var report = DriverReport(runID: config.runID)
    var exitCode: Int32 = 0
    do {
        try execute(stimulus, config: config, root: sessionURL.deletingLastPathComponent(), hostPID: hostPID, report: &report)
        report.status = "complete"
    } catch {
        report.reason = String(describing: error)
        report.status = error as? DriverError == .blockedPermission || error as? DriverError == .blockedLayout ? "blockedEnvironment" : "invalidRun"
        exitCode = report.status == "blockedEnvironment" ? 77 : 70
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(report).write(to: sessionURL.deletingLastPathComponent().appendingPathComponent("driver-result.json"), options: .atomic)
    exit(exitCode)
} catch {
    FileHandle.standardError.write(Data("Invalid external native driver configuration\n".utf8))
    exit(64)
}
