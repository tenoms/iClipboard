import Combine
import Foundation

@MainActor
final class TranslationPreferences: ObservableObject {
    static let shared = TranslationPreferences()

    private enum Keys {
        static let enabled = "globalSelectionTranslationEnabled"
        static let provider = "globalSelectionTranslationProvider"
    }

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.enabled) }
    }

    @Published var provider: TranslationProvider {
        didSet { defaults.set(provider.rawValue, forKey: Keys.provider) }
    }

    @Published private(set) var hasSessionID: Bool

    private let defaults: UserDefaults
    private let credentialStore: TranslationCredentialStore

    private init(
        defaults: UserDefaults = .standard,
        credentialStore: TranslationCredentialStore = TranslationCredentialStore()
    ) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        self.isEnabled = defaults.bool(forKey: Keys.enabled)
        self.provider = TranslationProvider(
            rawValue: defaults.string(forKey: Keys.provider) ?? ""
        ) ?? .doubaoAI
        self.hasSessionID = credentialStore.readSessionID() != nil
    }

    func sessionID() throws -> String {
        guard let value = credentialStore.readSessionID() else {
            throw TranslationFeatureError.missingSessionID
        }
        return value
    }

    func currentSessionIDForEditing() -> String {
        credentialStore.readSessionID() ?? ""
    }

    func saveSessionID(_ candidate: String) throws {
        let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw TranslationFeatureError.missingSessionID
        }
        guard normalized.count <= 256,
              !normalized.contains(";"),
              !normalized.contains("\n"),
              !normalized.contains("\r") else {
            throw TranslationFeatureError.invalidSessionID
        }
        try credentialStore.saveSessionID(normalized)
        hasSessionID = true
    }

    func clearSessionID() throws {
        try credentialStore.deleteSessionID()
        hasSessionID = false
    }
}