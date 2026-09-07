import Combine
import Foundation

@MainActor
final class DictationSettings: ObservableObject {
    @Published var language: String {
        didSet { defaults.set(language, forKey: Storage.language) }
    }
    @Published var vocabulary: String {
        didSet { defaults.set(vocabulary, forKey: Storage.vocabulary) }
    }
    @Published var zeroRetention: Bool {
        didSet { defaults.set(zeroRetention, forKey: Storage.zeroRetention) }
    }
    @Published var privacyReviewed: Bool {
        didSet { defaults.set(privacyReviewed, forKey: Storage.privacyGuidanceReviewed) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = defaults.string(forKey: Storage.language) ?? ""
        vocabulary = defaults.string(forKey: Storage.vocabulary) ?? ""
        zeroRetention = defaults.object(forKey: Storage.zeroRetention) as? Bool ?? false
        privacyReviewed = defaults.object(forKey: Storage.privacyGuidanceReviewed) as? Bool ?? false
    }

    var keyterms: [String] {
        vocabulary.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var vocabularyValid: Bool {
        keyterms.count <= 50 && keyterms.allSatisfy { $0.count <= 20 }
    }

    var configuration: RealtimeConfiguration {
        RealtimeConfiguration(
            language: language.isEmpty ? nil : language,
            keyterms: keyterms,
            zeroRetention: zeroRetention
        )
    }

    private enum Storage {
        static let language = "dictation.language"
        static let vocabulary = "dictation.vocabulary"
        static let zeroRetention = "dictation.zeroRetention"
        static let privacyGuidanceReviewed = "privacyGuidanceReviewed"
    }
}
