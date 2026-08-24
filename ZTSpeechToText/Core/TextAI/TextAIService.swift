import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum TextAIOperation: String, Sendable {
    case cleanup
    case summarize
    case structuredExtraction
}

enum TextAISummaryStyle: String, CaseIterable, Sendable {
    case short
    case standard
    case detailed

    nonisolated var displayName: String {
        switch self {
        case .short: return "Short"
        case .standard: return "Standard"
        case .detailed: return "Detailed"
        }
    }
}

struct TextAIRequest: Sendable {
    let operation: TextAIOperation
    let text: String
    let preferredLanguage: SupportedLanguage
    let summaryStyle: TextAISummaryStyle?
}

enum TextAIProviderID: String, Sendable {
    case appleFoundationModels
    case cloudAPI

    nonisolated var displayName: String {
        switch self {
        case .appleFoundationModels: return "Apple Foundation Models"
        case .cloudAPI: return "Cloud API"
        }
    }

    @MainActor
    var resolvedDisplayName: String {
        switch self {
        case .appleFoundationModels: return "Apple Foundation Models"
        case .cloudAPI:
            switch CloudAPIConfiguration.provider {
            case .gemini: return "Gemini"
            case .whisper: return "Cloud API"
            }
        }
    }
}

struct TextAIExecutionResult: Sendable {
    let provider: TextAIProviderID
    let outputText: String
}

enum TextAIError: LocalizedError, Sendable {
    case emptyInput
    case providerUnavailable(reason: String)
    case modelUnavailable(reason: String)
    case modelLoadingFailed(reason: String)
    case inferenceFailed(reason: String)
    case unsupportedOperation
    case unsupportedLanguage
    case cancelled

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Please enter text before running AI processing."
        case let .providerUnavailable(reason):
            return "Provider unavailable: \(reason)"
        case let .modelUnavailable(reason):
            return "Model unavailable: \(reason)"
        case let .modelLoadingFailed(reason):
            return "Model loading failed: \(reason)"
        case let .inferenceFailed(reason):
            return "Inference failed: \(reason)"
        case .unsupportedOperation:
            return "Unsupported operation."
        case .unsupportedLanguage:
            return "Unsupported language for this model."
        case .cancelled:
            return "The operation was cancelled."
        }
    }
}

protocol TextModelProvider: Sendable {
    nonisolated var id: TextAIProviderID { get }
    func process(_ request: TextAIRequest) async throws -> String
}

actor TextAIProviderResolver {
    struct Resolution: Sendable {
        let provider: any TextModelProvider
        let fallbackReason: String?
    }

    func resolveProvider(for request: TextAIRequest) async -> Resolution {
        if #available(iOS 26.0, *) {
            #if canImport(FoundationModels)
            let appleProvider = await MainActor.run { AppleFoundationModelProvider() }
            let appleAvailability = await appleProvider.capability(for: request.preferredLanguage)
            if case .available = appleAvailability {
                TextAILogger.log("provider=appleFoundationModels")
                return Resolution(provider: appleProvider, fallbackReason: nil)
            }
            TextAILogger.log("providerAvailability=\(appleAvailability.logValue)")
            #endif
        }

        // Cloud API fallback (not Whisper — audio only)
        TextAILogger.log("provider=cloudAPI")
        TextAILogger.log("fallbackReason=appleNotAvailable")
        return await Resolution(provider: CloudTextProvider(), fallbackReason: "appleNotAvailable")
    }

    func cloudFallbackProvider(reason: String) async -> any TextModelProvider {
        TextAILogger.log("provider=cloudAPI")
        TextAILogger.log("fallbackReason=\(reason)")
        return await CloudTextProvider()
    }

    func preferredProviderDisplayName(for language: SupportedLanguage) async -> String {
        let request = TextAIRequest(operation: .cleanup, text: "ping", preferredLanguage: language, summaryStyle: nil)
        let resolution = await resolveProvider(for: request)
        return await MainActor.run { resolution.provider.id.resolvedDisplayName }
    }
}

actor TextAIService {
    private let resolver: TextAIProviderResolver

    init(resolver: TextAIProviderResolver = TextAIProviderResolver()) {
        self.resolver = resolver
    }

    func cleanup(text: String, preferredLanguage: SupportedLanguage) async throws -> TextAIExecutionResult {
        let request = TextAIRequest(
            operation: .cleanup,
            text: text,
            preferredLanguage: preferredLanguage,
            summaryStyle: nil
        )
        return try await process(request)
    }

    func summarize(
        text: String,
        preferredLanguage: SupportedLanguage,
        style: TextAISummaryStyle
    ) async throws -> TextAIExecutionResult {
        let request = TextAIRequest(
            operation: .summarize,
            text: text,
            preferredLanguage: preferredLanguage,
            summaryStyle: style
        )
        return try await process(request)
    }

    func structuredExtract(text: String, preferredLanguage: SupportedLanguage) async throws -> TextAIExecutionResult {
        let request = TextAIRequest(
            operation: .structuredExtraction,
            text: text,
            preferredLanguage: preferredLanguage,
            summaryStyle: nil
        )
        return try await process(request)
    }

    func preferredProviderDisplayName(for language: SupportedLanguage) async -> String {
        await resolver.preferredProviderDisplayName(for: language)
    }

    private func process(_ request: TextAIRequest) async throws -> TextAIExecutionResult {
        try Task.checkCancellation()

        let trimmed = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TextAIError.emptyInput
        }

        TextAILogger.log("operation=\(request.operation.rawValue)")
        TextAILogger.log("preferredLanguage=\(request.preferredLanguage.rawValue)")

        let normalizedRequest = TextAIRequest(
            operation: request.operation,
            text: trimmed,
            preferredLanguage: request.preferredLanguage,
            summaryStyle: request.summaryStyle
        )

        let resolution = await resolver.resolveProvider(for: normalizedRequest)

        do {
            let output = try await resolution.provider.process(normalizedRequest)
            return TextAIExecutionResult(provider: resolution.provider.id, outputText: output)
        } catch {
            if resolution.provider.id == .appleFoundationModels {
                // Apple failed → cloud API
                let cloud = await resolver.cloudFallbackProvider(reason: "appleInferenceFailed")
                do {
                    let output = try await cloud.process(normalizedRequest)
                    return TextAIExecutionResult(provider: cloud.id, outputText: output)
                } catch {
                    throw mapProviderError(error)
                }
            }
            throw mapProviderError(error)
        }
    }

    private func mapProviderError(_ error: Error) -> TextAIError {
        if error is CancellationError {
            return .cancelled
        }
        if let textAIError = error as? TextAIError {
            return textAIError
        }

        let nsError = error as NSError
        return .inferenceFailed(reason: nsError.localizedDescription)
    }
}

private func offlineTextError(from error: Error) -> TextAIError? {
    let nsError = error as NSError
    guard nsError.domain == NSURLErrorDomain else { return nil }
    let offlineCodes: Set<Int> = [
        NSURLErrorNotConnectedToInternet,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorCannotConnectToHost,
        NSURLErrorCannotFindHost
    ]
    guard offlineCodes.contains(nsError.code) else { return nil }
    return .providerUnavailable(reason: "No internet connection. Check your network and try again.")
}

actor CloudTextProvider: TextModelProvider {
    nonisolated let id: TextAIProviderID = .cloudAPI

    func process(_ request: TextAIRequest) async throws -> String {
        try Task.checkCancellation()
        let (provider, apiKey): (CloudAPIConfiguration.Provider, String?) = await MainActor.run {
            (CloudAPIConfiguration.provider, CloudAPIConfiguration.activeAPIKey)
        }
        guard let apiKey, !apiKey.isEmpty else {
            throw TextAIError.providerUnavailable(reason: "No cloud API key configured")
        }
        let prompt = buildPrompt(for: request)
        do {
            switch provider {
            case .whisper:
                throw TextAIError.unsupportedOperation
            case .gemini:
                let model: String = await MainActor.run { CloudAPIConfiguration.geminiModel }
                return try await callGemini(prompt: prompt, apiKey: apiKey, model: model)
            }
        } catch {
            throw offlineTextError(from: error) ?? error
        }
    }

    private func buildPrompt(for request: TextAIRequest) -> String {
        let language = request.preferredLanguage.responseLanguageInstruction
        switch request.operation {
        case .cleanup:
            return """
            Clean up this speech-to-text transcript. Respond in \(language).
            Fix grammar, spelling, punctuation, and obvious errors. Keep the original meaning and language. Return only the corrected text, no explanation.

            Transcript:
            \(request.text)
            """
        case .summarize:
            let style: String
            switch request.summaryStyle ?? .standard {
            case .short:    style = "Write a summary in 1 to 2 sentences."
            case .standard: style = "Write a summary in 3 to 5 sentences."
            case .detailed: style = "Write a summary in 6 to 10 sentences."
            }
            return """
            Summarize this transcript. Respond in \(language). \(style) Return only the summary, no explanation.

            Transcript:
            \(request.text)
            """
        case .structuredExtraction:
            return """
            Extract structured information from this OCR text. Respond in \(language).
            Document can be invoice, estimate, bill, receipt, contact card, business card, fire inspection report, HVAC/electrical/plumbing inspection note, or other.
            Return valid JSON only with this exact shape:
            {
              "documentType": "",
              "keyFacts": [""],
              "entities": [{"name": "", "type": "", "value": ""}],
              "inspectionContext": {
                "domain": "",
                "inspectionType": "",
                "inspectionId": "",
                "workOrderNumber": "",
                "permitNumber": "",
                "jurisdiction": "",
                "status": "",
                "priority": ""
              },
              "site": {
                "siteName": "",
                "buildingName": "",
                "area": "",
                "floor": "",
                "unit": "",
                "room": "",
                "address": {
                  "street1": "",
                  "street2": "",
                  "city": "",
                  "state": "",
                  "postalCode": "",
                  "country": "",
                  "full": ""
                }
              },
              "dates": [{"label": "", "value": "", "normalized": ""}],
              "amounts": [{"label": "", "value": "", "currency": "", "normalized": ""}],
              "contactInfo": {
                "phones": [{"label": "", "countryCode": "", "number": "", "extension": "", "raw": ""}],
                "emails": [{"label": "", "value": ""}],
                "websites": [{"label": "", "value": ""}],
                "addresses": [{"label": "", "street1": "", "street2": "", "city": "", "state": "", "postalCode": "", "country": "", "full": ""}]
              },
              "parties": [{"role": "", "name": "", "taxId": "", "registrationId": ""}],
              "equipment": [{"system": "", "component": "", "assetTag": "", "serialNumber": "", "location": "", "condition": "", "status": ""}],
              "checklistItems": [{"system": "", "category": "", "item": "", "result": "", "measuredValue": "", "unit": "", "codeReference": "", "notes": ""}],
              "deficiencies": [{"id": "", "system": "", "severity": "", "description": "", "location": "", "recommendedAction": "", "codeReference": "", "dueDate": "", "photoRefs": [""]}],
              "compliance": {"passed": "", "score": "", "authorityHavingJurisdiction": "", "codes": [""]},
              "lineItems": [{"description": "", "quantity": "", "unitPrice": "", "amount": ""}],
              "totals": {"subtotal": "", "tax": "", "discount": "", "shipping": "", "grandTotal": "", "balanceDue": ""},
              "payment": {"method": "", "terms": "", "dueDate": "", "accountNumber": "", "iban": "", "swift": ""},
              "nextActions": [""],
              "summary": ""
            }
            Rules:
            - Keep facts exactly from OCR; do not invent values.
            - Use empty strings/empty arrays when data is missing.
            - Keep phone countryCode separate from number when possible.
            - Parse addresses into components and also provide full.
            - For trade systems use values like fire, hvac, electrical, plumbing when identifiable.
            - Do not add markdown fences or commentary.

            OCR Text:
            \(request.text)
            """
        }
    }

    private func callGemini(prompt: String, apiKey: String, model: String) async throws -> String {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!
        let body: [String: Any] = ["contents": [["role": "user", "parts": [["text": prompt]]]]]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"; req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TextAIError.inferenceFailed(reason: "Gemini HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        struct Resp: Decodable {
            let candidates: [Cand]
            struct Cand: Decodable { let content: Cont; struct Cont: Decodable { let parts: [Part]; struct Part: Decodable { let text: String? } } }
        }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        guard let text = decoded.candidates.first?.content.parts.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { throw TextAIError.inferenceFailed(reason: "Empty response") }
        return text
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
private enum AppleProviderCapability: Sendable {
    case available
    case unavailable(reason: String)

    nonisolated var logValue: String {
        switch self {
        case .available:
            return "available"
        case let .unavailable(reason):
            return "unavailable_\(reason)"
        }
    }
}

@available(iOS 26.0, *)
actor AppleFoundationModelProvider: TextModelProvider {
    nonisolated let id: TextAIProviderID = .appleFoundationModels
    private let model = SystemLanguageModel.default

    fileprivate func capability(for language: SupportedLanguage) -> AppleProviderCapability {
        if !model.isAvailable {
            return .unavailable(reason: "modelNotAvailable")
        }

        switch model.availability {
        case .available:
            break
        case let .unavailable(reason):
            return .unavailable(reason: "availability_\(String(describing: reason))")
        }

        let locale = Locale(identifier: language.localeIdentifier)
        guard model.supportsLocale(locale) else {
            return .unavailable(reason: "unsupportedLocale")
        }

        return .available
    }

    func process(_ request: TextAIRequest) async throws -> String {
        try Task.checkCancellation()

        let capabilityResult = capability(for: request.preferredLanguage)
        guard case .available = capabilityResult else {
            throw TextAIError.modelUnavailable(reason: capabilityResult.logValue)
        }

        let instructions = baseInstructions(for: request)
        let prompt = promptText(for: request)
        TextAILogger.logPayload("appleModel input", text: request.text)
        TextAILogger.logPayload("appleModel prompt", text: prompt)

        do {
            let session = LanguageModelSession(model: model, instructions: instructions)
            let response = try await session.respond(to: prompt)
            let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                throw TextAIError.inferenceFailed(reason: "emptyResponse")
            }
            TextAILogger.logPayload("appleModel output", text: content)
            return content
        } catch is CancellationError {
            throw TextAIError.cancelled
        } catch let generationError as LanguageModelSession.GenerationError {
            switch generationError {
            case .unsupportedLanguageOrLocale:
                throw TextAIError.unsupportedLanguage
            default:
                throw TextAIError.inferenceFailed(reason: String(describing: generationError))
            }
        } catch {
            throw TextAIError.inferenceFailed(reason: error.localizedDescription)
        }
    }

    private func baseInstructions(for request: TextAIRequest) -> String {
        switch request.operation {
        case .cleanup:
            return """
            You improve text quality while preserving meaning.
            You MUST respond in \(request.preferredLanguage.responseLanguageInstruction).
            Keep the original language and never translate.
            Fix grammar, spelling, punctuation, and sentence flow.
            Preserve names, numbers, dates, URLs, technical terms, and facts.
            Do not add new facts.
            Return only the improved text.
            """
        case .summarize:
            let styleInstruction: String
            switch request.summaryStyle ?? .standard {
            case .short:
                styleInstruction = "Write a short summary in 1 to 2 sentences."
            case .standard:
                styleInstruction = "Write a concise summary in 3 to 5 sentences."
            case .detailed:
                styleInstruction = "Write a detailed summary in 6 to 10 sentences."
            }

            return """
            You summarize text while preserving the source facts.
            You MUST respond in \(request.preferredLanguage.responseLanguageInstruction).
            Keep the original language and never translate.
            Do not invent facts.
            \(styleInstruction)
            Return only the summary.
            """
        case .structuredExtraction:
            return """
            You extract structured information from OCR text.
            You MUST respond in \(request.preferredLanguage.responseLanguageInstruction).
            Document can be invoice, estimate, bill, receipt, contact card, business card, fire inspection report, HVAC/electrical/plumbing inspection note, or other.
            Keep source facts exactly; do not invent values.
            Return valid JSON only, no markdown.
            Use this exact shape:
            {
              "documentType": "",
              "keyFacts": [""],
              "entities": [{"name": "", "type": "", "value": ""}],
              "inspectionContext": {
                "domain": "",
                "inspectionType": "",
                "inspectionId": "",
                "workOrderNumber": "",
                "permitNumber": "",
                "jurisdiction": "",
                "status": "",
                "priority": ""
              },
              "site": {
                "siteName": "",
                "buildingName": "",
                "area": "",
                "floor": "",
                "unit": "",
                "room": "",
                "address": {
                  "street1": "",
                  "street2": "",
                  "city": "",
                  "state": "",
                  "postalCode": "",
                  "country": "",
                  "full": ""
                }
              },
              "dates": [{"label": "", "value": "", "normalized": ""}],
              "amounts": [{"label": "", "value": "", "currency": "", "normalized": ""}],
              "contactInfo": {
                "phones": [{"label": "", "countryCode": "", "number": "", "extension": "", "raw": ""}],
                "emails": [{"label": "", "value": ""}],
                "websites": [{"label": "", "value": ""}],
                "addresses": [{"label": "", "street1": "", "street2": "", "city": "", "state": "", "postalCode": "", "country": "", "full": ""}]
              },
              "parties": [{"role": "", "name": "", "taxId": "", "registrationId": ""}],
              "equipment": [{"system": "", "component": "", "assetTag": "", "serialNumber": "", "location": "", "condition": "", "status": ""}],
              "checklistItems": [{"system": "", "category": "", "item": "", "result": "", "measuredValue": "", "unit": "", "codeReference": "", "notes": ""}],
              "deficiencies": [{"id": "", "system": "", "severity": "", "description": "", "location": "", "recommendedAction": "", "codeReference": "", "dueDate": "", "photoRefs": [""]}],
              "compliance": {"passed": "", "score": "", "authorityHavingJurisdiction": "", "codes": [""]},
              "lineItems": [{"description": "", "quantity": "", "unitPrice": "", "amount": ""}],
              "totals": {"subtotal": "", "tax": "", "discount": "", "shipping": "", "grandTotal": "", "balanceDue": ""},
              "payment": {"method": "", "terms": "", "dueDate": "", "accountNumber": "", "iban": "", "swift": ""},
              "nextActions": [""],
              "summary": ""
            }
            Rules:
            - Use empty arrays/empty strings when missing.
            - Keep phone countryCode separate from number when possible.
            - Parse addresses into components and also provide full.
            - For trade systems use values like fire, hvac, electrical, plumbing when identifiable.
            """
        }
    }

    private func promptText(for request: TextAIRequest) -> String {
        switch request.operation {
        case .cleanup:
            return "Improve this text:\n\n\(request.text)"
        case .summarize:
            return "Summarize this text:\n\n\(request.text)"
        case .structuredExtraction:
            return "Extract structured data from this OCR text:\n\n\(request.text)"
        }
    }

}
#endif

private enum TextAILogger {
    nonisolated static func log(_ message: String) {
        #if DEBUG
        print("[TEXT_AI] \(message)")
        #endif
    }

    nonisolated static func logPayload(_ label: String, text: String, maxChars: Int = 400) {
        #if DEBUG
        let normalized = text.replacingOccurrences(of: "\n", with: "\\n")
        let clipped: String
        if normalized.count > maxChars {
            let index = normalized.index(normalized.startIndex, offsetBy: maxChars)
            clipped = String(normalized[..<index]) + "…"
        } else {
            clipped = normalized
        }
        print("[TEXT_AI] \(label)=\(clipped)")
        #endif
    }
}
