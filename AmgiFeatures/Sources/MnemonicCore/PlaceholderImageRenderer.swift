//
//  PlaceholderImageRenderer.swift
//  MnemonicCore
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum PlaceholderImageRenderer {
    static let side: CGFloat = 512

    static func render(caption: String, hue: Double) async throws -> Data {
        #if canImport(UIKit)
        return await drawPNG(caption: caption, hue: hue)
        #else
        throw MnemonicError.imageUnavailable
        #endif
    }

    #if canImport(UIKit)
    /// Main actor so this compiles whether or not the SDK marks the UIKit
    /// drawing types as main-actor-bound. A 512pt square takes a few ms.
    @MainActor
    static func drawPNG(caption: String, hue: Double) -> Data {
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.pngData { context in
            UIColor(hue: CGFloat(hue), saturation: 0.55, brightness: 0.85, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let label = NSAttributedString(
                string: "PLACEHOLDER\n\n\(caption)",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 34, weight: .semibold),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: paragraph,
                ]
            )
            label.draw(in: CGRect(x: 32, y: 88, width: side - 64, height: side - 176))
        }
    }
    #endif
}
