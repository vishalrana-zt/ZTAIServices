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

    nonisolated(unsafe) static var provider: Provider = .openAI

    nonisolated(unsafe) static var openAIAPIKey: String? = nil
    nonisolated(unsafe) static var openAIModel: String = "whisper-1"
    nonisolated(unsafe) static var openAITextModel: String = "gpt-4o-mini"
    nonisolated(unsafe) static var openAITextTimeout: TimeInterval = 60.0
    nonisolated(unsafe) static var openAITextMaxRetries: Int = 2

    nonisolated(unsafe) static var geminiAPIKey: String? = nil
    nonisolated(unsafe) static var geminiModel: String = "gemini-3.6-flash"

    nonisolated(unsafe) static var defaultTimeout: TimeInterval = 60.0
    nonisolated(unsafe) static var timeoutPerAudioSecond: TimeInterval = 0.5
    nonisolated(unsafe) static var maxAudioDurationSeconds: Double = 120.0
    // Gemini-specific: separate upload timeout (scales with file size) vs generation timeout.
    nonisolated(unsafe) static var geminiUploadTimeoutBase: TimeInterval = 30.0
    nonisolated(unsafe) static var geminiUploadTimeoutPerMB: TimeInterval = 10.0
    nonisolated(unsafe) static var geminiUploadMaxRetries: Int = 2

    static var activeAPIKey: String? {
        switch provider {
        case .openAI: return openAIAPIKey
        case .gemini: return geminiAPIKey
        }
    }
}
