//
//  ShakeDetection.swift
//  ReviewFeature
//

#if canImport(UIKit)
public import UIKit
import Foundation

extension Notification.Name {
    /// The phone was shaken, and nothing in front took the shake for itself
    /// (a text field being edited keeps it for shake-to-undo).
    static let amgiDeviceDidShake = Notification.Name("amgiDeviceDidShake")
}

/// UIKit reports a shake as a motion event travelling up the responder
/// chain, not as a touch, so SwiftUI has no gesture for it. The window is
/// where the chain ends: a shake no text field claimed arrives here and is
/// announced, and the review screen acts on it only while it's open.
///
/// `public import UIKit` because an override in an extension of a public
/// class must be as visible as the method it overrides.
extension UIWindow {
    override open func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .amgiDeviceDidShake, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}
#endif
