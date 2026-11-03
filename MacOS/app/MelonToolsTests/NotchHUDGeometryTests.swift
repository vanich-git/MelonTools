import XCTest
@testable import MelonTools

final class NotchHUDGeometryTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1710, height: 1107)

    func testNotchedScreenMeasuresTheCutOut() {
        let geometry = NotchHUDGeometry(
            screenFrame: screen,
            safeAreaTop: 33.5,
            auxiliaryLeft: CGRect(x: 0, y: 1073.5, width: 762.5, height: 33.5),
            auxiliaryRight: CGRect(x: 947.5, y: 1073.5, width: 762.5, height: 33.5)
        )

        XCTAssertTrue(geometry.hasNotch)
        XCTAssertEqual(geometry.topInset, 33.5, accuracy: 0.01)
        XCTAssertEqual(geometry.notchWidth, 185, accuracy: 0.01)
        XCTAssertEqual(geometry.compactWidth, 185, accuracy: 0.01)
    }

    func testDisplayWithoutCutOutStartsAtTheTopEdge() {
        let geometry = NotchHUDGeometry(
            screenFrame: screen,
            safeAreaTop: 24,
            auxiliaryLeft: nil,
            auxiliaryRight: nil
        )

        XCTAssertFalse(geometry.hasNotch)
        XCTAssertEqual(geometry.topInset, 0)
        XCTAssertEqual(geometry.compactWidth, NotchHUDGeometry.minimumCompactWidth)
        XCTAssertEqual(geometry.windowFrame(screenFrame: screen).height, 242, accuracy: 0.01)
        XCTAssertEqual(geometry.windowFrame(screenFrame: screen).maxY, screen.maxY, accuracy: 0.01)
    }

    func testNotchedWindowIncludesTheCutOutHeight() {
        let geometry = NotchHUDGeometry(
            screenFrame: screen,
            safeAreaTop: 33.5,
            auxiliaryLeft: CGRect(x: 0, y: 1073.5, width: 762.5, height: 33.5),
            auxiliaryRight: CGRect(x: 947.5, y: 1073.5, width: 762.5, height: 33.5)
        )
        let frame = geometry.windowFrame(screenFrame: screen)

        XCTAssertEqual(frame.width, NotchHUDGeometry.expandedSize.width, accuracy: 0.01)
        XCTAssertEqual(frame.height, 275.5, accuracy: 0.01)
        XCTAssertEqual(frame.maxY, screen.maxY, accuracy: 0.01)
        XCTAssertEqual(frame.midX, screen.midX, accuracy: 0.01)
    }

    func testInvalidAuxiliaryAreasFallBackToTheDefaultNotchWidth() {
        let geometry = NotchHUDGeometry(
            screenFrame: screen,
            safeAreaTop: 33.5,
            auxiliaryLeft: CGRect(x: 0, y: 1073.5, width: 855, height: 33.5),
            auxiliaryRight: CGRect(x: 855, y: 1073.5, width: 855, height: 33.5)
        )

        XCTAssertEqual(geometry.notchWidth, NotchHUDGeometry.fallbackNotchWidth)
    }

    func testSideBarKeepsAHeightWithoutANotch() {
        XCTAssertEqual(NotchHUDGeometry.sideBarHeight(topInset: 0), 30)
        XCTAssertEqual(NotchHUDGeometry.sideBarHeight(topInset: 33.5), 33.5)
    }
}
