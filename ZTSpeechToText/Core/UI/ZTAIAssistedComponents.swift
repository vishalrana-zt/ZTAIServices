import SwiftUI
import UIKit
import Combine
import ZTAIServices

private enum ZTAIStrings {
    static func localized(_ key: String, fallback: String) -> String {
        let value = ZTAIServiceLocalizer.localized(key)
        return value == key ? fallback : value
    }

    static var shortTitle: String { localized("lbl_ai_summary_short_title", fallback: "Short") }
    static var standardTitle: String { localized("lbl_ai_summary_standard_title", fallback: "Standard") }
    static var detailedTitle: String { localized("lbl_ai_summary_detailed_title", fallback: "Detailed") }

    static var shortSubtitle: String { localized("lbl_ai_summary_short_subtitle", fallback: "1-2 line") }
    static var standardSubtitle: String { localized("lbl_ai_summary_standard_subtitle", fallback: "3-5 lines") }
    static var detailedSubtitle: String { localized("lbl_ai_summary_detailed_subtitle", fallback: "Full") }

    static var statusCleaning: String { localized("lbl_ai_status_cleaning", fallback: "Cleaning up...") }
    static var statusSummarizingFormat: String { localized("lbl_ai_status_summarizing_format", fallback: "Summarizing - %@...") }

    static var cleanUpTitle: String { localized("lbl_ai_cleanup_title", fallback: "Clean Up") }
    static var cleanUpSubtitle: String { localized("lbl_ai_cleanup_subtitle", fallback: "Fix wording, keep every detail") }
    static var summarizeTitle: String { localized("lbl_ai_summarize_title", fallback: "Summarize") }
    static var summarizeSubtitle: String { localized("lbl_ai_summarize_subtitle", fallback: "Make it shorter, keep key points") }

    static var toastCleanedUp: String { localized("lbl_ai_toast_cleaned_up", fallback: "Cleaned up") }
    static var toastSummarized: String { localized("lbl_ai_toast_summarized", fallback: "Summarized") }
    static var toastNoText: String { localized("lbl_ai_toast_no_text", fallback: "No text found") }
}

public enum ZTAIAssistedLocalization {
    public static func value(_ key: String, fallback: String) -> String {
        let localized = ZTAIServiceLocalizer.localized(key)
        return localized == key ? fallback : localized
    }

    public static var stopRecordingAlertTitle: String {
        value("lbl_ai_stop_recording_alert_title", fallback: "Stop Recording?")
    }

    public static var stopRecordingAlertActionTitle: String {
        value("lbl_ai_stop_recording_alert_action", fallback: "Stop Recording")
    }

    public static var stopRecordingAlertMessage: String {
        value(
            "lbl_ai_stop_recording_alert_message",
            fallback: "Recording is in progress. Do you want to stop recording and leave this screen?"
        )
    }
}

public extension UIViewController {
    func dismissAnyOpenZTAIAssistantMenu() {
        ZTAIAssistantController.requestCloseOpenMenus()
    }

    func presentStopRecordingBeforeLeavingAlert(onStop: @escaping () -> Void) {
        let alert = UIAlertController(
            title: ZTAIAssistedLocalization.stopRecordingAlertTitle,
            message: ZTAIAssistedLocalization.stopRecordingAlertMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: ZTAIAssistedLocalization.stopRecordingAlertActionTitle,
            style: .destructive
        ) { _ in
            onStop()
        })
        alert.addAction(UIAlertAction(title: ZTAIServiceLocalizer.localized("Cancel"), style: .cancel))
        present(alert, animated: true)
    }

    func withRecordingExitGuard(
        coordinator: ZTAIAssistedTextSectionCoordinator,
        proceed: @escaping () -> Void
    ) {
        guard coordinator.hasActiveRecording else {
            proceed()
            return
        }
        presentStopRecordingBeforeLeavingAlert {
            coordinator.stopRecordingAndDismissSheet()
            proceed()
        }
    }

    func guardedPresent(
        _ viewControllerToPresent: UIViewController,
        coordinator: ZTAIAssistedTextSectionCoordinator,
        animated: Bool = true,
        completion: (() -> Void)? = nil
    ) {
        withRecordingExitGuard(coordinator: coordinator) { [weak self] in
            self?.present(viewControllerToPresent, animated: animated, completion: completion)
        }
    }

    func guardedPush(
        _ viewControllerToPush: UIViewController,
        coordinator: ZTAIAssistedTextSectionCoordinator,
        animated: Bool = true
    ) {
        withRecordingExitGuard(coordinator: coordinator) { [weak self] in
            self?.navigationController?.pushViewController(viewControllerToPush, animated: animated)
        }
    }
}

public protocol RecordingGuardExecuting: AnyObject {
    var recordingGuardCoordinator: ZTAIAssistedTextSectionCoordinator { get }
}

public extension RecordingGuardExecuting where Self: UIViewController {
    func guardRecordingAndRun(_ action: @escaping () -> Void) {
        withRecordingExitGuard(coordinator: recordingGuardCoordinator, proceed: action)
    }
}

public extension View {
    func dismissOpenZTAIAssistantMenuOnTap() -> some View {
        simultaneousGesture(
            TapGesture().onEnded {
                ZTAIAssistantController.requestCloseOpenMenus()
            }
        )
    }
}

public enum ZTAISummaryStyle: String, CaseIterable {
    case short
    case standard
    case detailed

    public var title: String {
        switch self {
        case .short: return ZTAIStrings.shortTitle
        case .standard: return ZTAIStrings.standardTitle
        case .detailed: return ZTAIStrings.detailedTitle
        }
    }

    public var subtitle: String {
        switch self {
        case .short: return ZTAIStrings.shortSubtitle
        case .standard: return ZTAIStrings.standardSubtitle
        case .detailed: return ZTAIStrings.detailedSubtitle
        }
    }

    public var textAIStyle: TextAISummaryStyle {
        switch self {
        case .short: return .short
        case .standard: return .standard
        case .detailed: return .detailed
        }
    }
}

public enum ZTAIStatus: Equatable {
    case idle
    case cleaningUp
    case summarizing(ZTAISummaryStyle)

    public var label: String {
        switch self {
        case .idle:
            return ""
        case .cleaningUp:
            return ZTAIStrings.statusCleaning
        case let .summarizing(style):
            return String(format: ZTAIStrings.statusSummarizingFormat, style.title.lowercased())
        }
    }
}

public enum ZTAIToastStyle: Equatable {
    case success
    case error
}

public struct ZTAIToastState: Equatable {
    public let title: String
    public let badge: String?
    public let style: ZTAIToastStyle

    public init(title: String, badge: String?, style: ZTAIToastStyle) {
        self.title = title
        self.badge = badge
        self.style = style
    }
}

public enum AIGlyphPhase: Equatable {
    case idle
    case working
    case cancellable
}

public protocol ZTAITextProcessingServiceProtocol {
    func cleanUp(text: String, preferredLanguage: SupportedLanguage) async throws -> TextAIExecutionResult
    func summarize(text: String, style: ZTAISummaryStyle, preferredLanguage: SupportedLanguage) async throws -> TextAIExecutionResult
}

@MainActor
public protocol ZTAIDictationServiceProtocol {
    func requestPermission() async -> Bool
    func start(preferredLanguage: SupportedLanguage, onPartial: @escaping @MainActor (String) -> Void) async throws
    func stop() async throws -> String
    func cancel()
}

public actor ZTAITextProcessingServiceAdapter: ZTAITextProcessingServiceProtocol {
    private let service = TextAIService()

    public init() {}

    public func cleanUp(text: String, preferredLanguage: SupportedLanguage) async throws -> TextAIExecutionResult {
        try await service.cleanup(text: text, preferredLanguage: preferredLanguage)
    }

    public func summarize(text: String, style: ZTAISummaryStyle, preferredLanguage: SupportedLanguage) async throws -> TextAIExecutionResult {
        try await service.summarize(text: text, preferredLanguage: preferredLanguage, style: style.textAIStyle)
    }
}

@MainActor
public final class ZTSpeechDictationServiceAdapter: ZTAIDictationServiceProtocol {
    private let bridge = SpeechToTextFlowBridge()

    public init() {}

    public func requestPermission() async -> Bool {
        await bridge.requestPermissionAndPrepare()
    }

    public func start(preferredLanguage: SupportedLanguage, onPartial: @escaping @MainActor (String) -> Void) async throws {
        let configuration = SpeechToTextFlowBridge.Configuration(
            preferredLanguage: preferredLanguage,
            mode: .automatic
        )
        try await bridge.start(configuration: configuration, onPartialText: onPartial)
    }

    public func stop() async throws -> String {
        try await bridge.stop()
    }

    public func cancel() {
        bridge.cancel()
    }
}

@MainActor
public final class ZTAIAssistantController: ObservableObject {
    private static let closeMenusNotification = Notification.Name("ZTAIAssistantController.closeMenus")

    public static func requestCloseOpenMenus() {
        NotificationCenter.default.post(name: closeMenusNotification, object: nil)
    }

    @Published public private(set) var isRecording = false
    @Published public private(set) var isRunningAI = false
    @Published public private(set) var status: ZTAIStatus = .idle
    @Published public private(set) var aiGlyphPhase: AIGlyphPhase = .idle
    @Published public var isMenuOpen = false
    @Published public var toastState: ZTAIToastState?
    @Published public var errorMessage: String?
    public var onAnalyticsEvent: ((String, [String: Any]) -> Void)?

    private let aiCancelRevealDelay: UInt64 = 2_000_000_000

    private let aiService: ZTAITextProcessingServiceProtocol
    private let dictationService: ZTAIDictationServiceProtocol
    private var preRunSnapshot = ""
    private var recordingBaseText = ""
    private var toastDismissTask: Task<Void, Never>?
    private var aiTask: Task<Void, Never>?
    private var aiCancelTimerTask: Task<Void, Never>?
    private var cancelApplyText: ((String) -> Void)?
    private var closeMenusObserver: NSObjectProtocol?

    public init(
        aiService: ZTAITextProcessingServiceProtocol = ZTAITextProcessingServiceAdapter(),
        dictationService: ZTAIDictationServiceProtocol? = nil
    ) {
        self.aiService = aiService
        self.dictationService = dictationService ?? ZTSpeechDictationServiceAdapter()
        closeMenusObserver = NotificationCenter.default.addObserver(
            forName: Self.closeMenusNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.closeMenu()
        }
    }

    deinit {
        if let closeMenusObserver {
            NotificationCenter.default.removeObserver(closeMenusObserver)
        }
    }

    public var isBusy: Bool {
        isRecording || isRunningAI
    }

    public func toggleMenu() {
        guard !isRunningAI else { return }
        isMenuOpen.toggle()
    }

    public func closeMenu() {
        isMenuOpen = false
    }

    public func toggleRecording(currentText: @escaping () -> String, applyText: @escaping (String) -> Void) {
        guard !isRunningAI else { return }
        errorMessage = nil
        clearToast()
        isMenuOpen = false

        if isRecording {
            stopRecording(applyText: applyText)
        } else {
            onAnalyticsEvent?("AI_MIC_TAPPED", [:])
            startRecording(currentText: currentText, applyText: applyText)
        }
    }

    public func runCleanUp(currentText: @escaping () -> String, applyText: @escaping (String) -> Void) {
        onAnalyticsEvent?("AI_CLEANUP_TAPPED", [:])
        runAIAction(action: .cleaningUp, currentText: currentText, applyText: applyText)
    }

    public func runSummarize(style: ZTAISummaryStyle, currentText: @escaping () -> String, applyText: @escaping (String) -> Void) {
        onAnalyticsEvent?("AI_SUMMARIZE_TAPPED", ["mode": style.rawValue])
        runAIAction(action: .summarizing(style), currentText: currentText, applyText: applyText)
    }

    public func undoLastResult(applyText: @escaping (String) -> Void) {
        guard !preRunSnapshot.isEmpty || !(toastState?.title.isEmpty ?? true) else { return }
        applyText(preRunSnapshot)
        clearToast()
    }

    public func cancelAIOperation() {
        guard aiGlyphPhase == .cancellable else { return }
        aiTask?.cancel()
        aiTask = nil
        aiCancelTimerTask?.cancel()
        aiCancelTimerTask = nil
        cancelApplyText?(preRunSnapshot)
        cancelApplyText = nil
        isRunningAI = false
        status = .idle
        aiGlyphPhase = .idle
    }

    public func cancelActiveOperations() {
        aiTask?.cancel()
        aiTask = nil
        aiCancelTimerTask?.cancel()
        aiCancelTimerTask = nil
        cancelApplyText = nil
        dictationService.cancel()
        isRecording = false
        isRunningAI = false
        status = .idle
        aiGlyphPhase = .idle
        errorMessage = nil
        closeMenu()
        toastDismissTask?.cancel()
    }

    public func clearError() {
        errorMessage = nil
    }

    private func startRecording(currentText: @escaping () -> String, applyText: @escaping (String) -> Void) {
        recordingBaseText = currentText()
        isRecording = true

        Task { [weak self] in
            guard let self else { return }
            let hasPermission = await self.dictationService.requestPermission()
            guard hasPermission else {
                await MainActor.run { self.isRecording = false }
                return
            }

            do {
                let language = self.preferredLanguage()
                try await self.dictationService.start(preferredLanguage: language) { partialText in
                    self.applyDictationText(partialText, applyText: applyText)
                }
            } catch {
                await MainActor.run { self.isRecording = false }
            }
        }
    }

    private func stopRecording(applyText: @escaping (String) -> Void) {
        isRecording = false
        Task { [weak self] in
            guard let self else { return }
            do {
                let finalText = try await self.dictationService.stop()
                await MainActor.run { self.applyDictationText(finalText, applyText: applyText) }
            } catch {}
        }
    }

    private func applyDictationText(_ transcript: String, applyText: @escaping (String) -> Void) {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        let base = recordingBaseText.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty {
            applyText(cleaned)
        } else {
            applyText(base + "\n" + cleaned)
        }
    }

    private func runAIAction(action: ZTAIStatus, currentText: @escaping () -> String, applyText: @escaping (String) -> Void) {
        guard !isRunningAI else { return }

        isMenuOpen = false
        let source = currentText().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            presentToast(title: ZTAIStrings.toastNoText, badge: nil, style: .error)
            return
        }

        if isRecording {
            dictationService.cancel()
            isRecording = false
        }

        clearToast()
        errorMessage = nil
        preRunSnapshot = currentText()
        cancelApplyText = applyText
        isRunningAI = true
        status = action
        aiGlyphPhase = .working

        aiCancelTimerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.aiCancelRevealDelay ?? 3_500_000_000)
            await MainActor.run {
                guard let self, self.isRunningAI, self.aiGlyphPhase == .working else { return }
                self.aiGlyphPhase = .cancellable
            }
        }

        aiTask = Task { [weak self] in
            guard let self else { return }
            do {
                let language = self.preferredLanguage()
                let result: TextAIExecutionResult
                switch action {
                case .cleaningUp:
                    result = try await self.aiService.cleanUp(text: self.preRunSnapshot, preferredLanguage: language)
                case let .summarizing(style):
                    result = try await self.aiService.summarize(text: self.preRunSnapshot, style: style, preferredLanguage: language)
                case .idle:
                    result = TextAIExecutionResult(provider: .cloudAPI, outputText: self.preRunSnapshot)
                }

                await MainActor.run {
                    guard self.isRunningAI else { return }
                    self.aiCancelTimerTask?.cancel()
                    self.aiCancelTimerTask = nil
                    self.cancelApplyText = nil
                    applyText(result.outputText)
                    self.isRunningAI = false
                    self.status = .idle
                    self.aiGlyphPhase = .idle
                    switch action {
                    case .cleaningUp:
                        self.presentToast(title: ZTAIStrings.toastCleanedUp, badge: nil)
                    case let .summarizing(style):
                        self.presentToast(title: ZTAIStrings.toastSummarized, badge: style.title)
                    case .idle:
                        break
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.isRunningAI else { return }
                    self.aiCancelTimerTask?.cancel()
                    self.aiCancelTimerTask = nil
                    self.cancelApplyText = nil
                    self.isRunningAI = false
                    self.status = .idle
                    self.aiGlyphPhase = .idle
                    self.errorMessage = (error as? TextAIError)?.localizedDescription ?? error.localizedDescription
                }
            }
        }
    }

    private func preferredLanguage() -> SupportedLanguage {
        ZTAIServiceLocalizer.resolvedSupportedLanguage()
    }

    private func presentToast(title: String, badge: String?, style: ZTAIToastStyle = .success) {
        toastDismissTask?.cancel()
        toastState = ZTAIToastState(title: title, badge: badge, style: style)
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run { self?.toastState = nil }
        }
    }

    private func clearToast() {
        toastDismissTask?.cancel()
        toastDismissTask = nil
        toastState = nil
    }
}

public struct ZTAIAssistantButtonRow: View {
    @ObservedObject public var controller: ZTAIAssistantController
    public let onMicTap: () -> Void
    public let onAITap: () -> Void
    public var isRecordingOverride: Bool? = nil
    public var aiButtonDisabled: Bool = false

    public init(
        controller: ZTAIAssistantController,
        onMicTap: @escaping () -> Void,
        onAITap: @escaping () -> Void,
        isRecordingOverride: Bool? = nil,
        aiButtonDisabled: Bool = false
    ) {
        self.controller = controller
        self.onMicTap = onMicTap
        self.onAITap = onAITap
        self.isRecordingOverride = isRecordingOverride
        self.aiButtonDisabled = aiButtonDisabled
    }

    private var isRecording: Bool {
        isRecordingOverride ?? controller.isRecording
    }

    private var isAIButtonBlocked: Bool {
        isRecording || aiButtonDisabled
    }

    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    private var buttonSize: CGFloat { isPhone ? 40 : 48 }
    private var buttonSpacing: CGFloat { isPhone ? 8 : 12 }
    private var iconFont: Font { isPhone ? .headline : .title2 }

    public var body: some View {
        HStack(spacing: buttonSpacing) {
            Button(action: {
                dismissKeyboardIfNeeded()
                onMicTap()
            }) {
                ZStack {
                    if isRecording {
                        PulseRings(color: Color(hex: "#E0364C"))
                            .frame(width: buttonSize, height: buttonSize)
                    }
                    ZStack {
                        if isRecording {
                            RecordingWaveformIcon(isAnimated: true)
                        } else {
                            Image(systemName: "mic")
                                .font(iconFont)
                                .fontWeight(.semibold)
                                .foregroundStyle(Color(hex: "#0B6BEF"))
                        }
                    }
                    .frame(width: buttonSize, height: buttonSize)
                    .background(isRecording ? Color(hex: "#E0364C") : Color(hex: "#E8F1FF"))
                    .clipShape(Circle())
                    .shadow(color: Color.black.opacity(0.12), radius: 3, x: 0, y: 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(controller.isRunningAI)

            Button(action: {
                dismissKeyboardIfNeeded()
                switch controller.aiGlyphPhase {
                case .idle:   onAITap()
                case .working: break
                case .cancellable: controller.cancelAIOperation()
                }
            }) {
                ZStack {
                    if controller.isRunningAI {
                        PulseRings(color: Color(hex: "#0B6BEF"))
                            .frame(width: buttonSize, height: buttonSize)
                    }
                    ZStack {
                        switch controller.aiGlyphPhase {
                        case .idle:
                            Image(systemName: "sparkles")
                                .font(iconFont)
                                .fontWeight(.semibold)
                                .foregroundStyle(controller.isMenuOpen ? Color.white : Color(hex: "#0B6BEF"))
                                .transition(.scale(scale: 0.94).combined(with: .opacity))
                        case .working:
                            AISparkleLoadingGlyph(isAnimated: true)
                                .transition(.scale(scale: 0.94).combined(with: .opacity))
                        case .cancellable:
                            CancelXGlyph()
                                .transition(.scale(scale: 0.94).combined(with: .opacity))
                        }
                    }
                    .frame(width: buttonSize, height: buttonSize)
                    .background((controller.isRunningAI || controller.isMenuOpen) ? Color(hex: "#0B6BEF") : Color(hex: "#E8F1FF"))
                    .clipShape(Circle())
                    .shadow(color: Color.black.opacity(0.12), radius: 3, x: 0, y: 1)
                    .animation(.easeOut(duration: 0.18), value: controller.aiGlyphPhase)
                }
            }
            .buttonStyle(.plain)
            .disabled(isAIButtonBlocked)
            .opacity(isAIButtonBlocked ? 0.4 : 1.0)
            .accessibilityLabel(controller.aiGlyphPhase == .cancellable ? "Cancel" : "AI actions")
        }
    }
}

private struct PulseRings: View {
    let color: Color
    @State private var animate = false

    var body: some View {
        ZStack {
            ring(delay: 0)
            ring(delay: 0.7)
        }
        .allowsHitTesting(false)
        .onAppear { animate = true }
    }

    private func ring(delay: Double) -> some View {
        Circle()
            .strokeBorder(color.opacity(0.5), lineWidth: 2)
            .padding(-3)
            .scaleEffect(animate ? 1.5 : 0.85)
            .opacity(animate ? 0 : 0.9)
            .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false).delay(delay), value: animate)
    }
}

private struct AISparkleLoadingGlyph: View {
    let isAnimated: Bool
    @State private var pulse = false
    @State private var animateWhole = false

    var body: some View {
        ZStack {
            Image(systemName: "sparkles")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(Color.white)
                .scaleEffect(isAnimated && pulse ? 0.74 : 1.06, anchor: .center)
                .opacity(isAnimated && pulse ? 0.3 : 1.0)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)

            Image(systemName: "sparkle")
                .font(.footnote)
                .fontWeight(.bold)
                .foregroundStyle(Color.white)
                .offset(x: 7, y: -6)
                .scaleEffect(isAnimated && pulse ? 1.02 : 0.75, anchor: .center)
                .opacity(isAnimated && pulse ? 1.0 : 0.3)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true).delay(0.55), value: pulse)
        }
        .scaleEffect(isAnimated && animateWhole ? 1.12 : 1.0)
        .rotationEffect(.degrees(isAnimated && animateWhole ? 9 : 0))
        .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: animateWhole)
        .onAppear {
            guard isAnimated else { return }
            animateWhole = true
            pulse = true
        }
        .onChange(of: isAnimated) { animated in
            if animated { animateWhole = true; pulse = true }
            else { animateWhole = false; pulse = false }
        }
    }
}

private struct ZTAISectionPressButtonStyle: ButtonStyle {
    private let normalBackground = Color(hex: "#F5F7FB")
    private let pressedBackground = Color(hex: "#E8F1FF")
    private let normalBorder = Color.black.opacity(0.07)
    private let pressedBorder = Color(hex: "#0B6BEF")

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(configuration.isPressed ? pressedBackground : normalBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(configuration.isPressed ? pressedBorder : normalBorder, lineWidth: configuration.isPressed ? 1 : 0.5)
                    )
            )
    }
}

private struct ZTAISummaryPillButtonStyle: ButtonStyle {
    private let normalBackground = Color.white
    private let pressedBackground = Color(hex: "#E8F1FF")
    private let normalBorder = Color.black.opacity(0.11)
    private let pressedBorder = Color(hex: "#0B6BEF")

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(configuration.isPressed ? pressedBackground : normalBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(configuration.isPressed ? pressedBorder : normalBorder, lineWidth: configuration.isPressed ? 1 : 0.5)
                    )
            )
    }
}

public struct ZTAIAssistantMenuOverlay: View {
    @ObservedObject public var controller: ZTAIAssistantController
    public let menuAlignment: Alignment
    public let menuOffset: CGSize
    public let onCleanupTap: () -> Void
    public let onSummarizeTap: (ZTAISummaryStyle) -> Void
    public let onUndoTap: () -> Void

    public init(
        controller: ZTAIAssistantController,
        menuAlignment: Alignment,
        menuOffset: CGSize,
        onCleanupTap: @escaping () -> Void,
        onSummarizeTap: @escaping (ZTAISummaryStyle) -> Void,
        onUndoTap: @escaping () -> Void
    ) {
        self.controller = controller
        self.menuAlignment = menuAlignment
        self.menuOffset = menuOffset
        self.onCleanupTap = onCleanupTap
        self.onSummarizeTap = onSummarizeTap
        self.onUndoTap = onUndoTap
    }

    private var menuTransition: AnyTransition {
        .scale(scale: 0.95, anchor: .bottomTrailing).combined(with: .opacity)
    }

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    private var menuOuterPadding: CGFloat { 8 }
    private var sectionPadding: CGFloat { isPhone ? 10 : 12 }
    private var sectionCornerRadius: CGFloat { isPhone ? 16 : 14 }
    private var popupCornerRadius: CGFloat { isPhone ? 16 : 20 }
    private var sectionRowSpacing: CGFloat { isPhone ? 8 : 12 }
    private var summaryPillSpacing: CGFloat { isPhone ? 6 : 8 }
    private var summaryPillVerticalPadding: CGFloat { isPhone ? 8 : 10 }
    private var iconTextSpacing: CGFloat { isPhone ? 8 : 12 }
    private var subtitleFont: Font { .footnote }
    private var menuWidth: CGFloat { isPhone ? min(300, UIScreen.main.bounds.width - 28) : 328 }

    public var body: some View {
        ZStack {
            if controller.isMenuOpen {
                Rectangle()
                    .fill(Color.black.opacity(0.001))
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .onTapGesture { controller.closeMenu() }
                    .transition(.opacity)
            }

            if controller.isMenuOpen {
                menuCard
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: menuAlignment)
                    .offset(menuOffset)
                    .zIndex(10_000)
                    .transition(menuTransition)
            }

            if let toast = controller.toastState {
                ZTAIAssistantToastView(toast: toast, onUndoTap: onUndoTap)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controller.isMenuOpen)
        .animation(.easeInOut(duration: 0.2), value: controller.toastState)
    }

    private var menuCard: some View {
        VStack(alignment: .leading, spacing: isPhone ? 6 : 8) {
            Button {
                dismissKeyboardIfNeeded()
                onCleanupTap()
            } label: {
                HStack(spacing: iconTextSpacing) {
                    tileIcon(systemName: "sparkles")
                    VStack(alignment: .leading, spacing: 1) {
                        SwiftUI.Text(ZTAIStrings.cleanUpTitle)
                            .font(.headline).fontWeight(.semibold)
                            .foregroundStyle(Color(hex: "#10121A"))
                        SwiftUI.Text(ZTAIStrings.cleanUpSubtitle)
                            .font(subtitleFont)
                            .foregroundStyle(Color(hex: "#6C7079"))
                            .lineLimit(1).minimumScaleFactor(0.82)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(ZTAISectionPressButtonStyle())

            VStack(alignment: .leading, spacing: sectionRowSpacing) {
                HStack(spacing: iconTextSpacing) {
                    tileIcon(systemName: "text.justify.left")
                    VStack(alignment: .leading, spacing: 1) {
                        SwiftUI.Text(ZTAIStrings.summarizeTitle)
                            .font(.headline).fontWeight(.semibold)
                            .foregroundStyle(Color(hex: "#10121A"))
                        SwiftUI.Text(ZTAIStrings.summarizeSubtitle)
                            .font(.footnote)
                            .foregroundStyle(Color(hex: "#6C7079"))
                            .lineLimit(1).minimumScaleFactor(0.82)
                    }
                }

                HStack(spacing: summaryPillSpacing) {
                    ForEach(ZTAISummaryStyle.allCases, id: \.self) { style in
                        Button {
                            dismissKeyboardIfNeeded()
                            onSummarizeTap(style)
                        } label: {
                            VStack(spacing: 1) {
                                SwiftUI.Text(style.title)
                                    .font(.subheadline).fontWeight(.semibold)
                                    .foregroundStyle(Color(hex: "#10121A"))
                                SwiftUI.Text(style.subtitle)
                                    .font(subtitleFont)
                                    .foregroundStyle(Color(hex: "#6C7079"))
                                    .lineLimit(1).minimumScaleFactor(0.82)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, summaryPillVerticalPadding)
                        }
                        .buttonStyle(ZTAISummaryPillButtonStyle())
                    }
                }
            }
            .padding(sectionPadding)
            .background(
                RoundedRectangle(cornerRadius: sectionCornerRadius, style: .continuous)
                    .fill(Color(hex: "#F5F7FB"))
                    .overlay(
                        RoundedRectangle(cornerRadius: sectionCornerRadius, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.07), lineWidth: 0.5)
                    )
            )
        }
        .padding(menuOuterPadding)
        .frame(width: menuWidth)
        .background(
            RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.09), lineWidth: 0.5)
                )
        )
        .compositingGroup()
        .shadow(color: Color(hex: "#10121A").opacity(0.30), radius: 30, x: 0, y: 14)
    }

    private func tileIcon(systemName: String) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(hex: "#E8F1FF"))
            .frame(width: 30, height: 30)
            .overlay {
                Image(systemName: systemName)
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundStyle(Color(hex: "#0B6BEF"))
            }
    }
}

private struct ZTAIAssistantToastView: View {
    let toast: ZTAIToastState
    let onUndoTap: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.style == .error ? "exclamationmark.triangle.fill" : "checkmark")
                .font(.subheadline).fontWeight(.bold)
                .foregroundStyle(toast.style == .error ? Color.orange : Color(red: 0.114, green: 0.643, blue: 0.353))

            SwiftUI.Text(toast.title)
                .font(.subheadline).fontWeight(.medium)
                .foregroundStyle(Color(red: 0.227, green: 0.239, blue: 0.271))

            if let badge = toast.badge {
                SwiftUI.Text(badge)
                    .font(.caption2).fontWeight(.semibold)
                    .foregroundStyle(Color(red: 0.376, green: 0.404, blue: 0.475))
                    .textCase(.uppercase)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color(red: 0.945, green: 0.957, blue: 0.980), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .allowsHitTesting(false).accessibilityHidden(true)
            }

            if toast.style == .success {
                Divider().frame(height: 18)

                Button(ZTAIServiceLocalizer.localized("Undo")) { onUndoTap() }
                    .font(.subheadline).fontWeight(.semibold)
                    .foregroundStyle(Color(hex: "#0B6BEF"))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .buttonStyle(.plain)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, toast.style == .error ? 16 : 8)
        .padding(.vertical, 10)
        .background(Capsule().fill(Color.white.opacity(0.94)))
        .overlay(Capsule().stroke(Color.black.opacity(0.08), lineWidth: 0.5))
    }
}

/// A UIView wrapper that hosts a `ZTAICleanupPopupWrapper` UIHostingController.
///
/// It extends above the notes card to give the AI popup room to render and
/// receive touches. Hit-testing is gated so the extended spacer area only
/// intercepts touches when the popup is open — form fields above the notes
/// section remain fully tappable when the popup is closed.
public final class ZTAIPopupHostContainer: UIView {

    /// The view representing the notes card area (e.g. noteContainerView).
    /// Points inside this view are always forwarded to the hosting controller.
    public weak var notesCardView: UIView?

    public private(set) var isMenuOpen: Bool = false
    private var menuCancellable: AnyCancellable?

    public override init(frame: CGRect) { super.init(frame: frame) }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    public func observe(coordinator: ZTAIAssistedTextSectionCoordinator) {
        menuCancellable = coordinator.$isAIMenuOpen
            .receive(on: RunLoop.main)
            .sink { [weak self] isOpen in self?.isMenuOpen = isOpen }
    }

    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled else { return nil }
        // Points inside the notes card always reach the hosting controller (text editing).
        if let card = notesCardView {
            let cardPoint = card.convert(point, from: self)
            if card.bounds.contains(cardPoint) { return super.hitTest(point, with: event) }
        }
        // Extended spacer area: only forward when popup is open.
        guard isMenuOpen else { return nil }
        return super.hitTest(point, with: event)
    }
}

/// Wraps a `ZTAIAssistedTextSectionHostView` with a transparent spacer above
/// the editor so the AI popup—which floats above the card—can receive touches
/// when embedded in a UIHostingController constrained to a small container.
/// The spacer intercepts touches only while the popup is open, so all form
/// elements above remain fully tappable when it is closed.
public struct ZTAICleanupPopupWrapper: View {
    @ObservedObject public var coordinator: ZTAIAssistedTextSectionCoordinator
    public let content: ZTAIAssistedTextSectionHostView

    public init(coordinator: ZTAIAssistedTextSectionCoordinator, content: ZTAIAssistedTextSectionHostView) {
        self.coordinator = coordinator
        self.content = content
    }

    /// Returns the spacer height needed for a given notes view. Pass the
    /// negated result as the `constant` on the hosting view's `topAnchor`
    /// constraint so the notes card renders at the original container position.
    ///
    /// Formula: estimated popup height + button offset – editor min height,
    /// floored at 100pt, plus a 30pt safety buffer.
    public static func overflowHeight(for content: ZTAIAssistedTextSectionHostView) -> CGFloat {
        let buttonOffset: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 56 : 58
        let estimatedPopupHeight: CGFloat = 210
        let raw = estimatedPopupHeight + buttonOffset - content.editorMinHeight
        return max(100, raw) + 30
    }

    private var overflowHeight: CGFloat { Self.overflowHeight(for: content) }

    public var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: overflowHeight)
                .allowsHitTesting(coordinator.isAIMenuOpen)
                .onTapGesture {
                    ZTAIAssistantController.requestCloseOpenMenus()
                }
            content
        }
    }
}

@MainActor
private func dismissKeyboardIfNeeded() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

private struct CancelXGlyph: View {
    var body: some View {
        Canvas { context, size in
            let side: CGFloat = 15
            let d = (side / 2) / sqrt(2)
            let cx = size.width / 2
            let cy = size.height / 2
            var path = Path()
            path.move(to: CGPoint(x: cx - d, y: cy - d))
            path.addLine(to: CGPoint(x: cx + d, y: cy + d))
            path.move(to: CGPoint(x: cx + d, y: cy - d))
            path.addLine(to: CGPoint(x: cx - d, y: cy + d))
            context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        }
        .frame(width: 15, height: 15)
    }
}

private struct RecordingWaveformIcon: View {
    let isAnimated: Bool
    @State private var animate = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 3, height: 17)
                    .scaleEffect(y: isAnimated && animate ? 0.35 : 1.0, anchor: .center)
                    .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true).delay(Double(index) * 0.12), value: animate)
            }
        }
        .onAppear { animate = isAnimated }
        .onChange(of: isAnimated) { animated in animate = animated }
    }
}
