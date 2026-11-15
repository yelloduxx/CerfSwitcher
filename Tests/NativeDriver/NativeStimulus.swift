import Foundation
import RuSwitcherTestSupport

enum NativeAction: Decodable {
    case key(PhysicalTypingAction)
    case shift(at: UInt64, code: UInt16, pressed: Bool)
    case checkpoint(at: UInt64, id: String)

    private enum CodingKeys: String, CodingKey {
        case kind, atMicroseconds, keyCode, shift, id
    }

    private struct ActionKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(String.self, forKey: .kind)
        if kind == "flagsChanged" || kind == "checkpoint" {
            let keys = try decoder.container(keyedBy: ActionKey.self).allKeys.map(\.stringValue)
            let allowed = kind == "flagsChanged" ? ["kind", "atMicroseconds", "keyCode", "shift"] : ["kind", "atMicroseconds", "id"]
            guard Set(keys) == Set(allowed) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid native action fields"))
            }
        }
        switch kind {
        case "flagsChanged":
            self = .shift(at: try values.decode(UInt64.self, forKey: .atMicroseconds),
                          code: try values.decode(UInt16.self, forKey: .keyCode),
                          pressed: try values.decode(Bool.self, forKey: .shift))
        case "checkpoint":
            self = .checkpoint(at: try values.decode(UInt64.self, forKey: .atMicroseconds),
                               id: try values.decode(String.self, forKey: .id))
        default:
            self = .key(try PhysicalTypingAction(from: decoder))
        }
    }

    var atMicroseconds: UInt64 {
        switch self {
        case let .key(action): action.atMicroseconds
        case let .shift(at, _, _), let .checkpoint(at, _): at
        }
    }
}

struct NativeStimulus: Decodable {
    let physical: PhysicalTypingStimulus
    let actions: [NativeAction]

    private enum CodingKeys: String, CodingKey {
        case version, id, layoutIDs, initialLayoutID, keyboardType, actions, timing
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        actions = try values.decode([NativeAction].self, forKey: .actions)
        physical = PhysicalTypingStimulus(
            id: try values.decode(String.self, forKey: .id),
            layoutIDs: try values.decode([String].self, forKey: .layoutIDs),
            initialLayoutID: try values.decode(String.self, forKey: .initialLayoutID),
            keyboardType: try values.decode(UInt32.self, forKey: .keyboardType),
            actions: actions.compactMap { if case let .key(action) = $0 { action } else { nil } },
            version: try values.decode(Int.self, forKey: .version),
            timing: try values.decodeIfPresent(PhysicalTypingTiming.self, forKey: .timing)
        )
    }
}
