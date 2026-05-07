#!/usr/bin/env swift
import AppKit

// Generates AppIcon.iconset for Heart.
// Style: rounded square with crimson→pink gradient, a centered white heart silhouette,
// and a subtle pulse (EKG) line crossing through it — referencing live processes.

let outIconset = "AppIcon.iconset"
let sizes: [(Int, String)] = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

let fm = FileManager.default
try? fm.removeItem(atPath: outIconset)
try? fm.createDirectory(atPath: outIconset, withIntermediateDirectories: true)

/// Builds a classic two-lobe heart silhouette centered in the given rect.
/// Form: two circular lobes joined at a top notch, with two outer curves sweeping down
/// to a single bottom point. Tuned to look symmetric and clean at all icon sizes.
func heartPath(in rect: NSRect) -> NSBezierPath {
    let p = NSBezierPath()
    let w = rect.width
    let h = rect.height
    let cx = rect.midX
    let cy = rect.midY

    // Two lobes are circles whose centers sit slightly above the heart's vertical center.
    let lobeRadius = w * 0.25
    let lobeY = cy + h * 0.18
    let leftLobeX = cx - w * 0.22
    let rightLobeX = cx + w * 0.22

    let bottom = NSPoint(x: cx, y: cy - h * 0.46)
    let topNotch = NSPoint(x: cx, y: cy + h * 0.16)

    // Where each lobe's outer edge sits (left-most / right-most point of the heart).
    let leftOuter = NSPoint(x: leftLobeX - lobeRadius, y: lobeY)
    let rightOuter = NSPoint(x: rightLobeX + lobeRadius, y: lobeY)

    // Top of each lobe (peak).
    let leftPeak = NSPoint(x: leftLobeX, y: lobeY + lobeRadius)
    let rightPeak = NSPoint(x: rightLobeX, y: lobeY + lobeRadius)

    p.move(to: bottom)

    // Right side: bottom → right outer edge → up over right lobe → down to top notch
    p.curve(to: rightOuter,
            controlPoint1: NSPoint(x: cx + w * 0.18, y: cy - h * 0.18),
            controlPoint2: NSPoint(x: rightOuter.x, y: rightOuter.y - lobeRadius * 0.55))
    p.curve(to: rightPeak,
            controlPoint1: NSPoint(x: rightOuter.x, y: rightOuter.y + lobeRadius * 0.55),
            controlPoint2: NSPoint(x: rightPeak.x + lobeRadius * 0.55, y: rightPeak.y))
    p.curve(to: topNotch,
            controlPoint1: NSPoint(x: rightPeak.x - lobeRadius * 0.55, y: rightPeak.y),
            controlPoint2: NSPoint(x: topNotch.x + lobeRadius * 0.10, y: topNotch.y + lobeRadius * 0.20))

    // Left side: top notch → up over left lobe → left outer edge → down to bottom
    p.curve(to: leftPeak,
            controlPoint1: NSPoint(x: topNotch.x - lobeRadius * 0.10, y: topNotch.y + lobeRadius * 0.20),
            controlPoint2: NSPoint(x: leftPeak.x + lobeRadius * 0.55, y: leftPeak.y))
    p.curve(to: leftOuter,
            controlPoint1: NSPoint(x: leftPeak.x - lobeRadius * 0.55, y: leftPeak.y),
            controlPoint2: NSPoint(x: leftOuter.x, y: leftOuter.y + lobeRadius * 0.55))
    p.curve(to: bottom,
            controlPoint1: NSPoint(x: leftOuter.x, y: leftOuter.y - lobeRadius * 0.55),
            controlPoint2: NSPoint(x: cx - w * 0.18, y: cy - h * 0.18))

    p.close()
    return p
}

/// Returns an EKG/pulse polyline crossing the icon horizontally.
func pulsePoints(in rect: NSRect) -> [NSPoint] {
    let w = rect.width
    let cx = rect.midX
    let cy = rect.midY - rect.height * 0.02 // slightly below center

    let baseline = cy
    let small = rect.height * 0.04
    let bigUp = rect.height * 0.16
    let bigDown = rect.height * 0.10

    return [
        NSPoint(x: cx - w * 0.42, y: baseline),
        NSPoint(x: cx - w * 0.22, y: baseline),
        NSPoint(x: cx - w * 0.16, y: baseline - small),
        NSPoint(x: cx - w * 0.08, y: baseline + bigUp),
        NSPoint(x: cx,             y: baseline - bigDown),
        NSPoint(x: cx + w * 0.08, y: baseline),
        NSPoint(x: cx + w * 0.22, y: baseline),
        NSPoint(x: cx + w * 0.42, y: baseline)
    ]
}

for (size, name) in sizes {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    let cornerRadius = s * 0.225
    let outerPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

    // Background: warm crimson → pink → coral gradient (top-left → bottom-right)
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 1.00, green: 0.36, blue: 0.46, alpha: 1.0),
        NSColor(srgbRed: 0.92, green: 0.20, blue: 0.36, alpha: 1.0),
        NSColor(srgbRed: 0.66, green: 0.10, blue: 0.30, alpha: 1.0)
    ])!
    gradient.draw(in: outerPath, angle: -55)

    // Subtle radial highlight near top-left
    NSGraphicsContext.current?.saveGraphicsState()
    outerPath.addClip()
    let highlight = NSGradient(colors: [
        NSColor(white: 1.0, alpha: 0.30),
        NSColor(white: 1.0, alpha: 0.0)
    ])!
    let hRect = NSRect(x: rect.minX - s * 0.15,
                       y: rect.maxY - s * 0.55,
                       width: s * 1.0,
                       height: s * 1.0)
    highlight.draw(in: hRect, relativeCenterPosition: NSPoint(x: -0.3, y: 0.5))
    NSGraphicsContext.current?.restoreGraphicsState()

    // Heart silhouette — soft drop shadow then white fill
    let heartRect = NSInsetRect(rect, s * 0.18, s * 0.18)
    let heart = heartPath(in: heartRect)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.22)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowBlurRadius = s * 0.04
    shadow.set()
    NSColor.white.setFill()
    heart.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // EKG pulse line — drawn on top of the heart, clipped to it for a clean look.
    NSGraphicsContext.current?.saveGraphicsState()
    heart.addClip()

    let pulse = NSBezierPath()
    let points = pulsePoints(in: heartRect)
    pulse.move(to: points[0])
    for pt in points.dropFirst() {
        pulse.line(to: pt)
    }
    pulse.lineCapStyle = .round
    pulse.lineJoinStyle = .round
    pulse.lineWidth = max(s * 0.045, 1.2)
    NSColor(srgbRed: 0.92, green: 0.20, blue: 0.36, alpha: 1.0).setStroke()
    pulse.stroke()

    NSGraphicsContext.current?.restoreGraphicsState()

    img.unlockFocus()

    if let tiff = img.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: "\(outIconset)/\(name)"))
    }
}

print("✓ Generated \(outIconset)/")
