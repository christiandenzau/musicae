//
// MixVersionTests.swift
//
// Prüft das Erkennen der Mix-Version gegen echte Titel aus der Eurodance-
// Testscheibe (Phase 1) und gegen Titel ohne Versionszusatz.
//

import XCTest
@testable import BPMKit

final class MixVersionTests: XCTestCase {
    func testRecognizesVersionInBrackets() {
        XCTAssertEqual(MixVersionParser.parse(title: "Another Night (House mix)"), "House mix")
        XCTAssertEqual(MixVersionParser.parse(title: "Living on My Own (radio mix)"), "radio mix")
        XCTAssertEqual(MixVersionParser.parse(title: "Close Your Eyes (club mix)"), "club mix")
        XCTAssertEqual(MixVersionParser.parse(title: "Porque Te Vas (D.O.N.S. Remix)"), "D.O.N.S. Remix")
        XCTAssertEqual(MixVersionParser.parse(title: "Foo (Extended Mix)"), "Extended Mix")
    }

    func testPrefersTrailingVersionBracket() {
        // Erste Klammer ist ein Untertitel ohne Schlüsselwort, zweite die Version.
        XCTAssertEqual(
            MixVersionParser.parse(title: "Can U Feel It (Dee Ooh La La La) (radio edit)"),
            "radio edit"
        )
    }

    func testSupportsSquareBrackets() {
        XCTAssertEqual(MixVersionParser.parse(title: "Bar [Club Mix]"), "Club Mix")
    }

    func testReturnsNilWithoutVersion() {
        XCTAssertNil(MixVersionParser.parse(title: "Carry On"))
        XCTAssertNil(MixVersionParser.parse(title: "Last Warning"))
        XCTAssertNil(MixVersionParser.parse(title: "100% positiv"))
    }

    func testIgnoresNonVersionBrackets() {
        // Ein reiner Untertitel/Feature-Credit ist keine Mix-Version.
        XCTAssertNil(MixVersionParser.parse(title: "Track (Dee Ooh La La La)"))
        XCTAssertNil(MixVersionParser.parse(title: "Song (feat. Someone)"))
    }

    func testDoesNotFalseMatchSubstring() {
        // „mix" steckt in „remix" — als Wort-Token zählt nur das ganze Wort,
        // aber „remix" ist selbst ein Schlüsselwort und soll greifen.
        XCTAssertEqual(MixVersionParser.parse(title: "Tune (Quick Remix)"), "Quick Remix")
    }
}
