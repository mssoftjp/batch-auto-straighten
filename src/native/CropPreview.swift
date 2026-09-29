import CoreGraphics
import Foundation
import ImageIO

// A view-only estimate from the current rendered preview. Never writes photo settings.
enum CropPreview {
  static func render(image: CGImage, degrees: Double, output: String) throws {
    guard degrees.isFinite, abs(degrees) <= 90 else { throw PreviewError.invalidAngle }
    let fit = min(700.0/Double(image.width), 400.0/Double(image.height))
    let canvasW = max(1, Int((Double(image.width)*fit).rounded()))
    let canvasH = max(1, Int((Double(image.height)*fit).rounded()))
    guard let ctx = CGContext(data: nil, width: canvasW, height: canvasH,
      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PreviewError.render }
    let w = Double(canvasW), h = Double(canvasH)
    let angle = degrees * .pi / 180
    let c = abs(cos(angle)), s = abs(sin(angle))
    let scale = 1.0
    // Largest centered rectangle of the original aspect ratio inside the rotated image.
    let cropScale = min(w/(w*c+h*s), h/(w*s+h*c))
    let cropW = w*cropScale*scale, cropH = h*cropScale*scale
    let crop = CGRect(x: (Double(canvasW)-cropW)/2, y: (Double(canvasH)-cropH)/2, width: cropW, height: cropH)
    ctx.interpolationQuality = .high
    // Keep the photograph exactly as rendered. Rotate only the proposed crop boundary,
    // inverse to the clockwise correction that a positive Lightroom UI angle applies.
    ctx.draw(image, in: CGRect(x: (Double(canvasW)-w*scale)/2, y: (Double(canvasH)-h*scale)/2, width: w*scale, height: h*scale))
    let transform = CGAffineTransform(translationX: Double(canvasW)/2, y: Double(canvasH)/2)
      .rotated(by: angle).translatedBy(x: -Double(canvasW)/2, y: -Double(canvasH)/2)
    let outline = CGMutablePath()
    outline.addRect(crop, transform: transform)
    ctx.saveGState()
    ctx.addRect(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
    ctx.addPath(outline)
    ctx.clip(using: .evenOdd)
    ctx.setFillColor(CGColor(gray: 0, alpha: 0.48))
    ctx.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
    ctx.restoreGState()
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
    ctx.setLineWidth(1.5)
    ctx.addPath(outline)
    ctx.strokePath()
    ctx.saveGState()
    ctx.concatenate(transform)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.32))
    ctx.setLineWidth(0.6)
    for i in 1...2 {
      let part = Double(i)/3
      ctx.move(to: CGPoint(x: crop.minX+crop.width*part, y: crop.minY))
      ctx.addLine(to: CGPoint(x: crop.minX+crop.width*part, y: crop.maxY))
      ctx.move(to: CGPoint(x: crop.minX, y: crop.minY+crop.height*part))
      ctx.addLine(to: CGPoint(x: crop.maxX, y: crop.minY+crop.height*part))
    }
    ctx.strokePath()
    ctx.restoreGState()
    guard let rendered = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, "public.png" as CFString, 1, nil)
    else { throw PreviewError.render }
    CGImageDestinationAddImage(dest, rendered, nil)
    guard CGImageDestinationFinalize(dest) else { throw PreviewError.render }
  }
  enum PreviewError: Error { case invalidAngle, render }
}
