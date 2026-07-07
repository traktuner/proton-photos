import XCTest
@testable import GridCore

/// Locks the shared selection-toolbar center-text rule (0 → prompt, exactly 1 → hidden, many → count) so it
/// can never drift between platforms.
final class SelectionToolbarTextTests: XCTestCase {

    func testZeroSelectedShowsPrompt() {
        XCTAssertEqual(SelectionToolbarText.centerLabel(selectedCount: 0), .prompt)
    }

    func testOneSelectedIsHidden() {
        // A single selected item needs no count - its own decoration already says it is selected.
        XCTAssertEqual(SelectionToolbarText.centerLabel(selectedCount: 1), .hidden)
    }

    func testManySelectedShowsCount() {
        XCTAssertEqual(SelectionToolbarText.centerLabel(selectedCount: 2), .count(2))
        XCTAssertEqual(SelectionToolbarText.centerLabel(selectedCount: 3), .count(3))
        XCTAssertEqual(SelectionToolbarText.centerLabel(selectedCount: 999), .count(999))
    }

    func testNegativeCountIsTreatedAsPrompt() {
        // Defensive: counts are never negative, but a bad input must not fall through to `count`.
        XCTAssertEqual(SelectionToolbarText.centerLabel(selectedCount: -5), .prompt)
    }
}
