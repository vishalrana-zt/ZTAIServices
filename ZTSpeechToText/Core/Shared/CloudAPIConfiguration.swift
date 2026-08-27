import Foundation

// MARK: - Configuration

// Set provider + key once at app startup before any transcription occurs.
// Production: read keys from iOS Keychain.
//
// OpenAI (recommended):
//   CloudAPIConfiguration.provider      = .openAI
//   CloudAPIConfiguration.openAIAPIKey  = "sk-..."   // platform.openai.com
//
// Gemini:
//   CloudAPIConfiguration.provider      = .gemini
//   CloudAPIConfiguration.geminiAPIKey  = "AIza..."  // aistudio.google.com/apikey
//
enum CloudAPIConfiguration {
    enum Provider {
        case openAI
        case gemini
    }

    static var provider: Provider = .openAI

    static var openAIAPIKey: String? = nil
    static var openAIModel: String = "whisper-1"
    static var openAITextModel: String = "gpt-4o-mini"
    static var openAITextTimeout: TimeInterval = 60.0
    static var openAITextMaxRetries: Int = 2

    static var geminiAPIKey: String? = nil
    static var geminiModel: String = "gemini-3.6-flash"

    static var defaultTimeout: TimeInterval = 60.0
    static var timeoutPerAudioSecond: TimeInterval = 0.5
    static var maxAudioDurationSeconds: Double = 120.0
    // Gemini-specific: separate upload timeout (scales with file size) vs generation timeout.
    static var geminiUploadTimeoutBase: TimeInterval = 30.0
    static var geminiUploadTimeoutPerMB: TimeInterval = 10.0
    static var geminiUploadMaxRetries: Int = 2

    static var activeAPIKey: String? {
        switch provider {
        case .openAI: return openAIAPIKey
        case .gemini: return geminiAPIKey
        }
    }
}
