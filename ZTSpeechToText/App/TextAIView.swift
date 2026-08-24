import SwiftUI

struct TextAIView: View {
    @Environment(\.dismiss) private var dismiss
    private let service = TextAIService()

    @State private var inputText = ""
    @State private var resultText = ""
    @State private var selectedLanguage: TextAISupportedLanguage = .english
    @State private var selectedOperation: TextAIOperation = .cleanup
    @State private var summaryStyle: TextAISummaryStyle = .standard
    @State private var providerLabel = ""
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var activeTask: Task<Void, Never>?
    @State private var didCopyResult = false

    private var canRun: Bool {
        !isProcessing && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            .navigationTitle("Text AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    providerBadge
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                    }
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
            Picker("Language", selection: $selectedLanguage) {
                ForEach(TextAISupportedLanguage.allCases, id: \.self) {
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
                    Text("Paste or type text to process…")
                        .foregroundStyle(.tertiary)
                        .font(.body)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $inputText)
                    .frame(minHeight: 120, maxHeight: 300)
                    .scrollContentBackground(.hidden)
            }
        } header: {
            HStack {
                Text("Input")
                Spacer()
                if !inputText.isEmpty {
                    Button("Clear", role: .destructive) {
                        withAnimation { inputText = "" }
                    }
                    .font(.caption)
                    .textCase(nil)
                }
            }
        } footer: {
            if !inputText.isEmpty {
                Text("\(inputText.count) characters")
                    .font(.caption2)
            }
        }
    }

    private var operationSection: some View {
        Section("Operation") {
            Picker("Type", selection: $selectedOperation) {
                Text("Clean Up").tag(TextAIOperation.cleanup)
                Text("Summarize").tag(TextAIOperation.summarize)
            }
            .pickerStyle(.segmented)
            .disabled(isProcessing)

            if selectedOperation == .summarize {
                Picker("Length", selection: $summaryStyle) {
                    ForEach(TextAISummaryStyle.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isProcessing)
            }
        }
    }

    private var actionSection: some View {
        Section {
            if isProcessing {
                HStack {
                    ProgressView()
                    Text("Processing…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", role: .destructive) {
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
                        Text(selectedOperation == .cleanup ? "Clean Up Text" : "Summarize Text")
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
                    didCopyResult ? "Copied!" : "Copy to Clipboard",
                    systemImage: didCopyResult ? "checkmark.circle.fill" : "doc.on.doc"
                )
                .foregroundStyle(didCopyResult ? .green : .accentColor)
                .animation(.default, value: didCopyResult)
            }
        } header: {
            Text("Result")
        }
    }

    private var providerBadge: some View {
        Group {
            if !providerLabel.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.caption2)
                    Text(providerLabel)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func run() {
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
                await MainActor.run {
                    providerLabel = response.provider.resolvedDisplayName
                    resultText = response.outputText
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

    private func refreshProviderLabel() {
        Task {
            let value = await service.preferredProviderDisplayName(for: selectedLanguage)
            await MainActor.run { providerLabel = value }
        }
    }
}
