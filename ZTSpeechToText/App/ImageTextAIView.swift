import SwiftUI
import PhotosUI

// Image → OCR → extracted text.
// Pure on-device text extraction using Apple Vision. No AI processing, no network.
struct ImageTextAIView: View {
    @Environment(\.dismiss) private var dismiss

    private let ocrEngine = ImageOCREngine()

    private enum Phase: Equatable {
        case idle, extracting, done
    }

    @State private var phase: Phase = .idle
    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var showCameraPicker = false
    @State private var extractedText = ""
    @State private var errorMessage: String?
    @State private var activeTask: Task<Void, Never>?
    @State private var didCopy = false

    private var isExtracting: Bool { phase == .extracting }
    private var canExtract: Bool { selectedImage != nil && !isExtracting }

    var body: some View {
        NavigationStack {
            Form {
                imageSection
                if selectedImage != nil {
                    actionSection
                }
                if let errorMessage { errorSection(errorMessage) }
                if !extractedText.isEmpty { resultSection }
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
            .onChange(of: selectedItem) { item in loadPickedItem(item) }
            .onChange(of: selectedImage) { _ in
                extractedText = ""
                phase = .idle
                errorMessage = nil
                didCopy = false
            }
            .onDisappear { activeTask?.cancel() }
        }
    }

    // MARK: - Sections

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
                    .disabled(isExtracting)
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
                Text("Any image with readable text — documents, receipts, business cards, screenshots, and more.")
                    .font(.caption2)
            }
        }
    }

    private var actionSection: some View {
        Section {
            if isExtracting {
                HStack {
                    ProgressView()
                    Text("Reading text…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", role: .destructive) {
                        activeTask?.cancel()
                        phase = .idle
                    }
                }
            } else {
                Button {
                    extract()
                } label: {
                    HStack {
                        Spacer()
                        Image(systemName: "text.viewfinder")
                        Text("Extract Text")
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

    private var resultSection: some View {
        Section {
            Text(extractedText)
                .textSelection(.enabled)
                .font(.body)

            Button {
                UIPasteboard.general.string = extractedText
                withAnimation { didCopy = true }
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await MainActor.run { withAnimation { didCopy = false } }
                }
            } label: {
                Label(
                    didCopy ? "Copied!" : "Copy to Clipboard",
                    systemImage: didCopy ? "checkmark.circle.fill" : "doc.on.doc"
                )
                .foregroundStyle(didCopy ? .green : .accentColor)
                .animation(.default, value: didCopy)
            }
        } header: {
            Text("Extracted Text")
        }
    }

    // MARK: - Actions

    private func loadPickedItem(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                await MainActor.run { selectedImage = image }
            }
        }
    }

    private func extract() {
        guard let image = selectedImage else { return }
        let hints: [String] = []  // Vision auto-detects language

        activeTask?.cancel()
        activeTask = Task {
            await MainActor.run {
                phase = .extracting
                errorMessage = nil
                extractedText = ""
                didCopy = false
            }

            do {
                let text = try await ocrEngine.recognizeText(in: image, languageHints: hints)
                await MainActor.run {
                    extractedText = text
                    phase = .done
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    phase = .idle
                    errorMessage = (error as? ImageOCRError)?.localizedDescription ?? error.localizedDescription
                }
            }
        }
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
