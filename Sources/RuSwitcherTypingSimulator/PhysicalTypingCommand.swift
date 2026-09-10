import CryptoKit
import Foundation
import RuSwitcherCore
import RuSwitcherTestSupport

private struct PhysicalRunReport: Encodable {
    let simulator = "physical-keys-ideal-delivery"
    let engine = "v3"
    let limitations = ["synchronous-delivery", "no-AX-or-CGEvent", "no-manual-learning", "no-asynchronous-timing"]
    let runID: UUID
    var status = "invalidRun"
    var passed = false
    var error: String?
    let fault: String?
    var fixtureSHA256: String?
    var modelSHA256: String?
    var layoutSHA256: [String: String]?
    var keyboardType: UInt32?
    let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    var oracle: PhysicalTypingOracle?
    var execution: PhysicalTypingExecution?
    var assessment: PhysicalTypingAssessment?

    func write(to path: String?) throws {
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded().write(to: url, options: .atomic)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func runPhysical(inputPath: String, outputPath: String?, faultName: String?) -> Never {
    var report = PhysicalRunReport(runID: UUID(), error: "run has not completed", fault: faultName)
    var exitCode: Int32 = 70
    do {
        // Invalidate an old output before reading a fixture or loading resources.
        try report.write(to: outputPath)
        let data = try Data(contentsOf: URL(fileURLWithPath: inputPath))
        report.fixtureSHA256 = digest(data)
        let fixture = try JSONDecoder().decode(PhysicalTypingFixture.self, from: data)
        guard let model = LanguageModelStore.bundled, let modelURL = LanguageModelStore.bundledResourceURL else {
            throw PhysicalTypingError.invalidScenario("V3 model unavailable")
        }
        report.modelSHA256 = digest(try Data(contentsOf: modelURL))
        let layouts = try SystemTypingLayouts(ids: fixture.stimulus.layoutIDs)
        report.layoutSHA256 = layouts.entries.mapValues { digest($0.data) }
        report.keyboardType = fixture.stimulus.keyboardType
        var faults = PhysicalTypingFaults()
        switch faultName {
        case nil: break
        case "auto-off": faults.disableAutomaticConversion = true
        case "no-layout-switch": faults.disableLayoutSwitch = true
        case "drop-insertion": faults.dropInsertion = true
        case "duplicate-insertion": faults.duplicateInsertion = true
        default: throw PhysicalTypingError.invalidScenario("unknown injected fault")
        }
        // The interpreter receives no expected text, expected decisions or layout checkpoints.
        let execution = try PhysicalTypingRunner(layouts: layouts, model: model).run(fixture.stimulus, faults: faults)
        let assessment = PhysicalTypingAssessment.assess(execution, oracle: fixture.oracle)
        report.oracle = fixture.oracle
        report.execution = execution
        report.assessment = assessment
        report.passed = assessment.passed
        report.status = assessment.passed ? "passed" : "failed"
        report.error = nil
        exitCode = assessment.passed ? 0 : 1
    } catch PhysicalTypingError.unavailableLayout(let id) {
        report.status = "blockedEnvironment"
        report.error = "required layout unavailable: \(id)"
        exitCode = 77
    } catch {
        report.error = String(describing: error)
    }
    do {
        try report.write(to: outputPath)
        FileHandle.standardOutput.write(try report.encoded())
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("cannot write physical report: \(error)\n".utf8))
        exit(70)
    }
    exit(exitCode)
}
