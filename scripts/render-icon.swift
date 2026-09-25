// Renders assets/icon/source.png: a 1024x1024 macOS app icon on Apple's icon grid
// (824x824 tile inset 100px, 185.4px corner radius, standard drop shadow).
// Usage: swift scripts/render-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
  CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
          blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Use top-left origin so the coordinates below read like the design grid.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

let shape = CGPath(roundedRect: tile, cornerWidth: 185.4, cornerHeight: 185.4, transform: nil)

// Drop shadow: soft ambient plus a tighter contact shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.30))
ctx.addPath(shape); ctx.setFillColor(rgb(0xffffff)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 4, color: rgb(0x000000, 0.18))
ctx.addPath(shape); ctx.setFillColor(rgb(0xffffff)); ctx.fillPath()
ctx.restoreGState()

// Paper face: faint warm vertical gradient.
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let face = CGGradient(colorsSpace: nil, colors: [rgb(0xffffff), rgb(0xf2f1ed)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(face, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])
// Hairline inner edge so the white tile holds its shape on light backgrounds.
ctx.addPath(shape); ctx.setStrokeColor(rgb(0x000000, 0.08)); ctx.setLineWidth(4); ctx.strokePath()
ctx.restoreGState()

// Symbol: a red margin rule and three lines of text, centered on the tile.
let scale: CGFloat = 1.25
ctx.translateBy(x: 512, y: 512); ctx.scaleBy(x: scale, y: scale); ctx.translateBy(x: -512, y: -512)
let stroke: CGFloat = 44
ctx.setLineCap(.round)
ctx.setLineWidth(stroke)
ctx.setStrokeColor(rgb(0xe0463c))
ctx.move(to: CGPoint(x: 334, y: 334)); ctx.addLine(to: CGPoint(x: 334, y: 690)); ctx.strokePath()
ctx.setStrokeColor(rgb(0x3a3a3c))
for (y, end) in [(400, 690), (512, 690), (624, 598)] as [(CGFloat, CGFloat)] {
  ctx.move(to: CGPoint(x: 422, y: y)); ctx.addLine(to: CGPoint(x: end, y: y)); ctx.strokePath()
}

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
