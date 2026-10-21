import XCTest
@testable import DaziLow

final class HotkeyStateMachineTests: XCTestCase {
    func testHoldCommitsOnRelease() {
        var m = HotkeyStateMachine()
        XCTAssertEqual(m.keyDown(at: 0), .start)
        XCTAssertTrue(m.isRecording)
        XCTAssertEqual(m.keyUp(at: 2), .commit)
        XCTAssertEqual(m.state, .idle)
    }

    func testTapEntersHandsFreeAndNextTapCommits() {
        var m = HotkeyStateMachine()
        XCTAssertEqual(m.keyDown(at: 0), .start)
        XCTAssertEqual(m.keyUp(at: 0.1), .enterHandsFree)
        XCTAssertTrue(m.isRecording)
        XCTAssertNil(m.otherKeyDown(at: 1), "typing during hands-free must not cancel")
        XCTAssertEqual(m.keyDown(at: 5), .commit)
        XCTAssertFalse(m.isRecording)
        XCTAssertNil(m.keyUp(at: 5.1))
        XCTAssertEqual(m.state, .idle)
    }

    func testOptionChordCancels() {
        var m = HotkeyStateMachine()
        XCTAssertEqual(m.keyDown(at: 0), .start)
        XCTAssertEqual(m.otherKeyDown(at: 0.2), .cancel)
        XCTAssertNil(m.keyUp(at: 0.4), "release after a chord does nothing")
        XCTAssertEqual(m.state, .idle)
    }

    func testLateKeyPressDuringLongHoldIsIgnored() {
        var m = HotkeyStateMachine()
        _ = m.keyDown(at: 0)
        XCTAssertNil(m.otherKeyDown(at: 3))
        XCTAssertEqual(m.keyUp(at: 4), .commit)
    }

    func testEscapeCancelsHoldAndHandsFree() {
        var m = HotkeyStateMachine()
        _ = m.keyDown(at: 0)
        XCTAssertEqual(m.escape(keyStillDown: true), .cancel)
        XCTAssertNil(m.keyUp(at: 1))
        XCTAssertEqual(m.state, .idle)

        _ = m.keyDown(at: 10)
        _ = m.keyUp(at: 10.1)
        XCTAssertEqual(m.escape(keyStillDown: false), .cancel)
        XCTAssertEqual(m.state, .idle)
        XCTAssertNil(m.escape(keyStillDown: false))
    }

    func testToggleStartsAndFinishes() {
        var m = HotkeyStateMachine()
        XCTAssertEqual(m.toggle(), .start)
        XCTAssertTrue(m.isRecording)
        XCTAssertNil(m.otherKeyDown(at: 1), "typing while recording does not cancel")
        XCTAssertEqual(m.toggle(), .commit)
        XCTAssertFalse(m.isRecording)
        XCTAssertEqual(m.toggle(), .start)
        XCTAssertEqual(m.escape(keyStillDown: false), .cancel)
        XCTAssertEqual(m.toggle(), .start, "after a cancel the next press starts again")
    }

    func testResetWhileHeldSwallowsRelease() {
        var m = HotkeyStateMachine()
        _ = m.keyDown(at: 0)
        m.reset(keyStillDown: true)
        XCTAssertFalse(m.isRecording)
        XCTAssertNil(m.keyUp(at: 1))
        XCTAssertEqual(m.keyDown(at: 2), .start)
    }
}
