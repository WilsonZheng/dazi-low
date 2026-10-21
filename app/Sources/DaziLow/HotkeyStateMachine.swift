import Foundation

/// Push-to-talk / hands-free logic for a single modifier key (Right Option).
///
/// - Hold the key: records while held, commits on release.
/// - Tap the key (release within `tapThreshold`): hands-free; the next tap commits.
/// - Another key pressed shortly after the key goes down: it was a normal
///   Option shortcut, so the recording is cancelled silently.
/// - Escape cancels any recording.
///
/// Pure value type so it can be unit tested without a keyboard.
struct HotkeyStateMachine {
    enum Action: Equatable {
        case start
        /// A short tap: keep recording until the next tap.
        case enterHandsFree
        case commit
        case cancel
    }

    enum State: Equatable {
        case idle
        case holding(since: TimeInterval)
        case handsFree
        /// Key is still physically down but its press must be ignored.
        case swallowingRelease
    }

    var tapThreshold: TimeInterval = 0.30
    var chordWindow: TimeInterval = 1.0
    private(set) var state: State = .idle

    mutating func keyDown(at t: TimeInterval) -> Action? {
        switch state {
        case .idle:
            state = .holding(since: t)
            return .start
        case .handsFree:
            state = .swallowingRelease
            return .commit
        case .holding, .swallowingRelease:
            return nil
        }
    }

    mutating func keyUp(at t: TimeInterval) -> Action? {
        switch state {
        case .holding(let since):
            if t - since < tapThreshold {
                state = .handsFree
                return .enterHandsFree
            }
            state = .idle
            return .commit
        case .swallowingRelease:
            state = .idle
            return nil
        case .idle, .handsFree:
            return nil
        }
    }

    mutating func otherKeyDown(at t: TimeInterval) -> Action? {
        if case .holding(let since) = state, t - since < chordWindow {
            state = .swallowingRelease
            return .cancel
        }
        return nil
    }

    mutating func escape(keyStillDown: Bool) -> Action? {
        switch state {
        case .holding:
            state = keyStillDown ? .swallowingRelease : .idle
            return .cancel
        case .handsFree:
            state = .idle
            return .cancel
        case .idle, .swallowingRelease:
            return nil
        }
    }

    /// Forces the machine back to idle (e.g. recording hit its time limit).
    mutating func reset(keyStillDown: Bool) {
        state = keyStillDown ? .swallowingRelease : .idle
    }

    var isRecording: Bool {
        switch state {
        case .holding, .handsFree: return true
        case .idle, .swallowingRelease: return false
        }
    }
}
