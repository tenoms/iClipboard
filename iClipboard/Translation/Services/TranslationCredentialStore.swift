import Foundation

struct TranslationCredentialStore {
    private let defaults: UserDefaults
    private let key = "doubaoTranslationSessionID"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func readSessionID() -> String? {
        guard let value = defaults.string(forKey: key), !value.isEmpty else {
            return nil
        }
        return value
    }

    func saveSessionID(_ value: String) throws {
        defaults.set(value, forKey: key)
    }

    func deleteSessionID() throws {
        defaults.removeObject(forKey: key)
    }
}
