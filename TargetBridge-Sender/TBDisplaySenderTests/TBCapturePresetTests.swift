import XCTest
@testable import TargetBridge

final class TBCapturePresetTests: XCTestCase {
    func testFiveK60AllowsFourPendingPacketsForEncoderLatency() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["MPVP"] != nil, "MPVP override set")
        XCTAssertEqual(TBDisplayCapturePreset.native5k60Experimental.maxPendingVideoPackets, 4)
    }

    func testOtherPresetsKeepThreePendingPackets() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["MPVP"] != nil, "MPVP override set")
        for preset in TBDisplayCapturePreset.allCases where preset != .native5k60Experimental {
            XCTAssertEqual(preset.maxPendingVideoPackets, 3, preset.rawValue)
        }
    }
}
