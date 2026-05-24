#!/usr/bin/env swift

// Usage: swift make_icon.swift [output-dir]
// Generates a macOS app icon .iconset (then run iconutil to make .icns).

import AppKit
import Foundation

let symbolName = "arrow.uturn.up.circle.fill"  // "pickup / resume" feel
let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/AppIcon.iconset"

// macOS app-icon "squircle" corner radius is ~22.5% of the icon size.
let cornerRatio: CGFloat = 0.225
let bgColor = NSColor(srgbRed: 0.97, green: 0.97, blue: 0.99, alpha: 1)
let glyphColor = NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1)

// iconset filenames Apple expects
let entries: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func render(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    defer { img.unlockFocus() }

    // Background squircle
    let radius = size * cornerRatio
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    bgColor.setFill()
    path.fill()

    // Foreground SF Symbol (template image), tinted glyphColor
    let pt = size * 0.62
    let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: .regular)
    guard let sym = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil),
          let sized = sym.withSymbolConfiguration(cfg)
    else {
        NSLog("symbol \(symbolName) not available")
        return img
    }
    sized.isTemplate = true
    let symSize = sized.size
    let drawRect = NSRect(
        x: (size - symSize.width) / 2,
        y: (size - symSize.height) / 2,
        width: symSize.width,
        height: symSize.height
    )
    // Tint via NSGraphicsContext: draw symbol, then fill atop with color
    if let ctx = NSGraphicsContext.current {
        ctx.saveGraphicsState()
        sized.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
        glyphColor.set()
        rect.fill(using: .sourceAtop)
        ctx.restoreGraphicsState()
        // After fill(.sourceAtop), the background squircle outside the symbol may also be
        // tinted. Fix by re-drawing the background only where it's not occupied by the
        // glyph — easier path: clip background draw to the squircle, then redraw the
        // background, then draw the symbol with .sourceIn pattern.
    }
    return img
}

// Simpler approach: render symbol into its own bitmap (black glyph on transparent),
// then composite onto background.
func renderV2(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    defer { img.unlockFocus() }

    // Squircle background
    let radius = size * cornerRatio
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
    bgColor.setFill()
    rect.fill()

    // Glyph
    let pt = size * 0.62
    let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: .regular)
    guard let sym = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil),
          let sized = sym.withSymbolConfiguration(cfg)
    else {
        return img
    }
    // Render glyph into an offscreen bitmap with glyphColor.
    let symSize = sized.size
    let glyphImg = NSImage(size: symSize)
    glyphImg.lockFocus()
    sized.draw(at: .zero, from: NSRect(origin: .zero, size: symSize),
               operation: .sourceOver, fraction: 1)
    glyphColor.set()
    NSRect(origin: .zero, size: symSize).fill(using: .sourceAtop)
    glyphImg.unlockFocus()

    let drawRect = NSRect(
        x: (size - symSize.width) / 2,
        y: (size - symSize.height) / 2,
        width: symSize.width,
        height: symSize.height
    )
    glyphImg.draw(in: drawRect, from: NSRect(origin: .zero, size: symSize),
                  operation: .sourceOver, fraction: 1)

    return img
}

func savePNG(_ img: NSImage, to url: URL) throws {
    guard let tiff = img.tiffRepresentation,
          let bmp = NSBitmapImageRep(data: tiff),
          let png = bmp.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "make_icon", code: 1)
    }
    try png.write(to: url)
}

// Main
try? FileManager.default.createDirectory(
    atPath: outputDir, withIntermediateDirectories: true, attributes: nil
)
for entry in entries {
    let img = renderV2(size: CGFloat(entry.px))
    let url = URL(fileURLWithPath: "\(outputDir)/\(entry.name)")
    do {
        try savePNG(img, to: url)
        print("✓ \(entry.name) (\(entry.px)px)")
    } catch {
        print("✗ \(entry.name): \(error)")
    }
}
print("done → \(outputDir)")
