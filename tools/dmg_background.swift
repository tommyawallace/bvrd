// DMG window background. swift tools/dmg_background.swift <app-name> <output.png>
import AppKit

let args = CommandLine.arguments
let appName = args[1]
let output = URL(fileURLWithPath: args[2])
let size = NSSize(width: 640, height: 400)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

NSGradient(starting: NSColor(white: 0.98, alpha: 1), ending: NSColor(white: 0.90, alpha: 1))!
    .draw(in: NSRect(origin: .zero, size: size), angle: -90)

func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style,
    ]
    text.draw(in: NSRect(x: 0, y: y, width: 640, height: size * 1.5), withAttributes: attributes)
}

draw("Drag \(appName) to Applications", size: 20, weight: .semibold, color: NSColor(white: 0.2, alpha: 1), y: 330)

// Arrow from the app icon (x 160) to Applications (x 480).
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 255, y: 210))
arrow.line(to: NSPoint(x: 375, y: 210))
arrow.move(to: NSPoint(x: 360, y: 222))
arrow.line(to: NSPoint(x: 378, y: 210))
arrow.line(to: NSPoint(x: 360, y: 198))
arrow.lineWidth = 5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor(white: 0.55, alpha: 1).setStroke()
arrow.stroke()

draw("If macOS won't open it, read “How to Open”.", size: 13, weight: .regular,
     color: NSColor(white: 0.4, alpha: 1), y: 28)

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: output)
