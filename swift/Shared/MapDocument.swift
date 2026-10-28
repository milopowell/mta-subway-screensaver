import CoreGraphics
import Foundation

/// The black MTA map exported by the notebook (§8): a one-page vector PDF.
///
/// The PDF page *is* the map's coordinate system: x 0–1656 left→right, y 0–1978 bottom→top, one map unit per
/// PDF point. Every position in network.json uses the same coordinates, so they can be drawn onto it directly.
final class MapDocument {
    let page: CGPDFPage
    /// The whole map in map units (the PDF page's media box).
    let bounds: CGRect

    /// Opens the exported PDF. Returns nil if the file is missing or isn't a PDF.
    init?(url: URL) {
        guard let pdf = CGPDFDocument(url as CFURL), let firstPage = pdf.page(at: 1) else { return nil }
        page = firstPage
        bounds = firstPage.getBoxRect(.mediaBox)
    }

    /// Renders part of the map into a bitmap.
    ///
    /// - Parameters:
    ///   - mapRect: the region to show, in map units. It must have the same shape (aspect ratio) as `pixelSize`;
    ///     anything outside the map page is left black.
    ///   - pixelSize: the bitmap size in pixels (view size × screen scale, e.g. ×2 on Retina).
    /// - Returns: the rendered image, or nil if the bitmap couldn't be created.
    func renderImage(mapRect: CGRect, pixelSize: CGSize) -> CGImage? {
        let width = Int(pixelSize.width.rounded()), height = Int(pixelSize.height.rounded())
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        ctx.setFillColor(CGColor(gray: 0, alpha: 1))  // black everywhere first, including outside the page
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Map units → pixels. Both coordinate systems have their origin at the bottom-left, so this is
        // just "scale, then shift the requested region to the origin".
        let scale = CGFloat(width) / mapRect.width
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -mapRect.minX, y: -mapRect.minY)
        ctx.interpolationQuality = .high
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }
}
