// Single language enum shared across speech-to-text, text AI, and image OCR.
enum SupportedLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case spanish = "es"
    case french  = "fr"

    var displayName: String {
        switch self {
        case .english: return "English"
        case .spanish: return "Spanish"
        case .french:  return "French"
        }
    }

    // ISO 639-1 code — used as locale identifier and AI prompt language hint.
    var localeIdentifier: String { rawValue }

    // Full language name for AI prompt instructions.
    var responseLanguageInstruction: String {
        switch self {
        case .english: return "English"
        case .spanish: return "Spanish"
        case .french:  return "French"
        }
    }


}
