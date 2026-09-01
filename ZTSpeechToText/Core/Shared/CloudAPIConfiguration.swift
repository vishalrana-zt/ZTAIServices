import Foundation

// MARK: - Configuration


public enum CloudAPIConfiguration {
    public enum Provider {
        case openAI
        case gemini
    }

    nonisolated(unsafe) public static var provider: Provider = .openAI

    nonisolated(unsafe) public static var openAIAPIKey: String? = nil
    nonisolated(unsafe) public static var openAIModel: String = "whisper-1"
    nonisolated(unsafe) public static var openAITextModel: String = "gpt-4o-mini"
    nonisolated(unsafe) public static var openAITextTimeout: TimeInterval = 60.0
    nonisolated(unsafe) public static var openAITextMaxRetries: Int = 2

    nonisolated(unsafe) public static var geminiAPIKey: String? = nil
    nonisolated(unsafe) public static var geminiModel: String = "gemini-3.6-flash"

    nonisolated(unsafe) public static var defaultTimeout: TimeInterval = 60.0
    nonisolated(unsafe) public static var timeoutPerAudioSecond: TimeInterval = 0.5
    nonisolated(unsafe) public static var maxAudioDurationSeconds: Double = 120.0
    // Gemini-specific: separate upload timeout (scales with file size) vs generation timeout.
    nonisolated(unsafe) public static var geminiUploadTimeoutBase: TimeInterval = 30.0
    nonisolated(unsafe) public static var geminiUploadTimeoutPerMB: TimeInterval = 10.0
    nonisolated(unsafe) public static var geminiUploadMaxRetries: Int = 2

    public static var activeAPIKey: String? {
        switch provider {
        case .openAI: return openAIAPIKey
        case .gemini: return geminiAPIKey
        }
    }
}
