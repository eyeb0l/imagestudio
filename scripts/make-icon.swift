#!/usr/bin/env swift
// Renders the Image Studio app icon.
// Usage: swift scripts/make-icon.swift <output.png> [size]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("Usage: make-icon.swift <output.png> [size]")
    exit(1)
}
let outputURL = URL(fileURLWithPath: arguments[1])
let size = arguments.count >= 3 ? Int(arguments[2]) ?? 1024 : 1024
let s = CGFloat(size) / 1024 // design is authored at 1024 pt

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(1) }

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// CoreGraphics' origin is bottom-left; flip so the design reads top-down.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: s, y: -s)

// Background: deep graphite, slightly lighter at the top.
let background = CGGradient(colorsSpace: space, colors: [rgb(0x2C2C31), rgb(0x0D0D10)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 0), end: CGPoint(x: 512, y: 1024), options: [])

// Soft glow behind the main spark.
let glowCenter = CGPoint(x: 470, y: 560)
let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: glowCenter, startRadius: 0, endCenter: glowCenter, endRadius: 420, options: [])

/// A four-pointed spark with concave sides.
func spark(center c: CGPoint, radius r: CGFloat, pinch: CGFloat = 0.14) -> CGPath {
    let path = CGMutablePath()
    let k = r * pinch
    path.move(to: CGPoint(x: c.x, y: c.y - r))
    path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + k, y: c.y - k))
    path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + k, y: c.y + k))
    path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - k, y: c.y + k))
    path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - k, y: c.y - k))
    path.closeSubpath()
    return path
}

func fill(_ path: CGPath, top: CGColor, bottom: CGColor) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let box = path.boundingBox
    let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: box.midX, y: box.minY),
                           end: CGPoint(x: box.midX, y: box.maxY), options: [])
    ctx.restoreGState()
}

fill(spark(center: glowCenter, radius: 300), top: rgb(0xFFFFFF), bottom: rgb(0xD9D9E0))
fill(spark(center: CGPoint(x: 735, y: 300), radius: 108), top: rgb(0xFFFFFF, 0.92), bottom: rgb(0xCFCFD8, 0.92))
fill(spark(center: CGPoint(x: 770, y: 760), radius: 54), top: rgb(0xFFFFFF, 0.55), bottom: rgb(0xCFCFD8, 0.55))

guard let image = ctx.makeImage(),
      let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }
print("Wrote \(outputURL.path) (\(size)×\(size))")
