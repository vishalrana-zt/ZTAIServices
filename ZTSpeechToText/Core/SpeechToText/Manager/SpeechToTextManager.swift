//
//  SpeechToTextManager.swift
//  Offline, on-device speech-to-text with automatic language detection.
//
import Foundation
import AVFoundation
import CoreML
import Speech

final class SpeechToTextManager: NSObject {

    // MARK: - Singleton

    static let shared = SpeechToTextManager()
    private override init() {
        super.init()
        bootstrapAppleAdvancedPathSafetyState()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Types

    enum STTError: LocalizedError {
        case notReady
        case micPermissionDenied
        case audioSessionFailure
        case emptyRecording

        var errorDescription: String? {
            switch self {
            case .notReady: return "Speech model is not downloaded/ready yet."
            case .micPermissionDenied: return "Microphone permission was denied."
            case .audioSessionFailure: return "Could not configure the audio session."
            case .emptyRecording: return "No audio was captured."
            }
        }
    }

    enum OperationMode: String, CaseIterable {
        case liveStreaming
        case postRecording
    }
    
    enum TranscriptionEngine: String {
        case speechTranscriber
        case dictationTranscriber
        case cloudAPI
    }

    enum ModelProvider: String, CaseIterable {
        case appleModels

        var displayName: String {
            "Apple Models"
        }
    }

    var backendStatusLabel: String {
        if #available(iOS 26.0, *) {
            if operationMode == .liveStreaming {
                return useAdvancedAppleLiveTranscribers ? "Apple SpeechAnalyzer" : "Cloud API"
            }
            appleCapabilityLock.lock()
            let speechCapable = advancedSpeechTranscriberCapable
            appleCapabilityLock.unlock()
            return speechCapable ? "Apple SpeechAnalyzer" : "Cloud API"
        }
        return "Cloud API"
    }

    /// True only when the device is confirmed capable of on-device live streaming
    /// via DictationTranscriber (iOS 26+, capability check completed, capable).
    /// Use this to show or hide the "Live transcription" toggle in the UI.
    var isOnDeviceLiveStreamingAvailable: Bool {
        guard #available(iOS 26.0, *) else { return false }
        appleCapabilityLock.lock()
        let capable = didCheckAdvancedAppleTranscriberCapability && advancedDictationTranscriberCapable
        appleCapabilityLock.unlock()
        return capable
    }

    struct DownloadStatus: Equatable {
        let progress: Double
        let downloadedBytes: Int64
        let totalBytes: Int64
    }

    struct LivePartialResult: Sendable {
        let text: String
        let language: SupportedLanguage
        let windowStartTime: TimeInterval
        let windowEndTime: TimeInterval
        let segments: [LiveTranscriptSegment]
        let committedText: String?
        let volatileText: String?

        init(
            text: String,
            language: SupportedLanguage,
            windowStartTime: TimeInterval,
            windowEndTime: TimeInterval,
            segments: [LiveTranscriptSegment],
            committedText: String? = nil,
            volatileText: String? = nil
        ) {
            self.text = text
            self.language = language
            self.windowStartTime = windowStartTime
            self.windowEndTime = windowEndTime
            self.segments = segments
            self.committedText = committedText
            self.volatileText = volatileText
        }
    }

    enum ModelState: Equatable {
        case notDownloaded
        case downloading(DownloadStatus)
        case loadingModel(loaded: Int, total: Int)
        case ready
        case failed(String)
    }

    // MARK: - Public state

    private(set) var modelState: ModelState = .notDownloaded {
        didSet { onModelStateChange?(modelState) }
    }
    private(set) var isListening = false

    /// Hook this up to a progress bar / label in your opt-in UI.
    var onModelStateChange: ((ModelState) -> Void)?
    var onBackendStatusChange: ((String) -> Void)?

    // MARK: - Private

    private let audioEngine = AVAudioEngine()
    private var sampleBuffer: [Float] = []
    private let targetSampleRate: Double = 16_000
    private let bufferLock = NSLock()
    private let postRecordingFileLock = NSLock()
    private var postRecordingAudioFile: AVAudioFile?
    private var postRecordingAudioFileURL: URL?
    private var postRecordingAudioFileFinalized = false
    private var hasInputTapInstalled = false

    private var autoStopOnSilence = false
    private var requiredSilenceDuration: TimeInterval = 1.0
    private var silenceThreshold: Float = 0.003
    private var accumulatedSilenceDuration: TimeInterval = 0
    private var accumulatedRecordingDuration: TimeInterval = 0
    private var hasTriggeredAutoStop = false
    private let maxRecordingDuration: TimeInterval = 10 * 60
    private var liveLockedLanguage: SupportedLanguage?
    private var sessionPreferredLanguageHint: SupportedLanguage?
    private var pendingLiveLockLanguage: SupportedLanguage?
    private var pendingLiveLockConfirmations: Int = 0
    private var lastLiveResolvedLanguage: SupportedLanguage?
    private let liveLanguageLockMinimumSeconds: Double = 2.0
    private let liveLanguageLockConfirmationsRequired: Int = 2
    private let advancedLiveStreamStartupGraceSeconds: TimeInterval = 1.6
    private var didPrewarmRecordingPath = false
    private var hasLoggedRuntimeConfig = false
    private var hasDisabledSpeechAnalyzerForSession = false
    private var hasDisabledAdvancedLiveStreamForSession = false
    private var hasValidatedSpeechAnalyzerForSession = false
    private var loggedAppleGateFailures: Set<String> = []
    private var advancedLiveStreamNoResultStreak: Int = 0
    private let advancedLiveStreamNoResultDisableThreshold: Int = 8
    private let advancedLiveStreamNoResultMinimumLiveSeconds: TimeInterval = 3.5
    private let advancedLiveStreamStartupGraceSecondsFrenchBoost: TimeInterval = 1.2
    private let advancedLiveStreamNoResultDisableThresholdFrenchBoost: Int = 4
    private let advancedLiveStreamNoResultMinimumLiveSecondsFrenchBoost: TimeInterval = 2.0
    private var liveCaptureStartedAt: Date?
    private var activeCaptureSessionID: UUID?
    private struct SessionTranscribeCache {
        let sessionID: UUID
        let result: (text: String, language: SupportedLanguage)
        let timestamp: Date
    }
    private var lastSessionTranscribeCache: SessionTranscribeCache?
    private var lastPublishedLivePartialText: String = ""
    private var lastPublishedLivePartialWindowStartTime: TimeInterval = 0
    private var lastPublishedLivePartialWindowEndTime: TimeInterval = 0
    private var lastPublishedLivePartialAt: Date = .distantPast
    private let livePartialEmitMinimumInterval: TimeInterval = 0.30
    private let livePartialEmitMinimumCharAdvance: Int = 10
    private let livePartialEmitMinimumWindowAdvance: TimeInterval = 0.90
    private let firstLivePartialMinimumWindowEnd: TimeInterval = 1.80
    private let firstLivePartialMinimumChars: Int = 10
    private let appleCapabilityLock = NSLock()
    private var advancedDictationTranscriberCapable = false
    private var advancedSpeechTranscriberCapable = false
    private var didCheckAdvancedAppleTranscriberCapability = false
    private let speechAnalyzerValidationTaskLock = NSLock()
    private var speechAnalyzerValidationTaskID: UUID?
    private var speechAnalyzerValidationTask: Task<Bool, Never>?
    private actor LiveDecodeCoordinator {
        private var isInFlight = false
        private var lastStart: Date?
        private var hasEmittedText = false

        func reset() {
            isInFlight = false
            lastStart = nil
            hasEmittedText = false
        }

        func markTextEmitted() {
            hasEmittedText = true
        }

        func tryBegin(now: Date) -> Bool {
            guard !isInFlight else { return false }
            let minInterval = hasEmittedText ? 0.45 : 0.20
            if let lastStart, now.timeIntervalSince(lastStart) < minInterval {
                return false
            }
            isInFlight = true
            self.lastStart = now
            return true
        }

        func end() {
            isInFlight = false
        }
    }
    private let liveDecodeCoordinator = LiveDecodeCoordinator()
    private let appleLiveStateLock = NSLock()
    private var appleLiveCoordinatorBox: AnyObject?
    private var appleLiveFinalText: String?
    private var lastNonEmptyLiveTranscriptText: String?
    private var isAppleLiveSessionStarting = false
    private let transcriptionLifecycleLock = NSLock()
    private var isFinalizingTranscript = false
    private var sttSessionStartedAt: Date?
    private var sttLivePartialSequence: Int = 0
    private var sttPrimaryEngineForSession: TranscriptionEngine?
    private var sttFinalEngineForSession: TranscriptionEngine?
    private var sttFallbackOccurred = false
    private var sttFallbackReason: String?
    private var sttDidLogRecordingStop = false
    private var sttDidLogFirstPartialLatency = false
    private var sttLastPartialLoggedAt: Date?
    private var sttLastStreamUnavailableFallbackLogAt: Date?
    private var sttLastStreamUnavailableFallbackKey: String?
    private var sttDidLogStartupFallbackWarning = false
    private var sttAppleLiveTapBufferCount: Int = 0
    private var sttAppleLiveTapSampleCount: Int = 0
    private var sttAppleLiveTapFirstBufferAt: Date?
    private var sttAppleLiveTapLastBufferAt: Date?
    private var sttAppleLiveTapLastLogAt: Date?
    private let sttAppleLiveTapLogInterval: TimeInterval = 1.0

    private func setAppleLiveFinalText(_ text: String?) {
        appleLiveStateLock.lock()
        appleLiveFinalText = text
        appleLiveStateLock.unlock()
    }

    private func setFinalizingTranscript(_ finalizing: Bool) {
        transcriptionLifecycleLock.lock()
        isFinalizingTranscript = finalizing
        transcriptionLifecycleLock.unlock()
    }

    private func getFinalizingTranscript() -> Bool {
        transcriptionLifecycleLock.lock()
        let value = isFinalizingTranscript
        transcriptionLifecycleLock.unlock()
        return value
    }

    private func getAppleLiveFinalText() -> String? {
        appleLiveStateLock.lock()
        let value = appleLiveFinalText
        appleLiveStateLock.unlock()
        return value
    }

    private func rememberLiveTranscriptTextIfNonEmpty(_ text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        appleLiveStateLock.lock()
        lastNonEmptyLiveTranscriptText = normalized
        appleLiveStateLock.unlock()
    }

    private func getLastNonEmptyLiveTranscriptText() -> String? {
        appleLiveStateLock.lock()
        let value = lastNonEmptyLiveTranscriptText
        appleLiveStateLock.unlock()
        return value
    }

    @available(iOS 26.0, *)
    private func takeAppleLiveCoordinator() -> AppleLiveTranscriptionCoordinator? {
        appleLiveStateLock.lock()
        let coordinator = appleLiveCoordinatorBox as? AppleLiveTranscriptionCoordinator
        appleLiveCoordinatorBox = nil
        appleLiveStateLock.unlock()
        return coordinator
    }

    private func beginAppleLiveSessionStartIfNeeded() -> Bool {
        appleLiveStateLock.lock()
        defer { appleLiveStateLock.unlock() }
        if appleLiveCoordinatorBox != nil || isAppleLiveSessionStarting {
            return false
        }
        isAppleLiveSessionStarting = true
        return true
    }

    private func endAppleLiveSessionStartIfNeeded() {
        appleLiveStateLock.lock()
        isAppleLiveSessionStarting = false
        appleLiveStateLock.unlock()
    }
    
    private var useAdvancedAppleLiveTranscribers: Bool {
        guard #available(iOS 26.0, *) else {
            logAppleGateFailure("ios_version")
            return false
        }

        guard selectedModelProvider == .appleModels else {
            logAppleGateFailure("model_provider")
            return false
        }
        guard operationMode == .liveStreaming else {
            logAppleGateFailure("operation_mode")
            return false
        }
        guard !hasDisabledAdvancedLiveStreamForSession else {
            logAppleGateFailure("live_stream_disabled_for_session")
            return false
        }
        // Keep legacy disable gate for analyzer-based fallback only.
        guard !hasDisabledSpeechAnalyzerForSession else {
            logAppleGateFailure("disabled_for_session")
            return false
        }
        guard !isAppleAdvancedPathQuarantined() else {
            logAppleGateFailure("quarantined")
            return false
        }
        appleCapabilityLock.lock()
        let enabled = advancedDictationTranscriberCapable
        appleCapabilityLock.unlock()
        if !enabled {
            logAppleGateFailure("dictation_runtime_capability_check")
        }
        return enabled
    }

    private func logAppleGateFailure(_ reason: String) {
        // Suppress non-session gate noise during UI-only state changes.
        guard activeCaptureSessionID != nil else { return }
        let key = "\(operationMode.rawValue):\(reason)"
        guard !loggedAppleGateFailures.contains(key) else { return }
        loggedAppleGateFailures.insert(key)
        debugTrace("apple_gate fail=\(reason)")
    }

    private func setAdvancedAppleTranscriberCapability(dictation: Bool, speech: Bool, checked: Bool) {
        appleCapabilityLock.lock()
        advancedDictationTranscriberCapable = dictation
        advancedSpeechTranscriberCapable = speech
        didCheckAdvancedAppleTranscriberCapability = checked
        appleCapabilityLock.unlock()
    }

    private func shouldSkipAdvancedAppleCapabilityRefresh() -> Bool {
        appleCapabilityLock.lock()
        let shouldSkip = didCheckAdvancedAppleTranscriberCapability
        appleCapabilityLock.unlock()
        return shouldSkip
    }

    private func bootstrapAppleAdvancedPathSafetyState() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.appleAdvancedArmedKey) {
            defaults.set(true, forKey: Self.appleAdvancedQuarantinedKey)
            defaults.set(false, forKey: Self.appleAdvancedArmedKey)
        }
        // One-time drain of any locale reservations left over from before the
        // reserve/release fix (or any other stale reservation), so each fresh
        // app run starts at 0/5 instead of inheriting an already-exhausted quota.
        if #available(iOS 26.0, *) {
            Task(priority: .utility) {
                for locale in await AssetInventory.reservedLocales {
                    await AssetInventory.release(reservedLocale: locale)
                }
            }
        }
    #if DEBUG
        if defaults.bool(forKey: Self.appleAdvancedQuarantinedKey) {
            defaults.set(false, forKey: Self.appleAdvancedQuarantinedKey)
            defaults.set(false, forKey: Self.appleAdvancedArmedKey)
        }
    #endif
    }

    private func isAppleAdvancedPathQuarantined() -> Bool {
        UserDefaults.standard.bool(forKey: Self.appleAdvancedQuarantinedKey)
    }

    private func armAppleAdvancedPath() {
        UserDefaults.standard.set(true, forKey: Self.appleAdvancedArmedKey)
    }

    private func disarmAppleAdvancedPath() {
        UserDefaults.standard.set(false, forKey: Self.appleAdvancedArmedKey)
    }

    /// Controlled recovery hook: keeps quarantine mechanism, but allows an explicit retry.
    func clearAppleAdvancedPathQuarantineForRetry() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: Self.appleAdvancedQuarantinedKey)
        defaults.set(false, forKey: Self.appleAdvancedArmedKey)
        hasDisabledSpeechAnalyzerForSession = false
        hasDisabledAdvancedLiveStreamForSession = false
        hasValidatedSpeechAnalyzerForSession = false
        advancedLiveStreamNoResultStreak = 0
        resetLivePartialOutputState()
        sessionPreferredLanguageHint = nil
        setAdvancedAppleTranscriberCapability(dictation: false, speech: false, checked: false)
        Task(priority: .utility) { [weak self] in
            await self?.refreshAdvancedAppleTranscriberCapabilityIfNeeded(force: true)
        }
    }

    private func refreshAdvancedAppleTranscriberCapabilityIfNeeded(force: Bool) async {
        guard selectedModelProvider == .appleModels else {
            setAdvancedAppleTranscriberCapability(dictation: false, speech: false, checked: false)
            disarmAppleAdvancedPath()
            return
        }
        guard !isAppleAdvancedPathQuarantined() else {
            setAdvancedAppleTranscriberCapability(dictation: false, speech: false, checked: true)
            publishBackendStatus()
            return
        }
        guard #available(iOS 26.0, *) else {
            setAdvancedAppleTranscriberCapability(dictation: false, speech: false, checked: true)
            return
        }
        if !force, shouldSkipAdvancedAppleCapabilityRefresh() { return }

        let preferredLanguage = effectiveSessionLanguage(preferredLanguage: nil)
        let preferredLocale = speechAnalyzerLocaleHint(for: preferredLanguage) ?? Locale.current

        let dictationSupportedLocale = await DictationTranscriber.supportedLocale(equivalentTo: preferredLocale)
        let speechSupportedLocale: Locale?
        if SpeechTranscriber.isAvailable {
            speechSupportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: preferredLocale)
        } else {
            speechSupportedLocale = nil
        }

        let dictationCapable = dictationSupportedLocale != nil
        let speechCapable = speechSupportedLocale != nil
        let enabled = dictationCapable || speechCapable
        debugTrace(
            "apple_runtime_capability preferred=\(preferredLocale.identifier) dictation=\(dictationCapable) speech=\(speechCapable) enabled=\(enabled)"
        )
        setAdvancedAppleTranscriberCapability(dictation: dictationCapable, speech: speechCapable, checked: true)
        publishBackendStatus()

        if let speechLocale = speechSupportedLocale {
            Task(priority: .utility) { [weak self] in
                guard self != nil else { return }
                let engine = SpeechAnalyzerTranscriptionEngine()
                try? await engine.prepare(localeHint: speechLocale, preset: .transcription)
            }
        }
    }

    var onSilenceAutoStopTriggered: (() -> Void)?
    var onAudioLevelChange: ((Float) -> Void)?
    
    /// Compatibility bridge used by existing logic; now driven by model provider selection.
    var useSpeechAnalyzerWhenAvailable: Bool {
        get { selectedModelProvider == .appleModels }
        set { setModelProvider(.appleModels) }
    }

    private static let optedInKey = "SpeechToTextManager.optedIn"
    private static let liveTranscriptionEnabledKey = "SpeechToTextManager.liveTranscriptionEnabled"
    private static let modelProviderKey = "SpeechToTextManager.modelProvider"
    private static let appleAdvancedArmedKey = "SpeechToTextManager.appleAdvancedArmed"
    private static let appleAdvancedQuarantinedKey = "SpeechToTextManager.appleAdvancedQuarantined"
    
    /// True once the model is downloaded AND loaded into memory — the only
    /// state in which recording/transcription is actually usable.
    var isReady: Bool {
        if case .ready = modelState(for: operationMode) { return true }
        return false
    }

    /// True if the user has opted in, regardless of whether the download
    /// finished. Use this at launch/entry points to decide whether to
    /// silently resume the download screen instead of showing the opt-in CTA.
    var hasOptedIn: Bool {
        UserDefaults.standard.bool(forKey: Self.optedInKey)
    }

    var isLiveTranscriptionEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.liveTranscriptionEnabledKey) == nil {
                return false
            }
            return UserDefaults.standard.bool(forKey: Self.liveTranscriptionEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.liveTranscriptionEnabledKey)
        }
    }

    private var operationMode: OperationMode = .liveStreaming

    var selectedModelProvider: ModelProvider {
        get {
            if let raw = UserDefaults.standard.string(forKey: Self.modelProviderKey),
               let provider = ModelProvider(rawValue: raw) {
                return provider
            }
            return .appleModels
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.modelProviderKey)
        }
    }

    func setModelProvider(_ provider: ModelProvider) {
        let provider: ModelProvider = .appleModels
        let previous = selectedModelProvider
        guard previous != provider else { return }
        cancelSpeechAnalyzerValidationTaskIfNeeded()
        selectedModelProvider = provider
        hasDisabledSpeechAnalyzerForSession = false
        hasDisabledAdvancedLiveStreamForSession = false
        hasValidatedSpeechAnalyzerForSession = false
        loggedAppleGateFailures.removeAll()
        advancedLiveStreamNoResultStreak = 0
        resetLivePartialOutputState()
        liveCaptureStartedAt = nil
        activeCaptureSessionID = nil
        lastSessionTranscribeCache = nil
        setAdvancedAppleTranscriberCapability(dictation: false, speech: false, checked: false)
        hasLoggedRuntimeConfig = false
        setAppleLiveFinalText(nil)
        modelState = modelState(for: operationMode)
        publishBackendStatus()

        Task(priority: .utility) { [weak self] in
            await self?.refreshAdvancedAppleTranscriberCapabilityIfNeeded(force: true)
        }
    }

    func modelState(for _: OperationMode) -> ModelState {
        return .ready
    }

    func setOperationMode(_ mode: OperationMode) {
        guard operationMode != mode else { return }
        operationMode = mode
        // Mode switch should start with a fresh analyzer session gate.
        // Otherwise a live-mode disable can incorrectly force recognizer in post mode.
        hasDisabledSpeechAnalyzerForSession = false
        hasDisabledAdvancedLiveStreamForSession = false
        hasValidatedSpeechAnalyzerForSession = false
        loggedAppleGateFailures.removeAll()
        advancedLiveStreamNoResultStreak = 0
        resetLivePartialOutputState()
        liveCaptureStartedAt = nil
        activeCaptureSessionID = nil
        lastSessionTranscribeCache = nil
        sessionPreferredLanguageHint = nil
        modelState = modelState(for: mode)
        publishBackendStatus()
        debugLogRuntimeConfiguration(reason: "operation_mode_changed")
    }

    func resetSessionStateForLanguageChange(_ language: SupportedLanguage) {
        cancelSpeechAnalyzerValidationTaskIfNeeded()
        hasDisabledSpeechAnalyzerForSession = false
        hasDisabledAdvancedLiveStreamForSession = false
        hasValidatedSpeechAnalyzerForSession = false
        loggedAppleGateFailures.removeAll()
        advancedLiveStreamNoResultStreak = 0
        setFinalizingTranscript(false)
        setAppleLiveFinalText(nil)
        resetLivePartialOutputState()
        liveCaptureStartedAt = nil
        activeCaptureSessionID = nil
        lastSessionTranscribeCache = nil
        sessionPreferredLanguageHint = language
        liveLockedLanguage = language
        pendingLiveLockLanguage = nil
        pendingLiveLockConfirmations = 0
        lastLiveResolvedLanguage = nil

        appleLiveStateLock.lock()
        lastNonEmptyLiveTranscriptText = nil
        appleLiveStateLock.unlock()

        Task(priority: .utility) { [liveDecodeCoordinator] in
            await liveDecodeCoordinator.reset()
        }

        publishBackendStatus()
        debugTrace("runtime reason=language_changed language=\(language.rawValue)")
    }
    
    // Safe to call again on relaunch if a previous download was interrupted —
    // the underlying downloader resumes partial files rather than restarting.
    func prepareOnOptIn() async {
        UserDefaults.standard.set(true, forKey: Self.optedInKey)
        modelState = .ready
    }

    /// Call at app launch. Three outcomes:
    /// - never opted in -> stays `.notDownloaded`, show the opt-in CTA
    /// - opted in and model already downloaded -> silently loads, becomes `.ready`
    /// - opted in but download was interrupted (app killed mid-download) ->
    ///   resumes the download automatically, UI should show the progress screen
    func restoreIfAlreadyDownloaded() async {
        guard hasOptedIn else { return }
        await prepareOnOptIn()
    }

    /// Call this at any entry point where the user tries to use the feature
    /// (tap mic, open a voice-note screen, etc). Returns true if usable now;
    /// if false, the caller should navigate to / show the download-progress UI
    /// instead of proceeding, and resume the download if it isn't already running.
    func gateFeatureUsage() async -> Bool {
        await refreshAdvancedAppleTranscriberCapabilityIfNeeded(force: true)
        return true
    }

    // MARK: - Step 2: Mic capture

    func requestMicPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return true
            case .denied:
                return false
            case .undetermined:
                break
            @unknown default:
                break
            }
        } else {
            let permission = AVAudioSession.sharedInstance().recordPermission
            if permission == .granted { return true }
            if permission == .denied { return false }
        }

        return await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    /// Prepares the audio route/session once so the first user tap doesn't pay
    /// the full activation cost on the main interaction path.
    func prewarmRecordingPathIfNeeded() {
        guard !didPrewarmRecordingPath else { return }
        guard case .ready = modelState else { return }
        if #available(iOS 17.0, *) {
            guard AVAudioApplication.shared.recordPermission == .granted else { return }
        } else {
            guard AVAudioSession.sharedInstance().recordPermission == .granted else { return }
        }
        didPrewarmRecordingPath = true

        DispatchQueue.global(qos: .userInitiated).async {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.record, mode: .measurement, options: .duckOthers)
                try session.setActive(true)
                // Touching these upfront avoids some first-use graph costs.
                _ = self.audioEngine.inputNode
                self.audioEngine.prepare()
                try session.setActive(false)
            } catch {
                // Allow retry if warm-up failed.
                DispatchQueue.main.async {
                    self.didPrewarmRecordingPath = false
                }
            }
        }
    }

    func startListening(
        preferredLanguage: SupportedLanguage? = nil,
        autoStopOnSilence: Bool = false,
        silenceDuration: TimeInterval = 1.0,
        silenceThreshold: Float = 0.003
    ) throws {
        let currentModelState = modelState(for: operationMode)
        modelState = currentModelState
        guard case .ready = currentModelState else { throw STTError.notReady }

        self.autoStopOnSilence = autoStopOnSilence
        requiredSilenceDuration = silenceDuration
        self.silenceThreshold = silenceThreshold
        accumulatedSilenceDuration = 0
        accumulatedRecordingDuration = 0
        hasTriggeredAutoStop = false
        liveCaptureStartedAt = Date()
        activeCaptureSessionID = UUID()
        lastSessionTranscribeCache = nil
        hasDisabledSpeechAnalyzerForSession = false
        hasDisabledAdvancedLiveStreamForSession = false
        hasValidatedSpeechAnalyzerForSession = false
        loggedAppleGateFailures.removeAll()
        advancedLiveStreamNoResultStreak = 0
        sessionPreferredLanguageHint = preferredLanguage
        liveLockedLanguage = preferredLanguage
        pendingLiveLockLanguage = nil
        pendingLiveLockConfirmations = 0
        lastLiveResolvedLanguage = nil
        setFinalizingTranscript(false)
        setAppleLiveFinalText(nil)
        advancedLiveStreamNoResultStreak = 0
        resetLivePartialOutputState()
        appleLiveStateLock.lock()
        lastNonEmptyLiveTranscriptText = nil
        appleLiveStateLock.unlock()
        Task(priority: .utility) { [liveDecodeCoordinator] in
            await liveDecodeCoordinator.reset()
        }

        sttSessionStartedAt = Date()
        sttLivePartialSequence = 0
        sttPrimaryEngineForSession = nil
        sttFinalEngineForSession = nil
        sttFallbackOccurred = false
        sttFallbackReason = nil
        sttDidLogRecordingStop = false
        sttDidLogFirstPartialLatency = false
        sttLastPartialLoggedAt = nil
        sttLastStreamUnavailableFallbackLogAt = nil
        sttLastStreamUnavailableFallbackKey = nil
        sttDidLogStartupFallbackWarning = false
        sttAppleLiveTapBufferCount = 0
        sttAppleLiveTapSampleCount = 0
        sttAppleLiveTapFirstBufferAt = nil
        sttAppleLiveTapLastBufferAt = nil
        sttAppleLiveTapLastLogAt = nil
        let requested = preferredLanguage ?? preferredDeviceSupportedLanguage() ?? .english
        let resolvedLocale = speechAnalyzerLocaleHint(for: requested)?.identifier ?? "auto"
        sessionLog(
            "session_start",
            fields: [
                "mode": operationMode.rawValue,
                "requested_language": requested.rawValue,
                "resolved_locale": resolvedLocale,
                "ios": ProcessInfo.processInfo.operatingSystemVersionString,
                "provider": selectedModelProvider.rawValue,
                "platform": currentPlatformLabel()
            ]
        )
        sessionLog("recording_start", fields: ["mode": operationMode.rawValue])

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true)
        } catch {
            throw STTError.audioSessionFailure
        }

        bufferLock.lock()
        sampleBuffer.removeAll()
        bufferLock.unlock()
        if operationMode != .postRecording {
            cleanupPostRecordingAudioFileIfNeeded()
        }

        let input = audioEngine.inputNode
        if hasInputTapInstalled {
            input.removeTap(onBus: 0)
            hasInputTapInstalled = false
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw STTError.audioSessionFailure
        }
        if operationMode == .postRecording {
            try preparePostRecordingAudioFileIfNeeded(format: targetFormat)
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let ratio = self.targetSampleRate / inputFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }

            var convError: NSError?
            converter.convert(to: outBuffer, error: &convError) { _, status in
                status.pointee = .haveData
                return buffer
            }
            guard convError == nil, let channelData = outBuffer.floatChannelData else { return }
            let frames = Array(UnsafeBufferPointer(start: channelData[0], count: Int(outBuffer.frameLength)))

            self.bufferLock.lock()
            self.sampleBuffer.append(contentsOf: frames)
            self.bufferLock.unlock()
            self.appendPostRecordingBufferIfNeeded(outBuffer)

            if self.selectedModelProvider == .appleModels,
               self.useAdvancedAppleLiveTranscribers {
                self.logAppleLiveTapInput(buffer: outBuffer)
                self.pushAudioBufferToAppleLiveSessionIfNeeded(outBuffer)
            }

            let frameDuration = Double(outBuffer.frameLength) / self.targetSampleRate
            self.accumulatedRecordingDuration += frameDuration
            let energy = frames.reduce(0) { partialResult, sample in
                partialResult + (sample * sample)
            }
            let rms = sqrt(energy / Float(max(frames.count, 1)))
            let normalizedLevel = min(max(rms / 0.08, 0), 1)

            DispatchQueue.main.async {
                self.onAudioLevelChange?(normalizedLevel)
            }

            if !self.hasTriggeredAutoStop, self.accumulatedRecordingDuration >= self.maxRecordingDuration {
                self.hasTriggeredAutoStop = true
                DispatchQueue.main.async {
                    guard self.isListening else { return }
                    self.stopListening()
                    self.onSilenceAutoStopTriggered?()
                }
                return
            }

            if self.autoStopOnSilence {
                if rms < self.silenceThreshold {
                    self.accumulatedSilenceDuration += frameDuration
                } else {
                    self.accumulatedSilenceDuration = 0
                }

                if !self.hasTriggeredAutoStop, self.accumulatedSilenceDuration >= self.requiredSilenceDuration {
                    self.hasTriggeredAutoStop = true
                    DispatchQueue.main.async {
                        guard self.isListening else { return }
                        self.stopListening()
                        self.onSilenceAutoStopTriggered?()
                    }
                }
            }
        }
        hasInputTapInstalled = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            hasInputTapInstalled = false
            cleanupPostRecordingAudioFileIfNeeded()
            try? AVAudioSession.sharedInstance().setActive(false)
            throw STTError.audioSessionFailure
        }
        isListening = true
        if selectedModelProvider == .appleModels,
           useAdvancedAppleLiveTranscribers {
            Task(priority: .userInitiated) { [weak self] in
                await self?.startAppleLiveSessionIfNeeded()
            }
        }
    }

    func stopListening() {
        if hasInputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInputTapInstalled = false
        }
        audioEngine.stop()
        finalizePostRecordingAudioFileIfNeeded()
        try? AVAudioSession.sharedInstance().setActive(false)
        isListening = false

        if let sessionID = activeCaptureSessionID, !sttDidLogRecordingStop {
            let recordingDuration = liveCaptureStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            sessionLog(
                "recording_stop",
                sessionID: sessionID,
                fields: [
                    "mode": operationMode.rawValue,
                    "duration_s": String(format: "%.2f", recordingDuration)
                ]
            )
            sttDidLogRecordingStop = true
        }

        onAudioLevelChange?(0)
        accumulatedSilenceDuration = 0
        accumulatedRecordingDuration = 0
        hasTriggeredAutoStop = false
        liveCaptureStartedAt = nil
        resetLivePartialOutputState()
        Task(priority: .utility) { [liveDecodeCoordinator] in
            await liveDecodeCoordinator.reset()
        }
        if #available(iOS 26.0, *),
           selectedModelProvider == .appleModels,
           appleLiveCoordinator != nil {
            Task(priority: .userInitiated) { [weak self] in
                await self?.finalizeAppleLiveSessionIfNeeded()
            }
        }
    }

    @available(iOS 26.0, *)
    private var appleLiveCoordinator: AppleLiveTranscriptionCoordinator? {
        get {
            appleLiveStateLock.lock()
            defer { appleLiveStateLock.unlock() }
            return appleLiveCoordinatorBox as? AppleLiveTranscriptionCoordinator
        }
        set {
            appleLiveStateLock.lock()
            appleLiveCoordinatorBox = newValue
            appleLiveStateLock.unlock()
        }
    }

    private func pushAudioBufferToAppleLiveSessionIfNeeded(_ buffer: AVAudioPCMBuffer) {
        guard #available(iOS 26.0, *), selectedModelProvider == .appleModels, useAdvancedAppleLiveTranscribers else { return }
        guard let appleLiveCoordinator else { return }
        guard let copiedBuffer = copyPCMBuffer(buffer) else { return }
        appleLiveCoordinator.pushBuffer(copiedBuffer)
    }

    private func copyPCMBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameCapacity) else {
            return nil
        }
        copy.frameLength = source.frameLength
        guard let sourceChannelData = source.floatChannelData,
              let copiedChannelData = copy.floatChannelData else {
            return nil
        }
        let channelCount = Int(source.format.channelCount)
        let frameCount = Int(source.frameLength)
        for channel in 0..<channelCount {
            copiedChannelData[channel].update(from: sourceChannelData[channel], count: frameCount)
        }
        return copy
    }

    private func startAppleLiveSessionIfNeeded() async {
        // Start exactly one live analyzer session per recording start.
        // This removes the old per-tick session churn that caused UI stalls.
        guard #available(iOS 26.0, *), selectedModelProvider == .appleModels else { return }

        guard beginAppleLiveSessionStartIfNeeded() else { return }

        defer {
            endAppleLiveSessionStartIfNeeded()
        }

        do {
            armAppleAdvancedPath()
            let coordinator = AppleLiveTranscriptionCoordinator()
            let language = liveLockedLanguage
                ?? sessionPreferredLanguageHint
                ?? pendingLiveLockLanguage
                ?? preferredDeviceSupportedLanguage()
                ?? .english
            let localeHint = speechAnalyzerLocaleHint(for: language)
            sessionLog(
                "apple_live_session_start",
                fields: [
                    "mode": operationMode.rawValue,
                    "language": language.rawValue,
                    "resolved_locale": localeHint?.identifier ?? "auto",
                    "engine": "dictationTranscriber",
                    "phase": "attempt",
                    "ios": ProcessInfo.processInfo.operatingSystemVersionString,
                    "elapsed_ms": "\(sttSessionStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0)"
                ]
            )
            _ = try await coordinator.start(localeHint: localeHint, ownerSessionID: activeCaptureSessionID)
            sessionLog(
                "apple_live_session_start",
                fields: [
                    "mode": operationMode.rawValue,
                    "language": language.rawValue,
                    "resolved_locale": localeHint?.identifier ?? "auto",
                    "engine": "dictationTranscriber",
                    "phase": "running",
                    "elapsed_ms": "\(sttSessionStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0)"
                ]
            )
            appleLiveCoordinator = coordinator
        } catch {
            disarmAppleAdvancedPath()
            hasDisabledAdvancedLiveStreamForSession = true
            let nsError = error as NSError
            sessionLog(
                "apple_live_error",
                fields: [
                    "mode": operationMode.rawValue,
                    "phase": "session_start",
                    "domain": nsError.domain,
                    "code": "\(nsError.code)",
                    "reason": error.localizedDescription,
                    "elapsed_ms": "\(sttSessionStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0)"
                ]
            )
            debugTrace("live_stream session_start_failed fallback=windowed_partial error=\(error.localizedDescription)")
        }
    }

    private func finalizeAppleLiveSessionIfNeeded() async {
        // Finalize once on stop so volatile tail is committed before UI close.
        guard #available(iOS 26.0, *) else { return }

        guard let coordinator = takeAppleLiveCoordinator() else { return }

        do {
            try await coordinator.stop(finalize: true)
            disarmAppleAdvancedPath()
            let language = liveLockedLanguage ?? lastLiveResolvedLanguage ?? preferredDeviceSupportedLanguage() ?? .english
            let finalFromCoordinator = coordinator.latestLivePartial(language: language)?.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let finalFromHistory = getLastNonEmptyLiveTranscriptText()?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedFinalText: String?
            if let finalFromCoordinator, !finalFromCoordinator.isEmpty {
                resolvedFinalText = finalFromCoordinator
            } else if let finalFromHistory, !finalFromHistory.isEmpty {
                resolvedFinalText = finalFromHistory
            } else {
                resolvedFinalText = nil
            }
            setAppleLiveFinalText(resolvedFinalText)
        } catch {
        }
    }

    private func latestAppleLivePartialResult(preferredLanguage: SupportedLanguage?) -> LivePartialResult? {
        guard #available(iOS 26.0, *) else { return nil }
        let language = preferredLanguage ?? liveLockedLanguage ?? lastLiveResolvedLanguage ?? preferredDeviceSupportedLanguage() ?? .english

        appleLiveStateLock.lock()
        let coordinator = appleLiveCoordinatorBox as? AppleLiveTranscriptionCoordinator
        appleLiveStateLock.unlock()
        let partial = coordinator?.latestLivePartial(language: language)
        if let text = partial?.text {
            rememberLiveTranscriptTextIfNonEmpty(text)
        }
        return partial
    }

    // MARK: - Step 3: Transcription

    /// Stops listening (if active) and returns transcript text plus language used.
    /// In live-streaming mode, this final decode is performed with the Small model
    /// for higher post-recording accuracy.
    func transcribe(preferredLanguage: SupportedLanguage? = nil) async throws -> (text: String, language: SupportedLanguage) {
        let transcribeModeSnapshot = operationMode
        if let activeCaptureSessionID,
           let cache = lastSessionTranscribeCache,
           cache.sessionID == activeCaptureSessionID,
           Date().timeIntervalSince(cache.timestamp) < 3.0 {
            debugTrace("transcribe dedupe reuse session=\(activeCaptureSessionID.uuidString)")
            return cache.result
        }
        if let preferredLanguage {
            sessionPreferredLanguageHint = preferredLanguage
            liveLockedLanguage = preferredLanguage
        }
        setFinalizingTranscript(true)
        defer { setFinalizingTranscript(false) }
        debugTrace("transcribe begin mode=\(transcribeModeSnapshot.rawValue) preferred=\(preferredLanguage?.rawValue ?? "auto")")
        let requestedLanguage = preferredLanguage ?? effectiveSessionLanguage(preferredLanguage: preferredLanguage)
        sessionLog(
            "transcription_start",
            fields: [
                "mode": transcribeModeSnapshot.rawValue,
                "requested_language": requestedLanguage.rawValue,
                "resolved_locale": (speechAnalyzerLocaleHint(for: requestedLanguage)?.identifier ?? "auto")
            ]
        )
        defer {
            sessionLog("cleanup_start", fields: ["mode": operationMode.rawValue])
            if operationMode == .postRecording {
                cleanupPostRecordingAudioFileIfNeeded()
            }
            sessionLog("cleanup_complete", fields: ["mode": operationMode.rawValue])
        }
        if #available(iOS 26.0, *),
           appleLiveCoordinator != nil {
            await finalizeAppleLiveSessionIfNeeded()
        }
        debugLogRuntimeConfiguration(reason: "final_transcribe", modeOverride: transcribeModeSnapshot)
        let finalRoute = resolvedFinalTranscriptionRoute()
        let preferredEngine = finalRoute.engine
        sttPrimaryEngineForSession = preferredEngine
        sessionLog(
            "engine_selected",
            fields: [
                "mode": transcribeModeSnapshot.rawValue,
                "engine": engineDisplayName(preferredEngine),
                "platform": currentPlatformLabel()
            ]
        )
        debugLogEngineSelection(
            phase: "final_transcribe",
            engine: preferredEngine,
            detail: "mode=\(transcribeModeSnapshot.rawValue) preferredLanguage=\(preferredLanguage?.rawValue ?? "auto") route=\(finalRoute.rawValue) analyzer_gate=\(speechAnalyzerGateReason)"
        )
        let finalResult: (text: String, language: SupportedLanguage)
        do {
            switch finalRoute {
            case .ios26LiveDictation:
                finalResult = try await transcribeFinalWithDictationTranscriber(preferredLanguage: preferredLanguage)
            case .ios26PostSpeechTranscriber:
                finalResult = try await transcribeFinalWithSpeechTranscriber(preferredLanguage: preferredLanguage)
            case .cloudAPI:
                finalResult = try await transcribeFinalWithCloudAPI(preferredLanguage: preferredLanguage)
            }
        } catch {
            let finalEngine = sttFinalEngineForSession ?? preferredEngine
            let totalDuration = sttSessionStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            sessionLog(
                "transcription_complete",
                fields: [
                    "mode": transcribeModeSnapshot.rawValue,
                    "requested_language": requestedLanguage.rawValue,
                    "primary_engine": engineDisplayName(preferredEngine),
                    "final_engine": engineDisplayName(finalEngine),
                    "result": "failure",
                    "chars": "0",
                    "fallback": sttFallbackOccurred ? "true" : "false",
                    "fallback_reason": sttFallbackReason ?? "",
                    "duration_s": String(format: "%.2f", totalDuration),
                    "error": error.localizedDescription
                ]
            )
            sessionLog(
                "session_end",
                fields: [
                    "result": "failure",
                    "total_duration_s": String(format: "%.2f", totalDuration)
                ]
            )
            throw error
        }
        debugTrace("transcribe end mode=\(transcribeModeSnapshot.rawValue) lang=\(finalResult.language.rawValue) chars=\(finalResult.text.count)")
        let finalEngine = sttFinalEngineForSession ?? preferredEngine
        let totalDuration = sttSessionStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        sessionLog(
            "transcription_complete",
            fields: [
                "mode": transcribeModeSnapshot.rawValue,
                "requested_language": requestedLanguage.rawValue,
                "resolved_locale": (speechAnalyzerLocaleHint(for: finalResult.language)?.identifier ?? "auto"),
                "primary_engine": engineDisplayName(preferredEngine),
                "final_engine": engineDisplayName(finalEngine),
                "result": finalResult.text.isEmpty ? "empty" : "success",
                "chars": "\(finalResult.text.count)",
                "fallback": sttFallbackOccurred ? "true" : "false",
                "fallback_reason": sttFallbackReason ?? "",
                "duration_s": String(format: "%.2f", totalDuration)
            ]
        )
        sessionLog(
            "session_end",
            fields: [
                "result": finalResult.text.isEmpty ? "empty" : "success",
                "total_duration_s": String(format: "%.2f", totalDuration)
            ]
        )
        if let activeCaptureSessionID {
            lastSessionTranscribeCache = SessionTranscribeCache(
                sessionID: activeCaptureSessionID,
                result: finalResult,
                timestamp: Date()
            )
        }
        return finalResult
    }

    /// Lightweight partial transcription for live preview while recording.
    /// Uses a short rolling audio window to keep decoding fast.
    func transcribePartialCurrentBuffer(
        preferredLanguage: SupportedLanguage? = nil,
        maxAudioSeconds: Double = 8.0,
        minimumAudioSeconds: Double = 0.8
    ) async throws -> LivePartialResult? {
        if getFinalizingTranscript() { return nil }
        if let preferredLanguage {
            sessionPreferredLanguageHint = preferredLanguage
            liveLockedLanguage = preferredLanguage
        }
        debugLogRuntimeConfiguration(reason: "live_partial")
        let preferredEngine = preferredLivePartialEngine()
        debugLogEngineSelection(
            phase: "live_partial",
            engine: preferredEngine,
            detail: "mode=\(operationMode.rawValue) preferredLanguage=\(preferredLanguage?.rawValue ?? "auto") analyzer_gate=\(speechAnalyzerGateReason)"
        )

        if #available(iOS 26.0, *) {
            let useAdvancedStream = useAdvancedAppleLiveTranscribers
            if useAdvancedStream {
                let isFrenchSession = isFrenchLiveSession(preferredLanguage: preferredLanguage)
                let startupGraceSeconds = advancedLiveStreamStartupGraceSeconds + (isFrenchSession ? advancedLiveStreamStartupGraceSecondsFrenchBoost : 0)
                let noResultDisableThreshold = advancedLiveStreamNoResultDisableThreshold + (isFrenchSession ? advancedLiveStreamNoResultDisableThresholdFrenchBoost : 0)
                let noResultMinimumLiveSeconds = advancedLiveStreamNoResultMinimumLiveSeconds + (isFrenchSession ? advancedLiveStreamNoResultMinimumLiveSecondsFrenchBoost : 0)
                // Apple path: use one continuous analyzer session and read snapshots,
                // instead of re-transcribing rolling windows every tick.
                if appleLiveCoordinator == nil {
                    await startAppleLiveSessionIfNeeded()
                }
                let result = latestAppleLivePartialResult(preferredLanguage: preferredLanguage)
                if let result {
                    advancedLiveStreamNoResultStreak = 0
                    return publishLivePartialResultIfMeaningful(result, phase: "live_partial_stream")
                } else {
                    let liveElapsed = liveCaptureStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                    if liveElapsed < startupGraceSeconds {
                        // Dictation stream frequently needs a short warm-up; avoid noisy
                        // early fallback churn before first stream hypotheses arrive.
                        return nil
                    }
                    let liveSnapshot = appleLiveCoordinator?.diagnosticsSnapshot()
                    let shouldIncrementNoResultStreak =
                        (liveSnapshot?.state == "running") &&
                        (liveSnapshot?.hasReceivedBuffer == true)
                    if shouldIncrementNoResultStreak {
                        advancedLiveStreamNoResultStreak += 1
                    }
                    logAppleLiveNoResultDiagnostics(snapshot: liveSnapshot, liveElapsed: liveElapsed)
                    logStartupFallbackWarningOnce(
                        key: "windowed_partial:no_stream_result",
                        message: "live_partial stream_unavailable fallback=windowed_partial reason=no_stream_result"
                    )
                    if advancedLiveStreamNoResultStreak >= noResultDisableThreshold,
                       liveElapsed >= noResultMinimumLiveSeconds,
                       !hasDisabledAdvancedLiveStreamForSession {
                        hasDisabledAdvancedLiveStreamForSession = true
                        debugTrace(
                            "live_stream disabled_for_session reason=no_stream_result_streak count=\(advancedLiveStreamNoResultStreak) live_s=\(String(format: "%.2f", liveElapsed))"
                        )
                    }
                }
            }
            if operationMode == .liveStreaming {
                logStartupFallbackWarningOnce(
                    key: "streaming_speech_recognizer",
                    message: "live_partial stream_unavailable fallback=streaming_speech_recognizer"
                )
            } else if canUseSpeechAnalyzer {
                logStartupFallbackWarningOnce(
                    key: "windowed_speech_analyzer",
                    message: "live_partial stream_unavailable fallback=windowed_speech_analyzer"
                )
            }
        }

        switch preferredEngine {
        case .speechTranscriber:
            do {
                let transcriberResult = try await transcribePartialCurrentBufferWithSpeechAnalyzer(
                    preferredLanguage: preferredLanguage,
                    maxAudioSeconds: maxAudioSeconds,
                    minimumAudioSeconds: minimumAudioSeconds
                )
                return publishLivePartialResultIfMeaningful(transcriberResult, phase: "speech_transcriber_partial")
            } catch {
                if shouldDisableSpeechAnalyzer(for: error) {
                    hasDisabledSpeechAnalyzerForSession = true
                    publishBackendStatus()
                    debugTrace("speech_transcriber_partial disable_for_session reason=\(error.localizedDescription)")
                }
                debugTrace("speech_transcriber_partial error reason=\(error.localizedDescription)")
                return nil
            }
        case .dictationTranscriber:
            let result = latestAppleLivePartialResult(preferredLanguage: preferredLanguage)
            return publishLivePartialResultIfMeaningful(result, phase: "dictation_partial")
        case .cloudAPI:
            // Cloud API does not support live partial transcription.
            return nil
        }
    }

    private func beginLivePartialDecodeIfPossible() async -> Bool {
        await liveDecodeCoordinator.tryBegin(now: Date())
    }

    private func snapshotAudioBuffer() -> [Float] {
        bufferLock.withLock {
            sampleBuffer
        }
    }

    private func preparePostRecordingAudioFileIfNeeded(format: AVAudioFormat) throws {
        guard operationMode == .postRecording else { return }
        cleanupPostRecordingAudioFileIfNeeded()
        let fileName = "stt-post-\(UUID().uuidString).wav"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        let audioFile = try AVAudioFile(forWriting: fileURL, settings: format.settings)
        postRecordingFileLock.lock()
        postRecordingAudioFile = audioFile
        postRecordingAudioFileURL = fileURL
        postRecordingAudioFileFinalized = false
        postRecordingFileLock.unlock()
        debugTrace("post_recording file_opened path=\(fileURL.lastPathComponent) sample_rate=\(Int(format.sampleRate)) channels=\(format.channelCount)")
        sessionLog(
            "file_opened",
            fields: [
                "mode": operationMode.rawValue,
                "source": "post_recording_file",
                "path": fileURL.lastPathComponent,
                "sample_rate": "\(Int(format.sampleRate))",
                "channels": "\(format.channelCount)"
            ]
        )
    }

    private func appendPostRecordingBufferIfNeeded(_ buffer: AVAudioPCMBuffer) {
        guard operationMode == .postRecording else { return }
        postRecordingFileLock.lock()
        let file = postRecordingAudioFile
        postRecordingFileLock.unlock()
        guard let file else { return }
        do {
            try file.write(from: buffer)
        } catch {
        }
    }

    private func finalizePostRecordingAudioFileIfNeeded() {
        guard operationMode == .postRecording else { return }
        postRecordingFileLock.lock()
        let alreadyFinalized = postRecordingAudioFileFinalized
        postRecordingAudioFile = nil
        let fileURL = postRecordingAudioFileURL
        if !alreadyFinalized {
            postRecordingAudioFileFinalized = true
        }
        postRecordingFileLock.unlock()
        guard !alreadyFinalized else { return }
        guard let fileURL else { return }
        debugTrace("post_recording file_finalize path=\(fileURL.lastPathComponent)")
        sessionLog(
            "file_finalize",
            fields: [
                "mode": operationMode.rawValue,
                "source": "post_recording_file",
                "path": fileURL.lastPathComponent
            ]
        )
        do {
            _ = try AVAudioFile(forReading: fileURL)
            sessionLog(
                "file_validation",
                fields: [
                    "mode": operationMode.rawValue,
                    "source": "post_recording_file",
                    "path": fileURL.lastPathComponent,
                    "readable": "true"
                ]
            )
        } catch {
            sessionLog(
                "file_validation",
                fields: [
                    "mode": operationMode.rawValue,
                    "source": "post_recording_file",
                    "path": fileURL.lastPathComponent,
                    "readable": "false",
                    "reason": error.localizedDescription
                ]
            )
        }
    }

    private func loadPostRecordingAudioSamplesIfAvailable() throws -> [Float]? {
        guard operationMode == .postRecording else { return nil }
        postRecordingFileLock.lock()
        let fileURL = postRecordingAudioFileURL
        postRecordingFileLock.unlock()
        guard let fileURL else { return nil }

        let file = try AVAudioFile(forReading: fileURL)
        let sourceFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return [] }
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw STTError.audioSessionFailure
        }
        try file.read(into: sourceBuffer)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw STTError.audioSessionFailure
        }

        let outCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * (targetSampleRate / sourceFormat.sampleRate)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw STTError.audioSessionFailure
        }

        var conversionError: NSError?
        var didProvideSourceBuffer = false
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if didProvideSourceBuffer {
                status.pointee = .endOfStream
                return nil
            }
            didProvideSourceBuffer = true
            status.pointee = .haveData
            return sourceBuffer
        }
        if let conversionError {
            throw conversionError
        }
        guard let channelData = outputBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }

    private func finalAudioForTranscription() throws -> [Float] {
        if operationMode == .postRecording {
            finalizePostRecordingAudioFileIfNeeded()
            if let postAudio = try loadPostRecordingAudioSamplesIfAvailable(),
               !postAudio.isEmpty {
                let duration = Double(postAudio.count) / targetSampleRate
                let fileSizeBytes: Int64 = postRecordingFileLock.withLock {
                    guard let fileURL = postRecordingAudioFileURL else { return 0 }
                    let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                    return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                }
                debugTrace("final_audio source=post_recording_file samples=\(postAudio.count) audio_s=\(String(format: "%.2f", duration))")
                sessionLog(
                    "input_ready",
                    fields: [
                        "source": "post_recording_file",
                        "duration_s": String(format: "%.2f", duration),
                        "sample_rate": "\(Int(targetSampleRate))",
                        "channels": "1",
                        "samples": "\(postAudio.count)",
                        "file_size_bytes": "\(fileSizeBytes)"
                    ]
                )
                return postAudio
            }
        }
        let audio = snapshotAudioBuffer()
        guard !audio.isEmpty else { throw STTError.emptyRecording }
        let duration = Double(audio.count) / targetSampleRate
        debugTrace("final_audio source=live_buffer samples=\(audio.count) audio_s=\(String(format: "%.2f", duration))")
        sessionLog(
            "input_ready",
            fields: [
                "source": "live_audio_buffer",
                "duration_s": String(format: "%.2f", duration),
                "sample_rate": "\(Int(targetSampleRate))",
                "channels": "1",
                "samples": "\(audio.count)"
            ]
        )
        return audio
    }

    private func finalAudioForTranscriptionAsync() async throws -> [Float] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: STTError.audioSessionFailure)
                    return
                }
                do {
                    continuation.resume(returning: try self.finalAudioForTranscription())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func cleanupPostRecordingAudioFileIfNeeded() {
        postRecordingFileLock.lock()
        postRecordingAudioFile = nil
        let fileURL = postRecordingAudioFileURL
        postRecordingAudioFileURL = nil
        postRecordingAudioFileFinalized = false
        postRecordingFileLock.unlock()
        guard let fileURL else { return }
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
                debugTrace("post_recording file_cleanup path=\(fileURL.lastPathComponent)")
                sessionLog(
                    "audio_file_cleanup",
                    fields: [
                        "mode": operationMode.rawValue,
                        "path": fileURL.lastPathComponent,
                        "success": "true"
                    ]
                )
            }
        } catch {
        }
    }

    /// Current captured audio duration while recording.
    /// Used by live UI scheduler to avoid ultra-early partial decode churn.
    func currentBufferedAudioSeconds() -> Double {
        let samples = bufferLock.withLock { sampleBuffer.count }
        return Double(samples) / targetSampleRate
    }

    private func recentAudioWindow(_ audio: [Float], maxSeconds: Double) -> [Float] {
        let maxSamples = Int(targetSampleRate * max(1.0, maxSeconds))
        guard audio.count > maxSamples else { return audio }
        return Array(audio.suffix(maxSamples))
    }

    private func preferredDeviceSupportedLanguage() -> SupportedLanguage? {
        guard let preferredLocale = Locale.preferredLanguages.first?.lowercased() else {
            return nil
        }

        if preferredLocale.hasPrefix("en") { return .english }
        if preferredLocale.hasPrefix("es") { return .spanish }
        if preferredLocale.hasPrefix("fr") { return .french }
        return nil
    }

    private enum FinalTranscriptionRoute: String {
        case ios26LiveDictation
        case ios26PostSpeechTranscriber
        case cloudAPI

        var engine: TranscriptionEngine {
            switch self {
            case .ios26LiveDictation:
                return .dictationTranscriber
            case .ios26PostSpeechTranscriber:
                return .speechTranscriber
            case .cloudAPI:
                return .cloudAPI
            }
        }
    }

    private func resolvedFinalTranscriptionRoute() -> FinalTranscriptionRoute {
        guard #available(iOS 26.0, *) else {
            // Below iOS 26: always route to cloud API (record → encode → cloud transcription)
            return .cloudAPI
        }
        switch operationMode {
        case .liveStreaming:
            // iOS 26+: final live transcription should be based on runtime dictation
            // capability, independent from whether live streaming was disabled mid-session.
            // This keeps final decode on-device even when stream partials fallback.
            appleCapabilityLock.lock()
            let dictationCapable = advancedDictationTranscriberCapable
            appleCapabilityLock.unlock()
            return (canUseSpeechAnalyzer && dictationCapable) ? .ios26LiveDictation : .cloudAPI
        case .postRecording:
            // iOS 26+: prefer SpeechTranscriber when the device supports it;
            // fall back to cloud API otherwise.
            appleCapabilityLock.lock()
            let speechCapable = advancedSpeechTranscriberCapable
            appleCapabilityLock.unlock()
            return (canUseSpeechAnalyzer && speechCapable) ? .ios26PostSpeechTranscriber : .cloudAPI
        }
    }
    
    private func preferredLivePartialEngine() -> TranscriptionEngine {
        if #available(iOS 26.0, *) {
            if operationMode == .liveStreaming {
                return useAdvancedAppleLiveTranscribers ? .dictationTranscriber : .cloudAPI
            }
            return canUseSpeechAnalyzer ? .speechTranscriber : .cloudAPI
        }
        // Below iOS 26: cloud API only — no live partial transcription available
        return .cloudAPI
    }
    
    private var canAttemptSpeechAnalyzer: Bool {
        guard selectedModelProvider == .appleModels else { return false }
        guard !hasDisabledSpeechAnalyzerForSession else { return false }
        guard #available(iOS 26.0, *) else { return false }
        guard !isAppleAdvancedPathQuarantined() else { return false }
        // SpeechAnalyzer availability must not be coupled to advanced live-stream
        // opt-in/capability (SpeechTranscriber-specific gate).
        return true
    }

    private var canUseSpeechAnalyzer: Bool {
        canAttemptSpeechAnalyzer
    }

    private var speechAnalyzerGateReason: String {
        if selectedModelProvider != .appleModels { return "provider_not_apple_models" }
        if hasDisabledSpeechAnalyzerForSession { return "disabled_for_session" }
        if #unavailable(iOS 26.0) { return "ios_below_26" }
        if isAppleAdvancedPathQuarantined() { return "advanced_path_quarantined" }
        return "available"
    }

    private func isUsableTranscript(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func transcribeFinalWithDictationTranscriber(preferredLanguage: SupportedLanguage?) async throws -> (text: String, language: SupportedLanguage) {
        let startedAt = Date()
        sessionLog("engine_start", fields: ["engine": engineDisplayName(.dictationTranscriber), "mode": operationMode.rawValue])
        do {
            let dictationResult = try await transcribeWithDictationTranscriber(preferredLanguage: preferredLanguage)
            if isUsableTranscript(dictationResult.text) {
                sttFinalEngineForSession = .dictationTranscriber
                sessionLog(
                    "engine_success",
                    fields: [
                        "engine": engineDisplayName(.dictationTranscriber),
                        "chars": "\(dictationResult.text.count)",
                        "language": dictationResult.language.rawValue,
                        "latency_ms": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
                    ]
                )
                return dictationResult
            }
            sessionLog("engine_empty", fields: ["engine": engineDisplayName(.dictationTranscriber)])
            sttFallbackOccurred = true
            sttFallbackReason = "empty_result"
            sessionLog("fallback_start", fields: ["from": engineDisplayName(.dictationTranscriber), "to": engineDisplayName(.cloudAPI), "reason": "empty_result"])
            debugTrace("fallback source=dictationTranscriber target=cloudAPI reason=empty_transcript")
        } catch {
            sttFallbackOccurred = true
            sttFallbackReason = error.localizedDescription
            sessionLog("engine_error", fields: ["engine": engineDisplayName(.dictationTranscriber), "reason": error.localizedDescription])
            sessionLog("fallback_start", fields: ["from": engineDisplayName(.dictationTranscriber), "to": engineDisplayName(.cloudAPI), "reason": error.localizedDescription])
            debugTrace("fallback source=dictationTranscriber target=cloudAPI reason=\(error.localizedDescription)")
        }
        return try await transcribeWithCloudAPI(preferredLanguage: preferredLanguage)
    }

    private func transcribeFinalWithSpeechTranscriber(preferredLanguage: SupportedLanguage?) async throws -> (text: String, language: SupportedLanguage) {
        let startedAt = Date()
        sessionLog("engine_start", fields: ["engine": engineDisplayName(.speechTranscriber), "mode": operationMode.rawValue])
        do {
            let transcriberResult = try await transcribeWithSpeechTranscriber(preferredLanguage: preferredLanguage)
            if isUsableTranscript(transcriberResult.text) {
                sttFinalEngineForSession = .speechTranscriber
                sessionLog(
                    "engine_success",
                    fields: [
                        "engine": engineDisplayName(.speechTranscriber),
                        "chars": "\(transcriberResult.text.count)",
                        "language": transcriberResult.language.rawValue,
                        "latency_ms": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
                    ]
                )
                return transcriberResult
            }
            sessionLog("engine_empty", fields: ["engine": engineDisplayName(.speechTranscriber)])
            sttFallbackOccurred = true
            sttFallbackReason = "empty_result"
            sessionLog("fallback_start", fields: ["from": engineDisplayName(.speechTranscriber), "to": engineDisplayName(.cloudAPI), "reason": "empty_result"])
            debugTrace("fallback source=speechTranscriber target=cloudAPI reason=empty_transcript")
        } catch {
            if shouldDisableSpeechAnalyzer(for: error) {
                hasDisabledSpeechAnalyzerForSession = true
                publishBackendStatus()
            }
            sttFallbackOccurred = true
            sttFallbackReason = error.localizedDescription
            sessionLog("engine_error", fields: ["engine": engineDisplayName(.speechTranscriber), "reason": error.localizedDescription])
            sessionLog("fallback_start", fields: ["from": engineDisplayName(.speechTranscriber), "to": engineDisplayName(.cloudAPI), "reason": error.localizedDescription])
            debugTrace("fallback source=speechTranscriber target=cloudAPI reason=\(error.localizedDescription)")
        }
        return try await transcribeWithCloudAPI(preferredLanguage: preferredLanguage)
    }

    private func transcribeFinalWithCloudAPI(preferredLanguage: SupportedLanguage?) async throws -> (text: String, language: SupportedLanguage) {
        let startedAt = Date()
        sessionLog("engine_start", fields: ["engine": engineDisplayName(.cloudAPI), "mode": operationMode.rawValue])
        do {
            let result = try await transcribeWithCloudAPI(preferredLanguage: preferredLanguage)
            sttFinalEngineForSession = .cloudAPI
            sessionLog(
                sttFallbackOccurred ? "fallback_success" : "engine_success",
                fields: [
                    "engine": engineDisplayName(.cloudAPI),
                    "chars": "\(result.text.count)",
                    "language": result.language.rawValue,
                    "latency_ms": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
                ]
            )
            return result
        } catch {
            sessionLog(
                sttFallbackOccurred ? "fallback_failed" : "engine_error",
                fields: [
                    "engine": engineDisplayName(.cloudAPI),
                    "reason": error.localizedDescription
                ]
            )
            throw error
        }
    }

    private func transcribeWithCloudAPI(preferredLanguage: SupportedLanguage?) async throws -> (text: String, language: SupportedLanguage) {
        if isListening { stopListening() }
        let audio = try await finalAudioForTranscriptionAsync()
        let languageHint = effectiveSessionLanguage(preferredLanguage: preferredLanguage)
        let localeHint = speechAnalyzerLocaleHint(for: languageHint)
        let engine = CloudTranscriptionEngine()
        debugLogEngineSelection(
            phase: "cloud_api_final",
            engine: .cloudAPI,
            detail: "localeHint=\(localeHint?.identifier ?? "auto") audio_s=\(String(format: "%.2f", Double(audio.count) / targetSampleRate))"
        )
        let output = try await engine.transcribe(
            TranscriptionRequest(
                audio: audio,
                sampleRate: targetSampleRate,
                localeHint: localeHint,
                timeoutInterval: nil
            )
        )
        let resolvedLanguage = supportedLanguage(from: output.locale, fallback: languageHint)
        lastLiveResolvedLanguage = resolvedLanguage
        return (output.text, resolvedLanguage)
    }

    private func transcribeWithSpeechTranscriber(preferredLanguage: SupportedLanguage?) async throws -> (text: String, language: SupportedLanguage) {
        guard #available(iOS 26.0, *), canUseSpeechAnalyzer else { throw STTError.notReady }
        if isListening { stopListening() }
        let audio = try await finalAudioForTranscriptionAsync()
        let languageHint = effectiveSessionLanguage(preferredLanguage: preferredLanguage)
        let localeHint = speechAnalyzerLocaleHint(for: languageHint)
        guard let analyzerLocale = await resolveSupportedSpeechAnalyzerLocale(for: languageHint) else {
            debugTrace("speech_transcriber_final unsupported_locale language=\(languageHint.rawValue) preferred=\(localeHint?.identifier ?? "auto")")
            throw TranscriptionEngineError.unsupportedLocale
        }
        let engine = SpeechTranscriberEngine()
        let audioSeconds = Double(audio.count) / targetSampleRate
        debugLogEngineSelection(
            phase: "speech_transcriber_final",
            engine: .speechTranscriber,
            detail: "preset=transcription localeHint=\(analyzerLocale.identifier) audio_s=\(String(format: "%.2f", audioSeconds))"
        )
        let output = try await engine.transcribe(
            TranscriptionRequest(
                audio: audio,
                sampleRate: targetSampleRate,
                localeHint: analyzerLocale,
                timeoutInterval: nil
            )
        )
        let resolvedLanguage = supportedLanguage(from: output.locale, fallback: languageHint)
        lastLiveResolvedLanguage = resolvedLanguage
        return (output.text, resolvedLanguage)
    }

    private func transcribeWithDictationTranscriber(preferredLanguage: SupportedLanguage?) async throws -> (text: String, language: SupportedLanguage) {
        guard #available(iOS 26.0, *) else {
            return try await transcribeWithCloudAPI(preferredLanguage: preferredLanguage)
        }

        let streamFinalLanguage = preferredLanguage ?? liveLockedLanguage ?? lastLiveResolvedLanguage ?? preferredDeviceSupportedLanguage() ?? .english
        let streamFinalText: String? = {
            guard operationMode == .liveStreaming else { return nil }
            if let liveFinal = getAppleLiveFinalText()?.trimmingCharacters(in: .whitespacesAndNewlines), !liveFinal.isEmpty {
                return liveFinal
            }
            if let lastNonEmpty = getLastNonEmptyLiveTranscriptText()?.trimmingCharacters(in: .whitespacesAndNewlines), !lastNonEmpty.isEmpty {
                return lastNonEmpty
            }
            return nil
        }()
        if let streamFinalText {
            return (streamFinalText, streamFinalLanguage)
        }

        if isListening { stopListening() }
        let audio = try await finalAudioForTranscriptionAsync()
        let languageHint = effectiveSessionLanguage(preferredLanguage: preferredLanguage)
        let localeHint = speechAnalyzerLocaleHint(for: languageHint)
        let engine = DictationTranscriberEngine()
        debugLogEngineSelection(
            phase: "dictation_transcriber_final",
            engine: .dictationTranscriber,
            detail: "localeHint=\(localeHint?.identifier ?? "auto") audio_s=\(String(format: "%.2f", Double(audio.count) / targetSampleRate))"
        )
        let output = try await engine.transcribe(
            TranscriptionRequest(
                audio: audio,
                sampleRate: targetSampleRate,
                localeHint: localeHint,
                timeoutInterval: nil
            )
        )
        let decodedText = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if operationMode == .liveStreaming,
           let lateStreamFinalText = getAppleLiveFinalText()?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? getLastNonEmptyLiveTranscriptText()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !lateStreamFinalText.isEmpty,
           !decodedText.isEmpty,
           Double(decodedText.count) < (Double(lateStreamFinalText.count) * 0.70) {
            return (lateStreamFinalText, streamFinalLanguage)
        }
        let resolvedLanguage = supportedLanguage(from: output.locale, fallback: languageHint)
        lastLiveResolvedLanguage = resolvedLanguage
        return (decodedText, resolvedLanguage)
    }

    private func transcribePartialCurrentBufferWithSpeechAnalyzer(
        preferredLanguage: SupportedLanguage?,
        maxAudioSeconds: Double,
        minimumAudioSeconds: Double
    ) async throws -> LivePartialResult? {
        guard #available(iOS 26.0, *), canUseSpeechAnalyzer else { throw STTError.notReady }
        guard await beginLivePartialDecodeIfPossible() else { return nil }
        defer {
            Task(priority: .utility) { [liveDecodeCoordinator] in
                await liveDecodeCoordinator.end()
            }
        }

        let fullAudio = snapshotAudioBuffer()
        let minimumSamples = Int(targetSampleRate * max(0.2, minimumAudioSeconds))
        guard fullAudio.count >= minimumSamples else { return nil }

        let audioWindow = recentAudioWindow(fullAudio, maxSeconds: maxAudioSeconds)
        let windowStartSample = max(0, fullAudio.count - audioWindow.count)
        let windowStartTime = TimeInterval(windowStartSample) / targetSampleRate
        let windowEndTime = TimeInterval(fullAudio.count) / targetSampleRate
        let languageHint = effectiveSessionLanguage(preferredLanguage: preferredLanguage)
        let localeHint = speechAnalyzerLocaleHint(for: languageHint)
        guard let analyzerLocale = await resolveSupportedSpeechAnalyzerLocale(for: languageHint) else {
            debugTrace("speech_analyzer_partial unsupported_locale language=\(languageHint.rawValue) preferred=\(localeHint?.identifier ?? "auto")")
            throw SpeechAnalyzerTranscriptionEngine.EngineError.unsupportedLocale
        }
        let engine = SpeechAnalyzerTranscriptionEngine()
        let audioSeconds = Double(audioWindow.count) / targetSampleRate
        debugLogEngineSelection(
            phase: "speech_analyzer_partial",
            engine: .speechTranscriber,
            detail: "preset=progressiveTranscription localeHint=\(analyzerLocale.identifier) window_s=\(String(format: "%.2f", audioSeconds))"
        )
        let output = try await engine.transcribe(
            audio: audioWindow,
            sampleRate: targetSampleRate,
            localeHint: analyzerLocale,
            preset: .progressiveTranscription
        )

        let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let resolvedLanguage = supportedLanguage(from: output.locale, fallback: languageHint)
        if sessionPreferredLanguageHint == nil {
            if pendingLiveLockLanguage == resolvedLanguage {
                pendingLiveLockConfirmations += 1
            } else {
                pendingLiveLockLanguage = resolvedLanguage
                pendingLiveLockConfirmations = 1
            }
            if pendingLiveLockConfirmations >= liveLanguageLockConfirmationsRequired {
                liveLockedLanguage = resolvedLanguage
            }
        }
        lastLiveResolvedLanguage = resolvedLanguage
        await liveDecodeCoordinator.markTextEmitted()

        let segments = [
            LiveTranscriptSegment(
                startTime: windowStartTime,
                endTime: windowEndTime,
                text: text
            )
        ]
        return LivePartialResult(
            text: text,
            language: resolvedLanguage,
            windowStartTime: windowStartTime,
            windowEndTime: windowEndTime,
            segments: segments
        )
    }

    private func shouldDisableSpeechAnalyzer(for error: Error) -> Bool {
        if error is CancellationError { return false }
        if #available(iOS 26.0, *),
           let engineError = error as? SpeechAnalyzerTranscriptionEngine.EngineError,
           case .unsupportedLocale = engineError {
            return true
        }
        let message = error.localizedDescription.lowercased()
        if message.contains("not subscribed to transcription")
            || message.contains("cannot check the download status")
            || message.contains("asset")
            || message.contains("speech recognition")
            || message.contains("authorization")
            || message.contains("unsupported locale")
            || message.contains("no supported speechanalyzer locale found")
            || message.contains("too many allocated locales") {
            return true
        }
        // Keep analyzer enabled for transient runtime failures.
        return false
    }

    private func ensureSpeechAnalyzerReadyForUse() async -> Bool {
        guard canAttemptSpeechAnalyzer else { return false }
        guard !hasValidatedSpeechAnalyzerForSession else { return true }
        guard #available(iOS 26.0, *) else { return false }

        if let existing = currentSpeechAnalyzerValidationTask() {
            return await existing.task.value
        }

        let taskID = UUID()
        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            return await self.performSpeechAnalyzerReadinessProbe()
        }
        setSpeechAnalyzerValidationTask(task, id: taskID)
        let result = await task.value
        clearSpeechAnalyzerValidationTask(ifID: taskID)
        return result
    }

    @available(iOS 26.0, *)
    private func performSpeechAnalyzerReadinessProbe() async -> Bool {
        do {
            let engine = SpeechAnalyzerTranscriptionEngine()
            let preferred = liveLockedLanguage ?? preferredDeviceSupportedLanguage() ?? .english
            let localeHint = speechAnalyzerLocaleHint(for: preferred)
            try await engine.prepare(
                localeHint: speechAnalyzerLocaleHint(for: preferred),
                preset: .progressiveTranscription
            )
            // Readiness must prove decode viability, not only asset preparation.
            // This avoids showing "Speak now" when subscription/asset status will fail on first decode.
            _ = try await engine.transcribe(
                audio: speechAnalyzerPreflightProbeAudio(),
                sampleRate: targetSampleRate,
                localeHint: localeHint,
                preset: .progressiveTranscription
            )
            hasValidatedSpeechAnalyzerForSession = true
            publishBackendStatus()
            return true
        } catch {
            hasDisabledSpeechAnalyzerForSession = true
            hasValidatedSpeechAnalyzerForSession = false
            publishBackendStatus()
            return false
        }
    }

    private func currentSpeechAnalyzerValidationTask() -> (id: UUID, task: Task<Bool, Never>)? {
        speechAnalyzerValidationTaskLock.lock()
        defer { speechAnalyzerValidationTaskLock.unlock() }
        guard let id = speechAnalyzerValidationTaskID, let task = speechAnalyzerValidationTask else {
            return nil
        }
        return (id: id, task: task)
    }

    private func setSpeechAnalyzerValidationTask(_ task: Task<Bool, Never>, id: UUID) {
        speechAnalyzerValidationTaskLock.lock()
        defer { speechAnalyzerValidationTaskLock.unlock() }
        speechAnalyzerValidationTaskID = id
        speechAnalyzerValidationTask = task
    }

    private func clearSpeechAnalyzerValidationTask(ifID id: UUID) {
        speechAnalyzerValidationTaskLock.lock()
        defer { speechAnalyzerValidationTaskLock.unlock() }
        if speechAnalyzerValidationTaskID == id {
            speechAnalyzerValidationTaskID = nil
            speechAnalyzerValidationTask = nil
        }
    }

    private func cancelSpeechAnalyzerValidationTaskIfNeeded() {
        speechAnalyzerValidationTaskLock.lock()
        speechAnalyzerValidationTaskID = nil
        let task = speechAnalyzerValidationTask
        speechAnalyzerValidationTask = nil
        speechAnalyzerValidationTaskLock.unlock()
        task?.cancel()
    }

    private func publishBackendStatus() {
        let label = backendStatusLabel
        DispatchQueue.main.async { [weak self] in
            self?.onBackendStatusChange?(label)
        }
    }

    private func speechAnalyzerPreflightProbeAudio() -> [Float] {
        let sampleCount = max(1, Int(targetSampleRate * 0.35))
        return Array(repeating: 0, count: sampleCount)
    }

    // Prefer one stable regional locale per supported language to reduce
    // analyzer locale churn; resolver will still fall back if unavailable.
    private func speechAnalyzerLocaleHint(for language: SupportedLanguage?) -> Locale? {
        guard let language else { return nil }
        switch language {
        case .english:
            return Locale(identifier: "en-US")
        case .spanish:
            return Locale(identifier: "es-MX")
        case .french:
            return Locale(identifier: "fr-CA")
        }
    }

    @available(iOS 26.0, *)
    private func resolveSupportedSpeechAnalyzerLocale(for language: SupportedLanguage) async -> Locale? {
        guard SpeechTranscriber.isAvailable else { return nil }
        let supportedLocales = await SpeechTranscriber.supportedLocales
        guard !supportedLocales.isEmpty else { return nil }

        let supportedByIdentifier = Dictionary(
            supportedLocales.map { ($0.identifier.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let hint = speechAnalyzerLocaleHint(for: language) ?? Locale(identifier: language.rawValue)
        return SpeechLocaleResolution.resolve(
            localeHint: hint,
            supportedByIdentifier: supportedByIdentifier,
            allSupported: supportedLocales
        )
    }

    private func supportedLanguage(from locale: Locale, fallback: SupportedLanguage?) -> SupportedLanguage {
        switch locale.language.languageCode?.identifier {
        case "en": return .english
        case "es": return .spanish
        case "fr": return .french
        default: return fallback ?? preferredDeviceSupportedLanguage() ?? .english
        }
    }

    private func effectiveSessionLanguage(preferredLanguage: SupportedLanguage?) -> SupportedLanguage {
        preferredLanguage
            ?? sessionPreferredLanguageHint
            ?? liveLockedLanguage
            ?? lastLiveResolvedLanguage
            ?? preferredDeviceSupportedLanguage()
            ?? .english
    }

    private func shortSessionID(_ sessionID: UUID?) -> String {
        guard let sessionID else { return "none" }
        return String(sessionID.uuidString.prefix(8))
    }

    private func engineDisplayName(_ engine: TranscriptionEngine) -> String {
        switch engine {
        case .dictationTranscriber: return "DictationTranscriberEngine"
        case .speechTranscriber: return "SpeechTranscriberEngine"
        case .cloudAPI: return "CloudTranscriptionEngine"
        }
    }

    private func currentPlatformLabel() -> String {
        if #available(iOS 26.0, *) {
            return "iOS26+"
        }
        return "iOS16-25"
    }

    private func sessionLog(
        _ event: String,
        sessionID: UUID? = nil,
        fields: [String: String] = [:]
    ) {
        let resolvedSessionID = sessionID ?? activeCaptureSessionID
        let sid = shortSessionID(resolvedSessionID)
        let payload = fields
            .filter { !$0.value.isEmpty }
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: " ")
        let message = payload.isEmpty
            ? "[session=\(sid)] \(event)"
            : "[session=\(sid)] \(event) \(payload)"
        STTSessionLogger.shared.log(source: "STT", message: message)
#if DEBUG
        print("[STT_TRACE][STT] \(message)")
#endif
    }

    private func logAppleLiveTapInput(buffer: AVAudioPCMBuffer) {
        guard operationMode == .liveStreaming else { return }
        let now = Date()
        sttAppleLiveTapBufferCount += 1
        sttAppleLiveTapSampleCount += Int(buffer.frameLength)
        sttAppleLiveTapLastBufferAt = now
        if sttAppleLiveTapFirstBufferAt == nil {
            sttAppleLiveTapFirstBufferAt = now
            let firstLatencyMs = sttSessionStartedAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? 0
            sessionLog(
                "apple_live_audio_tap_first_buffer",
                fields: [
                    "mode": operationMode.rawValue,
                    "sample_rate": String(format: "%.0f", buffer.format.sampleRate),
                    "channels": "\(buffer.format.channelCount)",
                    "frames": "\(buffer.frameLength)",
                    "first_buffer_latency_ms": "\(firstLatencyMs)"
                ]
            )
        }
        guard sttAppleLiveTapLastLogAt == nil || now.timeIntervalSince(sttAppleLiveTapLastLogAt!) >= sttAppleLiveTapLogInterval else {
            return
        }
        sttAppleLiveTapLastLogAt = now
        let audioSeconds = Double(sttAppleLiveTapSampleCount) / targetSampleRate
        let elapsedMs = sttSessionStartedAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? 0
        sessionLog(
            "apple_live_audio_tap",
            fields: [
                "mode": operationMode.rawValue,
                "buffer_count": "\(sttAppleLiveTapBufferCount)",
                "samples": "\(sttAppleLiveTapSampleCount)",
                "audio_s": String(format: "%.2f", audioSeconds),
                "sample_rate": String(format: "%.0f", buffer.format.sampleRate),
                "channels": "\(buffer.format.channelCount)",
                "elapsed_ms": "\(elapsedMs)"
            ]
        )
    }

    private func logLiveStreamUnavailableFallback(_ key: String, message: String, minimumInterval: TimeInterval = 2.0) {
        let now = Date()
        if sttLastStreamUnavailableFallbackKey == key,
           let last = sttLastStreamUnavailableFallbackLogAt,
           now.timeIntervalSince(last) < minimumInterval {
            return
        }
        sttLastStreamUnavailableFallbackKey = key
        sttLastStreamUnavailableFallbackLogAt = now
        debugTrace(message)
    }

    private func logStartupFallbackWarningOnce(key: String, message: String) {
        if sttDidLogFirstPartialLatency {
            logLiveStreamUnavailableFallback(key, message: message)
            return
        }
        guard !sttDidLogStartupFallbackWarning else { return }
        sttDidLogStartupFallbackWarning = true
        sessionLog(
            "startup_fallback_warning",
            fields: [
                "mode": operationMode.rawValue,
                "reason": "no_stream_result",
                "detail": message
            ]
        )
        debugTrace(message)
    }

    @available(iOS 26.0, *)
    private func logAppleLiveNoResultDiagnostics(
        snapshot: AppleLiveTranscriptionCoordinator.LiveDiagnosticsSnapshot?,
        liveElapsed: TimeInterval
    ) {
        let now = Date()
        if sttLastStreamUnavailableFallbackKey == "apple_live_no_result",
           let last = sttLastStreamUnavailableFallbackLogAt,
           now.timeIntervalSince(last) < 2.0 {
            return
        }
        sttLastStreamUnavailableFallbackKey = "apple_live_no_result"
        sttLastStreamUnavailableFallbackLogAt = now

        let fallbackLanguage = effectiveSessionLanguage(preferredLanguage: nil)
        let locale = snapshot?.locale ?? (speechAnalyzerLocaleHint(for: fallbackLanguage)?.identifier ?? "auto")
        sessionLog(
            "apple_live_no_result",
            fields: [
                "locale": locale,
                "streak": "\(advancedLiveStreamNoResultStreak)",
                "live_s": String(format: "%.2f", liveElapsed),
                "state": snapshot?.state ?? "none",
                "coordinator_exists": snapshot == nil ? "false" : "true",
                "has_received_buffer": snapshot?.hasReceivedBuffer == true ? "true" : "false",
                "accepted_buffer_count": "\(snapshot?.acceptedBufferCount ?? 0)",
                "accepted_samples": "\(snapshot?.acceptedSampleCount ?? 0)",
                "converted_buffer_count": "\(snapshot?.convertedBufferCount ?? 0)",
                "dropped_buffer_count": "\(snapshot?.droppedBufferCount ?? 0)",
                "has_received_result": snapshot?.hasReceivedResult == true ? "true" : "false",
                "result_count": "\(snapshot?.resultCount ?? 0)",
                "first_buffer_elapsed_ms": snapshot?.firstBufferElapsedMs.map(String.init) ?? "",
                "first_result_elapsed_ms": snapshot?.firstResultElapsedMs.map(String.init) ?? ""
            ]
        )
    }

    private func isFrenchLiveSession(preferredLanguage: SupportedLanguage?) -> Bool {
        operationMode == .liveStreaming && effectiveSessionLanguage(preferredLanguage: preferredLanguage) == .french
    }

    private func debugLogRuntimeConfiguration(reason: String, modeOverride: OperationMode? = nil) {
        let mode = modeOverride ?? operationMode
        debugTrace("runtime reason=\(reason) mode=\(mode.rawValue) provider=\(selectedModelProvider.rawValue)")
    }

    private func debugLogEngineSelection(phase: String, engine: TranscriptionEngine, detail: String) {
        debugTrace("engine phase=\(phase) selected=\(engine.rawValue) detail=\(detail)")
    }

    private func logDetectedLanguage(stage: String, language: SupportedLanguage) {
        debugTrace("language stage=\(stage) value=\(language.rawValue)")
    }

    private func logLivePartialResultIfPresent(_ result: LivePartialResult?, phase: String, previousText: String) {
        guard let result else { return }
        sttLivePartialSequence += 1
        let committedChars = result.committedText?.count ?? 0
        let volatileChars = result.volatileText?.count ?? max(0, result.text.count - committedChars)
        let changed = result.text != previousText
        let now = Date()
        let sessionElapsedMs = sttSessionStartedAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? 0
        let partialIntervalMs = sttLastPartialLoggedAt.map { Int(now.timeIntervalSince($0) * 1000) }
        sttLastPartialLoggedAt = now

        var fields: [String: String] = [
            "seq": "\(sttLivePartialSequence)",
            "phase": phase,
            "mode": operationMode.rawValue,
            "engine": engineDisplayName(preferredLivePartialEngine()),
            "audio_s": String(format: "%.2f", result.windowEndTime),
            "window_start_s": String(format: "%.2f", result.windowStartTime),
            "window_end_s": String(format: "%.2f", result.windowEndTime),
            "chars": "\(result.text.count)",
            "committed_chars": "\(committedChars)",
            "volatile_chars": "\(volatileChars)",
            "changed": changed ? "true" : "false",
            "session_elapsed_ms": "\(sessionElapsedMs)"
        ]
        if let partialIntervalMs {
            fields["partial_interval_ms"] = "\(partialIntervalMs)"
        }
        if !sttDidLogFirstPartialLatency {
            sttDidLogFirstPartialLatency = true
            fields["first_partial_latency_ms"] = "\(sessionElapsedMs)"
        }

        sessionLog("partial", fields: fields)
        debugTrace(
            "live_output phase=\(phase) lang=\(result.language.rawValue) window=\(String(format: "%.2f", result.windowStartTime))-\(String(format: "%.2f", result.windowEndTime)) chars=\(result.text.count)"
        )
    }

    private func publishLivePartialResultIfMeaningful(_ result: LivePartialResult?, phase: String) -> LivePartialResult? {
        guard let result else { return nil }
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let now = Date()
        if lastPublishedLivePartialText.isEmpty,
           result.windowEndTime < firstLivePartialMinimumWindowEnd,
           trimmed.count < firstLivePartialMinimumChars {
            debugTrace(
                "live_output suppress reason=early_warmup phase=\(phase) window_end=\(String(format: "%.2f", result.windowEndTime)) chars=\(trimmed.count)"
            )
            return nil
        }
        if !lastPublishedLivePartialText.isEmpty {
            let sinceLastEmission = now.timeIntervalSince(lastPublishedLivePartialAt)
            let windowAdvance = result.windowEndTime - lastPublishedLivePartialWindowEndTime
            let charGrowth = max(0, trimmed.count - lastPublishedLivePartialText.count)
            let punctuationAdvance = hasTerminalPunctuation(trimmed) && !hasTerminalPunctuation(lastPublishedLivePartialText)
            let sameTextAndWindow = trimmed == lastPublishedLivePartialText && abs(windowAdvance) < 0.05
            let meaningfulAdvance = charGrowth >= livePartialEmitMinimumCharAdvance
                || windowAdvance >= livePartialEmitMinimumWindowAdvance
                || punctuationAdvance
            let minorWindowMovement = windowAdvance < 0.45
            let sameWindowTrack = result.windowStartTime <= (lastPublishedLivePartialWindowStartTime + 0.20)
            let heavyRewrite = trimmed.count + 12 < lastPublishedLivePartialText.count
            let streamShortRewrite = phase == "live_partial_stream"
                && windowAdvance < 1.20
                && trimmed.count + 6 < lastPublishedLivePartialText.count

            if sameTextAndWindow {
                debugTrace("live_output suppress reason=duplicate phase=\(phase)")
                return nil
            }
            if streamShortRewrite {
                debugTrace(
                    "live_output suppress reason=stream_short_rewrite phase=\(phase) prev_chars=\(lastPublishedLivePartialText.count) new_chars=\(trimmed.count)"
                )
                return nil
            }
            if sameWindowTrack && minorWindowMovement && heavyRewrite {
                debugTrace(
                    "live_output suppress reason=unstable_rewrite phase=\(phase) prev_chars=\(lastPublishedLivePartialText.count) new_chars=\(trimmed.count)"
                )
                return nil
            }
            if sinceLastEmission < livePartialEmitMinimumInterval && !meaningfulAdvance {
                debugTrace(
                    "live_output suppress reason=throttled phase=\(phase) dt=\(String(format: "%.2f", sinceLastEmission)) chars=+\(charGrowth)"
                )
                return nil
            }
        }

        let previousPublishedText = lastPublishedLivePartialText
        lastPublishedLivePartialText = trimmed
        lastPublishedLivePartialWindowStartTime = result.windowStartTime
        lastPublishedLivePartialWindowEndTime = result.windowEndTime
        lastPublishedLivePartialAt = now
        logLivePartialResultIfPresent(result, phase: phase, previousText: previousPublishedText)
        return result
    }

    private func hasTerminalPunctuation(_ text: String) -> Bool {
        guard let last = text.unicodeScalars.last else { return false }
        return CharacterSet(charactersIn: ".!?;:").contains(last)
    }

    private func resetLivePartialOutputState() {
        lastPublishedLivePartialText = ""
        lastPublishedLivePartialWindowStartTime = 0
        lastPublishedLivePartialWindowEndTime = 0
        lastPublishedLivePartialAt = .distantPast
    }

    private func isLiveStreamTextLanguageConsistent(_ text: String, expected: SupportedLanguage?) -> Bool {
        guard expected != nil else { return true }

        // Do not reject short/incremental live transcription.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return true }

        // Diagnostic-only guard: language consistency must not decide
        // engine routing without a true confidence API.
        return true
    }

    private func logPreview(_ text: String, max: Int = 120) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard trimmed.count > max else { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: max)
        return String(trimmed[..<idx]) + "..."
    }

    private func debugTrace(_ message: String) {
        let sessionTag = "session=\(shortSessionID(activeCaptureSessionID))"
        STTSessionLogger.shared.log(source: "SpeechToTextManager", message: "\(sessionTag) \(message)")
#if DEBUG
        print("[STT_TRACE][SpeechToTextManager] \(sessionTag) \(message)")
#endif
    }

    @objc
    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeRaw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else {
            return
        }

        switch type {
        case .began:
            stopListening()
        case .ended:
            break
        @unknown default:
            break
        }
    }

}
