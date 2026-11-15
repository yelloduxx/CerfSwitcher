import Foundation
import RuSwitcherCore

public enum PersonalDataStoreError: Error, Equatable {
    case readBackFailed
    case invalidStoredData
    case capacityExceeded
    case externalChange
}

public enum PersonalDataUndoResult: Equatable, Sendable {
    case undone
    case conflict
    /// Foreign, consumed, expired, or invalidated by a replacement/reset.
    case invalidReceipt
}

public struct ManualLearningSave: Sendable {
    public let decision: ManualLearningDecision
    public let receipt: ManualLearningReceipt
}

public struct ManualLearningReceipt: Sendable {
    let owner: UUID
    let id: UUID
    let changes: [RuleChange]
}

public struct PersonalLexiconRemovalReceipt: Sendable {
    public let wasPromoted: Bool
    let owner: UUID
    let id: UUID
    let key: String
    let entry: PersonalLexicon.Entry
}

struct RuleKey: Hashable, Sendable {
    let original: String
    let converted: String
    let app: String?

    init(_ rule: AdaptiveRule) {
        original = FrequentWordLexicon.normalize(SmartTokenizer.lexicalCore(of: rule.original))
        converted = FrequentWordLexicon.normalize(SmartTokenizer.lexicalCore(of: rule.converted))
        app = rule.appBundleID
    }
}

struct RuleChange: Sendable {
    let key: RuleKey
    let before: [IndexedRule]
    let after: [AdaptiveRule]

    struct IndexedRule: Sendable {
        let index: Int
        let rule: AdaptiveRule
    }

    static func between(_ before: [AdaptiveRule], _ after: [AdaptiveRule]) -> [RuleChange] {
        let old = Dictionary(grouping: before.enumerated().map { IndexedRule(index: $0.offset, rule: $0.element) }) {
            RuleKey($0.rule)
        }
        let new = Dictionary(grouping: after, by: RuleKey.init)
        return Set(old.keys).union(new.keys).compactMap { key in
            let previous = old[key] ?? []
            let next = new[key] ?? []
            guard previous.map(\.rule) != next else { return nil }
            return RuleChange(key: key, before: previous, after: next)
        }
    }
}

struct ReceiptWindow<Key: Hashable> {
    static var limit: Int { 32 }
    private var entries: [(id: UUID, keys: Set<Key>, conflicted: Bool)] = []

    mutating func insert(keys: Set<Key>) -> UUID {
        let id = UUID()
        entries.append((id, keys, false))
        if entries.count > Self.limit { entries.removeFirst() }
        return id
    }

    mutating func invalidate(keys: Set<Key>) {
        for index in entries.indices where !entries[index].keys.isDisjoint(with: keys) {
            entries[index].conflicted = true
        }
    }

    func status(_ id: UUID) -> PersonalDataUndoResult? {
        guard let entry = entries.first(where: { $0.id == id }) else { return .invalidReceipt }
        return entry.conflicted ? .conflict : nil
    }

    mutating func consume(_ id: UUID) { entries.removeAll { $0.id == id } }
    mutating func clear() { entries.removeAll() }
}
