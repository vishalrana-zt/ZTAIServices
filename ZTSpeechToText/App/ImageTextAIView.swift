import SwiftUI
import PhotosUI

// Image -> OCR (local) -> optional structured extraction (AI provider fallback).
struct ImageTextAIView: View {
    @Environment(\.dismiss) private var dismiss

    private let ocrEngine = ImageOCREngine()
    private let textAIService = TextAIService()

    private enum Phase: Equatable {
        case idle
        case extracting
        case structuring
        case done
    }

    @State private var phase: Phase = .idle
    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var showCameraPicker = false

    @State private var extractedText = ""
    @State private var structuredText = ""
    @State private var structuredProviderLabel = ""
    @State private var providerLabel = ""

    @State private var errorMessage: String?
    @State private var structuredErrorMessage: String?
    @State private var activeTask: Task<Void, Never>?
    @State private var loadingMessage = ""

    @State private var didCopyOCR = false
    @State private var didCopyStructured = false

    @State private var isStructuredExtractionEnabled = true
    @State private var selectedDocumentType: StructuredDocumentType?

    private var isBusy: Bool {
        phase == .extracting || phase == .structuring
    }

    private var canExtract: Bool {
        selectedImage != nil
            && !isBusy
            && (!isStructuredExtractionEnabled || selectedDocumentType != nil)
    }

    private var providerBadgeText: String {
        if phase == .structuring {
            return "Auto (Apple -> Cloud)"
        }
        return compactProviderLabel
    }

    private var structuredDocument: StructuredExtractionDocument? {
        guard !structuredText.isEmpty else { return nil }
        guard let data = structuredText.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StructuredExtractionDocument.self, from: data)
    }

    var body: some View {
        NavigationStack {
            Form {
                imageSection
                if selectedImage != nil {
                    actionSection
                }
                if let errorMessage {
                    errorSection(errorMessage)
                }
                if let structuredErrorMessage {
                    structuredInfoSection(structuredErrorMessage)
                }
                if !extractedText.isEmpty {
                    ocrResultSection
                }
                if let structuredDocument {
                    structuredPreviewSection(structuredDocument)
                }
                if !structuredText.isEmpty {
                    structuredResultSection
                }
            }
            .navigationTitle("Image Text AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showCameraPicker) {
                CameraImagePicker(image: $selectedImage)
            }
            .onAppear { refreshProviderLabel() }
            .onChange(of: selectedItem) { item in loadPickedItem(item) }
            .onChange(of: selectedImage) { _ in resetOutputs() }
            .onDisappear { activeTask?.cancel() }
        }
    }

    private var imageSection: some View {
        Section {
            if let image = selectedImage {
                HStack(spacing: 12) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Image selected")
                            .font(.subheadline.weight(.medium))
                        Text("\(Int(image.size.width)) × \(Int(image.size.height)) px")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        withAnimation {
                            selectedImage = nil
                            selectedItem = nil
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .imageScale(.large)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isBusy)
                }
                .padding(.vertical, 4)
            } else {
                HStack(spacing: 12) {
                    PhotosPicker(selection: $selectedItem, matching: .images) {
                        Label("Photo Library", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            showCameraPicker = true
                        } label: {
                            Label("Camera", systemImage: "camera")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Image")
        } footer: {
            if selectedImage == nil {
                Text("OCR is fully local. Structured extraction uses Apple Intelligence or cloud when available.")
                    .font(.caption2)
            }
        }
    }

    private var actionSection: some View {
        Section {
            HStack {
                Text("Structured extraction")
                Spacer()
                if !providerLabel.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "cpu")
                            .font(.caption2)
                        Text(providerBadgeText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("", isOn: $isStructuredExtractionEnabled)
                    .labelsHidden()
            }
            .disabled(isBusy)

            if isStructuredExtractionEnabled {
                Picker("Document type", selection: $selectedDocumentType) {
                    Text("").tag(StructuredDocumentType?.none)
                    ForEach(StructuredDocumentType.allCases) { type in
                        Text(type.displayName).tag(Optional(type))
                    }
                }
                .disabled(isBusy)
            }

            if isStructuredExtractionEnabled && selectedDocumentType == nil && !isBusy {
                Text("Select document type to continue.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if isBusy {
                HStack {
                    ProgressView(loadingMessage.isEmpty ? "Processing…" : loadingMessage)
                        .tint(.accentColor)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", role: .destructive) {
                        activeTask?.cancel()
                        phase = .idle
                        loadingMessage = ""
                    }
                }
            } else {
                Button {
                    extract()
                } label: {
                    HStack {
                        Spacer()
                        Image(systemName: isStructuredExtractionEnabled ? "sparkles.rectangle.stack" : "text.viewfinder")
                        Text(isStructuredExtractionEnabled ? "Extract + Structure" : "Extract Text")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(!canExtract)
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

    private func structuredInfoSection(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "info.circle")
                .foregroundStyle(.orange)
                .font(.footnote)
        }
    }

    private var ocrResultSection: some View {
        Section {
            Text(extractedText)
                .textSelection(.enabled)
                .font(.body)

            Button {
                UIPasteboard.general.string = extractedText
                withAnimation { didCopyOCR = true }
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await MainActor.run { withAnimation { didCopyOCR = false } }
                }
            } label: {
                Label(
                    didCopyOCR ? "Copied!" : "Copy OCR Text",
                    systemImage: didCopyOCR ? "checkmark.circle.fill" : "doc.on.doc"
                )
                .foregroundStyle(didCopyOCR ? .green : .accentColor)
                .animation(.default, value: didCopyOCR)
            }
        } header: {
            Text("Extracted Text (Vision)")
        }
    }

    private func structuredPreviewSection(_ doc: StructuredExtractionDocument) -> some View {
        Section("Technician Summary") {
            if let value = doc.documentType, !value.isEmpty {
                summaryRow("Document", value: value)
            }
            if let value = doc.inspectionContext?.domain, !value.isEmpty {
                summaryRow("Domain", value: value)
            }
            if let value = doc.inspectionContext?.inspectionType, !value.isEmpty {
                summaryRow("Inspection", value: value)
            }
            if let value = doc.inspectionContext?.workOrderNumber, !value.isEmpty {
                summaryRow("Work Order", value: value)
            }
            if let value = doc.site?.address?.full, !value.isEmpty {
                summaryRow("Site", value: value)
            }
            if let firstPhone = doc.contactInfo?.phones?.first?.raw, !firstPhone.isEmpty {
                summaryRow("Phone", value: firstPhone)
            }
            if let firstEmail = doc.contactInfo?.emails?.first?.value, !firstEmail.isEmpty {
                summaryRow("Email", value: firstEmail)
            }
            if let deficiencies = doc.deficiencies, !deficiencies.isEmpty {
                summaryRow("Deficiencies", value: "\(deficiencies.count)")
            }
            if let value = doc.totals?.grandTotal, !value.isEmpty {
                summaryRow("Grand Total", value: value)
            }
            if let firstAction = doc.nextActions?.first, !firstAction.isEmpty {
                summaryRow("Next Action", value: firstAction)
            }
        }
    }

    private var structuredResultSection: some View {
        Section {
            Text(structuredText)
                .textSelection(.enabled)
                .font(.body.monospaced())

            Button {
                UIPasteboard.general.string = structuredText
                withAnimation { didCopyStructured = true }
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await MainActor.run { withAnimation { didCopyStructured = false } }
                }
            } label: {
                Label(
                    didCopyStructured ? "Copied!" : "Copy Structured Output",
                    systemImage: didCopyStructured ? "checkmark.circle.fill" : "doc.on.doc"
                )
                .foregroundStyle(didCopyStructured ? .green : .accentColor)
                .animation(.default, value: didCopyStructured)
            }
        } header: {
            HStack {
                Text("Structured Extraction (JSON)")
                Spacer()
                if !structuredProviderLabel.isEmpty {
                    Text(structuredProviderLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .textCase(nil)
        }
    }

    private func summaryRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }

    private func repairInput(ocrText: String, invalidJSON: String) -> String {
        """
        OCR Text:
        \(ocrText)

        The previous structured extraction output was invalid JSON.
        Return corrected valid JSON only, strictly matching the schema in the system instructions.
        Invalid output to fix:
        \(invalidJSON)
        """
    }

    private func normalizeStructuredJSONString(_ raw: String) -> String? {
        guard let candidate = extractedJSONObjectString(from: raw) else { return nil }
        guard let data = candidate.data(using: .utf8) else { return nil }
        guard var doc = try? JSONDecoder().decode(StructuredExtractionDocument.self, from: data) else { return nil }

        doc.normalizeInPlace()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let normalizedData = try? encoder.encode(doc) else { return nil }
        return String(data: normalizedData, encoding: .utf8)
    }

    private func extractedJSONObjectString(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
            return trimmed
        }

        if let first = trimmed.firstIndex(of: "{"),
           let last = trimmed.lastIndex(of: "}"),
           first <= last {
            return String(trimmed[first...last])
        }

        return nil
    }

    private var compactProviderLabel: String {
        if providerLabel == "Apple Foundation Models" {
            return "Apple AI"
        }
        return providerLabel
    }

    private func refreshProviderLabel() {
        Task {
            let value = await textAIService.preferredProviderDisplayName(for: .english)
            await MainActor.run { providerLabel = value }
        }
    }

    private func loadPickedItem(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                await MainActor.run { selectedImage = image }
            }
        }
    }

    private func resetOutputs() {
        extractedText = ""
        structuredText = ""
        structuredProviderLabel = ""
        selectedDocumentType = nil
        loadingMessage = ""
        structuredErrorMessage = nil
        errorMessage = nil
        didCopyOCR = false
        didCopyStructured = false
        phase = .idle
    }

    private func extract() {
        guard let image = selectedImage else { return }
        let hints: [String] = []

        phase = .extracting
        loadingMessage = "Reading image text locally…"
        errorMessage = nil
        structuredErrorMessage = nil
        extractedText = ""
        structuredText = ""
        structuredProviderLabel = ""
        didCopyOCR = false
        didCopyStructured = false

        activeTask?.cancel()
        activeTask = Task {
            // Let SwiftUI render the busy state before OCR/model work starts.
            await Task.yield()
            do {
                let text = try await ocrEngine.recognizeText(in: image, languageHints: hints)
                await MainActor.run {
                    extractedText = text
                }

                guard isStructuredExtractionEnabled else {
                    await MainActor.run {
                        phase = .done
                        loadingMessage = ""
                    }
                    return
                }
                guard let selectedDocumentType else {
                    await MainActor.run {
                        phase = .idle
                        loadingMessage = ""
                        structuredErrorMessage = "Please select a document type."
                    }
                    return
                }

                await MainActor.run {
                    phase = .structuring
                    loadingMessage = "Structuring \(selectedDocumentType.displayName)…"
                }
                await Task.yield()
                do {
                    let result = try await textAIService.structuredExtract(
                        text: text,
                        preferredLanguage: .english,
                        documentType: selectedDocumentType
                    )
                    let normalizedPrimary = normalizeStructuredJSONString(result.outputText)

                    if let normalizedPrimary {
                        await MainActor.run {
                            structuredText = normalizedPrimary
                            structuredProviderLabel = result.provider.resolvedDisplayName
                            phase = .done
                            loadingMessage = ""
                        }
                    } else {
                        let repaired = try await textAIService.structuredExtract(
                            text: repairInput(ocrText: text, invalidJSON: result.outputText),
                            preferredLanguage: .english,
                            documentType: selectedDocumentType
                        )
                        guard let normalizedRepaired = normalizeStructuredJSONString(repaired.outputText) else {
                            throw TextAIError.inferenceFailed(reason: "Invalid structured JSON format")
                        }
                        await MainActor.run {
                            structuredText = normalizedRepaired
                            structuredProviderLabel = repaired.provider.resolvedDisplayName
                            structuredErrorMessage = "Structured JSON auto-repaired after initial invalid output."
                            phase = .done
                            loadingMessage = ""
                        }
                    }
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        await MainActor.run {
                            phase = .idle
                            loadingMessage = ""
                            structuredErrorMessage = nil
                        }
                        return
                    }
                    #if DEBUG
                    print("[IMAGE_TEXT_AI] structured_extraction_error=\(error)")
                    #endif
                    await MainActor.run {
                        phase = .done
                        loadingMessage = ""
                        let message = (error as? TextAIError)?.localizedDescription ?? error.localizedDescription
                        structuredErrorMessage = "Structured extraction unavailable: \(message)"
                    }
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    phase = .idle
                    loadingMessage = ""
                    errorMessage = (error as? ImageOCRError)?.localizedDescription ?? error.localizedDescription
                }
            }
        }
    }
}

private struct StructuredExtractionDocument: Codable {
    var documentType: String?
    var inspectionContext: InspectionContext?
    var site: Site?
    var contactInfo: ContactInfo?
    var dates: [DateEntry]?
    var amounts: [AmountEntry]?
    var deficiencies: [Deficiency]?
    var totals: Totals?
    var nextActions: [String]?

    struct InspectionContext: Codable {
        var domain: String?
        var inspectionType: String?
        var workOrderNumber: String?
    }

    struct Site: Codable {
        var address: Address?
    }

    struct Address: Codable {
        var full: String?
    }

    struct ContactInfo: Codable {
        var phones: [Phone]?
        var emails: [Email]?
    }

    struct Phone: Codable {
        var label: String?
        var countryCode: String?
        var number: String?
        var `extension`: String?
        var raw: String?
    }

    struct Email: Codable {
        var value: String?
    }

    struct DateEntry: Codable {
        var label: String?
        var value: String?
        var normalized: String?
    }

    struct AmountEntry: Codable {
        var label: String?
        var value: String?
        var currency: String?
        var normalized: String?
    }

    struct Deficiency: Codable {
        var id: String?
    }

    struct Totals: Codable {
        var grandTotal: String?
    }

    mutating func normalizeInPlace() {
        normalizePhones()
        normalizeDates()
        normalizeAmounts()
    }

    private mutating func normalizePhones() {
        guard var phones = contactInfo?.phones else { return }
        for index in phones.indices {
            var phone = phones[index]
            let raw = phone.raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if (!raw.isEmpty) && ((phone.countryCode ?? "").isEmpty || (phone.number ?? "").isEmpty) {
                let parsed = parsePhone(raw)
                if (phone.countryCode ?? "").isEmpty {
                    phone.countryCode = parsed.countryCode
                }
                if (phone.number ?? "").isEmpty {
                    phone.number = parsed.number
                }
            }
            if raw.isEmpty {
                let cc = (phone.countryCode ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let number = (phone.number ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !number.isEmpty {
                    phone.raw = cc.isEmpty ? number : "\(cc) \(number)"
                }
            }
            phones[index] = phone
        }
        contactInfo?.phones = phones
    }

    private mutating func normalizeDates() {
        guard var values = dates else { return }
        for index in values.indices {
            var entry = values[index]
            let normalized = (entry.normalized ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty,
               let source = entry.value,
               let converted = normalizedDateString(from: source) {
                entry.normalized = converted
            }
            values[index] = entry
        }
        dates = values
    }

    private mutating func normalizeAmounts() {
        guard var values = amounts else { return }
        for index in values.indices {
            var entry = values[index]
            let normalized = (entry.normalized ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty,
               let source = entry.value,
               let converted = normalizedAmountString(from: source) {
                entry.normalized = converted
            }
            values[index] = entry
        }
        amounts = values
    }

    private func parsePhone(_ raw: String) -> (countryCode: String, number: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.replacingOccurrences(of: "[^0-9+]", with: "", options: .regularExpression)
        if cleaned.hasPrefix("+") {
            let digits = String(cleaned.dropFirst())
            let ccLength = min(3, max(1, digits.count >= 10 ? digits.count - 10 : 1))
            let ccDigits = String(digits.prefix(ccLength))
            let numberDigits = String(digits.dropFirst(ccLength))
            return (countryCode: "+\(ccDigits)", number: numberDigits)
        }
        let digits = cleaned.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
        return (countryCode: "", number: digits)
    }

    private func normalizedDateString(from source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let formats = ["yyyy-MM-dd", "MM/dd/yyyy", "dd/MM/yyyy", "dd-MM-yyyy", "MMM d, yyyy", "d MMM yyyy"]
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)

        for format in formats {
            parser.dateFormat = format
            if let date = parser.date(from: trimmed) {
                let output = DateFormatter()
                output.locale = Locale(identifier: "en_US_POSIX")
                output.timeZone = TimeZone(secondsFromGMT: 0)
                output.dateFormat = "yyyy-MM-dd"
                return output.string(from: date)
            }
        }
        return nil
    }

    private func normalizedAmountString(from source: String) -> String? {
        let cleaned = source
            .replacingOccurrences(of: "[^0-9,.-]", with: "", options: .regularExpression)
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let value = Double(cleaned) else { return nil }
        return String(format: "%.2f", value)
    }
}

// MARK: - Camera picker

private struct CameraImagePicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraImagePicker
        init(_ parent: CameraImagePicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.image = info[.originalImage] as? UIImage
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
