import Foundation
import AVFoundation

// MARK: - Engine

// Cloud-based transcription engine. Records audio, encodes it to WAV,
// and forwards it to the configured cloud provider (Whisper or Gemini).
//
// iOS < 26: primary engine (the only path available).
// iOS 26+: fallback when DictationTranscriber / SpeechTranscriber are unavailable.
//
// Live partial transcription is NOT supported — callers receive nil from
// transcribePartialCurrentBuffer when this engine is selected.
// Returns a user-friendly error if the device is offline, otherwise returns nil.
private func offlineError(from error: Error) -> TranscriptionEngineError? {
    let nsError = error as NSError
    guard nsError.domain == NSURLErrorDomain else { return nil }
    let offlineCodes: Set<Int> = [
        NSURLErrorNotConnectedToInternet,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorCannotConnectToHost,
        NSURLErrorCannotFindHost
    ]
    if offlineCodes.contains(nsError.code) {
        return .transcriptionFailed(
            underlying: NSError(
                domain: "CloudTranscriptionEngine",
                code: nsError.code,
                userInfo: [NSLocalizedDescriptionKey: "No internet connection. Check your network and try again."]
            )
        )
    }
    let tlsCodes: Set<Int> = [
        NSURLErrorSecureConnectionFailed,
        NSURLErrorServerCertificateHasBadDate,
        NSURLErrorServerCertificateUntrusted,
        NSURLErrorServerCertificateHasUnknownRoot,
        NSURLErrorServerCertificateNotYetValid,
        NSURLErrorClientCertificateRejected
    ]
    if tlsCodes.contains(nsError.code) {
        return .transcriptionFailed(
            underlying: NSError(
                domain: "CloudTranscriptionEngine",
                code: nsError.code,
                userInfo: [NSLocalizedDescriptionKey: "Secure connection failed. Check your device date/time, VPN, or network settings and try again."]
            )
        )
    }
    return nil
}

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
        let locale = request.localeHint ?? Locale.current
        let audioDurationSeconds = Double(trimmedAudio.count) / request.sampleRate
        let scaledTimeout = CloudAPIConfiguration.defaultTimeout
            + audioDurationSeconds * CloudAPIConfiguration.timeoutPerAudioSecond
        let timeout = request.timeoutInterval ?? scaledTimeout

        let text: String
        do {
            switch CloudAPIConfiguration.provider {
            case .openAI:
                text = try await transcribeOpenAIAudio(
                    fullAudio: request.audio,
                    sampleRate: request.sampleRate,
                    locale: locale,
                    apiKey: apiKey,
                    timeoutOverride: request.timeoutInterval
                )
            case .gemini:
                let audioData = try encodeToWAV(audio: trimmedAudio, sampleRate: request.sampleRate)
                text = try await callGeminiAPI(audioData: audioData, locale: locale, apiKey: apiKey, timeout: timeout)
            }
        } catch {
            throw offlineError(from: error) ?? error
        }

        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw TranscriptionEngineError.noFinalText }
        return TranscriptionResult(text: normalized, locale: locale)
    }

    // OpenAI path:
    // - short audio: one upload
    // - long audio: split into sequential chunks and merge transcripts
    private func transcribeOpenAIAudio(
        fullAudio: [Float],
        sampleRate: Double,
        locale: Locale,
        apiKey: String,
        timeoutOverride: TimeInterval?
    ) async throws -> String {
        let maxSamples = max(1, Int(sampleRate * CloudAPIConfiguration.maxAudioDurationSeconds))
        guard fullAudio.count > maxSamples else {
            let audioData = try encodeToWAV(audio: fullAudio, sampleRate: sampleRate)
            let durationSeconds = Double(fullAudio.count) / sampleRate
            let timeout = timeoutOverride ?? (
                CloudAPIConfiguration.defaultTimeout
                + durationSeconds * CloudAPIConfiguration.timeoutPerAudioSecond
            )
            return try await callWhisperAPI(audioData: audioData, locale: locale, apiKey: apiKey, timeout: timeout)
        }

        var parts: [String] = []
        parts.reserveCapacity((fullAudio.count / maxSamples) + 1)

        var start = 0
        while start < fullAudio.count {
            try Task.checkCancellation()
            let end = min(start + maxSamples, fullAudio.count)
            let chunk = Array(fullAudio[start..<end])
            let chunkData = try encodeToWAV(audio: chunk, sampleRate: sampleRate)
            let durationSeconds = Double(chunk.count) / sampleRate
            let timeout = timeoutOverride ?? (
                CloudAPIConfiguration.defaultTimeout
                + durationSeconds * CloudAPIConfiguration.timeoutPerAudioSecond
            )
            let chunkText = try await callWhisperAPI(audioData: chunkData, locale: locale, apiKey: apiKey, timeout: timeout)
            let cleaned = chunkText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                parts.append(cleaned)
            }
            start = end
        }

        return parts.joined(separator: "\n")
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
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(CloudAPIConfiguration.openAIModel)\r\n".data(using: .utf8)!)

        // language field — ISO 639-1 code (en, es, fr); omit for auto-detect
        if let langCode = openAILanguageCode(for: locale) {
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

        struct OpenAITranscriptionResponse: Decodable { let text: String }
        let decoded = try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: data)
        return decoded.text
    }

    private func openAILanguageCode(for locale: Locale) -> String? {
        switch locale.language.languageCode?.identifier {
        case "en": return "en"
        case "es": return "es"
        case "fr": return "fr"
        default:   return nil  // nil = OpenAI auto-detects language
        }
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
        if nsError.domain == NSURLErrorDomain {
            let nonRetryableCodes: Set<Int> = [
                NSURLErrorNotConnectedToInternet,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorCannotConnectToHost,
                NSURLErrorCannotFindHost,
                NSURLErrorSecureConnectionFailed,
                NSURLErrorServerCertificateHasBadDate,
                NSURLErrorServerCertificateUntrusted,
                NSURLErrorServerCertificateHasUnknownRoot,
                NSURLErrorServerCertificateNotYetValid,
                NSURLErrorClientCertificateRejected
            ]
            if nonRetryableCodes.contains(nsError.code) { return false }
            return true
        }
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
