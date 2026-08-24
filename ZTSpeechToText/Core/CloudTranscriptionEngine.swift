import Foundation
import AVFoundation

// MARK: - Configuration

// Set provider + key once at app startup before any transcription occurs.
// Production: read keys from iOS Keychain.
//
// Whisper (recommended):
//   CloudAPIConfiguration.provider    = .whisper
//   CloudAPIConfiguration.whisperAPIKey = "sk-..."          // platform.openai.com
//
// Claude:
//   CloudAPIConfiguration.provider    = .claude
//   CloudAPIConfiguration.claudeAPIKey = "sk-ant-api03-..." // console.anthropic.com
//
// Gemini:
//   CloudAPIConfiguration.provider    = .gemini
//   CloudAPIConfiguration.geminiAPIKey = "AIza..."          // aistudio.google.com/apikey
//
enum CloudAPIConfiguration {
    enum Provider {
        case whisper
        case claude
        case gemini
    }

    static var provider: Provider = .whisper

    static var whisperAPIKey: String? = nil
    static var whisperModel: String = "whisper-1"

    static var claudeAPIKey: String? = nil
    static var claudeModel: String = "claude-opus-4-8"
    static var claudeMaxTokens: Int = 2048

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
        case .claude:  return claudeAPIKey
        case .gemini:  return geminiAPIKey
        }
    }
}

// MARK: - Engine

// Cloud-based transcription engine. Records audio, encodes it to WAV,
// and forwards it to the configured cloud provider (Claude or Gemini).
//
// iOS < 26: primary engine (the only path available).
// iOS 26+: fallback when DictationTranscriber / SpeechTranscriber are unavailable.
//
// Live partial transcription is NOT supported — callers receive nil from
// transcribePartialCurrentBuffer when this engine is selected.
final class CloudTranscriptionEngine: FinalTranscriptionEngine {
    let engineID = "cloudAPI"

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        guard !request.audio.isEmpty else { throw TranscriptionEngineError.emptyAudio }

        guard let apiKey = CloudAPIConfiguration.activeAPIKey, !apiKey.isEmpty else {
            throw TranscriptionEngineError.engineUnavailable
        }

        let maxSamples = Int(request.sampleRate * CloudAPIConfiguration.maxAudioDurationSeconds)
        let trimmedAudio = request.audio.count > maxSamples
            ? Array(request.audio.suffix(maxSamples))
            : request.audio
        let audioData = try encodeToWAV(audio: trimmedAudio, sampleRate: request.sampleRate)
        let locale = request.localeHint ?? Locale.current
        let audioDurationSeconds = Double(trimmedAudio.count) / request.sampleRate
        let scaledTimeout = CloudAPIConfiguration.defaultTimeout
            + audioDurationSeconds * CloudAPIConfiguration.timeoutPerAudioSecond
        let timeout = request.timeoutInterval ?? scaledTimeout

        let text: String
        switch CloudAPIConfiguration.provider {
        case .whisper:
            text = try await callWhisperAPI(audioData: audioData, locale: locale, apiKey: apiKey, timeout: timeout)
        case .claude:
            text = try await callClaudeAPI(audioData: audioData, locale: locale, apiKey: apiKey, timeout: timeout)
        case .gemini:
            text = try await callGeminiAPI(audioData: audioData, locale: locale, apiKey: apiKey, timeout: timeout)
        }

        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw TranscriptionEngineError.noFinalText }
        return TranscriptionResult(text: normalized, locale: locale)
    }

    // MARK: - WAV encoding

    private func encodeToWAV(audio: [Float], sampleRate: Double) throws -> Data {
        // Source buffer: Float32 (native format from AVAudioEngine)
        guard let srcFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw TranscriptionEngineError.emptyAudio }

        let frameCount = AVAudioFrameCount(audio.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            throw TranscriptionEngineError.emptyAudio
        }
        buffer.frameLength = frameCount
        buffer.floatChannelData?.pointee.update(from: audio, count: audio.count)

        // Write as Int16 PCM WAV — half the byte size of Float32, well within API limits.
        // AVAudioFile.processingFormat is always Float32 regardless of file bit depth,
        // so writing the Float32 buffer directly triggers the internal Float32→Int16 conversion.
        let int16Settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let file = try AVAudioFile(forWriting: tempURL, settings: int16Settings)
        try file.write(from: buffer)
        return try Data(contentsOf: tempURL)
    }

    // MARK: - Shared prompt

    private func transcriptionPrompt(for locale: Locale) -> String {
        let languageSuffix: String
        switch locale.language.languageCode?.identifier {
        case "en": languageSuffix = " in English"
        case "es": languageSuffix = " in Spanish"
        case "fr": languageSuffix = " in French"
        default:   languageSuffix = ""
        }
        return "Transcribe this audio exactly as spoken\(languageSuffix). Return only the transcribed text with no added commentary."
    }

    // MARK: - OpenAI Whisper API

    private func callWhisperAPI(
        audioData: Data,
        locale: Locale,
        apiKey: String,
        timeout: TimeInterval
    ) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

        let boundary = "stt\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()

        // model field
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(CloudAPIConfiguration.whisperModel)\r\n".data(using: .utf8)!)

        // language field — ISO 639-1 code (en, es, fr); omit for auto-detect
        if let langCode = whisperLanguageCode(for: locale) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n\(langCode)\r\n".data(using: .utf8)!)
        }

        // audio file field
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionEngineError.engineUnavailable
        }
        guard http.statusCode == 200 else {
            struct WhisperError: Decodable {
                struct Detail: Decodable { let message: String }
                let error: Detail
            }
            let detail = (try? JSONDecoder().decode(WhisperError.self, from: data))?.error.message
                ?? "HTTP \(http.statusCode)"
            throw TranscriptionEngineError.transcriptionFailed(
                underlying: NSError(
                    domain: "CloudTranscriptionEngine",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: detail]
                )
            )
        }

        struct WhisperResponse: Decodable { let text: String }
        let decoded = try JSONDecoder().decode(WhisperResponse.self, from: data)
        return decoded.text
    }

    private func whisperLanguageCode(for locale: Locale) -> String? {
        switch locale.language.languageCode?.identifier {
        case "en": return "en"
        case "es": return "es"
        case "fr": return "fr"
        default:   return nil  // nil = Whisper auto-detects language
        }
    }

    // MARK: - Claude Messages API

    private func callClaudeAPI(
        audioData: Data,
        locale: Locale,
        apiKey: String,
        timeout: TimeInterval
    ) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!

        let body = ClaudeRequest(
            model: CloudAPIConfiguration.claudeModel,
            maxTokens: CloudAPIConfiguration.claudeMaxTokens,
            messages: [
                ClaudeRequest.Message(role: "user", content: [
                    .document(audioData: audioData, mediaType: "audio/wav"),
                    .text(transcriptionPrompt(for: locale))
                ])
            ]
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionEngineError.engineUnavailable
        }
        guard http.statusCode == 200 else {
            let detail = (try? JSONDecoder().decode(ClaudeErrorEnvelope.self, from: data))?.error.message
                ?? "HTTP \(http.statusCode)"
            throw TranscriptionEngineError.transcriptionFailed(
                underlying: NSError(
                    domain: "CloudTranscriptionEngine",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: detail]
                )
            )
        }

        let decoded = try JSONDecoder().decode(ClaudeResponse.self, from: data)
        guard let text = decoded.content.first(where: { $0.type == "text" })?.text else {
            throw TranscriptionEngineError.noFinalText
        }
        return text
    }

    // MARK: - Gemini Files API
    //
    // Three-step flow:
    //   1. Upload WAV → Gemini returns a file URI  (separate upload timeout, retried on transient errors)
    //   2. generateContent referencing the URI     (tiny JSON, no size limit issues)
    //   3. Delete uploaded file                    (fire-and-forget; Gemini auto-expires after 48h anyway)

    private func callGeminiAPI(
        audioData: Data,
        locale: Locale,
        apiKey: String,
        timeout: TimeInterval
    ) async throws -> String {
        let uploadTimeout = geminiUploadTimeout(for: audioData)
        let fileURI = try await uploadToGeminiFilesWithRetry(audioData: audioData, apiKey: apiKey, timeout: uploadTimeout)
        defer { Task { await deleteGeminiFile(uri: fileURI, apiKey: apiKey) } }
        return try await generateGeminiContent(fileURI: fileURI, locale: locale, apiKey: apiKey, timeout: timeout)
    }

    // Upload timeout scales with file size so large recordings don't time out mid-upload.
    private func geminiUploadTimeout(for audioData: Data) -> TimeInterval {
        let mb = Double(audioData.count) / 1_048_576
        return CloudAPIConfiguration.geminiUploadTimeoutBase
            + mb * CloudAPIConfiguration.geminiUploadTimeoutPerMB
    }

    // Retries upload on transient network errors (5xx, timeout) up to geminiUploadMaxRetries.
    private func uploadToGeminiFilesWithRetry(audioData: Data, apiKey: String, timeout: TimeInterval) async throws -> String {
        var lastError: Error = TranscriptionEngineError.engineUnavailable
        let maxAttempts = max(1, CloudAPIConfiguration.geminiUploadMaxRetries + 1)
        for attempt in 1...maxAttempts {
            do {
                return try await uploadToGeminiFiles(audioData: audioData, apiKey: apiKey, timeout: timeout)
            } catch {
                lastError = error
                let retryable = isRetryableGeminiUploadError(error)
                guard retryable, attempt < maxAttempts else { break }
                // Brief back-off before retry (0.5s, 1.0s, …)
                try? await Task.sleep(nanoseconds: UInt64(500_000_000 * attempt))
            }
        }
        throw lastError
    }

    private func isRetryableGeminiUploadError(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        let nsError = error as NSError
        // Retry on network-layer errors and 5xx server errors
        if nsError.domain == NSURLErrorDomain { return true }
        if nsError.code >= 500 && nsError.code < 600 { return true }
        return false
    }

    private func uploadToGeminiFiles(audioData: Data, apiKey: String, timeout: TimeInterval) async throws -> String {
        let url = URL(string: "https://generativelanguage.googleapis.com/upload/v1beta/files?key=\(apiKey)")!

        let boundary = "sttboundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()
        body.append("--\(boundary)\r\nContent-Type: application/json; charset=utf-8\r\n\r\n".data(using: .utf8)!)
        body.append("{\"file\":{\"mimeType\":\"audio/wav\"}}".data(using: .utf8)!)
        body.append("\r\n--\(boundary)\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("multipart", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        req.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw TranscriptionEngineError.engineUnavailable }
        guard http.statusCode == 200 else {
            let msg = (try? JSONDecoder().decode(GeminiErrorEnvelope.self, from: data))?.error.message ?? "Upload HTTP \(http.statusCode)"
            throw NSError(domain: "CloudTranscriptionEngine", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let file = json["file"] as? [String: Any],
              let uri = file["uri"] as? String, !uri.isEmpty else {
            throw TranscriptionEngineError.engineUnavailable
        }
        return uri
    }

    private func generateGeminiContent(fileURI: String, locale: Locale, apiKey: String, timeout: TimeInterval) async throws -> String {
        let model = CloudAPIConfiguration.geminiModel
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!

        let body: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": [
                    ["fileData": ["mimeType": "audio/wav", "fileUri": fileURI]],
                    ["text": transcriptionPrompt(for: locale)]
                ]
            ]]
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw TranscriptionEngineError.engineUnavailable }
        guard http.statusCode == 200 else {
            let msg = (try? JSONDecoder().decode(GeminiErrorEnvelope.self, from: data))?.error.message ?? "HTTP \(http.statusCode)"
            throw TranscriptionEngineError.transcriptionFailed(
                underlying: NSError(domain: "CloudTranscriptionEngine", code: http.statusCode,
                                    userInfo: [NSLocalizedDescriptionKey: msg])
            )
        }

        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        guard let text = decoded.candidates.first?.content.parts.first(where: { $0.text != nil })?.text else {
            throw TranscriptionEngineError.noFinalText
        }
        return text
    }

    // Best-effort cleanup — Gemini auto-expires uploaded files after 48h if this fails.
    private func deleteGeminiFile(uri: String, apiKey: String) async {
        guard let name = uri.components(separatedBy: "/v1beta/").last,
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(name)?key=\(apiKey)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.timeoutInterval = 10
        _ = try? await URLSession.shared.data(for: req)
    }
}

// MARK: - Claude request / response models

private struct ClaudeRequest: Encodable {
    let model: String
    let maxTokens: Int
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model, messages
        case maxTokens = "max_tokens"
    }

    struct Message: Encodable {
        let role: String
        let content: [ContentBlock]
    }

    enum ContentBlock: Encodable {
        case document(audioData: Data, mediaType: String)
        case text(String)

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .document(audioData, mediaType):
                try c.encode("document", forKey: .type)
                try c.encode(
                    Source(type: "base64", mediaType: mediaType, data: audioData.base64EncodedString()),
                    forKey: .source
                )
            case let .text(value):
                try c.encode("text", forKey: .type)
                try c.encode(value, forKey: .text)
            }
        }

        enum CodingKeys: String, CodingKey { case type, source, text }

        struct Source: Encodable {
            let type: String
            let mediaType: String
            let data: String
            enum CodingKeys: String, CodingKey {
                case type, data
                case mediaType = "media_type"
            }
        }
    }
}

private struct ClaudeResponse: Decodable {
    let content: [Block]
    struct Block: Decodable {
        let type: String
        let text: String?
    }
}

private struct ClaudeErrorEnvelope: Decodable {
    let error: APIError
    struct APIError: Decodable { let message: String }
}

// MARK: - Gemini response models

private struct GeminiResponse: Decodable {
    let candidates: [Candidate]
    struct Candidate: Decodable {
        let content: Content
        struct Content: Decodable {
            let parts: [Part]
            struct Part: Decodable { let text: String? }
        }
    }
}

private struct GeminiErrorEnvelope: Decodable {
    let error: APIError
    struct APIError: Decodable { let message: String }
}
