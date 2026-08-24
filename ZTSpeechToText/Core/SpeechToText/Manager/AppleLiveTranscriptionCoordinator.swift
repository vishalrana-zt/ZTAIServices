import AVFoundation
import Speech
import CoreMedia

@available(iOS 26.0, *)
final class AppleLiveTranscriptionCoordinator {
    deinit {
        if let reservedLocale {
            Task { await AssetInventory.release(reservedLocale: reservedLocale) }
        }
    }

    enum EngineKind: String {
        case speechTranscriber
        case dictationTranscriber
    }

    struct EngineSelection {
        let engine: EngineKind
        let locale: Locale
        let reason: String
        let sessionID: UUID
    }

    struct LiveDiagnosticsSnapshot {
        let coordinatorSessionID: UUID?
        let state: String
        let locale: String
        let hasReceivedBuffer: Bool
        let acceptedBufferCount: Int
        let acceptedSampleCount: Int
        let convertedBufferCount: Int
        let droppedBufferCount: Int
        let hasReceivedResult: Bool
        let resultCount: Int
        let firstBufferElapsedMs: Int?
        let firstResultElapsedMs: Int?
    }

    private struct Entry {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        var isFinal: Bool
    }

    private let stateLock = NSLock()
    private var entries: [Entry] = []
    private var latestFinalizationTime: TimeInterval = 0
    private var latestWindowEnd: TimeInterval = 0
    private var latestLocale: Locale = .current
    private enum LifecycleState: String {
        case idle
        case starting
        case running
        case stopping
        case failed
    }
    private let lifecycleLock = NSLock()
    private var lifecycleState: LifecycleState = .idle
    private var activeSessionID: UUID?

    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var analyzeTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var analyzerInputFormat: AVAudioFormat?
    private let inputQueue = DispatchQueue(label: "AppleLiveTranscriptionCoordinator.inputQueue", qos: .userInitiated)
    private var hasLoggedFirstInputBuffer = false

    private var hasLoggedEngineSelection = false
    /// Locale reserved for this coordinator's live session. Held for the
    /// full session lifetime (not just asset install) and released in
    /// stop(finalize:) or deinit.
    private var reservedLocale: Locale?
    private var ownerSessionID: UUID?
    private var sessionStartedAt: Date?
    private var acceptedBufferCount: Int = 0
    private var acceptedSampleCount: Int = 0
    private var convertedBufferCount: Int = 0
    private var droppedBufferCount: Int = 0
    private var firstAcceptedBufferAt: Date?
    private var lastAcceptedBufferAt: Date?
    private var lastAudioInputLogAt: Date?
    private var resultCount: Int = 0
    private var hasReceivedResult: Bool = false
    private var firstResultAt: Date?
    private let audioInputLogInterval: TimeInterval = 1.0

    func start(localeHint: Locale?, ownerSessionID: UUID?) async throws -> EngineSelection {
        let sessionID = UUID()
        self.ownerSessionID = ownerSessionID
        sessionStartedAt = Date()
        let priorState = lifecycleLock.withLock { lifecycleState }
        if priorState == .running || priorState == .starting || priorState == .stopping {
            try await stop(finalize: false)
        }
        transitionLifecycle(to: .starting, sessionID: sessionID, detail: "phase=start_begin")
        resetTranscriptState()
        hasLoggedFirstInputBuffer = false
        acceptedBufferCount = 0
        acceptedSampleCount = 0
        convertedBufferCount = 0
        droppedBufferCount = 0
        firstAcceptedBufferAt = nil
        lastAcceptedBufferAt = nil
        lastAudioInputLogAt = nil
        resultCount = 0
        hasReceivedResult = false
        firstResultAt = nil

        let resolved = try await withThrowingTaskGroup(of: EngineSelection.self) { group in
            group.addTask { try await self.resolveEngine(localeHint: localeHint, sessionID: sessionID) }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw NSError(
                    domain: "AppleLiveTranscriptionCoordinator",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Engine resolution timed out"]
                )
            }
            guard let result = try await group.next() else {
                throw NSError(domain: "AppleLiveTranscriptionCoordinator", code: 4, userInfo: [NSLocalizedDescriptionKey: "Engine resolution produced no result"])
            }
            group.cancelAll()
            return result
        }
        logEvent(
            "apple_live_session_start",
            fields: [
                "coordinator_session_id": shortSessionID(sessionID),
                "locale": resolved.locale.identifier,
                "engine": resolved.engine.rawValue,
                "state": "resolved",
                "elapsed_ms": "\(elapsedMs())"
            ]
        )

        // Reserve for the whole live session — install AND ongoing analysis —
        // not just the install step. Released in stop(finalize:) / deinit.
        try await AssetInventory.reserve(locale: resolved.locale)
        reservedLocale = resolved.locale

        let stream = AsyncStream<AnalyzerInput> { continuation in
            self.inputContinuation = continuation
        }

        do {
            switch resolved.engine {
            case .speechTranscriber:
                let preset = SpeechTranscriber.Preset(
                    transcriptionOptions: [],
                    reportingOptions: [.volatileResults, .fastResults],
                    attributeOptions: []
                )

                let transcriber = SpeechTranscriber(locale: resolved.locale, preset: preset)
                try await ensureAssetsReady(module: transcriber)

                let analyzer = SpeechAnalyzer(modules: [transcriber])
                let defaultFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: 16_000,
                    channels: 1,
                    interleaved: false
                )
                let expectedFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) ?? defaultFormat
                guard let expectedFormat else {
                    throw NSError(
                        domain: "AppleLiveTranscriptionCoordinator",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to determine analyzer input format"]
                    )
                }
                analyzerInputFormat = expectedFormat
                try await analyzer.prepareToAnalyze(in: expectedFormat)
                self.analyzer = analyzer
                self.latestLocale = resolved.locale

                self.resultsTask = Task(priority: .userInitiated) { [weak self] in
                    guard let self else { return }
                    do {
                        for try await result in transcriber.results {
                            guard self.isSessionActive(sessionID) else { return }
                            self.applyResult(
                                range: result.range,
                                resultsFinalizationTime: result.resultsFinalizationTime,
                                text: result.text,
                                isFinal: result.isFinal,
                                locale: resolved.locale
                            )
                        }
                    } catch {
                        if self.isSessionActive(sessionID) {
                            self.logEvent("apple_live_error", fields: self.errorFields(error: error, phase: "results_stream_speech_transcriber"))
                        }
                    }
                }

                try await analyzer.start(inputSequence: stream)

            case .dictationTranscriber:
                let preset = DictationTranscriber.Preset.progressiveLongDictation

                let transcriber = DictationTranscriber(locale: resolved.locale, preset: preset)
                try await ensureAssetsReady(module: transcriber)

                let analyzer = SpeechAnalyzer(modules: [transcriber])
                let defaultFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: 16_000,
                    channels: 1,
                    interleaved: false
                )
                let expectedFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) ?? defaultFormat
                guard let expectedFormat else {
                    throw NSError(
                        domain: "AppleLiveTranscriptionCoordinator",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to determine analyzer input format"]
                    )
                }
                analyzerInputFormat = expectedFormat
                try await analyzer.prepareToAnalyze(in: expectedFormat)
                self.analyzer = analyzer
                self.latestLocale = resolved.locale

                self.resultsTask = Task(priority: .userInitiated) { [weak self] in
                    guard let self else { return }
                    do {
                        for try await result in transcriber.results {
                            guard self.isSessionActive(sessionID) else { return }
                            self.applyResult(
                                range: result.range,
                                resultsFinalizationTime: result.resultsFinalizationTime,
                                text: result.text,
                                isFinal: result.isFinal,
                                locale: resolved.locale
                            )
                        }
                    } catch {
                        if self.isSessionActive(sessionID) {
                            self.logEvent("apple_live_error", fields: self.errorFields(error: error, phase: "results_stream_dictation_transcriber"))
                        }
                    }
                }

                try await analyzer.start(inputSequence: stream)
            }
        } catch {
            logEvent("apple_live_error", fields: errorFields(error: error, phase: "start"))
            transitionLifecycle(to: .failed, sessionID: sessionID, detail: "phase=start_failed error=\"\(error.localizedDescription)\"")
            try? await stop(finalize: false)
            throw error
        }

        if !hasLoggedEngineSelection {
            hasLoggedEngineSelection = true
        }
        transitionLifecycle(to: .running, sessionID: sessionID, detail: "phase=running")

        return EngineSelection(
            engine: resolved.engine,
            locale: resolved.locale,
            reason: resolved.reason,
            sessionID: sessionID
        )
    }

    func pushBuffer(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        guard let continuation = inputContinuation else { return }
        guard let expectedFormat = analyzerInputFormat else { return }
        guard let sessionID = lifecycleLock.withLock({
            lifecycleState == .running ? activeSessionID : nil
        }) else { return }

        inputQueue.async { [weak self] in
            guard let self else { return }
            guard self.isSessionActive(sessionID) else { return }
            guard let inputBuffer = self.convertBufferIfNeeded(buffer, to: expectedFormat) else {
                self.recordDroppedBuffer()
                return
            }
            let shouldLogFirstBuffer = !self.hasLoggedFirstInputBuffer
            let didConvert = !self.isAudioFormat(buffer.format, equivalentTo: expectedFormat)
            self.recordAcceptedBuffer(inputBuffer, didConvert: didConvert)
            if shouldLogFirstBuffer {
                self.logEvent(
                    "apple_live_audio_first_buffer",
                    fields: [
                        "coordinator_session_id": self.shortSessionID(sessionID),
                        "sample_rate": String(format: "%.0f", inputBuffer.format.sampleRate),
                        "channels": "\(inputBuffer.format.channelCount)",
                        "frames": "\(inputBuffer.frameLength)",
                        "first_buffer_latency_ms": "\(self.elapsedMs())"
                    ]
                )
            }
            continuation.yield(AnalyzerInput(buffer: inputBuffer))
            if shouldLogFirstBuffer {
                self.hasLoggedFirstInputBuffer = true
            }
            self.logPeriodicAudioInputIfNeeded(inputBuffer)
        }
    }

    func latestLivePartial(language: SupportedLanguage) -> SpeechToTextManager.LivePartialResult? {
        stateLock.lock()
        let sorted = entries.sorted { lhs, rhs in
            if lhs.start == rhs.start { return lhs.end < rhs.end }
            return lhs.start < rhs.start
        }

        let committed = sorted
            .filter { $0.isFinal }
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let volatile = sorted
            .filter { !$0.isFinal }
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let windowEnd = latestWindowEnd
        let windowStart = max(0, latestFinalizationTime)
        stateLock.unlock()

        let rendered = join(committed: committed, volatile: volatile)
        guard !rendered.isEmpty else { return nil }

        let segments = [
            LiveTranscriptSegment(startTime: 0, endTime: windowStart, text: committed),
            LiveTranscriptSegment(startTime: windowStart, endTime: windowEnd, text: volatile)
        ].filter { !$0.text.isEmpty && $0.endTime >= $0.startTime }

        return SpeechToTextManager.LivePartialResult(
            text: rendered,
            language: language,
            windowStartTime: windowStart,
            windowEndTime: windowEnd,
            segments: segments,
            committedText: committed,
            volatileText: volatile
        )
    }

    func stop(finalize: Bool) async throws {
        guard let sessionID = lifecycleLock.withLock({ activeSessionID }) else {
            return
        }
        transitionLifecycle(to: .stopping, sessionID: sessionID, detail: "phase=stop_begin finalize=\(finalize)")
        inputContinuation?.finish()
        inputContinuation = nil

        if finalize, let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                logEvent("apple_live_error", fields: errorFields(error: error, phase: "stop_finalize"))
            }
        }

        if !finalize {
            await analyzer?.cancelAndFinishNow()
        }

        analyzeTask?.cancel()
        resultsTask?.cancel()
        analyzeTask = nil
        resultsTask = nil
        self.analyzer = nil
        lifecycleLock.withLock {
            activeSessionID = nil
        }
        hasLoggedEngineSelection = false
        if let reservedLocale {
            await AssetInventory.release(reservedLocale: reservedLocale)
            self.reservedLocale = nil
        }
        logEvent(
            "apple_live_audio_input",
            fields: [
                "state": "stop_totals",
                "buffer_count": "\(acceptedBufferCount)",
                "samples": "\(acceptedSampleCount)",
                "audio_s": String(format: "%.2f", acceptedAudioSeconds()),
                "converted_buffer_count": "\(convertedBufferCount)",
                "dropped_buffer_count": "\(droppedBufferCount)",
                "result_count": "\(resultCount)"
            ]
        )
        analyzerInputFormat = nil
        transitionLifecycle(to: .idle, sessionID: sessionID, detail: "phase=stopped")
    }

    func diagnosticsSnapshot() -> LiveDiagnosticsSnapshot {
        let state = lifecycleLock.withLock { lifecycleState.rawValue }
        let firstBufferElapsedMs = firstAcceptedBufferAt.map { first in
            sessionStartedAt.map { Int(first.timeIntervalSince($0) * 1000) } ?? 0
        }
        let firstResultElapsedMs = firstResultAt.map { first in
            sessionStartedAt.map { Int(first.timeIntervalSince($0) * 1000) } ?? 0
        }
        return LiveDiagnosticsSnapshot(
            coordinatorSessionID: lifecycleLock.withLock { activeSessionID },
            state: state,
            locale: latestLocale.identifier,
            hasReceivedBuffer: acceptedBufferCount > 0,
            acceptedBufferCount: acceptedBufferCount,
            acceptedSampleCount: acceptedSampleCount,
            convertedBufferCount: convertedBufferCount,
            droppedBufferCount: droppedBufferCount,
            hasReceivedResult: hasReceivedResult,
            resultCount: resultCount,
            firstBufferElapsedMs: firstBufferElapsedMs,
            firstResultElapsedMs: firstResultElapsedMs
        )
    }

    private func resolveEngine(localeHint: Locale?, sessionID: UUID) async throws -> EngineSelection {
        let preferred = localeHint ?? Locale.current

        // Live path must prefer DictationTranscriber to match Apple's live dictation behavior.
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: preferred) {
            return EngineSelection(
                engine: .dictationTranscriber,
                locale: locale,
                reason: "Preferred live path: DictationTranscriber.supportedLocale(equivalentTo:)",
                sessionID: sessionID
            )
        }

        if SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: preferred) {
            return EngineSelection(
                engine: .speechTranscriber,
                locale: locale,
                reason: "DictationTranscriber unsupported; fallback SpeechTranscriber.supportedLocale(equivalentTo:)",
                sessionID: sessionID
            )
        }

        throw NSError(
            domain: "AppleLiveTranscriptionCoordinator",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No supported locale equivalent to \(preferred.identifier)"]
        )
    }

    private func ensureAssetsReady(module: some LocaleDependentSpeechModule) async throws {
        if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await installationRequest.downloadAndInstall()
        }
    }

    private func applyResult(
        range: CMTimeRange,
        resultsFinalizationTime: CMTime,
        text: AttributedString,
        isFinal: Bool,
        locale: Locale
    ) {
        let now = Date()
        if !hasReceivedResult {
            hasReceivedResult = true
            firstResultAt = now
            let firstFromSessionMs = sessionStartedAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? 0
            let firstFromAudioMs = firstAcceptedBufferAt.map { Int(now.timeIntervalSince($0) * 1000) }
            logEvent(
                "apple_live_first_result",
                fields: [
                    "locale": locale.identifier,
                    "first_result_latency_ms": "\(firstFromSessionMs)",
                    "from_first_buffer_ms": firstFromAudioMs.map(String.init) ?? "",
                    "chars": "\(String(text.characters).count)"
                ]
            )
        }
        resultCount += 1
        logEvent(
            "apple_live_result",
            fields: [
                "locale": locale.identifier,
                "result_count": "\(resultCount)",
                "elapsed_ms": "\(sessionStartedAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? 0)",
                "chars": "\(String(text.characters).count)",
                "is_final": isFinal ? "true" : "false",
                "segment_count": "1"
            ]
        )
        let start = max(0, seconds(range.start))
        let end = max(start, seconds(range.end))
        let finalization = max(0, seconds(resultsFinalizationTime))
        let normalizedText = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)

        stateLock.lock()
        latestLocale = locale
        latestFinalizationTime = max(latestFinalizationTime, finalization)
        latestWindowEnd = max(latestWindowEnd, end)

        entries.removeAll { existing in
            let overlaps = existing.start < end && start < existing.end
            if !overlaps { return false }
            return !existing.isFinal || existing.end > finalization
        }

        if !normalizedText.isEmpty {
            entries.append(
                Entry(
                    start: start,
                    end: end,
                    text: normalizedText,
                    isFinal: isFinal || finalization >= end - 0.0001
                )
            )
        }

        entries = entries.map { entry in
            var updated = entry
            if updated.end <= finalization + 0.0001 {
                updated.isFinal = true
            }
            return updated
        }
        stateLock.unlock()
    }

    private func seconds(_ time: CMTime) -> TimeInterval {
        guard time.isNumeric else { return 0 }
        return CMTimeGetSeconds(time)
    }

    private func join(committed: String, volatile: String) -> String {
        let prefix = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = volatile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return tail }
        guard !tail.isEmpty else { return prefix }
        return prefix + " " + tail
    }

    private func resetTranscriptState() {
        stateLock.lock()
        entries.removeAll()
        latestFinalizationTime = 0
        latestWindowEnd = 0
        stateLock.unlock()
    }

    private func convertBufferIfNeeded(_ buffer: AVAudioPCMBuffer, to expectedFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        if isAudioFormat(buffer.format, equivalentTo: expectedFormat) {
            return buffer
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: expectedFormat) else {
            return nil
        }
        let ratio = expectedFormat.sampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: expectedFormat, frameCapacity: outputCapacity) else {
            return nil
        }

        var conversionError: NSError?
        var didSupplyInput = false
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if didSupplyInput {
                status.pointee = .endOfStream
                return nil
            }
            didSupplyInput = true
            status.pointee = .haveData
            return buffer
        }

        guard conversionError == nil, outputBuffer.frameLength > 0 else {
            return nil
        }
        return outputBuffer
    }

    private func isAudioFormat(_ lhs: AVAudioFormat, equivalentTo rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat
            && lhs.channelCount == rhs.channelCount
            && lhs.isInterleaved == rhs.isInterleaved
            && abs(lhs.sampleRate - rhs.sampleRate) < 0.5
    }

    private func transitionLifecycle(to next: LifecycleState, sessionID: UUID, detail: String) {
        lifecycleLock.lock()
        lifecycleState = next
        activeSessionID = (next == .idle) ? nil : sessionID
        lifecycleLock.unlock()
        logEvent(
            "apple_live_state",
            fields: [
                "state": next.rawValue,
                "coordinator_session_id": shortSessionID(sessionID),
                "locale": latestLocale.identifier,
                "elapsed_ms": "\(elapsedMs())"
            ]
        )
    }

    private func isSessionActive(_ sessionID: UUID) -> Bool {
        lifecycleLock.withLock {
            activeSessionID == sessionID && (lifecycleState == .starting || lifecycleState == .running)
        }
    }

    private func recordAcceptedBuffer(_ buffer: AVAudioPCMBuffer, didConvert: Bool) {
        acceptedBufferCount += 1
        acceptedSampleCount += Int(buffer.frameLength)
        if didConvert {
            convertedBufferCount += 1
        }
        if firstAcceptedBufferAt == nil {
            firstAcceptedBufferAt = Date()
        }
        lastAcceptedBufferAt = Date()
    }

    private func recordDroppedBuffer() {
        droppedBufferCount += 1
    }

    private func logPeriodicAudioInputIfNeeded(_ buffer: AVAudioPCMBuffer) {
        let now = Date()
        guard lastAudioInputLogAt == nil || now.timeIntervalSince(lastAudioInputLogAt!) >= audioInputLogInterval else { return }
        lastAudioInputLogAt = now
        logEvent(
            "apple_live_audio_input",
            fields: [
                "state": lifecycleLock.withLock { lifecycleState.rawValue },
                "buffer_count": "\(acceptedBufferCount)",
                "samples": "\(acceptedSampleCount)",
                "audio_s": String(format: "%.2f", acceptedAudioSeconds()),
                "sample_rate": String(format: "%.0f", buffer.format.sampleRate),
                "channels": "\(buffer.format.channelCount)",
                "converted_buffer_count": "\(convertedBufferCount)",
                "dropped_buffer_count": "\(droppedBufferCount)",
                "has_received_buffer": acceptedBufferCount > 0 ? "true" : "false",
                "elapsed_ms": "\(elapsedMs())"
            ]
        )
    }

    private func acceptedAudioSeconds() -> TimeInterval {
        guard let format = analyzerInputFormat else { return 0 }
        return Double(acceptedSampleCount) / format.sampleRate
    }

    private func elapsedMs() -> Int {
        guard let sessionStartedAt else { return 0 }
        return Int(Date().timeIntervalSince(sessionStartedAt) * 1000)
    }

    private func shortSessionID(_ sessionID: UUID?) -> String {
        guard let sessionID else { return "none" }
        return String(sessionID.uuidString.prefix(8))
    }

    private func errorFields(error: Error, phase: String) -> [String: String] {
        let nsError = error as NSError
        return [
            "phase": phase,
            "domain": nsError.domain,
            "code": "\(nsError.code)",
            "reason": error.localizedDescription,
            "elapsed_ms": "\(elapsedMs())"
        ]
    }

    private func logEvent(_ event: String, fields: [String: String]) {
        let sid = shortSessionID(ownerSessionID)
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

}
