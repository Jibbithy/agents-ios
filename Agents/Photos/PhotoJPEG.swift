import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Picked photo bytes (usually HEIC) -> JPEG at full resolution.
///
/// IMAGEIO, NOT `UIImage.jpegData`: that path drops every metadata dictionary,
/// and the spec keeps EXIF/GPS (the date a receipt was shot is useful to
/// Claude). Copying the source's properties onto the destination keeps them.
enum PhotoJPEG {
    static func jpeg(from data: Data, quality: Double = 0.9) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(src) > 0
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        props[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
