import SwiftUI
import PhotosUI
import UIKit
import ZTAIServices
// MARK: - Localized strings

private enum ZTAutofillStrings {
    private static func localized(_ key: String, fallback: String) -> String {
        let v = ZTAIServiceLocalizer.localized(key)
        return v == key ? fallback : v
    }

    static var pickerDescription: String { localized("lbl_autofill_picker_description", fallback: "Take a photo with Camera or choose one from Photo Library. The text is extracted, matched to the fields, and shown for review before anything is filled.") }
    static var scanPhoto: String       { localized("lbl_autofill_scan_photo",           fallback: "Photo") }
    static var scanPhotoSub: String    { localized("lbl_autofill_scan_photo_subtitle",   fallback: "Business card, work order, or label") }
    static var speak: String           { localized("lbl_autofill_speak",                 fallback: "Speak") }
    static var speakSub: String        { localized("lbl_autofill_speak_subtitle",         fallback: "Say the details in any order") }
    static var readingPhoto: String    { localized("lbl_autofill_reading_photo",          fallback: "Reading the photo…") }
    static var pullingDetails: String  { localized("lbl_autofill_pulling_details",        fallback: "Pulling details from the image") }
    static var extracting: String      { localized("lbl_autofill_extracting_details",     fallback: "Extracting details…") }
    static var matchingFields: String  { localized("lbl_autofill_matching_fields",        fallback: "Matching to form fields") }
    static var listening: String       { localized("lbl_autofill_listening",              fallback: "Listening…") }
    static var speakNow: String        { localized("lbl_autofill_speak_now",              fallback: "Speak now…") }
    static var stop: String            { localized("lbl_autofill_stop",                   fallback: "Stop") }
    static var discard: String         { localized("lbl_autofill_discard",                fallback: "Discard") }
    static var check: String           { localized("lbl_autofill_check",                  fallback: "Check") }
    static var tryAgain: String        { localized("lbl_autofill_try_again",              fallback: "Try Again") }
    static var missingFields: String   { localized("lbl_autofill_missing_fields",         fallback: "Fields not found will need to be filled manually.") }
    static var undo: String            { localized("lbl_autofill_undo",                   fallback: "Undo") }
    static var reviewSubtitle: String  { localized("lbl_autofill_review_subtitle",        fallback: "Untick anything you don't want. Nothing is written to the form until you tap Fill.") }
    static var fillNothing: String     { localized("lbl_autofill_fill_nothing",           fallback: "Fill nothing") }
    static var fieldSingular: String   { localized("lbl_autofill_field_singular",         fallback: "field") }
    static var fieldPlural: String     { localized("lbl_autofill_field_plural",           fallback: "fields") }

    static func foundDetails(_ n: Int) -> String {
        String(format: localized("lbl_autofill_found_details", fallback: "Found %d details"), n)
    }
    static func fillFields(_ n: Int) -> String {
        guard n > 0 else { return fillNothing }
        return String(format: localized("lbl_autofill_fill_fields", fallback: "Fill %d fields"), n)
    }
    static func bannerText(count: Int, source: String) -> String {
        let word = count == 1 ? fieldSingular : fieldPlural
        let fmt = localized("lbl_autofill_banner_text", fallback: "%d %@ filled from %@. Check anything marked, then save.")
        return String(format: fmt, count, word, source)
    }
}

private struct ZTAutofillSheetBackgroundModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content.presentationBackground(Color.white)
        } else {
            content.background(Color.white)
        }
    }
}

// MARK: - Sheet host view (transparent overlay that drives the .sheet)

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
            .sheet(
                isPresented: $coordinator.isSheetPresented,
                onDismiss: { coordinator.dismiss() }
            ) {
                ZTFormAutofillBottomPanel(coordinator: coordinator, title: panelTitle)
            }
    }
}

// MARK: - Bottom Panel (sheet content — no navigation bar)

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
        Group {
            switch coordinator.step {
            case .idle, .applied:
                EmptyView()
            case .picking:
                pickerView
            case .scanningPhoto:
                progressCard(headline: ZTAutofillStrings.readingPhoto, subline: ZTAutofillStrings.pullingDetails)
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
        .presentationDetents(detentsForStep(coordinator.step))
        .presentationDragIndicator(.visible)
        .modifier(ZTAutofillSheetBackgroundModifier())
        .interactiveDismissDisabled(false)
        .confirmationDialog("", isPresented: $showPhotoSourceDialog, titleVisibility: .hidden) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button(ZTAutofillStrings.scanPhoto) { showCameraPicker = true }
            }
            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                Text(ZTAutofillStrings.scanPhoto)
            }
            Button(ZTAutofillStrings.discard, role: .cancel) {}
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
                Text(ZTAutofillStrings.pickerDescription)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(hex: "#5a6070"))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)

            Button { showPhotoSourceDialog = true } label: {
                pickerRow(icon: "camera", title: ZTAutofillStrings.scanPhoto, subtitle: ZTAutofillStrings.scanPhotoSub)
            }
            .buttonStyle(.plain)

            Button { coordinator.selectSpeak() } label: {
                pickerRow(icon: "mic", title: ZTAutofillStrings.speak, subtitle: ZTAutofillStrings.speakSub)
            }
            .buttonStyle(.plain)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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

    private func progressCard(headline: String, subline: String) -> some View {
        VStack {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(
                        colors: [Color(hex: "#dfe6f0"), Color(hex: "#eef2f7")],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 56, height: 56)

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
            Text(ZTAutofillStrings.extracting)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(hex: "#10121A"))
            Text(ZTAutofillStrings.matchingFields)
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

                Text(ZTAutofillStrings.listening)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(hex: "#10121A"))

                Spacer()

                Button(ZTAutofillStrings.stop) { coordinator.stopListening() }
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Color(hex: "#0B6BEF"))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(hex: "#e8f1ff").opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            }
            .padding(.bottom, 10)

            Text(coordinator.liveTranscript.isEmpty ? ZTAutofillStrings.speakNow : coordinator.liveTranscript)
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
                Text(ZTAutofillStrings.foundDetails(coordinator.candidates.count))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(hex: "#10121A"))
                Text("\(coordinator.sourceLabel) \(ZTAutofillStrings.reviewSubtitle)")
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

                    HStack(spacing: 11) {
                        Circle()
                            .strokeBorder(
                                Color(hex: "#c6c6cc").opacity(0.8),
                                style: StrokeStyle(lineWidth: 1.6, dash: [4, 3])
                            )
                            .frame(width: 22, height: 22)
                        Text(ZTAutofillStrings.missingFields)
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
                    Text(ZTAutofillStrings.discard)
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
                    Text(ZTAutofillStrings.fillFields(count))
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
                Text(ZTAutofillStrings.check)
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
            Button(ZTAutofillStrings.tryAgain) { coordinator.retryFromPicker() }
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

    private func detentsForStep(_ step: ZTFormAutofillCoordinator.Step) -> Set<PresentationDetent> {
        switch step {
        case .picking:                     return [.height(380)]
        case .review:                      return [.medium, .large]
        case .scanningPhoto, .extracting:  return [.height(220)]
        case .listening:                   return [.height(260)]
        case .error:                       return [.height(300)]
        default:                           return [.medium]
        }
    }
}

// MARK: - Applied banner (shown inline in the form after fill)

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
                Text(ZTAutofillStrings.bannerText(
                    count: coordinator.appliedCount,
                    source: coordinator.sourceLabel
                        .lowercased()
                        .trimmingCharacters(in: .punctuationCharacters)
                        .trimmingCharacters(in: .whitespaces)
                ))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color(hex: "#20242e"))
                .lineLimit(2)
                Spacer(minLength: 8)
                Button(ZTAutofillStrings.undo) { coordinator.undoApply() }
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
            if let image = info[.originalImage] as? UIImage { parent.onImagePicked(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
