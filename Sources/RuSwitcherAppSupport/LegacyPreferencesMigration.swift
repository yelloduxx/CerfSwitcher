import Foundation

/// One-time copy of a previous product's defaults domain into the current one.
/// The legacy domain is only read, never changed, so the old app keeps working.
public enum LegacyPreferencesMigration {
    public static let markerKey = "com.cerfswitcher.migratedLegacyPreferences"

    public enum Outcome: Equatable {
        case alreadyMigrated
        case noLegacyDomain
        case copied(keys: Int)
    }

    /// Keys already stored in the target domain win, so a legacy domain that
    /// appears after the user configured the new app never overwrites them.
    /// Only the domains' own keys count: global and registered defaults do not.
    @discardableResult
    public static func run(
        legacyDomain: String,
        targetDomain: String,
        into target: UserDefaults
    ) -> Outcome {
        guard !target.bool(forKey: markerKey) else { return .alreadyMigrated }
        guard let legacy = target.persistentDomain(forName: legacyDomain), !legacy.isEmpty else {
            return .noLegacyDomain
        }
        let existing = target.persistentDomain(forName: targetDomain) ?? [:]
        var copied = 0
        for (key, value) in legacy where existing[key] == nil {
            target.set(value, forKey: key)
            copied += 1
        }
        target.set(true, forKey: markerKey)
        return .copied(keys: copied)
    }
}
