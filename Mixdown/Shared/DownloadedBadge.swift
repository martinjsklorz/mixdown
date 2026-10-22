import AppKit

/// The green check that marks downloaded models in the Settings model menus, for speech and
/// summary models alike.
enum DownloadedBadge {
    /// `checkmark.circle.fill` in green. Menus draw SF Symbols as monochrome templates, so the
    /// colors are baked into a non-template image. Menus also put a plain image's bottom on the
    /// baseline and ignore a baseline offset, so the symbol's padding is cropped off and the circle
    /// sized to the menu font's cap height: it then spans baseline to cap height, like the digits.
    /// The crop is to the drawn circle, not the `alignmentRect`, which is shorter and cuts it off.
    static let image: NSImage = {
        let font = NSFont.menuFont(ofSize: 0)
        let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .systemGreen]))
        guard
            let symbol = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
        else { return NSImage() }
        symbol.isTemplate = false
        guard let glyph = inkBounds(of: symbol), glyph.height > 0 else { return symbol }
        let scale = font.capHeight / glyph.height
        let size = NSSize(width: (glyph.width * scale).rounded(.up), height: font.capHeight)
        let image = NSImage(size: size, flipped: false) { _ in
            symbol.draw(
                in: NSRect(
                    x: -glyph.minX * scale,
                    y: -glyph.minY * scale,
                    width: symbol.size.width * scale,
                    height: symbol.size.height * scale
                )
            )
            return true
        }
        image.accessibilityDescription = "Downloaded"
        return image
    }()

    /// The part of `image` that isn't transparent, in points from its bottom left; nil if none is.
    private static func inkBounds(of image: NSImage) -> NSRect? {
        let pixelsPerPoint = 8.0
        let width = Int((image.size.width * pixelsPerPoint).rounded(.up))
        let height = Int((image.size.height * pixelsPerPoint).rounded(.up))
        guard
            width > 0, height > 0,
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
            let context = NSGraphicsContext(bitmapImageRep: bitmap),
            let pixels = bitmap.bitmapData
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()

        // Rows run top to bottom; alpha is each pixel's last byte.
        var minX = width, maxX = -1, minRow = height, maxRow = -1
        for row in 0..<height {
            for x in 0..<width where pixels[row * bitmap.bytesPerRow + x * 4 + 3] > 0 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minRow = min(minRow, row)
                maxRow = max(maxRow, row)
            }
        }
        guard maxX >= minX else { return nil }
        return NSRect(
            x: Double(minX) / pixelsPerPoint,
            y: Double(height - 1 - maxRow) / pixelsPerPoint,
            width: Double(maxX - minX + 1) / pixelsPerPoint,
            height: Double(maxRow - minRow + 1) / pixelsPerPoint
        )
    }
}
