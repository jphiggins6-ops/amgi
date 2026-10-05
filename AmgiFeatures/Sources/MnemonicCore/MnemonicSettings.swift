//
//  MnemonicSettings.swift
//  MnemonicCore
//

import Foundation
import Security

/// Picture settings. Quality and model live in UserDefaults; the API key
/// lives in the Keychain (`MnemonicAPIKey`) and never anywhere else.
public enum MnemonicSettings {
    public enum Quality: String, CaseIterable, Identifiable, Sendable {
        case low, medium, high

        public var id: String { rawValue }

        /// Rough price per 1024×1024 picture, from third-party trackers in
        /// September 2026. OpenAI's pricing page is the source of truth.
        public var roughCost: String {
            switch self {
            case .low: return "about 1¢"
            case .medium: return "about 3–4¢"
            case .high: return "about 13–17¢"
            }
        }
    }

    /// `gpt-image-1` retires on 23 October 2026, so it is not the default.
    public static let defaultModel = "gpt-image-1.5"

    static let qualityKey = "mnemonic_openai_quality"
    static let modelKey = "mnemonic_openai_model"

    /// Medium by default: a mnemonic has to be clear, not beautiful, and
    /// low quality can blur the one detail the picture exists to show.
    public static var quality: Quality {
        get { UserDefaults.standard.string(forKey: qualityKey).flatMap(Quality.init(rawValue:)) ?? .medium }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: qualityKey) }
    }

    /// Editable, so a retired model is a settings change, not a new build.
    public static var model: String {
        get {
            let stored = UserDefaults.standard.string(forKey: modelKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? defaultModel : stored
        }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }
}

/// The OpenAI API key, in the Keychain. Deliberately not profile-scoped:
/// the key belongs to the person paying, not to a collection.
public enum MnemonicAPIKey {
    static let item = KeychainKey(service: "com.amgiapp.mnemonic", account: "openai-api-key")

    public static func load() -> String? { item.load() }
    public static func save(_ key: String) throws { try item.save(key) }
    public static func delete() { item.delete() }
}

/// The Google Gemini API key, for hands-free mode's AI voice. In the
/// Keychain, like the OpenAI key, and likewise not profile-scoped.
public enum GeminiAPIKey {
    static let item = KeychainKey(service: "com.amgiapp.gemini", account: "gemini-api-key")

    public static func load() -> String? { item.load() }
    public static func save(_ key: String) throws { try item.save(key) }
    public static func delete() { item.delete() }

    /// Google's two kinds of key, told apart by how they start. Since
    /// September 2026 the Gemini API takes only auth keys.
    public enum Kind: Sendable {
        /// "AQ.": bound to a service account, made by Google AI Studio.
        case auth
        /// "AIza": the older kind, which Gemini now refuses.
        case standard
        case unknown
    }

    public static func kind(of key: String) -> Kind {
        if key.hasPrefix("AQ.") { return .auth }
        if key.hasPrefix("AIza") { return .standard }
        return .unknown
    }
}

/// An API key kept in the Keychain as a generic password.
struct KeychainKey: Sendable {
    let service: String
    let account: String

    func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else { return nil }
        return key
    }

    /// Update in place, else add — the same order as `KeychainHelper`, so a
    /// failed write never leaves the old key deleted.
    func save(_ key: String) throws {
        let data = Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateStatus = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw MnemonicError.keychain(updateStatus) }

        var insert = identity
        insert[kSecValueData as String] = data
        // ThisDeviceOnly: a paid API key shouldn't ride a backup onto
        // another device without the owner re-entering it. AfterFirstUnlock:
        // hands-free mode reads it with the screen locked.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw MnemonicError.keychain(status) }
    }

    func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
