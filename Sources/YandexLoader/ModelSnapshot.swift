import Foundation
import CoreGraphics
import libwebp

enum ModelSnapshot {
    static func destination(for file: FileEntry) -> Location {
        file.location.parent.child((file.name as NSString).deletingPathExtension + ".webp")
    }

    static func encode(_ image: CGImage) throws -> Data {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 16383, height <= 16383 else {
            throw LoaderError.message("Размер снимка не поддерживается форматом WebP.")
        }
        let stride = width * 4
        var pixels = [UInt8](repeating: 0, count: stride * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: stride, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // The preview is opaque. Composite into the same background before encoding.
            context.setFillColor(CGColor(gray: 0.13, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw LoaderError.message("Не удалось подготовить изображение снимка.") }
        var output: UnsafeMutablePointer<UInt8>?
        let count = pixels.withUnsafeBufferPointer {
            WebPEncodeLosslessRGBA($0.baseAddress, Int32(width), Int32(height), Int32(stride), &output)
        }
        guard count > 0, let output else { throw LoaderError.message("Не удалось сохранить изображение в WebP.") }
        defer { WebPFree(output) }
        return Data(bytes: output, count: count)
    }

    static func availableCopy(of target: Location, files: FileService) async throws -> Location {
        var number = 2
        var candidate: Location
        repeat {
            try Task.checkCancellation()
            candidate = target.parent.child(Listing.numberedName(target.name, number: number, isDirectory: false))
            number += 1
        } while try await files.exists(candidate)
        return candidate
    }
}
