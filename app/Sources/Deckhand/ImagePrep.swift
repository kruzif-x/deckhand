// ImagePrep.swift — turn any image into the JPEG the 293S firmware expects.
//
// Mirrors the vendor SDK's _to_native_format(): rotate 90° counter-clockwise (expand), then
// resize to the slot size (85x85 for keys, 80x80 for the 1x3 window), then encode as JPEG.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

enum ImagePrep {
    static let keySize = 85
    static let windowSize = 80

    static func size(for slot: Int) -> Int {
        slot >= 16 ? windowSize : keySize
    }

    /// Load any image file (png/jpeg/heic/…) as a CGImage.
    static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return img
    }

    /// Square the image without the firmware rotation — this is what we store on disk, so the
    /// rotation is applied exactly once, at send time.
    static func square(_ image: CGImage, side: Int, quality: Double = 0.95) -> Data? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        let scale = max(CGFloat(side) / w, CGFloat(side) / h)
        ctx.translateBy(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
        ctx.scaleBy(x: scale, y: scale)
        ctx.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        return ctx.makeImage().flatMap { jpeg($0, quality: quality) }
    }

    /// Rotate 90° CCW with expansion, resize to `side`, encode JPEG. This produces the bytes the
    /// firmware expects, so it must be applied exactly once — never to a file already prepared.
    static func isPrepared(side: Int) -> Bool { false }
    static func prepare(_ image: CGImage, side: Int, quality: Double = 0.94) -> Data? {
        let rotated = rotate90CCW(image) ?? image
        guard let scaled = resize(rotated, to: side) else { return nil }
        return jpeg(scaled, quality: quality)
    }

    static func prepare(url: URL, side: Int, quality: Double = 0.94) -> Data? {
        guard let img = load(url) else { return nil }
        return prepare(img, side: side, quality: quality)
    }

    // 90° counter-clockwise, expanding the canvas (PIL: Image.rotate(90, expand=True))
    static func rotate90CCW(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: h, height: w,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: CGFloat(h), y: 0)
        ctx.rotate(by: .pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Tall pane variant: rotate 90° CCW (the firmware's single rotation) and scale to
    /// `height × side` so a 80×N pane is sent as an N×80 JPEG.
    static func prepareTall(_ image: CGImage, side: Int, height: Int) -> Data? {
        let rotated = rotate90CCW(image) ?? image
        guard let scaled = resize(rotated, width: height, height: side) else { return nil }
        return jpeg(scaled, quality: 0.94)
    }

    static func resize(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    static func resize(_ image: CGImage, to side: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()
    }

    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
