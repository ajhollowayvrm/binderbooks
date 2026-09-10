// Draws the BinderBooks app icon: a card in a ring binder.
//
//   swift scripts/gen-icon.swift ios/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
//
// Core Graphics only, so the icon is reproducible from this file and needs no
// design tool. iOS masks the square to its own rounded shape, so the artwork is
// drawn full-bleed with the rings inset enough to survive the mask.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("no context") }

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

// Background: deep navy to blue, lighter toward the top right.
let bg = CGRect(x: 0, y: 0, width: size, height: size)
ctx.addRect(bg)
ctx.clip()
ctx.drawLinearGradient(
    gradient([rgb(0x0B1E4F), rgb(0x1E4FD1)], [0, 1]),
    start: CGPoint(x: 0, y: 0), end: CGPoint(x: size, y: size), options: []
)
ctx.resetClip()

// A soft glow behind the card so it lifts off the background.
ctx.saveGState()
ctx.drawRadialGradient(
    gradient([rgb(0x60A5FA, 0.35), rgb(0x60A5FA, 0)], [0, 1]),
    startCenter: CGPoint(x: 600, y: 540), startRadius: 0,
    endCenter: CGPoint(x: 600, y: 540), endRadius: 520, options: []
)
ctx.restoreGState()

// The card. Tilted a little, like one lifted out of a binder page.
let cardWidth: CGFloat = 520
let cardHeight: CGFloat = 728
ctx.saveGState()
ctx.translateBy(x: 590, y: 512)
ctx.rotate(by: -7 * .pi / 180)
let card = CGRect(x: -cardWidth / 2, y: -cardHeight / 2, width: cardWidth, height: cardHeight)
let cardPath = CGPath(roundedRect: card, cornerWidth: 36, cornerHeight: 36, transform: nil)

ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 48, color: rgb(0x000000, 0.45))
ctx.addPath(cardPath)
ctx.setFillColor(rgb(0xFFF7E6))
ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)

// Card border, a warm yellow like a real card's frame.
ctx.addPath(cardPath)
ctx.setStrokeColor(rgb(0xF2C14E))
ctx.setLineWidth(22)
ctx.strokePath()

// Art window: a gradient sky with a sun, the "holo" part of the card.
let art = CGRect(x: card.minX + 56, y: card.maxY - 56 - 400, width: cardWidth - 112, height: 400)
let artPath = CGPath(roundedRect: art, cornerWidth: 18, cornerHeight: 18, transform: nil)
ctx.saveGState()
ctx.addPath(artPath)
ctx.clip()
ctx.drawLinearGradient(
    gradient([rgb(0xF97316), rgb(0xEC4899), rgb(0x8B5CF6), rgb(0x06B6D4)], [0, 0.4, 0.75, 1]),
    start: CGPoint(x: art.minX, y: art.maxY), end: CGPoint(x: art.maxX, y: art.minY), options: []
)
// A pale diagonal sheen across the art.
ctx.setFillColor(rgb(0xFFFFFF, 0.22))
ctx.move(to: CGPoint(x: art.minX + 60, y: art.maxY))
ctx.addLine(to: CGPoint(x: art.minX + 190, y: art.maxY))
ctx.addLine(to: CGPoint(x: art.maxX - 120, y: art.minY))
ctx.addLine(to: CGPoint(x: art.maxX - 250, y: art.minY))
ctx.closePath()
ctx.fillPath()
ctx.restoreGState()

// Name bar and two text lines, in the card's own yellow and gray.
let nameBar = CGRect(x: card.minX + 56, y: art.minY - 26 - 44, width: 250, height: 44)
ctx.addPath(CGPath(roundedRect: nameBar, cornerWidth: 12, cornerHeight: 12, transform: nil))
ctx.setFillColor(rgb(0x1F2937))
ctx.fillPath()
for (i, width) in [cardWidth - 112, cardWidth - 200].enumerated() {
    let line = CGRect(x: card.minX + 56, y: nameBar.minY - 40 - CGFloat(i) * 40, width: width, height: 20)
    ctx.addPath(CGPath(roundedRect: line, cornerWidth: 10, cornerHeight: 10, transform: nil))
    ctx.setFillColor(rgb(0x9CA3AF))
    ctx.fillPath()
}
// Collector number, bottom right of the card, as a tiny bar.
let number = CGRect(x: card.maxX - 56 - 110, y: card.minY + 44, width: 110, height: 22)
ctx.addPath(CGPath(roundedRect: number, cornerWidth: 11, cornerHeight: 11, transform: nil))
ctx.setFillColor(rgb(0x6B7280))
ctx.fillPath()
ctx.restoreGState()

// Binder rings down the left edge. Three, like a real ring binder, drawn over
// the card so the card reads as filed in the binder.
let ringCenters: [CGFloat] = [790, 512, 234]
for y in ringCenters {
    let center = CGPoint(x: 150, y: y)
    let outer: CGFloat = 92
    let inner: CGFloat = 52

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.5))
    ctx.addArc(center: center, radius: outer, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    ctx.addArc(center: center, radius: inner, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
    ctx.setFillColor(rgb(0xD1D5DB))
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()

    // Metal shading: a gradient clipped to the ring.
    ctx.saveGState()
    ctx.addArc(center: center, radius: outer, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    ctx.addArc(center: center, radius: inner, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
    ctx.clip(using: .evenOdd)
    ctx.drawLinearGradient(
        gradient([rgb(0xF9FAFB), rgb(0xC7CDD6), rgb(0x8B94A3), rgb(0xE5E7EB)], [0, 0.45, 0.8, 1]),
        start: CGPoint(x: center.x - outer, y: center.y + outer),
        end: CGPoint(x: center.x + outer, y: center.y - outer), options: []
    )
    ctx.restoreGState()

    // The hole shows the binder's dark spine through it.
    ctx.addArc(center: center, radius: inner - 6, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    ctx.setFillColor(rgb(0x081536))
    ctx.fillPath()
}

// Write the PNG.
guard let image = ctx.makeImage() else { fatalError("no image") }
let url = URL(fileURLWithPath: output)
guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("cannot write \(output)")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("finalize failed") }
print("wrote \(output)")
