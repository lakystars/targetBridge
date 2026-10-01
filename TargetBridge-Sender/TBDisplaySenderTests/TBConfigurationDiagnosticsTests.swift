import XCTest
@testable import TargetBridge

final class TBConfigurationDiagnosticsTests: XCTestCase {
    func testMissingEssentialsNeedAttention() {
        let checks = TBConfigurationDiagnostics.checks(for: baseSnapshot(hasScreenRecording: false, localInterfaceName: nil, receiverAddress: ""))

        XCTAssertEqual(checks.first(where: { $0.id == "screen_recording" })?.state, .attention)
        XCTAssertEqual(checks.first(where: { $0.id == "local_link" })?.state, .attention)
        XCTAssertEqual(checks.first(where: { $0.id == "receiver_address" })?.state, .attention)
    }

    func testThunderboltTransportWarnsWhenBridgeIsNotSelected() {
        let checks = TBConfigurationDiagnostics.checks(for: baseSnapshot(localInterfaceName: "en0"))
        XCTAssertEqual(checks.first(where: { $0.id == "local_link" })?.state, .attention)
    }

    func testThunderboltTransportReportsInactiveLinkWhenNoBridgeInterface() {
        let check = TBConfigurationDiagnostics.checks(for: baseSnapshot(localInterfaceName: nil))
            .first(where: { $0.id == "local_link" })
        XCTAssertEqual(check?.state, .attention)
        XCTAssertEqual(check?.detailKey, "sender.diagnostics.thunderbolt_link_inactive")
    }

    func testThunderboltCableOnUSBGetsItsOwnHint() {
        var snapshot = baseSnapshot(localInterfaceName: nil)
        snapshot.thunderboltCableUSBOnly = true
        let check = TBConfigurationDiagnostics.checks(for: snapshot).first(where: { $0.id == "local_link" })
        XCTAssertEqual(check?.state, .attention)
        XCTAssertEqual(check?.detailKey, "sender.diagnostics.thunderbolt_link_usb_only")
    }

    func testNetworkTransportAsksForInterfaceWhenNoneSelected() {
        var snapshot = baseSnapshot(localInterfaceName: nil)
        snapshot.transportIsThunderbolt = false
        let check = TBConfigurationDiagnostics.checks(for: snapshot)
            .first(where: { $0.id == "local_link" })
        XCTAssertEqual(check?.detailKey, "sender.diagnostics.local_link_missing")
    }

    func testColorDepthFallbackNeedsAttention() {
        var snapshot = baseSnapshot()
        snapshot.colorDepth = .fallbackNoFrames
        let check = TBConfigurationDiagnostics.checks(for: snapshot).first(where: { $0.id == "color_depth" })
        XCTAssertEqual(check?.state, .attention)
        XCTAssertEqual(check?.detailKey, "sender.diagnostics.color_depth_fallback_no_frames")
    }

    func testColorDepthTenBitPasses() {
        var snapshot = baseSnapshot()
        snapshot.colorDepth = .tenBit
        let check = TBConfigurationDiagnostics.checks(for: snapshot).first(where: { $0.id == "color_depth" })
        XCTAssertEqual(check?.state, .passed)
    }

    func testReceiverControlChecksBothSidesOfInputRelay() {
        let checks = TBConfigurationDiagnostics.checks(for: baseSnapshot(requiresSenderAccessibility: true, senderAccessibilityGranted: false, requiresReceiverInputMonitoring: true, receiverInputMonitoringGranted: false))

        XCTAssertEqual(checks.first(where: { $0.id == "sender_accessibility" })?.state, .attention)
        XCTAssertEqual(checks.first(where: { $0.id == "receiver_input_monitoring" })?.state, .attention)
    }

    private func baseSnapshot(
        hasScreenRecording: Bool = true,
        localInterfaceName: String? = "bridge0",
        receiverAddress: String = "169.254.1.2",
        requiresSenderAccessibility: Bool = false,
        senderAccessibilityGranted: Bool = true,
        requiresReceiverInputMonitoring: Bool = false,
        receiverInputMonitoringGranted: Bool? = true
    ) -> TBConfigurationDiagnosticSnapshot {
        TBConfigurationDiagnosticSnapshot(
            hasScreenRecording: hasScreenRecording, transportIsThunderbolt: true, localInterfaceName: localInterfaceName,
            receiverAddress: receiverAddress, receiverProfileAvailable: true, receiverSupportsHEVC: true,
            requiresHEVC: false, cableRate: 18.5, requiresSenderInputMonitoring: false,
            senderInputMonitoringGranted: true, requiresSenderAccessibility: requiresSenderAccessibility,
            senderAccessibilityGranted: senderAccessibilityGranted, requiresReceiverInputMonitoring: requiresReceiverInputMonitoring,
            receiverInputMonitoringGranted: receiverInputMonitoringGranted, requiresReceiverAccessibility: false,
            receiverAccessibilityGranted: true
        )
    }
}
