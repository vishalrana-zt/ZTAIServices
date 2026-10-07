import Foundation

struct TranscriptionRequest {
    let audio: [Float]
    let sampleRate: Double
    let localeHint: Locale?
    let timeoutInterval: TimeInterval?
    /// Words the recognizer should expect (see `SpeechContextHints`). Empty = no hint.
    let contextualStrings: [String]

    init(
        audio: [Float],
        sampleRate: Double,
        localeHint: Locale?,
        timeoutInterval: TimeInterval? = nil,
        contextualStrings: [String] = []
    ) {
        self.audio = audio
        self.sampleRate = sampleRate
        self.localeHint = localeHint
        self.timeoutInterval = timeoutInterval
        self.contextualStrings = contextualStrings
    }
}

struct TranscriptionResult {
    let text: String
    let locale: Locale
}

enum TranscriptionEngineError: LocalizedError {
    case authorizationDenied
    case engineUnavailable
    case unsupportedLocale
    case emptyAudio
    case noFinalText
    case timeout
    case cancelled
    case transcriptionFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "Speech authorization denied."
        case .engineUnavailable:
            return "Speech engine is unavailable."
        case .unsupportedLocale:
            return "Locale is unsupported by this speech engine."
        case .emptyAudio:
            return "No audio available for transcription."
        case .noFinalText:
            return "No speech detected."
        case .timeout:
            return "Speech transcription timed out."
        case .cancelled:
            return "Speech transcription was cancelled."
        case .transcriptionFailed(let underlying):
            return underlying.localizedDescription
        }
    }
}

protocol FinalTranscriptionEngine {
    var engineID: String { get }
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult
}
