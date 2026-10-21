import XCTest
@testable import DaziLow

final class HotkeySpecTests: XCTestCase {
    typealias B = HotkeySpec.Bits

    func testDefaultIsLeftControlShiftToggle() {
        XCTAssertEqual(HotkeySpec.default.display, "左⌃ 左⇧")
        XCTAssertEqual(HotkeySpec.default.mode, .toggle)
        XCTAssertNil(HotkeySpec.default.problem)
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
