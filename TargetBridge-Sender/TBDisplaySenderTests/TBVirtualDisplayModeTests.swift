import XCTest
@testable import TargetBridge

final class TBVirtualDisplayModeTests: XCTestCase {
    private let mode = TBVirtualDisplayModeSize(width: 2560, height: 1440)

    func testHiDPIPrefersTwoTimesBackingOverLowResolutionDuplicate() {
        let candidates = [
            TBDisplayModeCandidate(width: 2560, height: 1440, pixelWidth: 2560, refreshRate: 60),
            TBDisplayModeCandidate(width: 2560, height: 1440, pixelWidth: 5120, refreshRate: 60)
        ]
        let index = ReceiverBackedVirtualDisplaySession.preferredCandidateOrder(
            candidates, mode: mode, hiDPI: true, refreshRate: 60).first
        XCTAssertEqual(index, 1)
    }

    func testNonHiDPIPrefersOneTimesBacking() {
        let candidates = [
            TBDisplayModeCandidate(width: 2560, height: 1440, pixelWidth: 5120, refreshRate: 60),
            TBDisplayModeCandidate(width: 2560, height: 1440, pixelWidth: 2560, refreshRate: 60)
        ]
        let index = ReceiverBackedVirtualDisplaySession.preferredCandidateOrder(
            candidates, mode: mode, hiDPI: false, refreshRate: 60).first
        XCTAssertEqual(index, 1)
    }

    func testRequestedRefreshRateWinsAmongBackingMatches() {
        let candidates = [
            TBDisplayModeCandidate(width: 2560, height: 1440, pixelWidth: 5120, refreshRate: 48),
            TBDisplayModeCandidate(width: 1920, height: 1080, pixelWidth: 3840, refreshRate: 60),
            TBDisplayModeCandidate(width: 2560, height: 1440, pixelWidth: 5120, refreshRate: 60)
        ]
        let index = ReceiverBackedVirtualDisplaySession.preferredCandidateOrder(
            candidates, mode: mode, hiDPI: true, refreshRate: 60).first
        XCTAssertEqual(index, 2)
    }

    func testNoMatchingPointSizeReturnsNil() {
        let candidates = [TBDisplayModeCandidate(width: 1920, height: 1080, pixelWidth: 3840, refreshRate: 60)]
        XCTAssertTrue(ReceiverBackedVirtualDisplaySession.preferredCandidateOrder(
            candidates, mode: mode, hiDPI: true, refreshRate: 60).isEmpty)
    }

    func testFallbackOrderKeepsLowResolutionVariantAfterHiDPI() {
        let candidates = [
            TBDisplayModeCandidate(width: 2560, height: 1440, pixelWidth: 2560, refreshRate: 60),
            TBDisplayModeCandidate(width: 2560, height: 1440, pixelWidth: 5120, refreshRate: 60)
        ]
        XCTAssertEqual(ReceiverBackedVirtualDisplaySession.preferredCandidateOrder(
            candidates, mode: mode, hiDPI: true, refreshRate: 60), [1, 0])
    }

    func testModeChoiceMatchesIgnoringRefreshRate() {
        let a = TBVirtualDisplayModeMemory.Choice(pointWidth: 2560, pointHeight: 1440,
                                                  pixelWidth: 5120, pixelHeight: 2880, refreshRate: 60)
        let b = TBVirtualDisplayModeMemory.Choice(pointWidth: 2560, pointHeight: 1440,
                                                  pixelWidth: 5120, pixelHeight: 2880, refreshRate: 59.94)
        let lowRes = TBVirtualDisplayModeMemory.Choice(pointWidth: 2560, pointHeight: 1440,
                                                       pixelWidth: 2560, pixelHeight: 1440, refreshRate: 60)
        XCTAssertTrue(a.matches(b))
        XCTAssertFalse(a.matches(lowRes))
    }
}
