// Fits a square icon artwork onto the macOS icon grid (1024 × 1024 canvas, 824 × 824 body,
// transparent corners, soft drop shadow).
//
//   swift scripts/prepare_icon.swift Resources/AppIcon-source.png Resources/AppIcon-1024.png
//
// The artwork's own rounded corners are detected (first non-black pixel along the diagonal) and
// everything outside them is made transparent.
import AppKit

let args = CommandLine.arguments
let src = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: args[1])))!
let w = src.pixelsWide, h = src.pixelsHigh

// Find the body's edge along the top-left diagonal and on the left/top sides.
// The artwork sits on a pure-black canvas; the body is anything brighter.
func isBody(_ x: Int, _ y: Int) -> Bool {
    guard let c = src.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
    return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.03
}
var diag = 0
while diag < w / 2 && !isBody(diag, diag) { diag += 1 }
var side = 0
while side < w / 2 && !isBody(side, h / 2) { side += 1 }
// For a rounded rect inset by `side` with radius r, the diagonal hits the edge at side + r(1 - 1/√2).
let radius = Double(diag - side) / (1 - 1 / 2.0.squareRoot())
let body = CGRect(x: side, y: side, width: w - 2 * side, height: h - 2 * side)
print("detected inset \(side) px, corner radius \(Int(radius)) px")

let S = 1024
let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
let target = CGRect(x: 100, y: 100, width: 824, height: 824)
let scale = target.width / body.width
let r = (radius + 1.5) * scale
let mask = CGPath(roundedRect: target, cornerWidth: r, cornerHeight: r, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.4))
ctx.addPath(mask); ctx.setFillColor(CGColor(gray: 0.08, alpha: 1)); ctx.fillPath()
ctx.restoreGState()

ctx.addPath(mask); ctx.clip()
// Draw the source so that its body lands exactly on the target rect (CG images draw bottom-up).
let drawRect = CGRect(x: target.minX - body.minX * scale, y: target.minY - body.minY * scale,
                      width: CGFloat(w) * scale, height: CGFloat(h) * scale)
ctx.draw(src.cgImage!, in: drawRect)

try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2])")
