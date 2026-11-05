import AppKit
import SwiftUI
import XCTest
@testable import MelonTools

/// Layout smoke tests for the shared controls.
///
/// They cannot prove that a native menu looks right, but they catch the
/// regression class that made the KV selector clip: a control that cannot fit
/// inside the width it is given.
@MainActor
final class ComponentLayoutTests: XCTestCase {
    private func hosted<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        return host
    }

    func testSelectFitsInNarrowSettingsRow() {
        let binding = Binding<String>(get: { "q8_0" }, set: { _ in })
        let view = MTSelect(
            selection: binding,
            options: LocalHardwareService.supportedKVCacheTypes.map { ($0, $0) },
            width: 196
        )
        let host = hosted(view, width: 260, height: 80)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        XCTAssertLessThanOrEqual(host.fittingSize.width, 260)
    }

    func testSearchableSelectFitsInSchedulerRow() {
        let binding = Binding<String>(get: { "Europe/Berlin" }, set: { _ in })
        let view = MTSearchableSelect(
            selection: binding,
            options: [("", "System"), ("Europe/Berlin", "Europe/Berlin")],
            width: 320
        )
        let host = hosted(view, width: 420, height: 80)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        XCTAssertLessThanOrEqual(host.fittingSize.width, 420)
    }

    func testSegmentedControlKeepsAllOptions() {
        let binding = Binding<String>(get: { "Dark" }, set: { _ in })
        let view = MTSegmented(selection: binding, options: [
            ("Dark", "Dark"), ("Light", "Light"), ("System", "System")
        ], width: 280)
        let host = hosted(view, width: 320, height: 60)
        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertLessThanOrEqual(host.fittingSize.width, 320)
    }
}
