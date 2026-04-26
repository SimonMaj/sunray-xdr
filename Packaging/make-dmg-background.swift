#!/usr/bin/env swift
import AppKit

let outputPath = CommandLine.arguments.dropFirst().first ?? "Packaging/dmg-background.png"
let size = NSSize(width: 560, height: 360)
let image = NSImage(size: size)

func drawText(_ string: String, at point: CGPoint, fontSize: CGFloat, weight: NSFont.Weight, alpha: CGFloat = 1.0) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
        .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        .paragraphStyle: paragraph
    ]
    let rect = CGRect(x: point.x, y: point.y, width: size.width - point.x * 2, height: fontSize + 10)
    string.draw(in: rect, withAttributes: attrs)
}

image.lockFocus()

let bounds = CGRect(origin: .zero, size: size)
let bg = NSGradient(colors: [
    NSColor(calibratedRed: 0.08, green: 0.06, blue: 0.18, alpha: 1.0),
    NSColor(calibratedRed: 0.18, green: 0.09, blue: 0.42, alpha: 1.0),
    NSColor(calibratedRed: 0.04, green: 0.07, blue: 0.20, alpha: 1.0)
])!
bg.draw(in: bounds, angle: -32)

NSColor(calibratedRed: 1.0, green: 0.76, blue: 0.18, alpha: 0.20).setFill()
NSBezierPath(ovalIn: CGRect(x: 16, y: 178, width: 220, height: 220)).fill()
NSColor(calibratedRed: 0.46, green: 0.20, blue: 1.0, alpha: 0.30).setFill()
NSBezierPath(ovalIn: CGRect(x: 332, y: -46, width: 250, height: 210)).fill()

drawText("Sunray XDR", at: CGPoint(x: 0, y: 306), fontSize: 28, weight: .bold)
drawText("Drag to Applications", at: CGPoint(x: 0, y: 278), fontSize: 15, weight: .medium, alpha: 0.72)

let arrow = NSBezierPath()
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.lineWidth = 7
arrow.move(to: CGPoint(x: 238, y: 176))
arrow.line(to: CGPoint(x: 322, y: 176))
arrow.move(to: CGPoint(x: 296, y: 203))
arrow.line(to: CGPoint(x: 323, y: 176))
arrow.line(to: CGPoint(x: 296, y: 149))
NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.24, alpha: 0.78).setStroke()
arrow.stroke()

let arrowGlow = NSBezierPath()
arrowGlow.lineCapStyle = .round
arrowGlow.lineJoinStyle = .round
arrowGlow.lineWidth = 15
arrowGlow.move(to: CGPoint(x: 238, y: 176))
arrowGlow.line(to: CGPoint(x: 322, y: 176))
NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.18, alpha: 0.12).setStroke()
arrowGlow.stroke()

drawText("Open after copying", at: CGPoint(x: 0, y: 34), fontSize: 12, weight: .regular, alpha: 0.44)

image.unlockFocus()

guard let data = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: data),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not render DMG background\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: outputPath))
