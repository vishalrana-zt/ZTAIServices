import Foundation
import SwiftUI
import UIKit
import ZTAIServices
import Combine

// MARK: - Candidate model

public struct ZTAutofillCandidate: Identifiable {
    public let id: String
    public let label: String
    public let value: String
    public let needsCheck: Bool
    public var isSelected: Bool

    public init(id: String, label: String, value: String, needsCheck: Bool = false, isSelected: Bool = true) {
        self.id = id
        self.label = label
        self.value = value
        self.needsCheck = needsCheck
        self.isSelected = isSelected
    }
}

public enum ZTAutofillImageSource { case camera, library }

// MARK: - Coordinator

@MainActor
public final class ZTFormAutofillCoordinator: ObservableObject {

    public enum Step: Equatable {
        case idle, picking, scanningPhoto, listening, extracting, review, applied, error(String)

        public static func == (lhs: Step, rhs: Step) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.picking, .picking), (.scanningPhoto, .scanningPhoto),
                 (.listening, .listening), (.extracting, .extracting),
                 (.review, .review), (.applied, .applied): return true
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    @Published public private(set) var step: Step = .idle
    @Published public var isSheetPresented = false
    @Published public private(set) var candidates: [ZTAutofillCandidate] = []
    @Published public private(set) var sourceLabel = ""
    @Published public private(set) var liveTranscript = ""
    @Published public private(set) var selectedImage: UIImage? = nil
    @Published public private(set) var ocrText: String = ""
    @Published public private(set) var previewCandidates: [ZTAutofillCandidate] = []
    @Published public var activeModelBadge: ZTAIModelBadgeKind? = nil

    public var onApply: (([ZTAutofillCandidate]) -> Void)?
    public var onUndo: (() -> Void)?
    public var onAnalyticsEvent: ((String, [String: Any]) -> Void)?

    private let documentType: StructuredDocumentType
    private let fieldMapper: @Sendable (String) -> [ZTAutofillCandidate]
    private let ocrEngine = ImageOCREngine()
    private let textAIService = TextAIService()
    private let speechBridge = SpeechToTextFlowBridge()
    private var extractionTask: Task<Void, Never>?

    public init(
        documentType: StructuredDocumentType = .customer,
        fieldMapper: @escaping @Sendable (String) -> [ZTAutofillCandidate],
        onApply: (([ZTAutofillCandidate]) -> Void)? = nil,
        onUndo: (() -> Void)? = nil
    ) {
        self.documentType = documentType
        self.fieldMapper = fieldMapper
        self.onApply = onApply
        self.onUndo = onUndo
    }

    // MARK: - Public actions

    public func openSheet() {
        candidates = []
        previewCandidates = []
        liveTranscript = ""
        sourceLabel = ""
        selectedImage = nil
        ocrText = ""
        activeModelBadge = nil
        step = .picking
        isSheetPresented = true
        onAnalyticsEvent?("AI_AUTOFILL_OPENED", ["document_type": documentType.rawValue])
    }

    public func dismiss() {
        extractionTask?.cancel()
        extractionTask = nil
        speechBridge.cancel()
        isSheetPresented = false
        candidates = []
        previewCandidates = []
        liveTranscript = ""
        sourceLabel = ""
        selectedImage = nil
        ocrText = ""
        activeModelBadge = nil
        step = .idle
    }

    public func handleSelectedImage(_ image: UIImage, source: ZTAutofillImageSource = .library) {
        selectedImage = image
        ocrText = ""
        activeModelBadge = .appleVisionOCR
        extractionTask?.cancel()
        onAnalyticsEvent?("AI_AUTOFILL_SOURCE_PHOTO", ["source": source == .camera ? "camera" : "library"])
        sourceLabel = Self.localizedLabel("lbl_autofill_source_photo", fallback: "Read from the photo.")
        step = .scanningPhoto
        extractionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await self.ocrEngine.recognizeText(in: image, languageHints: [])
                if Task.isCancelled { return }
                await MainActor.run {
                    self.ocrText = text
                    self.previewCandidates = self.mapNonEmptyCandidates(from: text, fallbackText: text)
                }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    if Task.isCancelled { return }
                }
                await self.runExtraction(from: text)
            } catch {
                if Task.isCancelled { return }
                let msg = (error as? ImageOCRError)?.localizedDescription ?? error.localizedDescription
                step = .error(msg)
            }
        }
    }

    public func selectSpeak() {
        extractionTask?.cancel()
        onAnalyticsEvent?("AI_AUTOFILL_SOURCE_AUDIO", [:])
        activeModelBadge = .appleSpeechAnalyzer
        sourceLabel = Self.localizedLabel("lbl_autofill_source_voice", fallback: "Heard from your dictation.")
        liveTranscript = ""
        previewCandidates = []
        step = .listening

        speechBridge.onPartialText = { [weak self] partial in
            self?.liveTranscript = partial
        }

        Task { [weak self] in
            guard let self else { return }
            let ok = await self.speechBridge.requestPermissionAndPrepare()
            guard ok else {
                step = .error("Microphone permission is required to use voice input.")
                return
            }
            do {
                try await self.speechBridge.start(configuration: .init(preferredLanguage: self.resolvedLanguage(), mode: .postRecording))
            } catch {
                step = .error(error.localizedDescription)
            }
        }
    }

    public func stopListening() {
        step = .extracting
        extractionTask?.cancel()
        let fallback = liveTranscript
        extractionTask = Task { [weak self] in
            guard let self else { return }
            var text = fallback
            if let final = try? await self.speechBridge.stop(),
               !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = final
            }
            await self.runExtraction(from: text)
        }
    }

    public func preferredLanguageForSpeechSheet() -> SupportedLanguage {
        resolvedLanguage()
    }

    public func handleSpokenText(_ text: String) {
        extractionTask?.cancel()
        speechBridge.cancel()
        sourceLabel = Self.localizedLabel("lbl_autofill_source_voice", fallback: "Heard from your dictation.")
        activeModelBadge = .appleSpeechAnalyzer
        liveTranscript = text
        previewCandidates = mapNonEmptyCandidates(from: text, fallbackText: text)
        extractionTask = Task { [weak self] in
            guard let self else { return }
            await self.runExtraction(from: text)
        }
    }

    public func toggleCandidate(id: String) {
        guard let idx = candidates.firstIndex(where: { $0.id == id }) else { return }
        candidates[idx].isSelected.toggle()
    }

    public func applySelected() {
        let selected = candidates.filter { $0.isSelected }
        onAnalyticsEvent?("AI_AUTOFILL_APPLIED", ["candidate_count": selected.count])
        onApply?(selected)
        candidates = []
        previewCandidates = []
        selectedImage = nil
        ocrText = ""
        liveTranscript = ""
        sourceLabel = ""
        activeModelBadge = nil
        step = .idle
        isSheetPresented = false
    }

    public func retryFromPicker() {
        extractionTask?.cancel()
        extractionTask = nil
        speechBridge.cancel()
        candidates = []
        liveTranscript = ""
        previewCandidates = []
        sourceLabel = ""
        selectedImage = nil
        ocrText = ""
        activeModelBadge = nil
        step = .picking
    }

    // MARK: - Private

    private func runExtraction(from text: String) async {
        step = .extracting
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        previewCandidates = mapNonEmptyCandidates(from: trimmed, fallbackText: trimmed)
        guard !trimmed.isEmpty else {
            step = .error("No text was captured. Please try again.")
            return
        }

        do {
            let nonEmpty = try await extractCandidates(from: trimmed, allowsRetry: true)
            if Task.isCancelled { return }

            if nonEmpty.isEmpty {
                step = .error("No details could be extracted. Try again with a clearer source.")
            } else {
                candidates = nonEmpty
                previewCandidates = nonEmpty
                step = .review
            }
        } catch {
            if Task.isCancelled { return }
            if isOffline(error) {
                if !previewCandidates.isEmpty {
                    candidates = previewCandidates
                    step = .review
                } else {
                    step = .error(Self.localizedLabel(
                        "err_autofill_no_internet",
                        fallback: "No internet connection. Connect to the internet and try again."
                    ))
                }
                return
            }

            let msg = (error as? TextAIError)?.localizedDescription ?? error.localizedDescription
            step = .error(msg)
        }
    }

    private func extractCandidates(from text: String, allowsRetry: Bool) async throws -> [ZTAutofillCandidate] {
        activeModelBadge = .appleFoundationModels
        let result = try await textAIService.structuredExtract(
            text: text,
            preferredLanguage: resolvedLanguage(),
            documentType: documentType
        )
        activeModelBadge = ZTAIModelBadgeKind(provider: result.provider)
        if Task.isCancelled { return [] }

        let nonEmpty = mapNonEmptyCandidates(from: result.outputText, fallbackText: text)

        // Structured extraction can occasionally return an unmappable payload on the first attempt.
        // Retry once automatically before surfacing an error state to the user.
        if nonEmpty.isEmpty, allowsRetry {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return [] }
            return try await extractCandidates(from: text, allowsRetry: false)
        }

        return nonEmpty
    }

    private func mapNonEmptyCandidates(from extractedText: String, fallbackText: String) -> [ZTAutofillCandidate] {
        var mapped = fieldMapper(extractedText)
        var nonEmpty = mapped.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        // Fallback to raw OCR/transcript text if structured output could not be mapped.
        if nonEmpty.isEmpty, extractedText != fallbackText {
            mapped = fieldMapper(fallbackText)
            nonEmpty = mapped.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        return nonEmpty
    }

    private static func localizedLabel(_ key: String, fallback: String) -> String {
        let v = ZTAIServiceLocalizer.localized(key)
        return v == key ? fallback : v
    }

    private func resolvedLanguage() -> SupportedLanguage {
        ZTAIServiceLocalizer.resolvedSupportedLanguage()
    }

    private func isOffline(_ error: Error) -> Bool {
        if case let TextAIError.providerUnavailable(reason) = error {
            let value = reason.lowercased()
            if value.contains("internet") || value.contains("network") || value.contains("offline") {
                return true
            }
        }

        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        let offlineCodes: Set<Int> = [
            NSURLErrorNotConnectedToInternet,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorCannotFindHost,
            NSURLErrorDNSLookupFailed
        ]
        return offlineCodes.contains(nsError.code)
    }
}

#if DEBUG
@MainActor
extension ZTFormAutofillCoordinator {
    func debugSetState(
        step: Step,
        selectedImage: UIImage? = nil,
        ocrText: String = "",
        liveTranscript: String = "",
        candidates: [ZTAutofillCandidate] = []
    ) {
        self.selectedImage = selectedImage
        self.ocrText = ocrText
        self.liveTranscript = liveTranscript
        self.candidates = candidates
        self.previewCandidates = candidates
        self.step = step
        self.isSheetPresented = true
    }
}
#endif
