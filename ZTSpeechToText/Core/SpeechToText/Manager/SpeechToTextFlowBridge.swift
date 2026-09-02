import Foundation
import ZTAIServices

@MainActor
public final class SpeechToTextFlowBridge {
    public enum Mode: Sendable {
        case automatic
        case liveStreaming
        case postRecording
    }

    public struct Configuration: Sendable {
        public var preferredLanguage: SupportedLanguage?
        public var mode: Mode
        public var partialPollingIntervalNanoseconds: UInt64

        public init(
            preferredLanguage: SupportedLanguage? = nil,
            mode: Mode = .automatic,
            partialPollingIntervalNanoseconds: UInt64 = 600_000_000
        ) {
            self.preferredLanguage = preferredLanguage
            self.mode = mode
            self.partialPollingIntervalNanoseconds = partialPollingIntervalNanoseconds
        }
    }

    public var onPartialText: (@MainActor (String) -> Void)?

    private let manager: SpeechToTextManager
    private var pollingTask: Task<Void, Never>?
    private var isRecording = false
    private var language: SupportedLanguage = .english
    private var pollInterval: UInt64 = 600_000_000

    public init(manager: SpeechToTextManager = .shared) {
        self.manager = manager
    }

    public func requestPermissionAndPrepare() async -> Bool {
        let available = await manager.gateFeatureUsage()
        guard available else { return false }
        return await manager.requestMicPermission()
    }

    public func start(
        configuration: Configuration = .init(),
        onPartialText: (@MainActor (String) -> Void)? = nil
    ) async throws {
        self.onPartialText = onPartialText
        try beginRecording(configuration: configuration)
    }

    public func start(configuration: Configuration = .init()) throws {
        try beginRecording(configuration: configuration)
    }

    private func beginRecording(configuration: Configuration) throws {
        guard !isRecording else { return }
        let resolvedLanguage = configuration.preferredLanguage ?? fallbackPreferredLanguage()
        language = resolvedLanguage
        pollInterval = configuration.partialPollingIntervalNanoseconds

        manager.setModelProvider(.appleModels)
        manager.setOperationMode(resolveManagerMode(from: configuration.mode))
        try manager.startListening(preferredLanguage: resolvedLanguage)

        isRecording = true
        startPollingPartials()
    }

    public func stop() async throws -> String {
        guard isRecording else { return "" }
        isRecording = false
        pollingTask?.cancel()
        pollingTask = nil
        manager.stopListening()
        let final = try await manager.transcribe(preferredLanguage: language)
        return final.text
    }

    public func cancel() {
        isRecording = false
        pollingTask?.cancel()
        pollingTask = nil
        manager.stopListening()
    }

    private func resolveManagerMode(from mode: Mode) -> SpeechToTextManager.OperationMode {
        switch mode {
        case .liveStreaming:
            return .liveStreaming
        case .postRecording:
            return .postRecording
        case .automatic:
            return manager.isOnDeviceLiveStreamingAvailable ? .liveStreaming : .postRecording
        }
    }

    private func startPollingPartials() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.isRecording {
                if let partial = try? await self.manager.transcribePartialCurrentBuffer(preferredLanguage: self.language) {
                    let text = partial.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        await self.onPartialText?(text)
                    }
                }
                try? await Task.sleep(nanoseconds: self.pollInterval)
            }
        }
    }

    private func fallbackPreferredLanguage() -> SupportedLanguage {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if preferred.hasPrefix("es") { return .spanish }
        if preferred.hasPrefix("fr") { return .french }
        return .english
    }
}
