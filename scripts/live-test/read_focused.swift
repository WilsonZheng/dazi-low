import AppKit
import ApplicationServices
// Prints the text of the focused element in the given app (needs Accessibility).
let bundle = CommandLine.arguments.dropFirst().first ?? "com.apple.TextEdit"
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { print("app not running"); exit(1) }
let el = AXUIElementCreateApplication(app.processIdentifier)
var focused: CFTypeRef?
guard AXUIElementCopyAttributeValue(el, kAXFocusedUIElementAttribute as CFString, &focused) == .success else { print("no focused element"); exit(1) }
var value: CFTypeRef?
AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXValueAttribute as CFString, &value)
print((value as? String) ?? "")
