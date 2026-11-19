// Draws the Chat Nudge app icon: a white bell on a warm rounded square.
// Usage: swift make-icon.swift <out.png>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(
    starting: NSColor(calibratedRed: 0.93, green: 0.47, blue: 0.29, alpha: 1),
    ending: NSColor(calibratedRed: 0.80, green: 0.33, blue: 0.20, alpha: 1))!
    .draw(in: shape, angle: -90)

let config = NSImage.SymbolConfiguration(pointSize: 480, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
if let bell = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config)
{
    let b = bell.size
    bell.draw(in: NSRect(x: (size - b.width) / 2, y: (size - b.height) / 2, width: b.width, height: b.height))
}

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
