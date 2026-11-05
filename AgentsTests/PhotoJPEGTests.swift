import ImageIO
import UIKit
import XCTest

@testable import Agents

final class PhotoJPEGTests: XCTestCase {
    /// A PNG with a known size and one EXIF field, standing in for a HEIC.
    private func png(width: Int, height: Int) -> Data {
        let img = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: {
                let f = UIGraphicsImageRendererFormat()
                f.scale = 1
                return f
            }()
        )
        .image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        let props: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "keep-me"]]
        CGImageDestinationAddImage(dest, img.cgImage!, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    func testOutputIsJPEGAtFullSize() throws {
        let jpeg = try XCTUnwrap(PhotoJPEG.jpeg(from: png(width: 400, height: 300)))
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])
        let src = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let p = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        XCTAssertEqual(p[kCGImagePropertyPixelWidth] as? Int, 400)
        XCTAssertEqual(p[kCGImagePropertyPixelHeight] as? Int, 300)
    }

    func testMetadataSurvives() throws {
        let jpeg = try XCTUnwrap(PhotoJPEG.jpeg(from: png(width: 10, height: 10)))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let p = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertEqual(exif?[kCGImagePropertyExifUserComment] as? String, "keep-me")
    }

    func testGarbageIsNil() {
        XCTAssertNil(PhotoJPEG.jpeg(from: Data("not an image".utf8)))
    }
}
