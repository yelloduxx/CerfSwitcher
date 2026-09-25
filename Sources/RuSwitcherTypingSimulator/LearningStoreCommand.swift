import Foundation
import RuSwitcherCore
import RuSwitcherAppSupport

private struct LearningStoreRequest: Decodable {
    enum Action: String, Decodable { case record, inspect, export, clear, restore }
    let runID: UUID
    let action: Action
    let original: String
    let converted: String
    let appBundleID: String
}

/// Isolated persistence probe. The domain is derived from a UUID and cannot
/// name the production app's defaults. No editor, input event or UI is created.
@MainActor
func runLearningStoreProbe(inputPath: String) -> Never {
    do {
        let inputURL = URL(fileURLWithPath: inputPath)
        let file = try FileHandle(forReadingFrom: inputURL)
        defer { try? file.close() }
        let data = try file.read(upToCount: 16_385) ?? Data()
        guard data.count <= 16_384 else { exit(64) }
        let request = try JSONDecoder().decode(LearningStoreRequest.self, from: data)
        let domain = "com.ruswitcher.learning-test.\(request.runID.uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else { exit(70) }
        let store = LearnedRulesStore(defaults: defaults)
        let archive = inputURL.deletingLastPathComponent().appendingPathComponent("learned-rules.json")
        var outcome = "none"
        switch request.action {
        case .record:
            switch store.recordManualCorrection(original: request.original, converted: request.converted,
                                                appBundleID: request.appBundleID, model: LanguageModelStore.bundled) {
            case .ignore: outcome = "ignored"
            case .confirmation: outcome = "confirmed"
            case .applicationException: outcome = "application-exception"
            }
        case .inspect: break
        case .export: try store.exportRules().write(to: archive, options: .atomic)
        case .clear: store.clear()
        case .restore: _ = try store.importRules(Data(contentsOf: archive))
        }
        let book = store.snapshot
        let report: [String: Any] = [
            "runID": request.runID.uuidString, "pid": ProcessInfo.processInfo.processIdentifier,
            "action": request.action.rawValue, "outcome": outcome, "ruleCount": book.rules.count,
            "confirmed": book.isConfirmed(original: request.original, converted: request.converted, appBundleID: request.appBundleID),
            "applicationException": book.hasApplicationException(original: request.original, converted: request.converted, appBundleID: request.appBundleID),
            "globalConfirmed": book.isConfirmed(original: request.original, converted: request.converted, appBundleID: nil),
        ]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]))
        FileHandle.standardOutput.write(Data("\n".utf8))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("learning persistence probe failed\n".utf8))
        exit(70)
    }
}
