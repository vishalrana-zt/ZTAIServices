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
    @Published public var feedbackToastState: ZTAIToastState?
    /// When true, perspective correction is applied before OCR and the camera shows a
    /// framing guide overlay. Only relevant for fireEquipment document type. Default: false.
    @Published public var tagScanModeEnabled: Bool = false

    /// True when this coordinator supports tag-scan mode (i.e. document type is fireEquipment).
    public var supportsTagScan: Bool { documentType == .fireEquipment }

    public var onApply: (([ZTAutofillCandidate]) -> Void)?
    public var onUndo: (() -> Void)?
    public var onAnalyticsEvent: ((String, [String: Any]) -> Void)?

    private let documentType: StructuredDocumentType
    private let fieldMapper: @Sendable (String) -> [ZTAutofillCandidate]
    private let ocrEngine = ImageOCREngine()
    private let textAIService = TextAIService()
    private let speechBridge = SpeechToTextFlowBridge()
    private var extractionTask: Task<Void, Never>?
    private var feedbackDismissTask: Task<Void, Never>?
    private var lastEmptyCandidateReason: String?
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

    /// Localized hint shown in the camera framing overlay when tag scan mode is active.
    public var cameraGuidanceHint: String {
        switch documentType {
        case .fireEquipment:
            return Self.localizedLabel("lbl_camera_guide_fire_tag",      fallback: "Fill frame with tag")
        case .customer:
            return Self.localizedLabel("lbl_camera_guide_business_card", fallback: "Fill frame with card")
        case .bill:
            return Self.localizedLabel("lbl_camera_guide_document",      fallback: "Fill frame with document")
        }
    }

    /// Hint always shown on the camera overlay — message depends on document type and scan mode.
    /// Never nil: the camera frame overlay is shown for every scan to guide the user.
    public var cameraHint: String {
        switch documentType {
        case .customer:
            return Self.localizedLabel("lbl_camera_guide_business_card", fallback: "Fill frame with card")
        case .bill:
            return Self.localizedLabel("lbl_camera_guide_document", fallback: "Fill frame with document")
        case .fireEquipment:
            if tagScanModeEnabled {
                return Self.localizedLabel("lbl_camera_guide_fire_tag", fallback: "Fill frame with tag")
            } else {
                return Self.localizedLabel("lbl_camera_guide_fire_nameplate", fallback: "Fill frame with equipment nameplate")
            }
        }
    }

    /// Localized subtitle shown under the photo action in the picker. Varies by document type.
    public var photoActionSubtitle: String {
        switch documentType {
        case .fireEquipment:
            return Self.localizedLabel("lbl_autofill_scan_photo_subtitle_fire_equipment", fallback: "Fire inspection tag, equipment label, or nameplate")
        case .customer:
            return Self.localizedLabel("lbl_autofill_scan_photo_subtitle_customer", fallback: "Business card, work order, or label")
        case .bill:
            return Self.localizedLabel("lbl_autofill_scan_photo_subtitle_bill", fallback: "Invoice, work order, or receipt")
        }
    }

    public func openSheet(preferCloudForStructuredExtraction: Bool = false) {
        CloudAPIConfiguration.preferCloudForStructuredExtraction = preferCloudForStructuredExtraction
        candidates = []
        previewCandidates = []
        liveTranscript = ""
        sourceLabel = ""
        selectedImage = nil
        ocrText = ""
        activeModelBadge = nil
        step = .picking
        isSheetPresented = true
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
        clearFeedbackToast()
        step = .idle
    }

    public func handleSelectedImage(_ image: UIImage, source: ZTAutofillImageSource = .library) {
        selectedImage = image
        ocrText = ""
        activeModelBadge = .appleVisionOCR
        extractionTask?.cancel()
        sourceLabel = Self.localizedLabel("lbl_autofill_source_photo", fallback: "Read from the photo.")
        step = .scanningPhoto
        extractionTask = Task { [weak self] in
            guard let self else { return }
            do {
                #if DEBUG
                let ocrStart = Date()
                #endif
                let text: String
                let supplementalContext: String?
                if self.documentType == .fireEquipment {
                    let workImage: UIImage
                    // Perspective correction only applies to camera shots (angled captures).
                    // Library photos are already composed by the user — skip the correction.
                    if self.tagScanModeEnabled && source == .camera {
                        #if DEBUG
                        let perspStart = Date()
                        #endif
                        workImage = await self.ocrEngine.perspectiveCorrected(image)
                        #if DEBUG
                        if CloudAPIConfiguration.isLoggingEnabled {
                            print("[AUTOFILL_TIMING] PerspectiveCorrection: \(String(format: "%.2f", Date().timeIntervalSince(perspStart)))s input=\(Int(image.size.width))x\(Int(image.size.height)) output=\(Int(workImage.size.width))x\(Int(workImage.size.height))")
                        }
                        #endif
                    } else {
                        workImage = image
                    }
                    let ocrResult = try await self.ocrEngine.recognizeDetailedText(in: workImage, languageHints: [])
                    text = ocrResult.fullText

                    // Punch-hole detection and visual-selection context are only meaningful
                    // when tag-scan mode is on — the user has confirmed they're scanning
                    // an inspection tag with a hole-punch date/type grid. For regular
                    // equipment photos (labels, nameplates) the pixel analysis produces
                    // unreliable results and the supplemental context is omitted.
                    if self.tagScanModeEnabled {
                        #if DEBUG
                        let punchStart = Date()
                        #endif
                        let punchDetections = await Task.detached(priority: .userInitiated) {
                            PunchHoleDetector().detectSelections(in: workImage, ocrResult: ocrResult)
                        }.value
                        #if DEBUG
                        if CloudAPIConfiguration.isLoggingEnabled {
                            print("[AUTOFILL_TIMING] PunchDetection: \(String(format: "%.2f", Date().timeIntervalSince(punchStart)))s, selections=\(punchDetections.count)")
                            let allSelected = punchDetections.filter { $0.selected }
                            let gridSelected = allSelected.filter { $0.strategy == .gridCell }
                            let optionSelected = allSelected.filter { $0.strategy == .optionList }
                            print("[AUTOFILL_PUNCH] selected=\(allSelected.count)/\(punchDetections.count) gridCell=[\(gridSelected.map { "\($0.lineText)@\(String(format: "%.2f", $0.confidence))" }.joined(separator: ", "))] optionList=[\(optionSelected.map { $0.lineText }.joined(separator: ", "))]")
                            print("[AUTOFILL_OCR] lines=\(ocrResult.lines.count) text=\(text.prefix(800).replacingOccurrences(of: "\n", with: " | "))")
                        }
                        #endif
                        let supplementalCtx = self.buildStructuredOCRContext(punchDetections: punchDetections)
                        #if DEBUG
                        if CloudAPIConfiguration.isLoggingEnabled {
                            print("[AUTOFILL_PUNCH] supplementalContext=\(supplementalCtx ?? "nil")")
                        }
                        #endif
                        supplementalContext = supplementalCtx
                    } else {
                        #if DEBUG
                        if CloudAPIConfiguration.isLoggingEnabled {
                            print("[AUTOFILL_OCR] lines=\(ocrResult.lines.count) text=\(text.prefix(800).replacingOccurrences(of: "\n", with: " | "))")
                        }
                        #endif
                        supplementalContext = nil
                    }
                } else {
                    text = try await self.ocrEngine.recognizeText(in: image, languageHints: [])
                    supplementalContext = nil
                    #if DEBUG
                    if CloudAPIConfiguration.isLoggingEnabled {
                        let lineCount = text.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
                        print("[AUTOFILL_OCR] docType=\(self.documentType.rawValue) lines=\(lineCount) text=\(text.prefix(800).replacingOccurrences(of: "\n", with: " | "))")
                    }
                    #endif
                }
                #if DEBUG
                if CloudAPIConfiguration.isLoggingEnabled {
                    print("[AUTOFILL_TIMING] OCR: \(String(format: "%.2f", Date().timeIntervalSince(ocrStart)))s")
                }
                #endif
                if Task.isCancelled { return }
                await MainActor.run {
                    self.ocrText = text
                    self.previewCandidates = self.mapNonEmptyCandidates(from: text, fallbackText: text)
                }
                if Task.isCancelled { return }
                await self.runExtraction(from: text, supplementalContext: supplementalContext)
            } catch {
                if Task.isCancelled { return }
                let msg = (error as? ImageOCRError)?.localizedDescription ?? error.localizedDescription
                step = .error(msg)
            }
        }
    }

    public func selectSpeak() {
        extractionTask?.cancel()
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
        presentFeedbackToast(action: "autofill")
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
        clearFeedbackToast()
        step = .picking
    }

    // MARK: - Private

    private func runExtraction(from text: String, supplementalContext: String? = nil) async {
        step = .extracting
        lastEmptyCandidateReason = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        previewCandidates = mapNonEmptyCandidates(from: trimmed, fallbackText: trimmed)
        guard !trimmed.isEmpty else {
            step = .error("No text was captured. Please try again.")
            return
        }

        do {
            #if DEBUG
            let extractStart = Date()
            #endif
            let nonEmpty = try await extractCandidates(from: trimmed, supplementalContext: supplementalContext, allowsRetry: true, attempt: 1)
            #if DEBUG
            if CloudAPIConfiguration.isLoggingEnabled {
                print("[AUTOFILL_TIMING] Extraction: \(String(format: "%.2f", Date().timeIntervalSince(extractStart)))s, \(nonEmpty.count) candidates")
            }
            #endif
            if Task.isCancelled { return }

            if nonEmpty.isEmpty {
                step = .error(emptyCandidateMessage())
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

            if let reason = lastEmptyCandidateReason, !reason.isEmpty {
                step = .error(emptyCandidateMessage())
                return
            }

            let msg = (error as? TextAIError)?.localizedDescription ?? error.localizedDescription
            step = .error(msg)
        }
    }

    private func extractCandidates(from text: String, supplementalContext: String?, allowsRetry: Bool, attempt: Int) async throws -> [ZTAutofillCandidate] {
        if CloudAPIConfiguration.preferCloudForStructuredExtraction {
            activeModelBadge = nil
        } else if ZTAIModelBadgeKind.isAppleFoundationModelsAvailable {
            activeModelBadge = .appleFoundationModels
        } else {
            activeModelBadge = nil
        }
        #if DEBUG
        let requestStart = Date()
        #endif
        let result = try await textAIService.structuredExtract(
            text: text,
            preferredLanguage: resolvedLanguage(),
            documentType: documentType,
            supplementalContext: supplementalContext
        )
        #if DEBUG
        if CloudAPIConfiguration.isLoggingEnabled {
            print("[AUTOFILL_TIMING] structuredExtract attempt=\(attempt) provider=\(result.provider.rawValue) duration=\(String(format: "%.2f", Date().timeIntervalSince(requestStart)))s")
        }
        #endif
        activeModelBadge = ZTAIModelBadgeKind(provider: result.provider)
        if Task.isCancelled { return [] }

        let nonEmpty = mapNonEmptyCandidates(from: result.outputText, fallbackText: text)
        if nonEmpty.isEmpty {
            lastEmptyCandidateReason = buildEmptyCandidateReason(from: result.outputText)
        } else {
            lastEmptyCandidateReason = nil
        }
        #if DEBUG
        if CloudAPIConfiguration.isLoggingEnabled {
            print("[AUTOFILL_DEBUG] provider=\(result.provider.rawValue) candidates=\(nonEmpty.count) output=\(result.outputText)")
            if let lastEmptyCandidateReason {
                print("[AUTOFILL_DEBUG] emptyCandidateReason=\(lastEmptyCandidateReason)")
            }
        }
        #endif

        // Structured extraction can occasionally return an unmappable payload on the first attempt.
        // Retry once automatically before surfacing an error state to the user.
        if nonEmpty.isEmpty, allowsRetry {
            #if DEBUG
            if CloudAPIConfiguration.isLoggingEnabled {
                print("[AUTOFILL_TIMING] structuredExtract retry triggered after attempt=\(attempt) dueTo=empty_candidates")
            }
            #endif
            if Task.isCancelled { return [] }
            return try await extractCandidates(from: text, supplementalContext: supplementalContext, allowsRetry: false, attempt: attempt + 1)
        }

        return nonEmpty
    }


    private func mapNonEmptyCandidates(from extractedText: String, fallbackText: String) -> [ZTAutofillCandidate] {
        var mapped = fieldMapper(extractedText)
        var nonEmpty = mapped.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        // Fallback to raw OCR/transcript text if structured output could not be mapped,
        // or if fire-equipment output only produced a generic note.
        let isOnlyNote = !nonEmpty.isEmpty && nonEmpty.allSatisfy { ["note", "notes"].contains($0.id.lowercased()) }
        if (nonEmpty.isEmpty || (documentType == .fireEquipment && isOnlyNote)), extractedText != fallbackText {
            mapped = fieldMapper(fallbackText)
            let fallbackNonEmpty = mapped.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !fallbackNonEmpty.isEmpty {
                nonEmpty = fallbackNonEmpty
            }
        }

        return nonEmpty
    }

    private struct StructuredVisualSelection: Encodable {
        let label: String
        let selected: Bool
        let confidence: Float
    }

    // Ordered canonical 3-letter prefixes. hasPrefix matching handles all OCR variants:
    // "JAN"/"JANUARY", "JUN"/"JUNE", "JUL"/"JULY", "SEP"/"SEPT"/"SEPTEMBER", etc.
    private static let canonicalMonthPrefixes = [
        "JAN","FEB","MAR","APR","MAY","JUN","JUL","AUG","SEP","OCT","NOV","DEC"
    ]

    /// Returns the canonical 3-letter month abbreviation for an OCR line text, or nil if not a month.
    private static func canonicalMonth(for text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces).uppercased()
        return canonicalMonthPrefixes.first { t.range(of: $0, options: [.caseInsensitive, .anchored]) != nil }
    }

    private func buildStructuredOCRContext(punchDetections: [PunchHoleDetectionResult]) -> String? {
        let gridSelected = punchDetections.filter { $0.selected && $0.strategy == .gridCell }

        // Include the single best optionList selection only when exactly one item passes
        // and it is clearly dominant (confidence ≥ 0.80). When multiple items are selected
        // the detection is ambiguous and we send nothing — wrong agent type misleads the AI
        // more than silence. Only affects punch-tag scans.
        let optionSelected = punchDetections.filter { $0.selected && $0.strategy == .optionList }
        let topOptionHint: PunchHoleDetectionResult? = {
            guard optionSelected.count == 1, let top = optionSelected.first, top.confidence >= 0.80 else { return nil }
            return top
        }()

        let selectedYears = gridSelected.filter { t in
            let s = t.lineText.trimmingCharacters(in: .whitespaces)
            return s.count == 4 && Int(s).map { $0 >= 1990 && $0 <= 2040 } == true
        }
        let selectedMonths = gridSelected.filter {
            Self.canonicalMonth(for: $0.lineText) != nil
        }

        // Months completely absent from OCR may have been punched through — the hole
        // destroys the printed text making it unreadable. Surfacing these to the AI lets
        // it infer the likely punched month from the gap in the sequence.
        let ocrMonthsPresent = Set(punchDetections.compactMap { Self.canonicalMonth(for: $0.lineText) })
        let monthsAbsentFromOCR = Set(Self.canonicalMonthPrefixes).subtracting(ocrMonthsPresent).sorted()

        guard !gridSelected.isEmpty || !monthsAbsentFromOCR.isEmpty || topOptionHint != nil else { return nil }

        var payload: [String: Any] = [:]

        var allSelections = gridSelected.map {
            ["label": $0.lineText, "selected": true, "confidence": $0.confidence] as [String: Any]
        }
        if let hint = topOptionHint {
            allSelections.append(["label": hint.lineText, "selected": true, "confidence": hint.confidence, "hint": "lowConfidence"] as [String: Any])
        }
        if !allSelections.isEmpty {
            payload["visualSelections"] = allSelections
        }

        // Only derive a date when exactly 1 year and 1 month are unambiguously detected.
        // When multiple years or months compete, omit derivedServiceDate and let the AI
        // use context clues — a wrong derivedServiceDate misleads the AI more than silence.
        if selectedYears.count == 1, selectedMonths.count == 1,
           let y = selectedYears.first, let m = selectedMonths.first {
            let canonMonth = Self.canonicalMonth(for: m.lineText) ?? m.lineText
            payload["derivedServiceDate"] = "\(canonMonth) \(y.lineText)"
        }

        if !monthsAbsentFromOCR.isEmpty {
            payload["possiblyPunchedAbsentFromOCR"] = monthsAbsentFromOCR
        }

        guard !payload.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    private func presentFeedbackToast(action: String) {
        clearFeedbackToast()
        let key = "lbl_ai_feedback_prompt_ai_output"
        let raw = ZTAIServiceLocalizer.localized(key)
        let title = raw == key ? "Was this AI output helpful?" : raw
        feedbackToastState = ZTAIToastState(title: title, badge: nil, style: .success, feedbackAction: action)
        feedbackDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await MainActor.run { self?.feedbackToastState = nil }
        }
    }

    public func clearFeedbackToast() {
        feedbackDismissTask?.cancel()
        feedbackDismissTask = nil
        feedbackToastState = nil
    }

    private static func localizedLabel(_ key: String, fallback: String) -> String {
        let v = ZTAIServiceLocalizer.localized(key)
        return v == key ? fallback : v
    }

    private func resolvedLanguage() -> SupportedLanguage {
        ZTAIServiceLocalizer.resolvedSupportedLanguage()
    }

    private func emptyCandidateMessage() -> String {
        if let reason = lastEmptyCandidateReason, !reason.isEmpty {
            return reason
        }
        return Self.localizedLabel(
            "err_autofill_no_details_extracted",
            fallback: "No matching form fields were found from this input."
        )
    }

    private func buildEmptyCandidateReason(from outputText: String) -> String? {
        let formatReason: (_ key: String, _ fallback: String, _ value: String) -> String = { key, fallback, value in
            let template = Self.localizedLabel(key, fallback: fallback)
            return String(format: template, value)
        }

        guard let data = outputText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let json = object as? [String: Any] else {
            return nil
        }

        let documentType = (json["documentType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let noticeType = (json["noticeType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let equipmentCount = (json["equipment"] as? [Any])?.count ?? 0

        var reasons: [String] = []

        if let documentType, !documentType.isEmpty, documentType.caseInsensitiveCompare("fireEquipment") != .orderedSame {
            reasons.append(formatReason(
                "err_autofill_reason_doc_type_mismatch",
                "Detected document type '%@' instead of fire equipment details.",
                documentType
            ))
        }

        if equipmentCount == 0 {
            reasons.append(Self.localizedLabel(
                "err_autofill_reason_equipment_empty",
                fallback: "Extracted output did not include equipment field values to map into this form."
            ))
        }

        if let noticeType, ["nonCompliance", "recharge"].contains(where: { $0.caseInsensitiveCompare(noticeType) == .orderedSame }) {
            reasons.append(formatReason(
                "err_autofill_reason_notice_type",
                "This looks like a '%@' inspection tag, which usually contains status/compliance data rather than editable asset fields.",
                noticeType
            ))
        }

        if supportsTagScan && !tagScanModeEnabled {
            reasons.append(Self.localizedLabel(
                "err_autofill_reason_enable_tag_scan",
                fallback: "If this is a punched inspection tag, enable Tag Scan mode for better extraction."
            ))
        }

        if reasons.isEmpty {
            return nil
        }

        return reasons.joined(separator: " ")
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
