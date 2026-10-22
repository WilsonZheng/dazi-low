import XCTest
@testable import Kaikou

final class HotkeySpecTests: XCTestCase {
    typealias B = HotkeySpec.Bits

    func testDefaultIsDoubleTapFn() {
        XCTAssertEqual(HotkeySpec.default.display, "双击 fn")
        XCTAssertTrue(HotkeySpec.default.isDoubleTap)
        XCTAssertNil(HotkeySpec.default.problem)
        XCTAssertTrue(HotkeySpec.default.help.contains("连按两下 fn"))
    }

    func testOldSavedSpecsStillDecode() throws {
        let old = #"{"modifiers":262144,"keyCode":48,"mode":"toggle","keyName":"⇥"}"#
        let s = try JSONDecoder().decode(HotkeySpec.self, from: Data(old.utf8))
        XCTAssertEqual(s.display, "⌃⇥")
        XCTAssertFalse(s.isDoubleTap)
    }

    func testRejectsEasyToHitKeys() {
        XCTAssertNotNil(HotkeySpec(modifiers: B.leftShift, keyCode: nil, keyName: nil, mode: .toggle).problem)
        XCTAssertNotNil(HotkeySpec(modifiers: B.leftCommand, keyCode: nil, keyName: nil, mode: .toggle).problem)
        XCTAssertNotNil(HotkeySpec(modifiers: 0, keyCode: 0, keyName: "A", mode: .toggle).problem, "a bare letter blocks typing")
    }

    func testAcceptsSafeChoices() {
        XCTAssertNil(HotkeySpec(modifiers: B.rightOption, keyCode: nil, keyName: nil, mode: .hold).problem)
        XCTAssertNil(HotkeySpec(modifiers: B.fn, keyCode: nil, keyName: nil, mode: .toggle).problem)
        let optSpace = HotkeySpec(modifiers: NSEvent.ModifierFlags.option.rawValue, keyCode: 49, keyName: "Space", mode: .toggle)
        XCTAssertNil(optSpace.problem)
        XCTAssertEqual(optSpace.display, "⌥Space")
    }

    func testRoundTrip() throws {
        let s = HotkeySpec(modifiers: B.leftOption | B.leftCommand, keyCode: nil, keyName: nil, mode: .hold)
        let back = try JSONDecoder().decode(HotkeySpec.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.display, "左⌥ 左⌘")
        XCTAssertTrue(back.help.contains("按住"))
    }
}
