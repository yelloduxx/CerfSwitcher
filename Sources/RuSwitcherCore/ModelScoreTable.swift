import Foundation

/// A string-to-score hash table read in place from the memory-mapped model,
/// so loading parses nothing and the scores stay clean file-backed pages.
/// Layout (little-endian): `RSHT`, version, reserved, entry count, slot
/// count, key-blob length; slots holding entry index + 1 (0 = empty);
/// entries sorted by key as (key offset, float64), a key ending where the
/// next begins; then the UTF-8 key blob.
struct ModelScoreTable: Sendable {
    private static let headerSize = 20
    private static let entrySize = 12

    static let empty = ModelScoreTable()

    let count: Int
    private let storage: Data
    private let slotCount: Int
    private let slotsOffset: Int
    private let entriesOffset: Int
    private let keysOffset: Int
    private let keysLength: Int

    private init() {
        count = 0
        storage = Data()
        slotCount = 0
        slotsOffset = 0
        entriesOffset = 0
        keysOffset = 0
        keysLength = 0
    }

    init(storage: Data, range: Range<Int>, section: Int) throws {
        let invalid = LanguageModelError.invalidSection(section)
        guard range.count >= Self.headerSize else { throw invalid }
        let header = storage.withUnsafeBytes { raw in
            (
                magic: raw.loadUnaligned(fromByteOffset: range.lowerBound, as: UInt32.self),
                version: UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: range.lowerBound + 4, as: UInt16.self)),
                count: Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: range.lowerBound + 8, as: UInt32.self))),
                slots: Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: range.lowerBound + 12, as: UInt32.self))),
                keys: Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: range.lowerBound + 16, as: UInt32.self)))
            )
        }
        guard header.magic == UInt32(littleEndian: 0x5448_5352),
              header.version == 1,
              header.slots > header.count,
              header.slots.nonzeroBitCount == 1,
              range.count == Self.headerSize + header.slots * 4 + header.count * Self.entrySize + header.keys
        else { throw invalid }
        self.storage = storage
        count = header.count
        slotCount = header.slots
        slotsOffset = range.lowerBound + Self.headerSize
        entriesOffset = slotsOffset + header.slots * 4
        keysOffset = entriesOffset + header.count * Self.entrySize
        keysLength = header.keys
        guard validate() else { throw invalid }
    }

    func value(for key: String) -> Double? {
        guard count > 0 else { return nil }
        var key = key
        return key.withUTF8 { utf8 -> Double? in
            guard !utf8.isEmpty else { return nil }
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x100_0000_01b3
            }
            return storage.withUnsafeBytes { raw -> Double? in
                let mask = slotCount - 1
                var slot = Int(truncatingIfNeeded: hash) & mask
                while true {
                    let reference = Int(UInt32(littleEndian: raw.loadUnaligned(
                        fromByteOffset: slotsOffset + slot * 4,
                        as: UInt32.self
                    )))
                    if reference == 0 { return nil }
                    let index = reference - 1
                    let key = keyRange(index, in: raw)
                    if key.count == utf8.count,
                       memcmp(raw.baseAddress! + keysOffset + key.lowerBound, utf8.baseAddress!, utf8.count) == 0 {
                        return Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(
                            fromByteOffset: entriesOffset + index * Self.entrySize + 4,
                            as: UInt64.self
                        )))
                    }
                    slot = (slot + 1) & mask
                }
            }
        }
    }

    /// Every entry in key order; offline quality gates only.
    func entries() -> [(key: String, value: Double)] {
        storage.withUnsafeBytes { raw in
            (0..<count).map { index in
                let key = keyRange(index, in: raw)
                let bytes = UnsafeRawBufferPointer(
                    rebasing: raw[(keysOffset + key.lowerBound)..<(keysOffset + key.upperBound)]
                )
                let value = Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(
                    fromByteOffset: entriesOffset + index * Self.entrySize + 4,
                    as: UInt64.self
                )))
                return (String(decoding: bytes, as: UTF8.self), value)
            }
        }
    }

    func minimumValue() -> Double? {
        storage.withUnsafeBytes { raw in
            (0..<count).lazy.map { index in
                Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(
                    fromByteOffset: entriesOffset + index * Self.entrySize + 4,
                    as: UInt64.self
                )))
            }.min()
        }
    }

    private func keyStart(_ index: Int, in raw: UnsafeRawBufferPointer) -> Int {
        guard index < count else { return keysLength }
        return Int(UInt32(littleEndian: raw.loadUnaligned(
            fromByteOffset: entriesOffset + index * Self.entrySize,
            as: UInt32.self
        )))
    }

    private func keyRange(_ index: Int, in raw: UnsafeRawBufferPointer) -> Range<Int> {
        keyStart(index, in: raw)..<keyStart(index + 1, in: raw)
    }

    /// Lookups trust offsets and slot references, so check them once at load.
    private func validate() -> Bool {
        storage.withUnsafeBytes { raw in
            var previous = 0
            for index in 0..<count {
                let start = keyStart(index, in: raw)
                guard index == 0 ? start == 0 : start > previous, start < keysLength else { return false }
                previous = start
            }
            var empty = false
            for slot in 0..<slotCount {
                let reference = Int(UInt32(littleEndian: raw.loadUnaligned(
                    fromByteOffset: slotsOffset + slot * 4,
                    as: UInt32.self
                )))
                guard reference <= count else { return false }
                empty = empty || reference == 0
            }
            return empty
        }
    }
}
