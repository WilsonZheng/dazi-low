import Foundation
import CoreGraphics
// Holds Right Option (keycode 61) for N seconds via synthetic flagsChanged events.
let secs = Double(CommandLine.arguments.dropFirst().first ?? "2") ?? 2
let src = CGEventSource(stateID: .hidSystemState)
func flags(_ down: Bool) {
    let e = CGEvent(keyboardEventSource: src, virtualKey: 61, keyDown: down)!
    e.type = .flagsChanged
    e.flags = down ? CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40) : []
    e.post(tap: .cghidEventTap)
}
// Synthetic modifier state decays after ~3 s, so keep re-posting the press
// (Kaikou ignores repeated presses); a real held key needs no such help.
flags(true)
var held = 0.0
while held < secs {
    let step = min(1.0, secs - held)
    Thread.sleep(forTimeInterval: step)
    held += step
    if held < secs { flags(true) }
}
flags(false)
print("posted Right Option hold for \(secs)s")
