//
//  MnemonicImageProcessing.swift
//  MnemonicCore
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Shrinks a generated picture before it becomes Anki media. A 1024 px PNG
/// is ~1.5 MB; at 768 px JPEG it's ~100 KB — a thousand mnemonics is then
/// ~100 MB of media instead of ~1.5 GB, and still sharp on a phone card.
enum MnemonicImageProcessing {
    static let maxSide: CGFloat = 768
    static let jpegQuality: CGFloat = 0.8

    static func finalize(_ data: Data) async -> MnemonicImage {
        #if canImport(UIKit)
        if let jpeg = await resizedJPEG(from: data) {
            return MnemonicImage(data: jpeg, fileExtension: "jpg")
        }
        #endif
        // Couldn't decode it here — keep the original, named for what it is.
        return MnemonicImage(data: data, fileExtension: sniffExtension(data))
    }

    static func sniffExtension(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if bytes.count >= 12,
           Array(bytes[0..<4]) == [0x52, 0x49, 0x46, 0x46],   // RIFF
           Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] { // WEBP
            return "webp"
        }
        return "png"
    }

    #if canImport(UIKit)
    @MainActor
    static func resizedJPEG(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxSide / longest)
        let size = CGSize(
            width: (image.size.width * scale).rounded(),
            height: (image.size.height * scale).rounded()
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { context in
            // JPEG has no transparency; paint white so any transparent
            // pixels don't come out black.
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: jpegQuality)
    }
    #endif
}
