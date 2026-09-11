import SwiftUI
import UIKit
import Combine
import ZTAIServices

public struct ZTAIAssistedTextSectionHostView: View {
    @ObservedObject public var coordinator: ZTAIAssistedTextSectionCoordinator
    public let title: String
    public var placeholder: String? = nil
    @Binding public var text: String
    public let isReadOnly: Bool
    public var showCharacterCount: Bool = false
    public var characterLimit: Int = 0
    public var characterCountLabel: String = ""
    public var readOnlyMinHeight: CGFloat = 80
    public var editorMinHeight: CGFloat = 150
    public var editorMaxHeight: CGFloat = 300
    public var showBorder: Bool = true
    public var cardBackground: Color = Color(.systemBackground)
    public var showEditorBorder: Bool = true
    public var editorBorderColor: Color = Color(hex: "#AFAFAF")
    public var editorBorderWidth: CGFloat = 0.5
    public var showShadow: Bool = false
    public var editorBackground: Color = Color(.secondarySystemBackground)
    public var showButtonsInHeader: Bool = true
    public var showTitle: Bool = true
    public var titleFont: Font = .callout.weight(.semibold)
    public var titleColor: Color = .primary
    public var editorTextStyle: UIFont.TextStyle = .callout
    public var editorHorizontalPadding: CGFloat = 8
    public var placeholderHorizontalPadding: CGFloat = 14
    public var aiMenuOffset: CGSize? = nil
    public var topPadding: CGFloat? = nil
    public var bottomPadding: CGFloat? = nil
    /// Set to false when an external keyboard manager (IQKeyboardManager) is active on the
    /// host screen — the built-in Done toolbar conflicts with IQKeyboardManager's scroll calc.
    public var showDoneToolbar: Bool = true
    public var dismissKeyboard: () -> Void
    public var onDisappear: (() -> Void)? = nil

    public init(
        coordinator: ZTAIAssistedTextSectionCoordinator,
        title: String,
        placeholder: String? = nil,
        text: Binding<String>,
        isReadOnly: Bool,
        showCharacterCount: Bool = false,
        characterLimit: Int = 0,
        characterCountLabel: String = "",
        readOnlyMinHeight: CGFloat = 80,
        editorMinHeight: CGFloat = 150,
        editorMaxHeight: CGFloat = 300,
        showBorder: Bool = true,
        cardBackground: Color = Color(.systemBackground),
        showEditorBorder: Bool = true,
        editorBorderColor: Color = Color(hex: "#AFAFAF"),
        editorBorderWidth: CGFloat = 0.5,
        showShadow: Bool = false,
        editorBackground: Color = Color(.secondarySystemBackground),
        showButtonsInHeader: Bool = true,
        showTitle: Bool = true,
        titleFont: Font = .callout.weight(.semibold),
        titleColor: Color = .primary,
        editorTextStyle: UIFont.TextStyle = .callout,
        editorHorizontalPadding: CGFloat = 8,
        placeholderHorizontalPadding: CGFloat = 14,
        aiMenuOffset: CGSize? = nil,
        topPadding: CGFloat? = nil,
        bottomPadding: CGFloat? = nil,
        showDoneToolbar: Bool = true,
        dismissKeyboard: @escaping () -> Void,
        onDisappear: (() -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.title = title
        self.placeholder = placeholder
        self._text = text
        self.isReadOnly = isReadOnly
        self.showCharacterCount = showCharacterCount
        self.characterLimit = characterLimit
        self.characterCountLabel = characterCountLabel
        self.readOnlyMinHeight = readOnlyMinHeight
        self.editorMinHeight = editorMinHeight
        self.editorMaxHeight = editorMaxHeight
        self.showBorder = showBorder
        self.cardBackground = cardBackground
        self.showEditorBorder = showEditorBorder
        self.editorBorderColor = editorBorderColor
        self.editorBorderWidth = editorBorderWidth
        self.showShadow = showShadow
        self.editorBackground = editorBackground
        self.showButtonsInHeader = showButtonsInHeader
        self.showTitle = showTitle
        self.titleFont = titleFont
        self.titleColor = titleColor
        self.editorTextStyle = editorTextStyle
        self.editorHorizontalPadding = editorHorizontalPadding
        self.placeholderHorizontalPadding = placeholderHorizontalPadding
        self.aiMenuOffset = aiMenuOffset
        self.topPadding = topPadding
        self.bottomPadding = bottomPadding
        self.showDoneToolbar = showDoneToolbar
        self.dismissKeyboard = dismissKeyboard
        self.onDisappear = onDisappear
    }

    public var body: some View {
        ZTAIAssistedTextSectionCard(
            title: title,
            placeholder: placeholder,
            text: $text,
            isReadOnly: isReadOnly,
            showCharacterCount: showCharacterCount,
            characterLimit: characterLimit,
            characterCountLabel: characterCountLabel,
            readOnlyMinHeight: readOnlyMinHeight,
            editorMinHeight: editorMinHeight,
            editorMaxHeight: editorMaxHeight,
            showBorder: showBorder,
            cardBackground: cardBackground,
            showEditorBorder: showEditorBorder,
            editorBorderColor: editorBorderColor,
            editorBorderWidth: editorBorderWidth,
            showShadow: showShadow,
            editorBackground: editorBackground,
            showButtonsInHeader: showButtonsInHeader,
            showTitle: showTitle,
            titleFont: titleFont,
            titleColor: titleColor,
            editorTextStyle: editorTextStyle,
            editorHorizontalPadding: editorHorizontalPadding,
            placeholderHorizontalPadding: placeholderHorizontalPadding,
            aiMenuOffset: aiMenuOffset,
            topPadding: topPadding,
            bottomPadding: bottomPadding,
            isSpeechToTextSheetPresented: coordinator.isSpeechToTextSheetPresented,
            isSpeechRecordingActive: coordinator.isSpeechRecordingActive,
            livePreviewText: coordinator.livePreviewText,
            activeModelBadge: coordinator.activeModelBadge,
            onMicTap: {
                coordinator.handleMicTap(
                    isReadOnly: isReadOnly,
                    dismissKeyboard: dismissKeyboard
                )
            },
            onDisappear: {
                coordinator.handleSectionDisappear()
                onDisappear?()
            },
            onAIMenuOpenChanged: { isOpen in
                coordinator.isAIMenuOpen = isOpen
            },
            onCleanupAnalyticsTap: {
                coordinator.reportCleanupTapped()
            },
            onSummarizeAnalyticsTap: { style in
                coordinator.reportSummarizeTapped(style: style)
            },
            showDoneToolbar: showDoneToolbar
        )
    }
}

public struct ZTAIAssistedSpeechToTextSheetHostView: View {
    @ObservedObject public var coordinator: ZTAIAssistedTextSectionCoordinator
    public let currentText: () -> String
    public let applyText: (String) -> Void

    public init(
        coordinator: ZTAIAssistedTextSectionCoordinator,
        currentText: @escaping () -> String,
        applyText: @escaping (String) -> Void
    ) {
        self.coordinator = coordinator
        self.currentText = currentText
        self.applyText = applyText
    }

    public var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .speechToTextSheet(
                isPresented: $coordinator.isSpeechToTextSheetPresented,
                configuration: coordinator.speechSheetConfiguration,
                onLiveTranscriptChanged: { partial in
                    coordinator.updateRecordingState(true)
                    coordinator.handleLiveTranscriptPartial(
                        partial,
                        currentText: currentText,
                        applyText: applyText
                    )
                },
                onTextReady: { sessionID, transcribedText in
                    coordinator.updateRecordingState(false)
                    coordinator.handleFinalTranscript(
                        sessionID: sessionID,
                        finalText: transcribedText,
                        currentText: currentText,
                        applyText: applyText
                    )
                },
                onRecordingStateChanged: { isRecording in
                    coordinator.updateRecordingState(isRecording)
                }
            )
            .onChange(of: coordinator.isSpeechToTextSheetPresented) { isPresented in
                coordinator.handleSheetPresentationChanged(isPresented)
            }
            .onAppear {
                coordinator.prepareForScreenAppearance()
            }
    }
}

public struct ZTAIAssistedTextSectionCard: View {
    public let title: String
    public var placeholder: String? = nil
    @Binding public var text: String
    public let isReadOnly: Bool
    public var showCharacterCount: Bool = false
    public var characterLimit: Int = 0
    public var characterCountLabel: String = ""
    public var readOnlyMinHeight: CGFloat = 80
    public var editorMinHeight: CGFloat = 150
    public var editorMaxHeight: CGFloat = 300
    public var showBorder: Bool = true
    public var cardBackground: Color = Color(.systemBackground)
    public var showEditorBorder: Bool = true
    public var editorBorderColor: Color = Color(hex: "#AFAFAF")
    public var editorBorderWidth: CGFloat = 0.5
    public var showShadow: Bool = false
    public var editorBackground: Color = Color(.secondarySystemBackground)
    public var showButtonsInHeader: Bool = true
    public var showTitle: Bool = true
    public var titleFont: Font = .headline
    public var titleColor: Color = .primary
    public var editorTextStyle: UIFont.TextStyle = .callout
    public var editorHorizontalPadding: CGFloat = 8
    public var placeholderHorizontalPadding: CGFloat = 14
    public var aiMenuOffset: CGSize? = nil
    public var topPadding: CGFloat? = nil
    public var bottomPadding: CGFloat? = nil
    public var isSpeechToTextSheetPresented: Bool = false
    public var isSpeechRecordingActive: Bool = false
    public var livePreviewText: String = ""
    public var activeModelBadge: ZTAIModelBadgeKind? = nil
    public var onMicTap: (() -> Void)?
    public var onDisappear: (() -> Void)?
    public var onAIMenuOpenChanged: ((Bool) -> Void)?
    public var onCleanupAnalyticsTap: (() -> Void)?
    public var onSummarizeAnalyticsTap: ((ZTAISummaryStyle) -> Void)?
    public var showDoneToolbar: Bool = true

    @StateObject private var aiController = ZTAIAssistantController()
    @State private var editorText: String = ""

    private var sectionCornerRadius: CGFloat { 16 }
    private var editorCornerRadius: CGFloat { 12 }
    private var cardVerticalPadding: CGFloat { showBorder ? 16 : 8 }
    private var cardHorizontalPadding: CGFloat { (showBorder || showShadow) ? 16 : 0 }

    private var canUseAIFeatures: Bool { !isReadOnly }

    private var resolvedAIMenuOffset: CGSize {
        if let aiMenuOffset { return aiMenuOffset }
        let buttonDiameter: CGFloat = 46
        let menuGap: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 10 : 12
        return CGSize(width: -(buttonDiameter + menuGap), height: -(buttonDiameter + menuGap))
    }

    private var shouldShowLiveCaret: Bool {
        isSpeechToTextSheetPresented && !livePreviewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isEditorDisabled: Bool {
        aiController.isRunningAI || isSpeechToTextSheetPresented
    }

    private var shouldShowHeaderRow: Bool {
        let hasTitle = showTitle && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasTitle || (canUseAIFeatures && showButtonsInHeader)
    }

    private var resolvedModelBadge: ZTAIModelBadgeKind? {
        activeModelBadge ?? aiController.activeModelBadge
    }

    private var characterCountText: String {
        characterCountLabel.isEmpty
            ? "\(editorText.count)/\(characterLimit)"
            : "\(editorText.count)/\(characterLimit) \(characterCountLabel)"
    }

    private var resolvedPlaceholder: String {
        let custom = placeholder?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty { return custom }

        if canUseAIFeatures {
            let key = "lbl_Write_note_or_tap_mic"
            let localized = ZTAIServiceLocalizer.localized(key)
            return localized == key ? "Write your note or tap mic to dictate..." : localized
        }

        let key = "lbl_Write_note_here"
        let localized = ZTAIServiceLocalizer.localized(key)
        return localized == key ? "Write your note here..." : localized
    }

    public init(
        title: String,
        placeholder: String? = nil,
        text: Binding<String>,
        isReadOnly: Bool,
        showCharacterCount: Bool = false,
        characterLimit: Int = 0,
        characterCountLabel: String = "",
        readOnlyMinHeight: CGFloat = 80,
        editorMinHeight: CGFloat = 150,
        editorMaxHeight: CGFloat = 300,
        showBorder: Bool = true,
        cardBackground: Color = Color(.systemBackground),
        showEditorBorder: Bool = true,
        editorBorderColor: Color = Color(hex: "#AFAFAF"),
        editorBorderWidth: CGFloat = 0.5,
        showShadow: Bool = false,
        editorBackground: Color = Color(.secondarySystemBackground),
        showButtonsInHeader: Bool = true,
        showTitle: Bool = true,
        titleFont: Font = .headline,
        titleColor: Color = .primary,
        editorTextStyle: UIFont.TextStyle = .callout,
        editorHorizontalPadding: CGFloat = 8,
        placeholderHorizontalPadding: CGFloat = 14,
        aiMenuOffset: CGSize? = nil,
        topPadding: CGFloat? = nil,
        bottomPadding: CGFloat? = nil,
        isSpeechToTextSheetPresented: Bool = false,
        isSpeechRecordingActive: Bool = false,
        livePreviewText: String = "",
        activeModelBadge: ZTAIModelBadgeKind? = nil,
        onMicTap: (() -> Void)? = nil,
        onDisappear: (() -> Void)? = nil,
        onAIMenuOpenChanged: ((Bool) -> Void)? = nil,
        onCleanupAnalyticsTap: (() -> Void)? = nil,
        onSummarizeAnalyticsTap: ((ZTAISummaryStyle) -> Void)? = nil,
        showDoneToolbar: Bool = true
    ) {
        self.title = title
        self.placeholder = placeholder
        self._text = text
        self.isReadOnly = isReadOnly
        self.showCharacterCount = showCharacterCount
        self.characterLimit = characterLimit
        self.characterCountLabel = characterCountLabel
        self.readOnlyMinHeight = readOnlyMinHeight
        self.editorMinHeight = editorMinHeight
        self.editorMaxHeight = editorMaxHeight
        self.showBorder = showBorder
        self.cardBackground = cardBackground
        self.showEditorBorder = showEditorBorder
        self.editorBorderColor = editorBorderColor
        self.editorBorderWidth = editorBorderWidth
        self.showShadow = showShadow
        self.editorBackground = editorBackground
        self.showButtonsInHeader = showButtonsInHeader
        self.showTitle = showTitle
        self.titleFont = titleFont
        self.titleColor = titleColor
        self.editorTextStyle = editorTextStyle
        self.editorHorizontalPadding = editorHorizontalPadding
        self.placeholderHorizontalPadding = placeholderHorizontalPadding
        self.aiMenuOffset = aiMenuOffset
        self.topPadding = topPadding
        self.bottomPadding = bottomPadding
        self.isSpeechToTextSheetPresented = isSpeechToTextSheetPresented
        self.isSpeechRecordingActive = isSpeechRecordingActive
        self.livePreviewText = livePreviewText
        self.activeModelBadge = activeModelBadge
        self.onMicTap = onMicTap
        self.onDisappear = onDisappear
        self.onAIMenuOpenChanged = onAIMenuOpenChanged
        self.onCleanupAnalyticsTap = onCleanupAnalyticsTap
        self.onSummarizeAnalyticsTap = onSummarizeAnalyticsTap
        self.showDoneToolbar = showDoneToolbar
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if shouldShowHeaderRow {
                HStack(alignment: .center, spacing: 12) {
                    if showTitle && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        SwiftUI.Text(title)
                            .font(titleFont)
                            .foregroundStyle(titleColor)
                    }
                    if let badge = resolvedModelBadge {
                        ZTAIModelBadge(kind: badge)
                    }
                    Spacer()
                    if canUseAIFeatures && showButtonsInHeader {
                        ZTAIAssistantButtonRow(
                            controller: aiController,
                            onMicTap: {
                                guard !aiController.isRunningAI else { return }
                                aiController.closeMenu()
                                onMicTap?()
                            },
                            onAITap: { aiController.toggleMenu() },
                            isRecordingOverride: isSpeechRecordingActive,
                            aiButtonDisabled: isSpeechToTextSheetPresented
                        )
                    }
                }
            }

            Group {
                if isReadOnly {
                    ScrollView {
                        SwiftUI.Text(verbatim: editorText)
                            .font(.body)
                            .foregroundStyle(Color.primary)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                            .textSelection(.enabled)
                            .padding(4)
                    }
                    .frame(minHeight: readOnlyMinHeight, maxHeight: editorMaxHeight)
                } else {
                    ZStack(alignment: .topLeading) {
                        LiveAwareTextView(
                            text: $editorText,
                            shouldAutoScrollLiveInsertion: isSpeechToTextSheetPresented,
                            shouldShowLiveCaret: shouldShowLiveCaret,
                            textStyle: editorTextStyle,
                            showDoneToolbar: showDoneToolbar
                        )
                        .frame(minHeight: editorMinHeight, maxHeight: editorMaxHeight)
                        .padding(.horizontal, editorHorizontalPadding)
                        .padding(.top, 8)
                        .padding(.bottom, canUseAIFeatures && !showButtonsInHeader ? 56 : 8)
                        .disabled(isEditorDisabled)

                        if editorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            SwiftUI.Text(resolvedPlaceholder)
                                .font(.body)
                                .foregroundStyle(.secondary.opacity(0.55))
                                .padding(.horizontal, placeholderHorizontalPadding)
                                .padding(.vertical, 14)
                                .allowsHitTesting(false)
                        }

                        if canUseAIFeatures && !showButtonsInHeader {
                            VStack {
                                Spacer()
                                HStack {
                                    Spacer()
                                    ZTAIAssistantButtonRow(
                                        controller: aiController,
                                        onMicTap: {
                                            guard !aiController.isRunningAI else { return }
                                            aiController.closeMenu()
                                            onMicTap?()
                                        },
                                        onAITap: { aiController.toggleMenu() },
                                        isRecordingOverride: isSpeechRecordingActive,
                                        aiButtonDisabled: isSpeechToTextSheetPresented
                                    )
                                }
                            }
                            .padding(.trailing, 8)
                            .padding(.bottom, 8)
                        }
                    }
                }
            }
            .background(editorBackground, in: RoundedRectangle(cornerRadius: editorCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: editorCornerRadius, style: .continuous)
                    .stroke(!showBorder && showEditorBorder ? editorBorderColor : Color.clear, lineWidth: editorBorderWidth)
            )

            if !isReadOnly, showCharacterCount {
                SwiftUI.Text(characterCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, (topPadding ?? cardVerticalPadding) + (canUseAIFeatures && showButtonsInHeader && cardHorizontalPadding == 0 ? 12 : 0))
        .padding(.bottom, bottomPadding ?? cardVerticalPadding)
        .padding(.horizontal, cardHorizontalPadding)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: sectionCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: sectionCornerRadius, style: .continuous)
                .stroke(showBorder ? Color(.separator) : Color.clear, lineWidth: 0.5)
        )
        .shadow(color: showShadow ? Color.black.opacity(0.06) : Color.clear, radius: 4, x: 0, y: 2)
        .overlay(alignment: .bottomTrailing) {
            if canUseAIFeatures {
                ZTAIAssistantMenuOverlay(
                    controller: aiController,
                    menuAlignment: .bottomTrailing,
                    menuOffset: resolvedAIMenuOffset,
                    onCleanupTap: {
                        onCleanupAnalyticsTap?()
                        aiController.runCleanUp(
                            currentText: { editorText },
                            applyText: { updatedText in
                                editorText = updatedText
                                text = updatedText
                            }
                        )
                    },
                    onSummarizeTap: { style in
                        onSummarizeAnalyticsTap?(style)
                        aiController.runSummarize(
                            style: style,
                            currentText: { editorText },
                            applyText: { updatedText in
                                editorText = updatedText
                                text = updatedText
                            }
                        )
                    },
                    onUndoTap: {
                        aiController.undoLastResult { updatedText in
                            editorText = updatedText
                            text = updatedText
                        }
                    }
                )
                .allowsHitTesting(aiController.isMenuOpen || aiController.toastState != nil)
                .zIndex(10_000)
            }
        }
        .onAppear {
            if editorText != text { editorText = text }
        }
        .onChange(of: editorText) { newValue in
            if newValue != text { text = newValue }
        }
        .onChange(of: text) { newValue in
            if newValue != editorText { editorText = newValue }
        }
        .onChange(of: aiController.isMenuOpen) { isOpen in
            onAIMenuOpenChanged?(isOpen)
        }
        .onDisappear {
            aiController.cancelActiveOperations()
            onDisappear?()
        }
        .alert(
            ZTAIServiceLocalizer.localized("lbl_Error"),
            isPresented: Binding(
                get: { aiController.errorMessage != nil },
                set: { newValue in if !newValue { aiController.clearError() } }
            ),
            actions: {
                Button(ZTAIServiceLocalizer.localized("OK")) { aiController.clearError() }
            },
            message: {
                SwiftUI.Text(aiController.errorMessage ?? "")
            }
        )
    }
}
