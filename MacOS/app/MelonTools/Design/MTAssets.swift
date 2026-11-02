import AppKit
import SwiftUI

/// App artwork: the bundle logo, sized for each surface.
enum MelonAssets {
    /// Full-resolution logo from the app bundle (`Logo.png`).
    static let logo: NSImage = {
        if let url = Bundle.main.url(forResource: "Logo", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(size: NSSize(width: 64, height: 64))
    }()

    /// Small logo pre-rendered at menu-bar height.
    static let menuBarLogo: NSImage = {
        let height: CGFloat = 18
        let ratio = logo.size.height > 0 ? logo.size.width / logo.size.height : 1
        let size = NSSize(width: (height * ratio).rounded(), height: height)
        return NSImage(size: size, flipped: false) { rect in
            logo.draw(in: rect)
            return true
        }
    }()

    /// SwiftUI logo view sized to fit.
    ///
    /// The bundle artwork is a full-resolution illustration; drawing it directly at
    /// 18–56 pt makes CoreGraphics resample a ~1400 px bitmap for every frame of a
    /// scroll or a hover animation. Small prescaled copies are cached per pixel size.
    static func logoImage(size: CGFloat) -> some View {
        Image(nsImage: thumbnail(size: size))
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
    }

    private static let thumbnails = NSCache<NSString, NSImage>()

    private static func thumbnail(size: CGFloat) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let box = max(1, (size * scale).rounded())
        let key = String(Int(box)) as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }

        let aspect = logo.size.height > 0 ? logo.size.width / logo.size.height : 1
        let drawn = aspect >= 1
            ? NSSize(width: box, height: box / aspect)
            : NSSize(width: box * aspect, height: box)
        let image = NSImage(size: NSSize(width: box, height: box), flipped: false) { rect in
            let origin = NSPoint(
                x: rect.midX - drawn.width / 2,
                y: rect.midY - drawn.height / 2
            )
            logo.draw(in: NSRect(origin: origin, size: drawn))
            return true
        }
        thumbnails.setObject(image, forKey: key)
        return image
    }
}
