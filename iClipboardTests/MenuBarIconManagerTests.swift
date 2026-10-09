import XCTest
@testable import iClipboard

final class MenuBarIconManagerTests: XCTestCase {
    func testDisambiguationChangesDisplayTitleButPreservesSourceIdentity() {
        let first = makeEntry(title: "VPN", x: 100, itemIndex: 0)
        let second = makeEntry(title: "VPN", x: 200, itemIndex: 1)

        let result = MenuBarEntryPresenter.disambiguated([first, second])

        XCTAssertEqual(result[0].displayTitle, "VPN")
        XCTAssertEqual(result[1].displayTitle, "VPN (2)")
        XCTAssertEqual(result[1].sourceTitle, "VPN")
        XCTAssertEqual(result[1].itemIndex, 1)
    }

    func testMatcherPrefersSameIndexAndSourceTitle() {
        let entry = makeEntry(title: "Status", x: 300, itemIndex: 1)
        let candidates = [
            MenuBarCandidateIdentity(
                title: "Status",
                geometry: geometry(x: 100)
            ),
            MenuBarCandidateIdentity(
                title: "Status",
                geometry: geometry(x: 900)
            )
        ]

        XCTAssertEqual(
            MenuBarEntryMatcher.bestCandidateIndex(
                for: entry,
                candidates: candidates
            ),
            1
        )
    }

    func testMatcherFallsBackToNearestSameTitleWhenIndexChanges() {
        let entry = makeEntry(title: "Status", x: 310, itemIndex: 7)
        let candidates = [
            MenuBarCandidateIdentity(
                title: "Other",
                geometry: geometry(x: 305)
            ),
            MenuBarCandidateIdentity(
                title: "Status",
                geometry: geometry(x: 120)
            ),
            MenuBarCandidateIdentity(
                title: "Status",
                geometry: geometry(x: 320)
            )
        ]

        XCTAssertEqual(
            MenuBarEntryMatcher.bestCandidateIndex(
                for: entry,
                candidates: candidates
            ),
            2
        )
    }

    func testMatcherRejectsIndexWithoutMatchingTitle() {
        let entry = makeEntry(title: "Status", x: 310, itemIndex: 1)
        let candidates = [
            MenuBarCandidateIdentity(
                title: "Different Item",
                geometry: geometry(x: 310)
            )
        ]

        XCTAssertNil(
            MenuBarEntryMatcher.bestCandidateIndex(
                for: entry,
                candidates: candidates
            )
        )
    }

    func testTitleTruncationHonorsLimit() {
        XCTAssertEqual(
            MenuBarEntryPresenter.truncatedTitle("123456", limit: 6),
            "123456"
        )
        XCTAssertEqual(
            MenuBarEntryPresenter.truncatedTitle("1234567", limit: 6),
            "12345…"
        )
    }

    private func makeEntry(
        title: String,
        x: Double,
        itemIndex: Int
    ) -> ManagedMenuBarEntry {
        ManagedMenuBarEntry(
            processIdentifier: 123,
            applicationName: "Test",
            sourceTitle: title,
            displayTitle: title,
            itemIndex: itemIndex,
            geometry: geometry(x: x)
        )
    }

    private func geometry(x: Double) -> MenuBarItemGeometry {
        MenuBarItemGeometry(
            rect: .init(x: x, y: 0, width: 20, height: 20)
        )
    }
}
