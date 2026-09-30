//
//  MnemonicError.swift
//  MnemonicCore
//

public import Foundation

public enum MnemonicError: LocalizedError, Equatable, Sendable {
    case noteNotFound
    case ideaMissing
    case imageUnavailable
    case unimplemented(String)
    /// OpenAI refused or failed; carries its own explanation.
    case imageService(String)
    /// Keychain OSStatus.
    case keychain(Int32)

    public var errorDescription: String? {
        switch self {
        case .noteNotFound:
            return "This card's note no longer exists."
        case .ideaMissing:
            return "This idea is no longer on the card — it may have been removed on another device."
        case .imageUnavailable:
            return "Pictures can't be made on this device."
        case .unimplemented(let what):
            return "\(what) isn't available here."
        case .imageService(let message):
            return "OpenAI: \(message)"
        case .keychain(let status):
            return "Couldn't save the key to this iPhone's Keychain (error \(status))."
        }
    }
}
