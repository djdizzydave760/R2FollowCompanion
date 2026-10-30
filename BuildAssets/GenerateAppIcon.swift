import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    fatalError("Usage: swift GenerateAppIcon.swift <output.png>")
}

let output = args[1]
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)

image.lockFocus()

// Background
let bg = NSColor(
    calibratedRed: 0.025,
    green: 0.055,
    blue: 0.11,
    alpha: 1
)
bg.setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

// Soft radial glow
let glowRect = NSRect(x: 120, y: 120, width: 784, height: 784)
let glow = NSGradient(colors: [
    NSColor(calibratedRed: 0.06, green: 0.38, blue: 0.78, alpha: 0.40),
    NSColor(calibratedRed: 0.02, green: 0.08, blue: 0.16, alpha: 0.02)
])!
glow.draw(in: NSBezierPath(ovalIn: glowRect), angle: 90)

// R2 dome/body badge
let bodyWhite = NSColor(calibratedWhite: 0.96, alpha: 1)
let blue = NSColor(calibratedRed: 0.07, green: 0.34, blue: 0.78, alpha: 1)
let darkBlue = NSColor(calibratedRed: 0.025, green: 0.15, blue: 0.38, alpha: 1)
let red = NSColor(calibratedRed: 0.95, green: 0.12, blue: 0.13, alpha: 1)

let badge = NSBezierPath(ovalIn: NSRect(x: 154, y: 154, width: 716, height: 716))
NSColor(calibratedWhite: 1, alpha: 0.08).setFill()
badge.fill()

// Main cylindrical body
let body = NSBezierPath(roundedRect: NSRect(x: 310, y: 260, width: 404, height: 420), xRadius: 70, yRadius: 70)
bodyWhite.setFill()
body.fill()

// Dome
let dome = NSBezierPath()
dome.move(to: NSPoint(x: 320, y: 628))
dome.curve(
    to: NSPoint(x: 704, y: 628),
    controlPoint1: NSPoint(x: 340, y: 846),
    controlPoint2: NSPoint(x: 684, y: 846)
)
dome.line(to: NSPoint(x: 704, y: 608))
dome.line(to: NSPoint(x: 320, y: 608))
dome.close()
bodyWhite.setFill()
dome.fill()

// Blue dome panels
let leftPanel = NSBezierPath(roundedRect: NSRect(x: 365, y: 654, width: 92, height: 118), xRadius: 18, yRadius: 18)
blue.setFill()
leftPanel.fill()

let rightPanel = NSBezierPath(roundedRect: NSRect(x: 567, y: 654, width: 92, height: 118), xRadius: 18, yRadius: 18)
blue.setFill()
rightPanel.fill()

let centerPanel = NSBezierPath(roundedRect: NSRect(x: 475, y: 690, width: 74, height: 102), xRadius: 16, yRadius: 16)
darkBlue.setFill()
centerPanel.fill()

// Main red lens
let lens = NSBezierPath(ovalIn: NSRect(x: 493, y: 720, width: 38, height: 38))
red.setFill()
lens.fill()

// Body blue details
for rect in [
    NSRect(x: 360, y: 470, width: 78, height: 116),
    NSRect(x: 473, y: 475, width: 78, height: 138),
    NSRect(x: 586, y: 470, width: 78, height: 116)
] {
    let p = NSBezierPath(roundedRect: rect, xRadius: 15, yRadius: 15)
    blue.setFill()
    p.fill()
}

// Center dark port
let port = NSBezierPath(ovalIn: NSRect(x: 485, y: 346, width: 54, height: 54))
darkBlue.setFill()
port.fill()

// Side legs
let leftLeg = NSBezierPath(roundedRect: NSRect(x: 246, y: 300, width: 94, height: 300), xRadius: 42, yRadius: 42)
let rightLeg = NSBezierPath(roundedRect: NSRect(x: 684, y: 300, width: 94, height: 300), xRadius: 42, yRadius: 42)
bodyWhite.setFill()
leftLeg.fill()
rightLeg.fill()

// Blue leg panels
for rect in [
    NSRect(x: 270, y: 410, width: 46, height: 116),
    NSRect(x: 708, y: 410, width: 46, height: 116)
] {
    let p = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
    blue.setFill()
    p.fill()
}

// Bottom shadow
let shadow = NSBezierPath(ovalIn: NSRect(x: 260, y: 208, width: 504, height: 52))
NSColor(calibratedWhite: 0, alpha: 0.25).setFill()
shadow.fill()

// Small title
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 54, weight: .heavy),
    .foregroundColor: NSColor.white,
    .paragraphStyle: paragraph,
    .kern: 3.0
]
NSAttributedString(string: "R2 FOLLOW", attributes: attrs)
    .draw(in: NSRect(x: 150, y: 102, width: 724, height: 72))

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:])
else {
    fatalError("Could not render app icon")
}

try png.write(to: URL(fileURLWithPath: output))
print("Generated app icon: \(output)")
