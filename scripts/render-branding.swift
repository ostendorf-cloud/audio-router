// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

// Renders the branding SVGs with AppKit. scripts/render-branding.sh compiles and runs it.
//   render-branding render <svg> <pixels> <out.png>   one square PNG in sRGB
//   render-branding sheet <branding dir> <iconset dir> <out.png>   the contact sheet preview.png
// NSImage reads SVG through CoreSVG, so no tool outside the macOS SDK is needed.

import AppKit

let states = ["off", "running", "warning", "error"]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func bitmap(width: Int, height: Int) -> NSBitmapImageRep {
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
    else { fail("cannot allocate a \(width)x\(height) bitmap") }
    return rep
}

func draw(into rep: NSBitmapImageRep, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { fail("no graphics context") }
    NSGraphicsContext.current = context
    context.imageInterpolation = .none
    body()
}

func write(_ rep: NSBitmapImageRep, to path: String) {
    guard let srgb = rep.retagging(with: .sRGB),
        let data = srgb.representation(using: .png, properties: [:])
    else { fail("cannot encode \(path)") }
    do {
        try data.write(to: URL(fileURLWithPath: path))
    } catch {
        fail("cannot write \(path): \(error)")
    }
}

func load(_ path: String) -> NSImage {
    guard let image = NSImage(contentsOf: URL(fileURLWithPath: path)) else { fail("cannot read \(path)") }
    return image
}

/// One PNG at its own pixel size, so a 16 px file is drawn 1:1 and not scaled.
func pixels(_ path: String) -> (NSImage, NSSize) {
    let image = load(path)
    guard let rep = image.representations.first else { fail("no image data in \(path)") }
    return (image, NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
}

func render(svg: String, size: Int, out: String) {
    let image = load(svg)
    let rep = bitmap(width: size, height: size)
    draw(into: rep) {
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    }
    write(rep, to: out)
}

/// Draws a template PNG the way the menu bar does: its alpha channel filled with one colour.
func drawTemplate(_ path: String, in rect: NSRect, color: NSColor) {
    let (image, size) = pixels(path)
    let tinted = NSImage(size: size)
    tinted.lockFocus()
    image.draw(in: NSRect(origin: .zero, size: size))
    color.set()
    NSRect(origin: .zero, size: size).fill(using: .sourceIn)
    tinted.unlockFocus()
    NSGraphicsContext.current?.imageInterpolation = .none
    tinted.draw(in: rect)
}

func label(_ text: String, at point: NSPoint, color: NSColor, size: CGFloat = 13) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color,
    ]
    NSString(string: text).draw(at: point, withAttributes: attributes)
}

/// The contact sheet: the four states on a light and a dark menu bar at 16 px (1x) and 32 px (2x)
/// each at real size, then both enlarged without smoothing, then the app icon at 512 px and the small
/// iconset sizes on white and on a dark background.
func sheet(branding: String, iconset: String, out: String) {
    let width = 1240
    let barHeight = 230
    let iconHeight = 600
    let height = barHeight * 2 + iconHeight
    let rep = bitmap(width: width, height: height)
    let column = 300
    draw(into: rep) {
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let bars: [(String, NSColor, NSColor, NSColor)] = [
            ("Menu bar, light", NSColor(white: 0.93, alpha: 1), NSColor(white: 0, alpha: 0.85), .black),
            ("Menu bar, dark", NSColor(white: 0.16, alpha: 1), NSColor(white: 1, alpha: 0.9), .white),
        ]
        for (index, bar) in bars.enumerated() {
            let (title, background, symbol, text) = bar
            let top = CGFloat(height - barHeight * index)
            background.setFill()
            NSRect(x: 0, y: top - CGFloat(barHeight), width: CGFloat(width), height: CGFloat(barHeight)).fill()
            label(title, at: NSPoint(x: 20, y: top - 28), color: text, size: 15)
            for (offset, state) in states.enumerated() {
                let left = CGFloat(20 + offset * column)
                let one = "\(branding)/menubar-\(state).png"
                let two = "\(branding)/menubar-\(state)@2x.png"
                label(state, at: NSPoint(x: left, y: top - 56), color: text)
                label("16 px", at: NSPoint(x: left, y: top - 80), color: text, size: 11)
                drawTemplate(one, in: NSRect(x: left + 4, y: top - 108, width: 16, height: 16), color: symbol)
                label("32 px", at: NSPoint(x: left + 50, y: top - 80), color: text, size: 11)
                drawTemplate(two, in: NSRect(x: left + 50, y: top - 124, width: 32, height: 32), color: symbol)
                label("16 px x5", at: NSPoint(x: left + 100, y: top - 80), color: text, size: 11)
                drawTemplate(one, in: NSRect(x: left + 100, y: top - 180, width: 80, height: 80), color: symbol)
                label("32 px x3", at: NSPoint(x: left + 190, y: top - 80), color: text, size: 11)
                drawTemplate(two, in: NSRect(x: left + 190, y: top - 196, width: 96, height: 96), color: symbol)
            }
        }
        label("App icon, 512 px and 128, 64, 32, 16 px", at: NSPoint(x: 20, y: CGFloat(iconHeight - 30)), color: .black)
        let (big, _) = pixels("\(iconset)/icon_512x512.png")
        big.draw(in: NSRect(x: 20, y: 40, width: 512, height: 512))
        var left: CGFloat = 580
        for name in ["icon_128x128", "icon_32x32@2x", "icon_32x32", "icon_16x16"] {
            let (image, size) = pixels("\(iconset)/\(name).png")
            image.draw(in: NSRect(x: left, y: 40 + 512 - size.height, width: size.width, height: size.height))
            left += size.width + 40
        }
        let (dark, _) = pixels("\(iconset)/icon_128x128.png")
        NSColor(white: 0.16, alpha: 1).setFill()
        NSRect(x: 580, y: 40, width: 600, height: 300).fill()
        dark.draw(in: NSRect(x: 620, y: 120, width: 128, height: 128))
        var small: CGFloat = 800
        for name in ["icon_32x32@2x", "icon_32x32", "icon_16x16"] {
            let (image, size) = pixels("\(iconset)/\(name).png")
            image.draw(in: NSRect(x: small, y: 120 + 128 - size.height, width: size.width, height: size.height))
            small += size.width + 40
        }
        label("on a dark desktop", at: NSPoint(x: 600, y: 60), color: .white, size: 11)
    }
    write(rep, to: out)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "render" where arguments.count == 4:
    guard let size = Int(arguments[2]), size > 0 else { fail("pixels must be a positive number") }
    render(svg: arguments[1], size: size, out: arguments[3])
case "sheet" where arguments.count == 4:
    sheet(branding: arguments[1], iconset: arguments[2], out: arguments[3])
default:
    fail("usage: render-branding render <svg> <pixels> <out.png> | sheet <branding dir> <iconset dir> <out.png>")
}
