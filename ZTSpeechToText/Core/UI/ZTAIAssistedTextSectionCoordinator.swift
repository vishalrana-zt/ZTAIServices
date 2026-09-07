import Foundation

@MainActor
public final class ZTAIAssistedTextSectionCoordinator: ObservableObject {
    @Published public var isSpeechToTextSheetPresented = false
    @Published public var isSpeechRecordingActive = false
    @Published public private(set) var livePreviewText = ""

    private var isOnDeviceLiveStreamingAvailable = false
    private var liveSessionID: UUID?
    private var liveDraftBaseText = ""
    private var liveReconciler = LiveTranscriptReconciler()
    private let speechManager = SpeechToTextManager.shared

    public init() {}

    private var shouldForcePostRecordingOnSimulator: Bool {
#if targetEnvironment(simulator)
        return true
#else
        return false
#endif
    }

    private var resolvedSpeechMode: SpeechToTextManager.OperationMode {
        if shouldForcePostRecordingOnSimulator {
            return .postRecording
        }
        return isOnDeviceLiveStreamingAvailable ? .liveStreaming : .postRecording
    }

    private var shouldEnableLiveTranscriptionInitially: Bool {
        resolvedSpeechMode == .liveStreaming
    }

    public var speechSheetConfiguration: SpeechToTextSheetConfiguration {
        SpeechToTextSheetConfiguration(
            preferredLanguage: preferredLanguage(),
            operationMode: resolvedSpeechMode,
            modelProvider: .appleModels,
            showsModelProviderSelector: false,
            initialLiveTranscriptionEnabled: shouldEnableLiveTranscriptionInitially,
            showsLiveTranscriptionToggle: false,
            livePartialMaxAudioSeconds: 6.0,
            livePartialMinimumAudioSeconds: 0.6,
            livePollingIntervalNanoseconds: 600_000_000
        )
    }

    public func prepareForScreenAppearance() {
        speechManager.setModelProvider(.appleModels)
        attachBackendStatusCallback()

        Task {
            _ = await speechManager.gateFeatureUsage()
            await MainActor.run { refreshLiveStreamingCapability() }
        }
    }

    public func handleSheetPresentationChanged(_ isPresented: Bool) {
        guard !isPresented else { return }
        isSpeechRecordingActive = false
        attachBackendStatusCallback()
        resetLiveDraftState()
    }

    public func updateRecordingState(_ isRecording: Bool) {
        isSpeechRecordingActive = isRecording
    }

    public var hasActiveRecording: Bool {
        isSpeechRecordingActive
    }

    public func stopRecordingAndDismissSheet() {
        isSpeechRecordingActive = false
        isSpeechToTextSheetPresented = false
        resetLiveDraftState()
    }

    public func handleSectionDisappear() {
        isSpeechToTextSheetPresented = false
        resetLiveDraftState()
    }

    public func handleMicTap(isReadOnly: Bool, dismissKeyboard: () -> Void) {
        guard !isReadOnly else { return }
        dismissKeyboard()

        Task {
            _ = await speechManager.gateFeatureUsage()
            let hasMicPermission = await speechManager.requestMicPermission()
            guard hasMicPermission else { return }

            _ = await speechManager.gateFeatureUsage()
            let isLiveCapable = shouldForcePostRecordingOnSimulator ? false : speechManager.isOnDeviceLiveStreamingAvailable
            await MainActor.run {
                isOnDeviceLiveStreamingAvailable = isLiveCapable
                isSpeechRecordingActive = false
                resetLiveDraftState()
            }

            speechManager.prewarmRecordingPathIfNeeded()

            await MainActor.run {
                isSpeechRecordingActive = true
                isSpeechToTextSheetPresented = true
            }
        }
    }

    public func handleLiveTranscriptPartial(
        _ partial: LiveTranscriptPartial,
        currentText: () -> String,
        applyText: (String) -> Void
    ) {
        if liveSessionID != partial.sessionID {
            liveSessionID = partial.sessionID
            liveDraftBaseText = currentText()
            livePreviewText = ""
            liveReconciler.beginSession(partial.sessionID)
        }

        let preview: String
        if let committed = partial.committedText, let volatile = partial.volatileText {
            preview = [committed, volatile]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        } else {
            guard let renderState = liveReconciler.apply(partial) else { return }
            preview = renderState.renderedText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !preview.isEmpty else { return }
        guard preview != livePreviewText else { return }

        livePreviewText = preview
        applyText(merge(liveDraftBaseText, with: preview))
    }

    public func handleFinalTranscript(
        sessionID: UUID,
        finalText: String,
        currentText: () -> String,
        applyText: (String) -> Void
    ) {
        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            resetLiveDraftState()
            return
        }

        let committed: String
        if sessionID == liveSessionID {
            committed = liveReconciler.finalize(sessionID: sessionID, finalText: trimmed) ?? trimmed
        } else {
            committed = trimmed
        }

        let base = (sessionID == liveSessionID) ? liveDraftBaseText : currentText()
        applyText(merge(base, with: committed))
        resetLiveDraftState()
    }

    private func resetLiveDraftState() {
        liveSessionID = nil
        liveDraftBaseText = ""
        livePreviewText = ""
        liveReconciler.reset()
    }

    private func merge(_ baseText: String, with transcript: String) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return baseText }
        if baseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return trimmed
        }
        return baseText + "\n" + trimmed
    }

    private func preferredLanguage() -> SupportedLanguage {
        let languageCode = (ZTAIServiceLocalizer.currentLanguageCode ?? Locale.preferredLanguages.first ?? "en").lowercased()
        if languageCode.hasPrefix("es") { return .spanish }
        if languageCode.hasPrefix("fr") { return .french }
        return .english
    }

    private func attachBackendStatusCallback() {
        speechManager.onBackendStatusChange = { [weak self] _ in
            Task { @MainActor in
                self?.refreshLiveStreamingCapability()
            }
        }
    }

    private func refreshLiveStreamingCapability() {
        if shouldForcePostRecordingOnSimulator {
            isOnDeviceLiveStreamingAvailable = false
            return
        }
        isOnDeviceLiveStreamingAvailable = speechManager.isOnDeviceLiveStreamingAvailable
    }
}
