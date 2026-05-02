// Composes the three screenshots into a single image laid out as:
//
//   ┌───────────────────────────────────────────────────┐
//   │              menu-bar (full width)                │
//   ├──────────────────────┬────────────────────────────┤
//   │       popover        │         settings           │
//   └──────────────────────┴────────────────────────────┘
//
// Run from the repo root with:  swift docs/screenshots/compose.swift

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

let dir = URL(fileURLWithPath: "docs/screenshots")
func loadCG(_ name: String) -> CGImage {
    let url = dir.appending(path: name)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        fputs("Could not load \(name)\n", stderr); exit(1)
    }
    return img
}
let menubar  = loadCG("menu-bar.png")
let popover  = loadCG("popover.png")
let settings = loadCG("settings.png")

func aspect(_ img: CGImage) -> CGFloat { CGFloat(img.width) / CGFloat(img.height) }

let pad: CGFloat = 20
let gap: CGFloat = 20
let rowGap: CGFloat = 20
let bottomHeight: CGFloat = 420

let popoverW  = (bottomHeight * aspect(popover)).rounded()
let settingsW = (bottomHeight * aspect(settings)).rounded()

// Bottom row dictates the working width; menu-bar scales to match.
let bottomRowWidth = popoverW + gap + settingsW
let menuW = bottomRowWidth
let menuH = (menuW / aspect(menubar)).rounded()

let canvasW = (bottomRowWidth + pad * 2)
let canvasH = (menuH + rowGap + bottomHeight + pad * 2)

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: Int(canvasW),
    height: Int(canvasH),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("Could not create CGContext\n", stderr); exit(1)
}

// Transparent background; both light and dark GitHub themes render OK.
ctx.clear(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))

// Cocoa-style coords (origin bottom-left). Place menu-bar at top.
ctx.draw(menubar, in: CGRect(
    x: pad,
    y: canvasH - pad - menuH,
    width: menuW,
    height: menuH
))

// Bottom row, popover left + settings right, both at bottomHeight.
ctx.draw(popover, in: CGRect(
    x: pad,
    y: pad,
    width: popoverW,
    height: bottomHeight
))
ctx.draw(settings, in: CGRect(
    x: pad + popoverW + gap,
    y: pad,
    width: settingsW,
    height: bottomHeight
))

guard let cgOut = ctx.makeImage() else {
    fputs("Failed to make image from context\n", stderr); exit(1)
}

let outURL = dir.appending(path: "hero.png")
guard let dest = CGImageDestinationCreateWithURL(
    outURL as CFURL, UTType.png.identifier as CFString, 1, nil
) else {
    fputs("Could not create destination\n", stderr); exit(1)
}
CGImageDestinationAddImage(dest, cgOut, nil)
guard CGImageDestinationFinalize(dest) else {
    fputs("Failed to finalize PNG\n", stderr); exit(1)
}
print("wrote \(outURL.path) (\(Int(canvasW))×\(Int(canvasH)))")
