import SwiftUI
import ZTAIServices

struct TextAIView: View {
    @Environment(\.dismiss) private var dismiss
    private let service = TextAIService()

    @State private var inputText = ""
    @State private var resultText = ""
    @State private var selectedLanguage: SupportedLanguage = .english
    @State private var selectedOperation: TextAIOperation = .cleanup
    @AppStorage("CloudAPIConfiguration.provider") private var cloudProviderKey: String = "openAI"
    @State private var summaryStyle: TextAISummaryStyle = .standard
    @State private var providerLabel = ""
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var activeTask: Task<Void, Never>?
    @State private var didCopyResult = false
    @State private var canUndo = false
    @FocusState private var isInputFocused: Bool

    private var canRun: Bool {
        !isProcessing && !normalizedInput.isEmpty
    }

    private var normalizedInput: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                languageSection
                inputSection
                operationSection
                actionSection
                if let errorMessage { errorSection(errorMessage) }
                if !resultText.isEmpty { resultSection }
            }
            .navigationTitle(AppLocalizer.localized("title_text_ai"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalizer.localized("btn_done")) {
                        if isInputFocused {
                            isInputFocused = false
                        } else {
                            dismiss()
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear { refreshProviderLabel() }
            .onChange(of: selectedLanguage) { _ in refreshProviderLabel() }
            .onDisappear { activeTask?.cancel() }
        }
    }

    // MARK: - Sections

    private var languageSection: some View {
        Section {
            Picker(AppLocalizer.localized("lbl_cloud_provider"), selection: $cloudProviderKey) {
                Text("OpenAI").tag("openAI")
                Text("Gemini").tag("gemini")
            }
            .pickerStyle(.segmented)
            .disabled(isProcessing)
            .onChange(of: cloudProviderKey) { key in
                CloudAPIConfiguration.provider = key == "gemini" ? .gemini : .openAI
            }

            Picker(AppLocalizer.localized("lbl_language"), selection: $selectedLanguage) {
                ForEach(SupportedLanguage.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isProcessing)
        }
    }

    private var inputSection: some View {
        Section {
            ZStack(alignment: .topLeading) {
                if inputText.isEmpty {
                    Text(AppLocalizer.localized("ph_paste_or_type_text"))
                        .foregroundStyle(.tertiary)
                        .font(.body)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $inputText)
                    .focused($isInputFocused)
                    .frame(minHeight: 120, maxHeight: 300)
                    .scrollContentBackground(.hidden)
            }
        } header: {
            HStack {
                Text(AppLocalizer.localized("lbl_input"))
                Spacer()
                if !inputText.isEmpty {
                    Button(AppLocalizer.localized("btn_clear"), role: .destructive) {
                        withAnimation { inputText = "" }
                    }
                    .font(.caption)
                    .textCase(nil)
                }
            }
        } footer: {
            if !inputText.isEmpty {
                Text("\(inputText.count) \(AppLocalizer.localized("lbl_characters"))")
                    .font(.caption2)
            }
        }
    }

    private var operationSection: some View {
        Section {
            Picker(AppLocalizer.localized("lbl_type"), selection: $selectedOperation) {
                Text(AppLocalizer.localized("opt_clean_up")).tag(TextAIOperation.cleanup)
                Text(AppLocalizer.localized("opt_summarize")).tag(TextAIOperation.summarize)
            }
            .pickerStyle(.segmented)
            .disabled(isProcessing)

            if selectedOperation == .summarize {
                Picker(AppLocalizer.localized("lbl_length"), selection: $summaryStyle) {
                    ForEach(TextAISummaryStyle.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isProcessing)
            }

        } header: {
            HStack {
                Text(AppLocalizer.localized("lbl_operation"))
                Spacer()
                providerBadge
            }
        }
    }

    private var actionSection: some View {
        Section {
            if isProcessing {
                HStack {
                    ProgressView()
                    Text(AppLocalizer.localized("lbl_processing"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(AppLocalizer.localized("btn_cancel"), role: .destructive) {
                        activeTask?.cancel()
                    }
                }
            } else {
                Button {
                    run()
                } label: {
                    HStack {
                        Spacer()
                        Image(systemName: selectedOperation == .cleanup ? "sparkles" : "text.quote")
                        Text(selectedOperation == .cleanup
                             ? AppLocalizer.localized("btn_clean_up_text")
                             : AppLocalizer.localized("btn_summarize_text"))
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(!canRun)
            }
        }
    }

    private func errorSection(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.footnote)
        }
    }

    private var resultSection: some View {
        Section {
            Text(resultText)
                .textSelection(.enabled)
                .font(.body)

            Button {
                UIPasteboard.general.string = resultText
                withAnimation { didCopyResult = true }
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await MainActor.run { withAnimation { didCopyResult = false } }
                }
            } label: {
                Label(
                    didCopyResult
                    ? AppLocalizer.localized("msg_copied")
                    : AppLocalizer.localized("btn_copy_to_clipboard"),
                    systemImage: didCopyResult ? "checkmark.circle.fill" : "doc.on.doc"
                )
                .foregroundStyle(didCopyResult ? .green : .accentColor)
                .animation(.default, value: didCopyResult)
            }

            if canUndo {
                Button(role: .destructive) {
                    performUndo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
            }
        } header: {
            Text(AppLocalizer.localized("lbl_result"))
        }
    }

    private var providerBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "cpu")
                .font(.caption2)
            Text(compactProviderLabel.isEmpty ? AppLocalizer.localized("lbl_detecting") : compactProviderLabel)
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
    }

    private var compactProviderLabel: String {
        if providerLabel == "Apple Foundation Models" {
            return "Apple AI"
        }
        return providerLabel
    }

    // MARK: - Actions

    private func run() {
        let textToValidate = normalizedInput
        if let validationMessage = validationMessage(for: textToValidate) {
            errorMessage = validationMessage
            resultText = ""
            didCopyResult = false
            return
        }

        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
        activeTask?.cancel()
        activeTask = Task {
            await MainActor.run {
                isProcessing = true
                errorMessage = nil
                resultText = ""
                didCopyResult = false
            }
            do {
                let response: TextAIExecutionResult
                if selectedOperation == .cleanup {
                    response = try await service.cleanup(text: inputText, preferredLanguage: selectedLanguage)
                } else {
                    response = try await service.summarize(
                        text: inputText,
                        preferredLanguage: selectedLanguage,
                        style: summaryStyle
                    )
                }
                let undoAvailable = await service.canUndo
                await MainActor.run {
                    providerLabel = response.provider.resolvedDisplayName
                    resultText = response.outputText
                    canUndo = undoAvailable
                    isProcessing = false
                }
            } catch {
                let message = (error as? TextAIError)?.localizedDescription ?? error.localizedDescription
                await MainActor.run {
                    isProcessing = false
                    errorMessage = message
                }
            }
        }
    }

    private func validationMessage(for text: String) -> String? {
        if text.isEmpty {
            return AppLocalizer.localized("err_input_text_required")
        }

        let minimumCharacters = 12
        let minimumWords = 3
        let wordCount = text.split(whereSeparator: \.isWhitespace).count
        if text.count < minimumCharacters || wordCount < minimumWords {
            return AppLocalizer.localized("err_input_text_too_short")
        }

        return nil
    }

    private func performUndo() {
        Task {
            guard let original = await service.undo() else { return }
            let stillCanUndo = await service.canUndo
            await MainActor.run {
                inputText = original
                resultText = ""
                canUndo = stillCanUndo
                didCopyResult = false
            }
        }
    }

    private func refreshProviderLabel() {
        Task {
            let value = await service.preferredProviderDisplayName(for: selectedLanguage)
            await MainActor.run { providerLabel = value }
        }
    }
}
