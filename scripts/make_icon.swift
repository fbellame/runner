import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let ctx = CGContext(data: nil,
                    width: size,
                    height: size,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

ctx.setFillColor(CGColor(srgbRed: 10 / 255, green: 11 / 255, blue: 16 / 255, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

ctx.setStrokeColor(CGColor(srgbRed: 27 / 255, green: 32 / 255, blue: 48 / 255, alpha: 1))
ctx.setLineWidth(14)
for y in stride(from: 200, through: 824, by: 208) {
    ctx.move(to: CGPoint(x: 0, y: y))
    ctx.addLine(to: CGPoint(x: 1024, y: y))
}
for x in stride(from: 200, through: 824, by: 208) {
    ctx.move(to: CGPoint(x: x, y: 0))
    ctx.addLine(to: CGPoint(x: x, y: 1024))
}
ctx.strokePath()

func route(_ c: CGContext) {
    c.move(to: CGPoint(x: 190, y: 240))
    c.addCurve(to: CGPoint(x: 512, y: 512),
               control1: CGPoint(x: 420, y: 210),
               control2: CGPoint(x: 350, y: 500))
    c.addCurve(to: CGPoint(x: 840, y: 790),
               control1: CGPoint(x: 700, y: 525),
               control2: CGPoint(x: 680, y: 810))
}

let lime = CGColor(srgbRed: 200 / 255, green: 1.0, blue: 0, alpha: 1)
ctx.setShadow(offset: .zero,
              blur: 90,
              color: CGColor(srgbRed: 200 / 255, green: 1.0, blue: 0, alpha: 0.85))
ctx.setStrokeColor(lime)
ctx.setLineWidth(58)
ctx.setLineCap(.round)
route(ctx)
ctx.strokePath()

ctx.setShadow(offset: .zero, blur: 0, color: nil)
ctx.setFillColor(CGColor(srgbRed: 10 / 255, green: 11 / 255, blue: 16 / 255, alpha: 1))
ctx.fillEllipse(in: CGRect(x: 190 - 46, y: 240 - 46, width: 92, height: 92))
ctx.setStrokeColor(lime)
ctx.setLineWidth(30)
ctx.strokeEllipse(in: CGRect(x: 190 - 46, y: 240 - 46, width: 92, height: 92))
ctx.setFillColor(lime)
ctx.fillEllipse(in: CGRect(x: 840 - 52, y: 790 - 52, width: 104, height: 104))

let image = ctx.makeImage()!
let out = URL(fileURLWithPath: "Runner/Resources/Assets.xcassets/AppIcon.appiconset/icon_1024.png")
try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.path)")
