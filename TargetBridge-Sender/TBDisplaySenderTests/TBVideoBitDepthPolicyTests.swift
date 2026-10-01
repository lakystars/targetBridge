import CoreMedia
import XCTest
@testable import TargetBridge

final class TBVideoBitDepthPolicyTests: XCTestCase {
    func testHEVCToMain10ReceiverUsesTenBit() {
        XCTAssertTrue(TBVideoBitDepthPolicy.usesTenBit(
            codecType: kCMVideoCodecType_HEVC, usesRawNV12: false, receiverSupportsMain10: true, extendedCaptureAvailable: true, override: nil))
    }

    func testOlderReceiverStaysEightBit() {
        XCTAssertFalse(TBVideoBitDepthPolicy.usesTenBit(
            codecType: kCMVideoCodecType_HEVC, usesRawNV12: false, receiverSupportsMain10: nil, extendedCaptureAvailable: true, override: nil))
        XCTAssertFalse(TBVideoBitDepthPolicy.usesTenBit(
            codecType: kCMVideoCodecType_HEVC, usesRawNV12: false, receiverSupportsMain10: false, extendedCaptureAvailable: true, override: nil))
    }

    func testH264AndRawStayEightBit() {
        XCTAssertFalse(TBVideoBitDepthPolicy.usesTenBit(
            codecType: kCMVideoCodecType_H264, usesRawNV12: false, receiverSupportsMain10: true, extendedCaptureAvailable: true, override: nil))
        XCTAssertFalse(TBVideoBitDepthPolicy.usesTenBit(
            codecType: kCMVideoCodecType_HEVC, usesRawNV12: true, receiverSupportsMain10: true, extendedCaptureAvailable: true, override: nil))
    }

    func testPlatformWithoutExtendedCaptureStaysEightBit() {
        XCTAssertFalse(TBVideoBitDepthPolicy.usesTenBit(
            codecType: kCMVideoCodecType_HEVC, usesRawNV12: false, receiverSupportsMain10: true,
            extendedCaptureAvailable: false, override: nil))
    }

    func testOverrideZeroDisablesTenBit() {
        XCTAssertFalse(TBVideoBitDepthPolicy.usesTenBit(
            codecType: kCMVideoCodecType_HEVC, usesRawNV12: false, receiverSupportsMain10: true, extendedCaptureAvailable: true, override: "0"))
    }
}
