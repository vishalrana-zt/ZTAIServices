import Foundation

import Foundation

// Single language enum shared across speech-to-text, text AI, and image OCR.
public enum SupportedLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case spanish = "es"
    case french  = "fr"

    nonisolated public var displayName: String {
        switch self {
        case .english: return "English"
        case .spanish: return "Spanish"
        case .french:  return "French"
        }
    }

    // ISO 639-1 code — used as locale identifier and AI prompt language hint.
    nonisolated public var localeIdentifier: String { rawValue }

    // Full language name for AI prompt instructions.
    nonisolated public var responseLanguageInstruction: String {
        switch self {
        case .english: return "English"
        case .spanish: return "Spanish"
        case .french:  return "French"
        }
    }


}

public extension SupportedLanguage {
    static func from(languageCode: String?) -> SupportedLanguage {
        guard let languageCode else { return .english }
        let code = languageCode.lowercased()
        if code.hasPrefix("es") { return .spanish }
        if code.hasPrefix("fr") { return .french }
        return .english
    }

    static func defaultFromPreferredLocale() -> SupportedLanguage {
        from(languageCode: Locale.preferredLanguages.first)
    }
}
