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

enum StructuredDocumentType: String, CaseIterable, Identifiable, Sendable {
    case invoice
    case estimate
    case bill
    case receipt
    case contactCard
    case businessCard
    case fireEquipmentManualSticker
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .invoice: return "Invoice"
        case .estimate: return "Estimate"
        case .bill: return "Bill"
        case .receipt: return "Receipt"
        case .contactCard: return "Contact Card"
        case .businessCard: return "Business Card"
        case .fireEquipmentManualSticker: return "Fire Equipment Manual Sticker"
        case .other: return "Other"
        }
    }

    var extractionHint: String {
        switch self {
        case .invoice, .estimate, .bill, .receipt:
            return "Prioritize parties, billing/shipping addresses, line items, totals, currency, taxes, payment terms, and due dates."
        case .contactCard, .businessCard:
            return "Prioritize person name, title, organization, phone numbers, emails, websites, and full postal address fields."
        case .fireEquipmentManualSticker:
            return "Prioritize equipment identity, system/component, serial/asset tags, compliance/code references, inspection status, and next actions."
        case .other:
            return "Use broad extraction across entities, dates, amounts, contacts, addresses, equipment, checklist items, deficiencies, and summary."
        }
    }
}

struct TextAIRequest: Sendable {
    let operation: TextAIOperation
    let text: String
    let preferredLanguage: SupportedLanguage
    let summaryStyle: TextAISummaryStyle?
    let documentType: StructuredDocumentType?
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
            case .openAI: return "OpenAI"
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
    case missingDocumentType
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
        case .missingDocumentType:
            return "Please select a document type before running structured extraction."
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
        let request = TextAIRequest(
            operation: .cleanup,
            text: "ping",
            preferredLanguage: language,
            summaryStyle: nil,
            documentType: nil
        )
        let resolution = await resolveProvider(for: request)
        return await MainActor.run { resolution.provider.id.resolvedDisplayName }
    }
}

actor TextAIService {
    private let resolver: TextAIProviderResolver
    private let appleProviderTimeoutSeconds: Double = 20

    init(resolver: TextAIProviderResolver = TextAIProviderResolver()) {
        self.resolver = resolver
    }

    func cleanup(text: String, preferredLanguage: SupportedLanguage) async throws -> TextAIExecutionResult {
        let request = TextAIRequest(
            operation: .cleanup,
            text: text,
            preferredLanguage: preferredLanguage,
            summaryStyle: nil,
            documentType: nil
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
            summaryStyle: style,
            documentType: nil
        )
        return try await process(request)
    }

    func structuredExtract(
        text: String,
        preferredLanguage: SupportedLanguage,
        documentType: StructuredDocumentType
    ) async throws -> TextAIExecutionResult {
        let request = TextAIRequest(
            operation: .structuredExtraction,
            text: text,
            preferredLanguage: preferredLanguage,
            summaryStyle: nil,
            documentType: documentType
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
        if request.operation == .structuredExtraction, request.documentType == nil {
            throw TextAIError.missingDocumentType
        }

        TextAILogger.log("operation=\(request.operation.rawValue)")
        TextAILogger.log("preferredLanguage=\(request.preferredLanguage.rawValue)")
        if let documentType = request.documentType {
            TextAILogger.log("documentType=\(documentType.rawValue)")
        }

        let normalizedRequest = TextAIRequest(
            operation: request.operation,
            text: trimmed,
            preferredLanguage: request.preferredLanguage,
            summaryStyle: request.summaryStyle,
            documentType: request.documentType
        )

        let resolution = await resolver.resolveProvider(for: normalizedRequest)

        do {
            let output: String
            if resolution.provider.id == .appleFoundationModels {
                output = try await withTimeout(seconds: appleProviderTimeoutSeconds) {
                    try await resolution.provider.process(normalizedRequest)
                }
            } else {
                output = try await resolution.provider.process(normalizedRequest)
            }
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

private func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            let nanos = UInt64(max(0, seconds) * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanos)
            throw TextAIError.inferenceFailed(reason: "Apple model timed out")
        }

        let first = try await group.next()!
        group.cancelAll()
        return first
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

private func structuredExtractionFieldFocus(for documentType: StructuredDocumentType) -> String {
    switch documentType {
    case .invoice:
        return """
        - Billing document focus:
          documentType, parties (seller/buyer), site.address, dates (issue/due), lineItems, totals, payment terms, tax.
        """
    case .estimate:
        return """
        - Quote/estimate focus:
          documentType, parties, scope-related keyFacts, lineItems, totals, validity/due dates, nextActions.
        """
    case .bill:
        return """
        - Billing statement focus:
          documentType, account/workOrder identifiers, parties, dates, amounts, totals, balanceDue, payment info.
        """
    case .receipt:
        return """
        - Proof-of-payment focus:
          merchant party, purchase date/time, purchased items, subtotal/tax/grandTotal, payment method, transaction identifiers.
        """
    case .contactCard, .businessCard:
        return """
        - Contact identity focus:
          entities (person/org), role/title, contactInfo (phones/emails/websites), full and parsed postal addresses, keyFacts/tagline.
        """
    case .fireEquipmentManualSticker:
        return """
        - Fire equipment sticker/manual focus:
          equipment (system/component/serial/assetTag/location/condition/status),
          compliance codes, checklistItems, deficiencies, inspectionContext, nextActions, dates.
        """
    case .other:
        return """
        - General document focus:
          extract all identifiable entities, contacts, addresses, dates, amounts, line items, equipment/inspection details, and summary.
        """
    }
}

private func structuredExtractionSchemaTemplate(for documentType: StructuredDocumentType) -> String {
    switch documentType {
    case .invoice, .estimate, .bill, .receipt:
        return """
        {
          "documentType": "",
          "keyFacts": [""],
          "entities": [{"name": "", "type": "", "value": ""}],
          "parties": [{"role": "", "name": "", "taxId": "", "registrationId": ""}],
          "site": {"address": {"street1": "", "street2": "", "city": "", "state": "", "postalCode": "", "country": "", "full": ""}},
          "dates": [{"label": "", "value": "", "normalized": ""}],
          "amounts": [{"label": "", "value": "", "currency": "", "normalized": ""}],
          "lineItems": [{"description": "", "quantity": "", "unitPrice": "", "amount": ""}],
          "totals": {"subtotal": "", "tax": "", "discount": "", "shipping": "", "grandTotal": "", "balanceDue": ""},
          "payment": {"method": "", "terms": "", "dueDate": "", "accountNumber": "", "iban": "", "swift": ""},
          "summary": ""
        }
        """
    case .contactCard, .businessCard:
        return """
        {
          "documentType": "",
          "keyFacts": [""],
          "entities": [{"name": "", "type": "", "value": ""}],
          "contactInfo": {
            "phones": [{"label": "", "countryCode": "", "number": "", "extension": "", "raw": ""}],
            "emails": [{"label": "", "value": ""}],
            "websites": [{"label": "", "value": ""}],
            "addresses": [{"label": "", "street1": "", "street2": "", "city": "", "state": "", "postalCode": "", "country": "", "full": ""}]
          },
          "parties": [{"role": "", "name": "", "taxId": "", "registrationId": ""}],
          "summary": ""
        }
        """
    case .fireEquipmentManualSticker:
        return """
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
            "address": {"street1": "", "street2": "", "city": "", "state": "", "postalCode": "", "country": "", "full": ""}
          },
          "equipment": [{"system": "", "component": "", "assetTag": "", "serialNumber": "", "location": "", "condition": "", "status": ""}],
          "checklistItems": [{"system": "", "category": "", "item": "", "result": "", "measuredValue": "", "unit": "", "codeReference": "", "notes": ""}],
          "deficiencies": [{"id": "", "system": "", "severity": "", "description": "", "location": "", "recommendedAction": "", "codeReference": "", "dueDate": "", "photoRefs": [""]}],
          "compliance": {"passed": "", "score": "", "authorityHavingJurisdiction": "", "codes": [""]},
          "dates": [{"label": "", "value": "", "normalized": ""}],
          "nextActions": [""],
          "summary": ""
        }
        """
    case .other:
        return """
        {
          "documentType": "",
          "keyFacts": [""],
          "entities": [{"name": "", "type": "", "value": ""}],
          "contactInfo": {
            "phones": [{"raw": ""}],
            "emails": [{"value": ""}],
            "addresses": [{"full": ""}]
          },
          "dates": [{"label": "", "value": "", "normalized": ""}],
          "amounts": [{"label": "", "value": "", "currency": "", "normalized": ""}],
          "summary": ""
        }
        """
    }
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
            case .openAI:
                let model: String = await MainActor.run { CloudAPIConfiguration.openAITextModel }
                let baseTimeout: TimeInterval = await MainActor.run { CloudAPIConfiguration.openAITextTimeout }
                let baseRetries: Int = await MainActor.run { CloudAPIConfiguration.openAITextMaxRetries }
                let timeout: TimeInterval
                let maxRetries: Int
                if request.operation == .structuredExtraction {
                    // Structured extraction should feel responsive in UI.
                    timeout = min(baseTimeout, 25.0)
                    maxRetries = min(baseRetries, 1)
                } else {
                    timeout = baseTimeout
                    maxRetries = baseRetries
                }
                return try await callOpenAIWithRetry(
                    prompt: prompt,
                    apiKey: apiKey,
                    model: model,
                    operation: request.operation,
                    timeout: timeout,
                    maxRetries: maxRetries
                )
            case .gemini:
                let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmedKey.hasPrefix("AIza") else {
                    throw TextAIError.providerUnavailable(
                        reason: "Gemini requires an API key from Google AI Studio (usually starts with 'AIza'). OAuth/access tokens are not supported here."
                    )
                }
                let model: String = await MainActor.run { CloudAPIConfiguration.geminiModel }
                return try await callGemini(prompt: prompt, apiKey: trimmedKey, model: model)
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
            return structuredExtractionPrompt(
                request: request,
                responseLanguage: language
            )
        }
    }

    private func structuredExtractionPrompt(
        request: TextAIRequest,
        responseLanguage: String
    ) -> String {
        let documentType = request.documentType ?? .other
        let optimizedOCRText = optimizedStructuredInputText(
            request.text,
            documentType: documentType
        )
        return """
        Extract structured information from this OCR text. Respond in \(responseLanguage).
        Target document type: \(documentType.displayName).
        Document-specific extraction focus:
        \(structuredExtractionFieldFocus(for: documentType))
        Return valid JSON only with this exact shape:
        \(structuredExtractionSchemaTemplate(for: documentType))
        Rules:
        - Keep facts exactly from OCR; do not invent values.
        - Use empty strings/empty arrays when data is missing.
        - Keep phone countryCode separate from number when possible.
        - Parse addresses into components and also provide full.
        - For trade systems use values like fire, hvac, electrical, plumbing when identifiable.
        - Set `documentType` in output to the best matching subtype from OCR.
        - Do not add markdown fences or commentary.

        OCR Text:
        \(optimizedOCRText)
        """
    }

    private func callOpenAIWithRetry(
        prompt: String,
        apiKey: String,
        model: String,
        operation: TextAIOperation,
        timeout: TimeInterval,
        maxRetries: Int
    ) async throws -> String {
        var lastError: Error = TextAIError.inferenceFailed(reason: "OpenAI request failed")
        let maxAttempts = max(1, maxRetries + 1)

        for attempt in 1...maxAttempts {
            do {
                TextAILogger.log("openAI_attempt=\(attempt)/\(maxAttempts) operation=\(operation.rawValue)")
                return try await callOpenAI(
                    prompt: prompt,
                    apiKey: apiKey,
                    model: model,
                    operation: operation,
                    timeout: timeout
                )
            } catch {
                lastError = error
                let retryable = isRetryableOpenAIError(error)
                TextAILogger.log("openAI_attempt_failed=\(attempt) retryable=\(retryable) error=\(error.localizedDescription)")
                guard retryable, attempt < maxAttempts else { break }
                try? await Task.sleep(nanoseconds: UInt64(500_000_000 * attempt))
            }
        }

        throw lastError
    }

    private func callOpenAI(
        prompt: String,
        apiKey: String,
        model: String,
        operation: TextAIOperation,
        timeout: TimeInterval
    ) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var body: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "system",
                    "content": "You are a precise text transformation assistant. Follow instructions exactly and return only the requested output."
                ],
                [
                    "role": "user",
                    "content": prompt
                ]
            ]
        ]

        if operation == .structuredExtraction {
            body["response_format"] = ["type": "json_object"]
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.allowsConstrainedNetworkAccess = true
        req.allowsExpensiveNetworkAccess = true
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw TextAIError.inferenceFailed(reason: "Invalid OpenAI response")
        }

        guard http.statusCode == 200 else {
            throw mapOpenAIHTTPError(statusCode: http.statusCode, data: data)
        }

        struct Response: Decodable {
            let choices: [Choice]
            struct Choice: Decodable {
                let message: Message
                struct Message: Decodable {
                    let content: String?
                }
            }
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let text = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw TextAIError.inferenceFailed(reason: "Empty OpenAI response")
        }
        return text
    }

    private func isRetryableOpenAIError(_ error: Error) -> Bool {
        if error is CancellationError { return false }

        if let textAIError = error as? TextAIError {
            switch textAIError {
            case .providerUnavailable, .unsupportedOperation, .unsupportedLanguage, .emptyInput, .missingDocumentType, .cancelled:
                return false
            case .modelUnavailable, .modelLoadingFailed:
                return false
            case .inferenceFailed:
                break
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let retryableCodes: Set<Int> = [
                NSURLErrorTimedOut,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorCannotConnectToHost,
                NSURLErrorCannotFindHost,
                NSURLErrorDNSLookupFailed
            ]
            return retryableCodes.contains(nsError.code)
        }
        if nsError.code >= 500 && nsError.code < 600 { return true }
        return false
    }

    private func mapOpenAIHTTPError(statusCode: Int, data: Data) -> TextAIError {
        struct ErrorEnvelope: Decodable {
            let error: OpenAIErrorPayload
        }

        struct OpenAIErrorPayload: Decodable {
            let message: String?
            let code: String?
            let type: String?
        }

        let decoded = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
        let message = decoded?.error.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let code = decoded?.error.code?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let type = decoded?.error.type?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        TextAILogger.log("openAI_http_error status=\(statusCode) code=\(code) type=\(type) message=\(message)")

        if statusCode == 401 || code == "invalid_api_key" || type == "invalid_request_error" && message.localizedCaseInsensitiveContains("api key") {
            return .providerUnavailable(reason: "OpenAI authentication failed. Set a valid `CloudAPIConfiguration.openAIAPIKey`.")
        }

        if statusCode == 403 {
            return .providerUnavailable(reason: "OpenAI access denied (403). Check project, model access, and organization permissions.")
        }

        if statusCode == 429 {
            return .providerUnavailable(reason: "OpenAI rate limit reached (429). Retry shortly.")
        }

        if statusCode == 415 {
            return .inferenceFailed(reason: "OpenAI rejected request format (415). Verify model and payload format.")
        }

        if !message.isEmpty {
            return .inferenceFailed(reason: "OpenAI HTTP \(statusCode): \(message)")
        }

        return .inferenceFailed(reason: "OpenAI HTTP \(statusCode)")
    }

    private func callGemini(prompt: String, apiKey: String, model: String) async throws -> String {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!
        let body: [String: Any] = ["contents": [["role": "user", "parts": [["text": prompt]]]]]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw TextAIError.inferenceFailed(reason: "Invalid Gemini response")
        }

        guard http.statusCode == 200 else {
            throw mapGeminiHTTPError(statusCode: http.statusCode, data: data)
        }

        struct Resp: Decodable {
            let candidates: [Cand]
            struct Cand: Decodable {
                let content: Cont
                struct Cont: Decodable {
                    let parts: [Part]
                    struct Part: Decodable {
                        let text: String?
                    }
                }
            }
        }

        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        guard let text = decoded.candidates.first?.content.parts.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw TextAIError.inferenceFailed(reason: "Empty Gemini response")
        }
        return text
    }

    private func mapGeminiHTTPError(statusCode: Int, data: Data) -> TextAIError {
        struct ErrorEnvelope: Decodable {
            let error: GeminiErrorPayload
        }

        struct GeminiErrorPayload: Decodable {
            let message: String?
            let status: String?
            let details: [GeminiErrorDetail]?
        }

        struct GeminiErrorDetail: Decodable {
            let reason: String?
        }

        let decoded = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
        let message = decoded?.error.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let status = decoded?.error.status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reason = decoded?.error.details?.first?.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if statusCode == 401 || status == "UNAUTHENTICATED" || reason == "ACCESS_TOKEN_TYPE_UNSUPPORTED" {
            return .providerUnavailable(
                reason: "Gemini authentication failed. Set `CloudAPIConfiguration.geminiAPIKey` to a valid Google AI Studio API key (starts with 'AIza')."
            )
        }

        if statusCode == 403 {
            return .providerUnavailable(reason: "Gemini access denied (403). Check API key permissions and model access.")
        }

        if !message.isEmpty {
            return .inferenceFailed(reason: "Gemini HTTP \(statusCode): \(message)")
        }

        return .inferenceFailed(reason: "Gemini HTTP \(statusCode)")
    }

    private func optimizedStructuredInputText(
        _ rawText: String,
        documentType: StructuredDocumentType
    ) -> String {
        let lines = rawText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return rawText }

        let maxLines: Int
        let maxChars: Int
        switch documentType {
        case .contactCard, .businessCard:
            maxLines = 80
            maxChars = 3500
        case .invoice, .estimate, .bill, .receipt:
            maxLines = 140
            maxChars = 7000
        case .fireEquipmentManualSticker:
            maxLines = 160
            maxChars = 8500
        case .other:
            maxLines = 120
            maxChars = 5500
        }

        let highSignal = lines.filter { isHighSignalStructuredLine($0, documentType: documentType) }
        let selected = highSignal.isEmpty ? Array(lines.prefix(maxLines)) : Array(highSignal.prefix(maxLines))
        let joined = selected.joined(separator: "\n")
        if joined.count <= maxChars { return joined }
        let index = joined.index(joined.startIndex, offsetBy: maxChars)
        return String(joined[..<index])
    }

    private func isHighSignalStructuredLine(
        _ line: String,
        documentType: StructuredDocumentType
    ) -> Bool {
        let lower = line.lowercased()
        let hasDigit = lower.rangeOfCharacter(from: .decimalDigits) != nil
        let hasEmail = lower.contains("@")
        let hasCurrency = lower.contains("$") || lower.contains("usd") || lower.contains("eur") || lower.contains("inr")
        let hasDate = lower.contains("/") || lower.contains("-") || lower.contains("date")
        let hasPhoneHint = lower.contains("tel") || lower.contains("phone") || lower.contains("mobile") || hasDigit
        let hasAddressHint = lower.contains("address") || lower.contains("street") || lower.contains("lane") || lower.contains("city") || lower.contains("state") || lower.contains("zip")
        let hasInvoiceHint = lower.contains("invoice") || lower.contains("estimate") || lower.contains("receipt") || lower.contains("bill") || lower.contains("subtotal") || lower.contains("total") || lower.contains("tax")
        let hasInspectionHint = lower.contains("inspection") || lower.contains("deficiency") || lower.contains("serial") || lower.contains("asset") || lower.contains("compliance") || lower.contains("system")

        switch documentType {
        case .contactCard, .businessCard:
            return hasEmail || hasPhoneHint || hasAddressHint || lower.contains("www") || lower.contains("http")
        case .invoice, .estimate, .bill, .receipt:
            return hasInvoiceHint || hasCurrency || hasDate || hasDigit || hasEmail || hasAddressHint
        case .fireEquipmentManualSticker:
            return hasInspectionHint || hasDate || hasDigit || hasAddressHint
        case .other:
            return hasEmail || hasPhoneHint || hasAddressHint || hasCurrency || hasDate || hasInvoiceHint || hasInspectionHint || hasDigit
        }
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
            let documentType = request.documentType ?? .other
            return """
            You extract structured information from OCR text.
            You MUST respond in \(request.preferredLanguage.responseLanguageInstruction).
            Target document type is \(documentType.displayName).
            Document-specific extraction focus:
            \(structuredExtractionFieldFocus(for: documentType))
            Keep source facts exactly; do not invent values.
            Return valid JSON only, no markdown.
            Use this exact shape:
            \(structuredExtractionSchemaTemplate(for: documentType))
            Rules:
            - Use empty arrays/empty strings when missing.
            - Keep phone countryCode separate from number when possible.
            - Parse addresses into components and also provide full.
            - For trade systems use values like fire, hvac, electrical, plumbing when identifiable.
            - Set `documentType` in output to the best matching subtype from OCR.
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
            let docType = request.documentType?.displayName ?? "Unspecified"
            return "Extract structured data for document type '\(docType)' from this OCR text:\n\n\(request.text)"
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
