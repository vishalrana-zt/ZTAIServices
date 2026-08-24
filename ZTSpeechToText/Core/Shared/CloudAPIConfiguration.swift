import Foundation

// MARK: - Configuration

// Set provider + key once at app startup before any transcription occurs.
// Production: read keys from iOS Keychain.
//
// Whisper (recommended):
//   CloudAPIConfiguration.provider      = .whisper
//   CloudAPIConfiguration.whisperAPIKey = "sk-..."   // platform.openai.com
//
// Gemini:
//   CloudAPIConfiguration.provider      = .gemini
//   CloudAPIConfiguration.geminiAPIKey  = "AIza..."  // aistudio.google.com/apikey
//
enum CloudAPIConfiguration {
    enum Provider {
        case whisper
        case gemini
    }

    static var provider: Provider = .whisper

    static var whisperAPIKey: String? = nil
    static var whisperModel: String = "whisper-1"

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
        case .whisper: return whisperAPIKey
        case .gemini:  return geminiAPIKey
        }
    }
}
