// Draws the Kaikou app icon (1024 px PNG): a violet squircle with a white speech
// bubble holding a short sound wave. Run: swift scripts/make_icon.swift out.png
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Squircle background on the macOS icon grid (824 px body, centered).
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bg = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
ctx.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor(calibratedRed: 0.36, green: 0.28, blue: 0.95, alpha: 1).setFill()
bg.fill()
ctx.restoreGState()
NSGradient(colors: [NSColor(calibratedRed: 0.55, green: 0.42, blue: 1.0, alpha: 1),
                    NSColor(calibratedRed: 0.20, green: 0.12, blue: 0.62, alpha: 1)])!
    .draw(in: bg, angle: -90)

// Speech bubble.
let bubbleRect = NSRect(x: 232, y: 330, width: 560, height: 400)
let bubble = NSBezierPath(roundedRect: bubbleRect, xRadius: 150, yRadius: 150)
let tail = NSBezierPath()
tail.move(to: NSPoint(x: 330, y: 360))
tail.line(to: NSPoint(x: 290, y: 250))
tail.line(to: NSPoint(x: 440, y: 340))
tail.close()
bubble.append(tail)
NSColor.white.setFill()
bubble.fill()

// Sound wave inside the bubble.
let heights: [CGFloat] = [70, 150, 230, 150, 70]
let barW: CGFloat = 46, gap: CGFloat = 36
let total = barW * 5 + gap * 4
var x = bubbleRect.midX - total / 2
let waveColor = NSGradient(colors: [NSColor(calibratedRed: 0.55, green: 0.42, blue: 1.0, alpha: 1),
                                    NSColor(calibratedRed: 0.28, green: 0.18, blue: 0.80, alpha: 1)])!
for h in heights {
    let r = NSRect(x: x, y: bubbleRect.midY - h / 2, width: barW, height: h)
    waveColor.draw(in: NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2), angle: -90)
    x += barW + gap
}
img.unlockFocus()

let out = CommandLine.arguments.dropFirst().first ?? "icon.png"
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
