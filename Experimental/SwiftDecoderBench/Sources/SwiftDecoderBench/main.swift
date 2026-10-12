import Foundation
import RuSwitcherCore

// Modes (stdout carries counts and timings only, never typed text):
//   load  --model M                         model load time
//   trace --model M --phrases P --out O     per-token detail, same schema as rscore
//   bench --model M --phrases P             warm single-thread per-token latency

private struct PhraseStep: Decodable {
    let typed: String
    let manualLanguage: String?
}

private struct PhraseFixture: Decodable {
    let id: String
    let initialLanguage: String
    let steps: [PhraseStep]
}

private struct StepOutcome {
    let evaluation: LayoutDecoderEvaluation
    let resolved: String
    let nanos: UInt64
}

private func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

private func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

/// The exact RuSwitcherSimulator `evaluatePhrase` loop; the timed span is
/// `KeyMapping.convert` + `LayoutDecoder.evaluate`, as in the Rust port.
private func runPhrase(_ fixture: PhraseFixture, model: LanguageModelStore, timed: Bool) -> [StepOutcome] {
    var currentLanguage = fixture.initialLanguage
    var context: [String] = []
    var belief = LanguageBelief.neutral
    var outcomes: [StepOutcome] = []
    outcomes.reserveCapacity(fixture.steps.count)
    for step in fixture.steps {
        if let manualLanguage = step.manualLanguage { currentLanguage = manualLanguage }
        let targetLanguage = currentLanguage == "ru" ? "en" : "ru"
        let typed = step.typed
        let start = timed ? now() : 0
        let converted = KeyMapping.convert(typed)
        let evaluation = LayoutDecoder.evaluate(
            typed: typed,
            converted: converted,
            currentLanguage: currentLanguage,
            targetLanguage: targetLanguage,
            capsLock: typed == typed.uppercased() && typed != typed.lowercased(),
            contextWords: context,
            languageBelief: belief,
            policy: .empty,
            model: model
        )
        let nanos = timed ? now() - start : 0
        let switched = evaluation.decision.verdict == .switchToConverted
        let resolved = switched ? evaluation.decision.candidate.replacement : typed
        let resolvedLanguage = switched ? targetLanguage : currentLanguage
        let contextToken = SmartTokenizer.lexicalCore(of: resolved)
        if !contextToken.isEmpty {
            context.append(contextToken)
            if context.count > 5 { context.removeFirst(context.count - 5) }
            belief.observe(language: resolvedLanguage, weight: switched ? 1.4 : 1.0)
        }
        if switched { currentLanguage = targetLanguage }
        outcomes.append(StepOutcome(evaluation: evaluation, resolved: resolved, nanos: nanos))
    }
    return outcomes
}

private func loadPhrases(_ path: String) -> [PhraseFixture] {
    let text = try! String(contentsOfFile: path, encoding: .utf8)
    let decoder = JSONDecoder()
    return text.split(whereSeparator: \.isNewline).enumerated().map { line, value in
        guard let fixture = try? decoder.decode(PhraseFixture.self, from: Data(value.utf8)) else {
            FileHandle.standardError.write(Data("invalid phrase JSONL at line \(line + 1)\n".utf8))
            exit(65)
        }
        return fixture
    }
}

private func percentile(_ sorted: [UInt64], _ p: Double) -> UInt64 {
    let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
    return sorted[min(max(rank, 1), sorted.count) - 1]
}

private func printJSON(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private func kindName(_ kind: AutoConvertCandidate.Kind) -> String {
    switch kind {
    case .directWord: "DirectWord"
    case .trailingPunctuation: "TrailingPunctuation"
    case .layoutLetterTail: "LayoutLetterTail"
    case .wrappingPunctuation: "WrappingPunctuation"
    }
}

let mode = CommandLine.arguments.dropFirst().first ?? ""
let modelPath = argument("--model") ?? "../../Sources/RuSwitcherCore/Resources/language-model-v1.bin"
let loadStarted = now()
guard let model = try? LanguageModelStore(contentsOf: URL(fileURLWithPath: modelPath)) else {
    FileHandle.standardError.write(Data("language model unavailable\n".utf8))
    exit(70)
}
let loadMilliseconds = Double(now() - loadStarted) / 1e6

switch mode {
case "load":
    printJSON(["engine": "swift", "loadMilliseconds": loadMilliseconds, "modelVersion": model.metadata.modelVersion])
case "trace":
    guard let phrasesPath = argument("--phrases"), let outPath = argument("--out") else { exit(64) }
    let phrases = loadPhrases(phrasesPath)
    var lines: [String] = []
    var tokens = 0
    for phrase in phrases {
        let steps = runPhrase(phrase, model: model, timed: false)
        tokens += steps.count
        let rows: [[String: Any]] = steps.map { step in
            let e = step.evaluation
            return [
                "verdict": String(describing: e.decision.verdict),
                "resolved": step.resolved,
                "reason": String(describing: e.decision.reason),
                "literalScore": e.literalScore,
                "convertedScore": e.convertedScore,
                "threshold": e.threshold,
                "evidence": e.evidence.map { String(describing: $0) },
                "prefix": e.decision.candidate.prefix,
                "suffix": e.decision.candidate.suffix,
                "kind": kindName(e.decision.candidate.kind),
            ]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["id": phrase.id, "steps": rows], options: [.sortedKeys])
        lines.append(String(decoding: data, as: UTF8.self))
    }
    try! Data((lines.joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: outPath))
    printJSON(["engine": "swift", "phrases": phrases.count, "tokens": tokens, "loadMilliseconds": loadMilliseconds])
case "bench":
    guard let phrasesPath = argument("--phrases") else { exit(64) }
    let phrases = loadPhrases(phrasesPath)
    // Warm pass, untimed; then one timed pass on the same input.
    for phrase in phrases { _ = runPhrase(phrase, model: model, timed: false) }
    let wallStarted = now()
    var samples: [UInt64] = []
    for phrase in phrases {
        samples.append(contentsOf: runPhrase(phrase, model: model, timed: true).map(\.nanos))
    }
    let wallMilliseconds = Double(now() - wallStarted) / 1e6
    samples.sort()
    let mean = Double(samples.reduce(0, +)) / Double(samples.count)
    printJSON([
        "engine": "swift",
        "measured": "KeyMapping.convert + LayoutDecoder.evaluate per token, single thread, second pass",
        "samples": samples.count,
        "p50Micros": Double(percentile(samples, 50)) / 1e3,
        "p90Micros": Double(percentile(samples, 90)) / 1e3,
        "p99Micros": Double(percentile(samples, 99)) / 1e3,
        "p999Micros": Double(percentile(samples, 99.9)) / 1e3,
        "maxMicros": Double(samples.last!) / 1e3,
        "meanMicros": mean / 1e3,
        "timedPassMilliseconds": wallMilliseconds,
        "loadMilliseconds": loadMilliseconds,
    ])
default:
    FileHandle.standardError.write(Data("usage: SwiftDecoderBench load|trace|bench --model M [--phrases P] [--out O]\n".utf8))
    exit(64)
}
