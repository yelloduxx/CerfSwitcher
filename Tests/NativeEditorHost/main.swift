import AppKit
import Foundation
import RuSwitcherAppSupport

private enum HostStatus: String, Codable {
    case ready, recording, complete, interrupted
}

private enum HostError: Error {
    case invalidOutput
}

private struct HostEvent: Codable, Equatable {
    let kind: String
    let keyCode: Int
    let marker: Int64
    let atNanoseconds: UInt64
    let textAfter: String
    let selection: [Int]
    let eventCharacters: String?
}

private struct ReceivedEvent: Codable, Equatable {
    let kind: String
    let keyCode: Int
    let marker: Int64
    let atNanoseconds: UInt64
}

private struct QuartzEvent: Codable, Equatable {
    let kind: String
    let keyCode: Int
    let marker: Int64
    let atNanoseconds: UInt64
    let eventTimestampNanoseconds: UInt64
}

private struct HostSnapshot: Codable, Equatable {
    var schemaVersion = 2
    let runID: String
    let pid: Int
    let status: HostStatus
    let active: Bool
    let keyWindow: Bool
    let text: String
    let selection: [Int]
    let unexpectedInputCount: Int
    let eventTrace: [HostEvent]
    let receivedEvents: [ReceivedEvent]
    let quartzEvents: [QuartzEvent]
    let quartzTapAvailable: Bool
    let quartzTapInterrupted: Bool

    func write(to root: URL, final: Bool) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: root.appendingPathComponent("host-state.json"), options: .atomic)
        if final {
            try data.write(to: root.appendingPathComponent("host-result.json"), options: .atomic)
        }
    }
}

@MainActor
private final class ProbeTextView: NSTextView {
    weak var host: NativeEditorHost?

    override func keyDown(with event: NSEvent) {
        guard host?.acceptKeyboard(event) == true else { return }
        super.keyDown(with: event)
        host?.record(event, kind: "keyDown")
    }

    override func keyUp(with event: NSEvent) {
        guard host?.acceptKeyboard(event) == true else { return }
        super.keyUp(with: event)
        host?.record(event, kind: "keyUp")
    }

    override func flagsChanged(with event: NSEvent) {
        guard host?.acceptKeyboard(event) == true else { return }
        super.flagsChanged(with: event)
        host?.record(event, kind: "flagsChanged")
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard host?.acceptKeyboard(event) == true else { return true }
        let handled = super.performKeyEquivalent(with: event)
        if handled { host?.record(event, kind: "keyEquivalent") }
        return handled
    }

    override func mouseDown(with event: NSEvent) {
        host?.unexpectedInput()
    }

    override func rightMouseDown(with event: NSEvent) {
        host?.unexpectedInput()
    }

    override func otherMouseDown(with event: NSEvent) {
        host?.unexpectedInput()
    }

    // Even marked shortcuts must not import or export the user's clipboard.
    override func paste(_ sender: Any?) { host?.unexpectedInput() }
    override func pasteAsPlainText(_ sender: Any?) { host?.unexpectedInput() }
    override func pasteAsRichText(_ sender: Any?) { host?.unexpectedInput() }
    override func copy(_ sender: Any?) { host?.unexpectedInput() }
    override func cut(_ sender: Any?) { host?.unexpectedInput() }
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        host?.unexpectedInput()
        return false
    }
}

@MainActor
private final class NativeEditorHost: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let config: ExternalNativeProbeConfiguration
    private let root: URL
    private let started = ProcessInfo.processInfo.systemUptime
    private var status = HostStatus.ready
    private var text = ""
    private var selection = [0, 0]
    private var unexpectedInputCount = 0
    private var eventTrace: [HostEvent] = []
    private var receivedEvents: [ReceivedEvent] = []
    private var quartzEvents: [QuartzEvent] = []
    private var quartzTapAvailable = false
    private var quartzTapInterrupted = false
    private var quartzTap: CFMachPort?
    private var quartzSource: CFRunLoopSource?
    private var window: NSWindow?
    private var textView: ProbeTextView?
    private var timer: Timer?
    private var eventMonitor: Any?
    private var finished = false

    init(config: ExternalNativeProbeConfiguration, root: URL) {
        self.config = config
        self.root = root
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard startQuartzObservation() else {
            finish(.interrupted, terminate: false)
            exit(77)
        }
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 720, height: 360),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "RuSwitcher Native Editor"
        window.delegate = self
        window.isReleasedWhenClosed = false

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 720, height: 360))
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]
        let view = ProbeTextView(frame: scrollView.contentView.bounds)
        view.host = self
        view.isRichText = false
        view.isEditable = true
        view.isSelectable = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.enabledTextCheckingTypes = 0
        scrollView.documentView = view
        window.contentView = scrollView
        self.window = window
        textView = view

        // Filter before AppKit can dispatch an unmarked command-key equivalent.
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            let allowed = MainActor.assumeIsolated {
                guard let self else { return false }
                switch event.type {
                case .keyDown, .keyUp, .flagsChanged:
                    guard self.acceptKeyboard(event) else { return false }
                    self.recordReceipt(event)
                    return true
                default:
                    self.checkControlFiles()
                    if self.status == .recording {
                        self.unexpectedInput()
                        return false
                    }
                    return !self.finished
                }
            }
            return allowed ? event : nil
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)

        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        tick()
    }

    func applicationDidResignActive(_ notification: Notification) {
        if status == .recording { finish(.interrupted) }
    }

    func windowDidResignKey(_ notification: Notification) {
        if status == .recording { finish(.interrupted) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(.interrupted)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !finished { finish(.interrupted, terminate: false) }
        return .terminateNow
    }

    private func startQuartzObservation() -> Bool {
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreateForPid(
            pid: ProcessInfo.processInfo.processIdentifier,
            place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, pointer in
                if let pointer {
                    MainActor.assumeIsolated {
                        Unmanaged<NativeEditorHost>.fromOpaque(pointer).takeUnretainedValue()
                            .recordQuartzReceipt(type: type, event: event)
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        quartzTap = tap
        quartzSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        quartzTapAvailable = CGEvent.tapIsEnabled(tap: tap)
        return quartzTapAvailable
    }

    private func recordQuartzReceipt(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            quartzTapInterrupted = true
            finish(.interrupted)
            return
        }
        guard status == .recording, !finished else { return }
        let marker = event.getIntegerValueField(.eventSourceUserData)
        guard config.inputActionIndex(eventMarker: marker) != nil || marker == config.replacementMarker else {
            unexpectedInput()
            return
        }
        guard quartzEvents.count < 10_000 else { finish(.interrupted); return }
        let kind: String
        switch type {
        case .keyDown: kind = "keyDown"
        case .keyUp: kind = "keyUp"
        case .flagsChanged: kind = "flagsChanged"
        default: return
        }
        // Process-scoped, listen-only observation. Never read the key's text,
        // mutate an event, or touch files in the ordinary callback path.
        quartzEvents.append(.init(kind: kind,
                                  keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
                                  marker: marker, atNanoseconds: DispatchTime.now().uptimeNanoseconds,
                                  eventTimestampNanoseconds: event.timestamp))
    }

    func acceptKeyboard(_ event: NSEvent) -> Bool {
        checkControlFiles()
        guard status == .recording, !finished else { return false }
        let marker = event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
        guard config.inputActionIndex(eventMarker: marker) != nil || marker == config.replacementMarker else {
            unexpectedInput()
            return false
        }
        guard editorMatchesSnapshot() else {
            unexpectedInput()
            return false
        }
        guard eventTrace.count < 10_000 else {
            finish(.interrupted)
            return false
        }
        return true
    }

    func record(_ event: NSEvent, kind: String) {
        guard status == .recording, !finished, let view = textView else { return }
        guard eventTrace.count < 10_000 else {
            finish(.interrupted)
            return
        }
        text = view.string
        let range = view.selectedRange()
        selection = [range.location, range.length]
        eventTrace.append(HostEvent(
            kind: kind,
            keyCode: Int(event.keyCode),
            marker: event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0,
            atNanoseconds: DispatchTime.now().uptimeNanoseconds,
            textAfter: text,
            selection: selection,
            eventCharacters: event.type == .keyDown || event.type == .keyUp ? event.characters : nil
        ))
    }

    private func recordReceipt(_ event: NSEvent) {
        guard receivedEvents.count < 10_000 else { finish(.interrupted); return }
        let kind: String
        switch event.type {
        case .keyDown: kind = "keyDown"
        case .keyUp: kind = "keyUp"
        default: kind = "flagsChanged"
        }
        // Arrival at the app is different from NSTextView choosing to handle it.
        receivedEvents.append(.init(kind: kind, keyCode: Int(event.keyCode),
                                     marker: event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0,
                                     atNanoseconds: DispatchTime.now().uptimeNanoseconds))
    }

    func unexpectedInput() {
        checkControlFiles()
        guard status == .recording, !finished else { return }
        unexpectedInputCount += 1
        finish(.interrupted)
    }

    private func checkControlFiles() {
        guard !finished else { return }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("stop").path) {
            finish(.complete)
            return
        }
        if ProcessInfo.processInfo.systemUptime - started >= min(config.timeoutSeconds, 120) {
            finish(.interrupted)
            return
        }
        if status == .ready,
           FileManager.default.fileExists(atPath: root.appendingPathComponent("record").path) {
            status = .recording
        }
        if status == .recording,
           !NSApp.isActive || window?.isKeyWindow != true || window?.firstResponder !== textView {
            finish(.interrupted)
        }
    }

    private func tick() {
        checkControlFiles()
        guard !finished else { return }
        // Retain only snapshots captured after trusted key handling. An unrelated
        // edit or selection change must not enter the serialized record.
        if !editorMatchesSnapshot() {
            unexpectedInputCount += 1
            finish(.interrupted)
            return
        }
        write(final: false)
    }

    private func editorMatchesSnapshot() -> Bool {
        guard let view = textView else { return false }
        let range = view.selectedRange()
        return view.string == text && [range.location, range.length] == selection
    }

    private func write(final: Bool) {
        let snapshot = HostSnapshot(
            runID: config.runID.uuidString,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            status: status,
            active: NSApp.isActive,
            keyWindow: window?.isKeyWindow ?? false,
            text: text,
            selection: selection,
            unexpectedInputCount: unexpectedInputCount,
            eventTrace: eventTrace,
            receivedEvents: receivedEvents,
            quartzEvents: quartzEvents,
            quartzTapAvailable: quartzTapAvailable,
            quartzTapInterrupted: quartzTapInterrupted
        )
        do {
            try snapshot.write(to: root, final: final)
        } catch {
            FileHandle.standardError.write(Data("native editor output failed\n".utf8))
            exit(74)
        }
    }

    private func finish(_ finalStatus: HostStatus, terminate: Bool = true) {
        guard !finished else { return }
        let completionIsCurrent = status == .recording && NSApp.isActive
            && window?.isKeyWindow == true && window?.firstResponder === textView
            && editorMatchesSnapshot()
        status = finalStatus
        // Validate before completing, but never copy untrusted edits into the report.
        if status == .complete, !completionIsCurrent {
            unexpectedInputCount += 1
            status = .interrupted
        }
        finished = true
        timer?.invalidate()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let quartzSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), quartzSource, .commonModes) }
        if let quartzTap { CFMachPortInvalidate(quartzTap) }
        quartzSource = nil
        quartzTap = nil
        write(final: true)
        if terminate { NSApp.terminate(nil) }
    }
}

private func selfCheck(config: ExternalNativeProbeConfiguration, root: URL) throws {
    try config.validate()
    let snapshot = HostSnapshot(
        runID: config.runID.uuidString,
        pid: Int(ProcessInfo.processInfo.processIdentifier),
        status: .complete,
        active: false,
        keyWindow: false,
        text: "",
        selection: [0, 0],
        unexpectedInputCount: 0,
        eventTrace: [],
        receivedEvents: [],
        quartzEvents: [.init(kind: "keyUp", keyCode: 49, marker: config.inputMarker + 1,
                             atNanoseconds: UInt64.max, eventTimestampNanoseconds: UInt64.max)],
        quartzTapAvailable: false,
        quartzTapInterrupted: false
    )
    // Exercise exact integer encoding without allocating any native event.
    guard let sampleMarker = config.inputEventMarker(actionIndex: 0) else { throw HostError.invalidOutput }
    let sample = HostEvent(
        kind: "keyDown", keyCode: 0, marker: sampleMarker,
        atNanoseconds: UInt64.max, textAfter: "synthetic", selection: [9, 0], eventCharacters: "a"
    )
    let sampleData = try JSONEncoder().encode(sample)
    guard try JSONDecoder().decode(HostEvent.self, from: sampleData) == sample else {
        throw HostError.invalidOutput
    }
    try snapshot.write(to: root, final: true)
    for name in ["host-state.json", "host-result.json"] {
        let data = try Data(contentsOf: root.appendingPathComponent(name))
        guard try JSONDecoder().decode(HostSnapshot.self, from: data) == snapshot else {
            throw HostError.invalidOutput
        }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let isSelfCheck = arguments.contains("--self-check")
if !isSelfCheck && ProcessInfo.processInfo.environment["RUSWITCH_ALLOW_FOCUS_STEALING"] != "1" {
    exit(77)
}
var sessionPath: String?
var index = 0
var selfCheckCount = 0
while index < arguments.count {
    switch arguments[index] {
    case "--self-check":
        selfCheckCount += 1
        guard selfCheckCount == 1 else { exit(64) }
    case "--session":
        index += 1
        guard index < arguments.count, sessionPath == nil else { exit(64) }
        sessionPath = arguments[index]
    default:
        exit(64)
    }
    index += 1
}
guard let sessionPath, sessionPath.hasPrefix("/") else {
    FileHandle.standardError.write(Data("usage: RuSwitcherNativeEditorHost --session PATH [--self-check]\n".utf8))
    exit(64)
}
let sessionURL = URL(fileURLWithPath: sessionPath)
let root = sessionURL.deletingLastPathComponent()
let config: ExternalNativeProbeConfiguration
do {
    config = try ExternalNativeProbeConfiguration.load(from: sessionURL)
} catch {
    FileHandle.standardError.write(Data("invalid native editor configuration\n".utf8))
    exit(64)
}
if isSelfCheck {
    do {
        try selfCheck(config: config, root: root)
        print("native editor self-check passed; no application, window or input events")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("native editor self-check failed\n".utf8))
        exit(74)
    }
}

var textServiceOverrides = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
textServiceOverrides["NSAutomaticPeriodSubstitutionEnabled"] = false
textServiceOverrides["NSAutomaticCapitalizationEnabled"] = false
UserDefaults.standard.setVolatileDomain(textServiceOverrides, forName: UserDefaults.argumentDomain)
let app = NSApplication.shared
private let host = NativeEditorHost(config: config, root: root)
app.setActivationPolicy(.regular)
app.delegate = host
withExtendedLifetime(host) { app.run() }
