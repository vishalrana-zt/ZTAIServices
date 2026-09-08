import SwiftUI
import PhotosUI
import UIKit

// MARK: - Sheet host view (use as full-screen overlay in UIHostingController)

public struct ZTFormAutofillSheetHostView: View {
    @ObservedObject public var coordinator: ZTFormAutofillCoordinator
    public let panelTitle: String

    public init(coordinator: ZTFormAutofillCoordinator, panelTitle: String = "Autofill details") {
        self.coordinator = coordinator
        self.panelTitle = panelTitle
    }

    public var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .sheet(isPresented: $coordinator.isSheetPresented) {
                ZTFormAutofillBottomPanel(coordinator: coordinator, title: panelTitle)
            }
    }
}

// MARK: - Bottom Panel (sheet content)

public struct ZTFormAutofillBottomPanel: View {
    @ObservedObject public var coordinator: ZTFormAutofillCoordinator
    public let title: String

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showCameraPicker = false
    @State private var showPhotoSourceDialog = false

    public init(coordinator: ZTFormAutofillCoordinator, title: String = "Autofill details") {
        self.coordinator = coordinator
        self.title = title
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch coordinator.step {
                case .idle, .applied:
                    EmptyView()
                case .picking:
                    pickerView
                case .scanningPhoto:
                    progressCard(
                        placeholder: "photo",
                        headline: "Reading the photo…",
                        subline: "Pulling details from the image"
                    )
                case .listening:
                    listeningView
                case .extracting:
                    extractingView
                case .review:
                    reviewView
                case .error(let message):
                    errorView(message)
                }
            }
            .navigationTitle(titleForStep(coordinator.step))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { coordinator.dismiss() }
                        .foregroundStyle(Color(hex: "#0B6BEF"))
                }
            }
        }
        .presentationDetents(detentsForStep(coordinator.step))
        .presentationDragIndicator(.visible)
        .confirmationDialog("Choose Source", isPresented: $showPhotoSourceDialog, titleVisibility: .hidden) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Camera") { showCameraPicker = true }
            }
            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                Text("Photo Library")
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showCameraPicker) {
            ZTInlineCameraPickerView { image in coordinator.handleSelectedImage(image) }
                .ignoresSafeArea()
        }
        .onChange(of: selectedPhotoItem) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    coordinator.handleSelectedImage(image)
                }
                selectedPhotoItem = nil
            }
        }
    }

    // MARK: - Picker

    private var pickerView: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(hex: "#0B6BEF"))
                    Text(title)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(Color(hex: "#10121A"))
                }
                Text("Take a photo or speak the details. The text is extracted, matched to the fields, and shown for review before anything is filled.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(hex: "#5a6070"))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)

            Button { showPhotoSourceDialog = true } label: {
                pickerRow(icon: "camera", title: "Scan Photo", subtitle: "Business card, work order, or label")
            }
            .buttonStyle(.plain)

            Button { coordinator.selectSpeak() } label: {
                pickerRow(icon: "mic", title: "Speak", subtitle: "Say the details in any order")
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func pickerRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color(hex: "#0B6BEF"))
                .frame(width: 38, height: 38)
                .background(Color(hex: "#e8f1ff"))
                .clipShape(RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(Color(hex: "#10121A"))
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(hex: "#6c7079"))
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(hex: "#c6c6cc"))
        }
        .padding(13)
        .background(Color(hex: "#f5f7fb"))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.black.opacity(0.07), lineWidth: 0.5)
        )
    }

    // MARK: - Progress card (scanning photo)

    private func progressCard(placeholder: String, headline: String, subline: String) -> some View {
        VStack {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(
                        colors: [Color(hex: "#dfe6f0"), Color(hex: "#eef2f7")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 56, height: 56)
                    .overlay(
                        Text(placeholder)
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color(hex: "#7a8394"))
                    )

                VStack(alignment: .leading, spacing: 7) {
                    Text(headline)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(hex: "#10121A"))
                    Text(subline)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color(hex: "#5a6070"))
                    ZTAutofillShimmerBar()
                }
                Spacer()
            }
            .padding(13)
            .background(Color(hex: "#f2f7ff"))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color(hex: "#cfe0fb"), lineWidth: 1)
            )

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Extracting

    private var extractingView: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView()
                .progressViewStyle(.circular)
                .tint(Color(hex: "#0B6BEF"))
                .scaleEffect(1.2)
            Text("Extracting details…")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(hex: "#10121A"))
            Text("Matching to form fields")
                .font(.system(size: 12.5))
                .foregroundStyle(Color(hex: "#5a6070"))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Listening

    private var listeningView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 11) {
                ZTRecordingPulseView()
                    .frame(width: 38, height: 38)

                Text("Listening…")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(hex: "#10121A"))

                Spacer()

                Button("Stop") { coordinator.stopListening() }
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Color(hex: "#0B6BEF"))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(hex: "#e8f1ff").opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            }
            .padding(.bottom, 10)

            Text(coordinator.liveTranscript.isEmpty ? "Speak now…" : coordinator.liveTranscript)
                .font(.system(size: 14.5))
                .foregroundStyle(coordinator.liveTranscript.isEmpty ? Color(hex: "#7a8090") : Color(hex: "#10121A"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Review

    private var reviewView: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Found \(coordinator.candidates.count) details")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(hex: "#10121A"))
                Text("\(coordinator.sourceLabel) Untick anything you don't want. Nothing is written to the form until you tap Fill.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(hex: "#5a6070"))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(coordinator.candidates.indices), id: \.self) { idx in
                        Button { coordinator.toggleCandidate(id: coordinator.candidates[idx].id) } label: {
                            reviewRow(coordinator.candidates[idx])
                        }
                        .buttonStyle(.plain)

                        if idx < coordinator.candidates.count - 1 {
                            Divider().padding(.leading, 51)
                        }
                    }

                    // "Missing" placeholder row
                    HStack(spacing: 11) {
                        Circle()
                            .strokeBorder(Color(hex: "#c6c6cc").opacity(0.8), style: StrokeStyle(lineWidth: 1.6, dash: [4, 3]))
                            .frame(width: 22, height: 22)
                        Text("Fields not found will need to be filled manually.")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: "#7a8090"))
                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button { coordinator.dismiss() } label: {
                    Text("Discard")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(hex: "#3a3d45"))
                        .frame(height: 48)
                        .padding(.horizontal, 18)
                        .background(Color(hex: "#f2f2f7"))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                Button { coordinator.applySelected() } label: {
                    let count = coordinator.candidates.filter { $0.isSelected }.count
                    Text(count > 0 ? "Fill \(count) fields" : "Fill nothing")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color(hex: "#0B6BEF"))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .padding(.bottom, 8)
        }
    }

    private func reviewRow(_ candidate: ZTAutofillCandidate) -> some View {
        HStack(alignment: .center, spacing: 11) {
            checkmarkCircle(isOn: candidate.isSelected)

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.label)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: "#7a8090"))
                Text(candidate.value)
                    .font(.system(size: 15.5, weight: .medium))
                    .foregroundStyle(Color(hex: "#10121A"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 4)

            if candidate.needsCheck {
                Text("Check")
                    .font(.system(size: 10.5, weight: .semibold))
                    .kerning(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(Color(hex: "#8a5a00"))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color(hex: "#fdf0d5"))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color(hex: "#E0364C"))
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: "#5a6070"))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Button("Try Again") { coordinator.retryFromPicker() }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(hex: "#0B6BEF"))
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(Color(hex: "#e8f1ff"))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private func checkmarkCircle(isOn: Bool) -> some View {
        ZStack {
            Circle().fill(isOn ? Color(hex: "#0B6BEF") : Color.white)
            Circle().strokeBorder(isOn ? Color(hex: "#0B6BEF") : Color(hex: "#c6c6cc"), lineWidth: 1.6)
            if isOn {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 22, height: 22)
        .animation(.easeInOut(duration: 0.15), value: isOn)
    }

    private func titleForStep(_ step: ZTFormAutofillCoordinator.Step) -> String {
        switch step {
        case .picking: return title
        case .scanningPhoto: return "Reading Photo"
        case .listening: return "Listening"
        case .extracting: return "Extracting"
        case .review: return "Review Details"
        default: return title
        }
    }

    private func detentsForStep(_ step: ZTFormAutofillCoordinator.Step) -> Set<PresentationDetent> {
        switch step {
        case .review: return [.medium, .large]
        case .scanningPhoto, .extracting: return [.height(220)]
        case .listening: return [.height(260)]
        case .error: return [.height(300)]
        default: return [.medium]
        }
    }
}

// MARK: - Applied banner (shown inline in the form)

public struct ZTFormAutofillAppliedBannerView: View {
    @ObservedObject public var coordinator: ZTFormAutofillCoordinator

    public init(coordinator: ZTFormAutofillCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        if coordinator.step == .applied {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(hex: "#0B6BEF"))
                Text(bannerText)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Color(hex: "#20242e"))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button("Undo") { coordinator.undoApply() }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hex: "#0B6BEF"))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(Color(hex: "#dbe9fd"))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Color(hex: "#eaf3ff"))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(hex: "#cfe0fb"), lineWidth: 1)
            )
            .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
    }

    private var bannerText: String {
        let n = coordinator.appliedCount
        let src = coordinator.sourceLabel
            .lowercased()
            .trimmingCharacters(in: .punctuationCharacters)
            .trimmingCharacters(in: .whitespaces)
        return "\(n) \(n == 1 ? "field" : "fields") filled from \(src). Check anything marked, then save."
    }
}

// MARK: - Shimmer animation bar

public struct ZTAutofillShimmerBar: View {
    @State private var phase: CGFloat = -1

    public init() {}

    public var body: some View {
        GeometryReader { _ in
            LinearGradient(
                stops: [
                    .init(color: Color(hex: "#cfe0fb"), location: 0),
                    .init(color: Color(hex: "#0B6BEF").opacity(0.8), location: 0.45),
                    .init(color: Color(hex: "#cfe0fb"), location: 0.9),
                ],
                startPoint: UnitPoint(x: phase, y: 0.5),
                endPoint: UnitPoint(x: phase + 1, y: 0.5)
            )
        }
        .frame(height: 4)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .onAppear {
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

// MARK: - Recording pulse (mic waveform)

public struct ZTRecordingPulseView: View {
    @State private var pulse = false

    public init() {}

    public var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color(hex: "#E0364C").opacity(0.45), lineWidth: 2)
                .scaleEffect(pulse ? 1.5 : 0.85)
                .opacity(pulse ? 0 : 0.9)
                .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pulse)

            Circle().fill(Color(hex: "#E0364C"))

            HStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { i in
                    ZTWaveBarView(delay: Double(i) * 0.12)
                }
            }
        }
        .onAppear { pulse = true }
    }
}

struct ZTWaveBarView: View {
    let delay: Double
    @State private var animate = false

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white)
            .frame(width: 3, height: animate ? 14 : 4)
            .animation(
                .easeInOut(duration: 0.85).repeatForever(autoreverses: true).delay(delay),
                value: animate
            )
            .onAppear { animate = true }
    }
}

// MARK: - Camera picker (UIKit bridge)

struct ZTInlineCameraPickerView: UIViewControllerRepresentable {
    let onImagePicked: (UIImage) -> Void
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
        let parent: ZTInlineCameraPickerView
        init(_ parent: ZTInlineCameraPickerView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImagePicked(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
