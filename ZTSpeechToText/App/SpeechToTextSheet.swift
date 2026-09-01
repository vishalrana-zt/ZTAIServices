//
//  SpeechToTextSheet.swift
//  Reusable presenter for opening STT flow and returning transcribed text.
//

import SwiftUI
import ZTAIServices

struct SpeechToTextSheetConfiguration {
    var preferredLanguage: SupportedLanguage? = nil
    var operationMode: SpeechToTextManager.OperationMode = .liveStreaming
    var modelProvider: SpeechToTextManager.ModelProvider? = nil
    var showsModelProviderSelector: Bool = true
    var initialLiveTranscriptionEnabled: Bool? = nil
    var showsLiveTranscriptionToggle: Bool = false
    var livePartialMaxAudioSeconds: Double = 12.0
    var livePartialMinimumAudioSeconds: Double = 0.8
    var livePollingIntervalNanoseconds: UInt64 = 1_200_000_000
}

private struct SpeechToTextFlowSheet: View {

    @Environment(\.colorScheme) private var colorScheme

    @State private var shouldAutoStartRecording = true

    private let manager = SpeechToTextManager.shared
    let configuration: SpeechToTextSheetConfiguration
    let onLiveTranscriptChanged: (LiveTranscriptPartial) -> Void
    let onTextReady: (UUID, String) -> Void
    let onSetupReady: () -> Void
    let onCloseRequested: () -> Void

    var body: some View {
        panelView
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .onAppear {
                manager.setModelProvider(.appleModels)
                applyModeSelection(
                    configuration.operationMode,
                    shouldKickoffSetup: true,
                    allowAutoStartWhenReady: true
                )
            }
            .onChange(of: configuration.operationMode) { newMode in
                applyModeSelection(
                    newMode,
                    shouldKickoffSetup: true,
                    allowAutoStartWhenReady: false
                )
            }
    }

    @ViewBuilder
    private var panelView: some View {
        VStack(alignment: .leading, spacing: 10) {
            RecordScreen(
                autoStartOnAppear: shouldAutoStartRecording,
                preferredLanguage: configuration.preferredLanguage,
                initialLiveTranscriptionEnabled: configuration.initialLiveTranscriptionEnabled,
                showsLiveTranscriptionToggle: configuration.showsLiveTranscriptionToggle,
                livePartialMaxAudioSeconds: configuration.livePartialMaxAudioSeconds,
                livePartialMinimumAudioSeconds: configuration.livePartialMinimumAudioSeconds,
                livePollingIntervalNanoseconds: configuration.livePollingIntervalNanoseconds,
                onLiveTranscriptChanged: { partial in
                    onLiveTranscriptChanged(partial)
                },
                onTranscriptReady: { sessionID, text in
                    onTextReady(sessionID, text)
                },
                onProcessingCompleted: {
                    onCloseRequested()
                }
            )
        }
    }

    private func applyModeSelection(
        _ mode: SpeechToTextManager.OperationMode,
        shouldKickoffSetup: Bool,
        allowAutoStartWhenReady: Bool
    ) {
        manager.setOperationMode(mode)
        onSetupReady()
        if allowAutoStartWhenReady {
            shouldAutoStartRecording = true
        }
        guard shouldKickoffSetup else { return }
        return
    }

    private var panelFillColor: Color {
        if colorScheme == .dark {
            return Color(.secondarySystemBackground).opacity(0.92)
        }
        return Color(.systemBackground).opacity(0.97)
    }

    private var panelBorderColor: Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.12)
        }
        return Color.black.opacity(0.09)
    }

    private var panelShadowColor: Color {
        if colorScheme == .dark {
            return Color.black.opacity(0.35)
        }
        return Color.black.opacity(0.14)
    }
}

private struct SpeechToTextSheetModifier: ViewModifier {

    @Binding var isPresented: Bool
    let configuration: SpeechToTextSheetConfiguration
    let onLiveTranscriptChanged: (LiveTranscriptPartial) -> Void
    let onTextReady: (UUID, String) -> Void
    let onSetupReady: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay {
                if isPresented {
                    SpeechToTextFlowSheet(
                        configuration: configuration,
                        onLiveTranscriptChanged: { partial in
                            onLiveTranscriptChanged(partial)
                        },
                        onTextReady: { sessionID, text in
                            onTextReady(sessionID, text)
                        },
                        onSetupReady: {
                            onSetupReady()
                        },
                        onCloseRequested: {
                            isPresented = false
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.interactiveSpring(response: 0.30, dampingFraction: 0.90, blendDuration: 0.10), value: isPresented)
    }
}

extension View {
    func speechToTextSheet(
        isPresented: Binding<Bool>,
        configuration: SpeechToTextSheetConfiguration = SpeechToTextSheetConfiguration(),
        onLiveTranscriptChanged: @escaping (LiveTranscriptPartial) -> Void = { _ in },
        onTextReady: @escaping (UUID, String) -> Void,
        onSetupReady: @escaping () -> Void = {}
    ) -> some View {
        modifier(
            SpeechToTextSheetModifier(
                isPresented: isPresented,
                configuration: configuration,
                onLiveTranscriptChanged: onLiveTranscriptChanged,
                onTextReady: onTextReady,
                onSetupReady: onSetupReady
            )
        )
    }

    func speechToTextSheet(
        isPresented: Binding<Bool>,
        preferredLanguage: SupportedLanguage? = nil,
        onLiveTranscriptChanged: @escaping (LiveTranscriptPartial) -> Void = { _ in },
        onTextReady: @escaping (UUID, String) -> Void,
        onSetupReady: @escaping () -> Void = {}
    ) -> some View {
        var configuration = SpeechToTextSheetConfiguration()
        configuration.preferredLanguage = preferredLanguage
        return speechToTextSheet(
            isPresented: isPresented,
            configuration: configuration,
            onLiveTranscriptChanged: onLiveTranscriptChanged,
            onTextReady: onTextReady,
            onSetupReady: onSetupReady
        )
    }
}
