import Foundation
import SwiftUI
import UIKit

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
    @Published public private(set) var appliedCount = 0
    @Published public private(set) var sourceLabel = ""
    @Published public private(set) var liveTranscript = ""

    public var onApply: (([ZTAutofillCandidate]) -> Void)?
    public var onUndo: (() -> Void)?

    private let documentType: StructuredDocumentType
    private let fieldMapper: @Sendable (String) -> [ZTAutofillCandidate]
    private let ocrEngine = ImageOCREngine()
    private let textAIService = TextAIService()
    private let speechBridge = SpeechToTextFlowBridge()
    private var extractionTask: Task<Void, Never>?
    private var snapshotBeforeApply: [ZTAutofillCandidate] = []

    public init(
        documentType: StructuredDocumentType = .businessCard,
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
        liveTranscript = ""
        step = .picking
        isSheetPresented = true
    }

    public func dismiss() {
        extractionTask?.cancel()
        extractionTask = nil
        speechBridge.cancel()
        isSheetPresented = false
        step = .idle
    }

    public func handleSelectedImage(_ image: UIImage) {
        extractionTask?.cancel()
        sourceLabel = "Read from the photo."
        step = .scanningPhoto
        extractionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await self.ocrEngine.recognizeText(in: image, languageHints: [])
                if Task.isCancelled { return }
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
        sourceLabel = "Heard from your dictation."
        liveTranscript = ""
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
                try self.speechBridge.start(configuration: .init(mode: .postRecording))
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

    public func toggleCandidate(id: String) {
        guard let idx = candidates.firstIndex(where: { $0.id == id }) else { return }
        candidates[idx].isSelected.toggle()
    }

    public func applySelected() {
        let selected = candidates.filter { $0.isSelected }
        snapshotBeforeApply = candidates
        appliedCount = selected.count
        onApply?(selected)
        step = .applied
        isSheetPresented = false
    }

    public func undoApply() {
        onUndo?()
        candidates = snapshotBeforeApply
        step = .idle
    }

    public func retryFromPicker() {
        extractionTask?.cancel()
        extractionTask = nil
        speechBridge.cancel()
        liveTranscript = ""
        step = .picking
    }

    // MARK: - Private

    private func runExtraction(from text: String) async {
        step = .extracting
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            step = .error("No text was captured. Please try again.")
            return
        }
        do {
            let result = try await textAIService.structuredExtract(
                text: trimmed,
                preferredLanguage: resolvedLanguage(),
                documentType: documentType
            )
            if Task.isCancelled { return }
            let mapped = fieldMapper(result.outputText)
            let nonEmpty = mapped.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if nonEmpty.isEmpty {
                step = .error("No details could be extracted. Try again with a clearer source.")
            } else {
                candidates = nonEmpty
                step = .review
            }
        } catch {
            if Task.isCancelled { return }
            let msg = (error as? TextAIError)?.localizedDescription ?? error.localizedDescription
            step = .error(msg)
        }
    }

    private func resolvedLanguage() -> SupportedLanguage {
        let code = (ZTAIServiceLocalizer.currentLanguageCode ?? Locale.preferredLanguages.first ?? "en").lowercased()
        if code.hasPrefix("es") { return .spanish }
        if code.hasPrefix("fr") { return .french }
        return .english
    }
}
