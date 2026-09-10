import XCTest
import RuSwitcherAppSupport

final class ExternalNativeProbeConfigurationTests: XCTestCase {
    func testConfigurationRoundTripKeepsIsolatedScopeAndMarkers() throws {
        let config = configuration()
        try config.validate()
        XCTAssertEqual(try JSONDecoder().decode(ExternalNativeProbeConfiguration.self,
                                               from: JSONEncoder().encode(config)), config)
        XCTAssertNotEqual(configuration().preferencesDomain, config.preferencesDomain)
    }

    func testInvalidConfigurationFailsBeforeAnyNativeAction() {
        for config in [configuration(layouts: ["en", "en"]), configuration(layouts: []),
                       configuration(inputMarker: 0), configuration(inputMarker: 0x52555300),
                       configuration(inputMarker: 0x52555300 - 5), configuration(inputMarker: .max),
                       configuration(timeout: 0), configuration(timeout: 121), configuration(timeout: .infinity)] {
            XCTAssertThrowsError(try config.validate())
        }
    }

    func testEveryActionHasAnUnambiguousMarkerIncludingRepeatedKeys() throws {
        let config = configuration()
        try config.validate()
        let markers = (0..<ExternalNativeProbeConfiguration.maximumActions).compactMap { config.inputEventMarker(actionIndex: $0) }
        XCTAssertEqual(Set(markers).count, ExternalNativeProbeConfiguration.maximumActions)
        for (index, marker) in markers.enumerated() {
            XCTAssertEqual(config.inputActionIndex(eventMarker: marker), index)
        }
        XCTAssertNil(config.inputEventMarker(actionIndex: -1))
        XCTAssertNil(config.inputEventMarker(actionIndex: ExternalNativeProbeConfiguration.maximumActions))
        for marker in [config.inputMarker, config.replacementMarker, Int64.min, Int64.max] {
            XCTAssertNil(config.inputActionIndex(eventMarker: marker))
        }
    }

    private func configuration(layouts: [String] = ["en", "ru"], inputMarker: Int64 = 1,
                               timeout: Double = 45) -> ExternalNativeProbeConfiguration {
        .init(runID: UUID(), layoutIDs: layouts, automaticConversion: true,
              inputMarker: inputMarker, replacementMarker: 0x52555300, timeoutSeconds: timeout)
    }
}
