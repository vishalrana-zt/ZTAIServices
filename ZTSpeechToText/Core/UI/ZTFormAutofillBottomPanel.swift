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
    static var camera: String          { localized("btn_camera",                        fallback: "Camera") }
    static var photoLibrary: String    { localized("btn_photo_library",                 fallback: "Photo Library") }
    static var scanPhotoSub: String    { localized("lbl_autofill_scan_photo_subtitle",   fallback: "Business card, work order, or label") }
    static var speak: String           { localized("lbl_autofill_speak",                 fallback: "Speak") }
    static var speakSub: String        { localized("lbl_autofill_speak_subtitle",         fallback: "Say the details in any order") }
    static var readingPhoto: String    { localized("lbl_autofill_reading_photo",          fallback: "Reading the photo…") }
    static var pullingDetails: String  { localized("lbl_autofill_pulling_details",        fallback: "Finding text in the image") }
    static var extracting: String      { localized("lbl_autofill_extracting_details",     fallback: "Extracting details…") }
    static var matchingFields: String  { localized("lbl_autofill_matching_fields",        fallback: "Matching to form fields") }
    static var listening: String       { localized("lbl_autofill_listening",              fallback: "Listening…") }
    static var speakNow: String        { localized("lbl_autofill_speak_now",              fallback: "Speak now…") }
    static var stop: String            { localized("lbl_autofill_stop",                   fallback: "Stop") }
    static var cancel: String          { localized("lbl_autofill_cancel",                 fallback: "Cancel") }
    static var textFound: String       { localized("lbl_autofill_text_found",             fallback: "TEXT FOUND") }
    static var discard: String         { localized("lbl_autofill_discard",                fallback: "Discard") }
    static var check: String           { localized("lbl_autofill_check",                  fallback: "Check") }
    static var tryAgain: String        { localized("lbl_autofill_try_again",              fallback: "Try Again") }
    static var missingFields: String   { localized("lbl_autofill_missing_fields",         fallback: "Fields not found will need to be filled manually.") }
    static var undo: String            { localized("lbl_autofill_undo",                   fallback: "Undo") }
    static var reviewSubtitle: String  { localized("lbl_autofill_review_subtitle",        fallback: "Untick anything you don't want. Nothing is written to the form until you tap Fill.") }
    static var sourcePhoto: String     { localized("lbl_autofill_source_photo",           fallback: "Read from the photo.") }
    static var sourceVoice: String     { localized("lbl_autofill_source_voice",           fallback: "Heard from your dictation.") }
    static var fillNothing: String     { localized("lbl_autofill_fill_nothing",           fallback: "Fill nothing") }
    static var fieldSingular: String   { localized("lbl_autofill_field_singular",         fallback: "field") }
    static var fieldPlural: String     { localized("lbl_autofill_field_plural",           fallback: "fields") }
    static var extractionAlertTitle: String { localized("lbl_autofill_extraction_alert_title", fallback: "Extraction in progress") }
    static var extractionAlertMessage: String { localized("lbl_autofill_extraction_alert_message", fallback: "Details are still being extracted. Do you want to stop and discard this autofill?") }
    static var extractionAlertContinue: String { localized("lbl_autofill_extraction_alert_continue", fallback: "Continue") }
    static var extractionAlertStopDiscard: String { localized("lbl_autofill_extraction_alert_stop_discard", fallback: "Stop & Discard") }

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
            content.presentationBackground(.white)
        } else {
            content.background(Color.white)
        }
    }
}

private struct ZTAutofillSheetSizingModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            if #available(iOS 18.0, *) {
                content.presentationSizing(.page)
            } else {
                content
            }
        } else {
            content
        }
    }
}

private struct ZTTopSheetCornersShape: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: [.topLeft, .topRight],
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

private struct ZTSheetDismissInterceptor: UIViewControllerRepresentable {
    let isDismissDisabled: Bool
    let onAttemptToDismiss: () -> Void

    func makeUIViewController(context: Context) -> DismissAwareViewController {
        let viewController = DismissAwareViewController()
        viewController.onAttemptToDismiss = onAttemptToDismiss
        viewController.isDismissDisabled = isDismissDisabled
        return viewController
    }

    func updateUIViewController(_ uiViewController: DismissAwareViewController, context: Context) {
        uiViewController.onAttemptToDismiss = onAttemptToDismiss
        uiViewController.isDismissDisabled = isDismissDisabled
        uiViewController.updatePresentationDelegate()
    }

    final class DismissAwareViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
        var onAttemptToDismiss: (() -> Void)?
        var isDismissDisabled = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            updatePresentationDelegate()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            updatePresentationDelegate()
        }

        func updatePresentationDelegate() {
            parent?.presentationController?.delegate = self
            parent?.sheetPresentationController?.prefersGrabberVisible = false
        }

        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            !isDismissDisabled
        }

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            guard isDismissDisabled else { return }
            onAttemptToDismiss?()
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
            .overlay {
                if coordinator.isSheetPresented {
                    ZStack(alignment: .bottom) {
                        Color.black.opacity(0.28)
                            .ignoresSafeArea()
                            .allowsHitTesting(true)
                            .onTapGesture { }

                        ZTFormAutofillBottomPanel(coordinator: coordinator, title: panelTitle)
                            .frame(maxWidth: .infinity, alignment: .bottom)
                            .background(Color.white)
                            .clipShape(ZTTopSheetCornersShape(radius: 34))
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(true)
                }
            }
            .animation(.interactiveSpring(response: 0.30, dampingFraction: 0.90, blendDuration: 0.10), value: coordinator.isSheetPresented)
    }
}

// MARK: - Bottom Panel (sheet content — no navigation bar)

public struct ZTFormAutofillBottomPanel: View {
    @ObservedObject public var coordinator: ZTFormAutofillCoordinator
    public let title: String

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showCameraPicker = false
    @State private var showPhotoSourceDialog = false
    @State private var showPhotoLibraryPicker = false
    @State private var showExtractionDismissAlert = false
    @State private var showSpeechSheet = false

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
                    .frame(height: pickerPanelHeight, alignment: .top)
            case .scanningPhoto:
                scanningPhotoView
                    .frame(height: UIDevice.current.userInterfaceIdiom == .pad ? 200 : 220, alignment: .top)
            case .extracting, .listening:
                extractingView
                    .frame(height: UIDevice.current.userInterfaceIdiom == .pad ? 200 : 220, alignment: .top)
            case .review:
                reviewView
                    .frame(height: reviewPanelHeight, alignment: .top)
            case .error(let message):
                errorView(message)
                    .frame(height: 260, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .blur(radius: showSpeechSheet ? 6 : 0)
        .allowsHitTesting(!showSpeechSheet)
        .presentationDetents(detentsForStep(coordinator.step))
        .presentationDragIndicator(.hidden)
        .modifier(ZTAutofillSheetSizingModifier())
        .modifier(ZTAutofillSheetBackgroundModifier())
        .interactiveDismissDisabled(isExtractionInProgress)
        .background(
            ZTSheetDismissInterceptor(isDismissDisabled: isExtractionInProgress) {
                showExtractionDismissAlert = true
            }
        )
        .alert(ZTAutofillStrings.extractionAlertTitle, isPresented: $showExtractionDismissAlert) {
            Button(ZTAutofillStrings.extractionAlertContinue, role: .cancel) {}
            Button(ZTAutofillStrings.extractionAlertStopDiscard, role: .destructive) {
                coordinator.dismiss()
            }
        } message: {
            Text(ZTAutofillStrings.extractionAlertMessage)
        }
        .confirmationDialog("", isPresented: $showPhotoSourceDialog, titleVisibility: .hidden) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button(ZTAutofillStrings.camera) { showCameraPicker = true }
            }
            Button(ZTAutofillStrings.photoLibrary) { showPhotoLibraryPicker = true }
            Button(ZTAutofillStrings.discard, role: .cancel) {}
        }
        .sheet(isPresented: $showCameraPicker) {
            ZTInlineCameraPickerView { image in coordinator.handleSelectedImage(image, source: .camera) }
                .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotoLibraryPicker, selection: $selectedPhotoItem, matching: .images)
        .onChange(of: selectedPhotoItem) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    coordinator.handleSelectedImage(image, source: .library)
                }
                selectedPhotoItem = nil
            }
        }
        .speechToTextSheet(
            isPresented: $showSpeechSheet,
            configuration: SpeechToTextSheetConfiguration(
                preferredLanguage: coordinator.preferredLanguageForSpeechSheet(),
                operationMode: .postRecording,
                showsModelProviderSelector: false,
                showsLiveTranscriptionToggle: false
            ),
            onTextReady: { _, text in
                coordinator.handleSpokenText(text)
            }
        )
    }

    private var isExtractionInProgress: Bool {
        switch coordinator.step {
        case .scanningPhoto, .extracting:
            return true
        default:
            return false
        }
    }

    private var pickerHeaderBadge: ZTAIModelBadgeKind? {
        let supportsPhoto = ZTAIModelBadgeKind.isAppleVisionOCRAvailable
        let supportsSpeech = ZTAIModelBadgeKind.isAppleSpeechAnalyzerAvailable
        return (supportsPhoto && supportsSpeech) ? .appleFoundationModels : nil
    }

    private var photoRowBadge: ZTAIModelBadgeKind? {
        let supportsPhoto = ZTAIModelBadgeKind.isAppleVisionOCRAvailable
        let supportsSpeech = ZTAIModelBadgeKind.isAppleSpeechAnalyzerAvailable
        return (supportsPhoto && !supportsSpeech) ? .appleVisionOCR : nil
    }

    private var speechRowBadge: ZTAIModelBadgeKind? {
        let supportsPhoto = ZTAIModelBadgeKind.isAppleVisionOCRAvailable
        let supportsSpeech = ZTAIModelBadgeKind.isAppleSpeechAnalyzerAvailable
        return (!supportsPhoto && supportsSpeech) ? .appleSpeechAnalyzer : nil
    }

    // MARK: - Picker

    private var pickerView: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.headline)
                        .foregroundStyle(Color(hex: "#0B6BEF"))
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Color(hex: "#10121A"))
                    Spacer()
                    if let headerBadge = pickerHeaderBadge {
                        ZTAIModelBadge(kind: headerBadge)
                    }
                }
                Text(ZTAutofillStrings.pickerDescription)
                    .font(.subheadline)
                    .foregroundStyle(Color(hex: "#5a6070"))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)

            Button { showPhotoSourceDialog = true } label: {
                pickerRow(
                    icon: "camera",
                    title: ZTAutofillStrings.scanPhoto,
                    subtitle: ZTAutofillStrings.scanPhotoSub,
                    trailingBadge: photoRowBadge
                )
            }
            .buttonStyle(.plain)

            Button { showSpeechSheet = true } label: {
                pickerRow(
                    icon: "mic",
                    title: ZTAutofillStrings.speak,
                    subtitle: ZTAutofillStrings.speakSub,
                    trailingBadge: speechRowBadge
                )
            }
            .buttonStyle(.plain)

            cancelButton
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(16)
        .background(Color.white)
    }

    private func pickerRow(icon: String, title: String, subtitle: String, trailingBadge: ZTAIModelBadgeKind? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color(hex: "#0B6BEF"))
                .frame(width: 38, height: 38)
                .background(Color(hex: "#e8f1ff"))
                .clipShape(RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color(hex: "#10121A"))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color(hex: "#6c7079"))
            }

            Spacer()

            if let trailingBadge {
                ZTAIModelBadge(kind: trailingBadge)
            }
        }
        .padding(10)
        .background(Color(hex: "#f5f7fb"))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - Scanning photo

    private var scanningPhotoView: some View {
        VStack(spacing: 10) {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    scanningThumb
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ZTAutofillStrings.readingPhoto)
                            .font(.headline)
                            .foregroundStyle(Color(hex: "#10121A"))
                        Text(ZTAutofillStrings.pullingDetails)
                            .font(.subheadline)
                            .foregroundStyle(Color(hex: "#5a6070"))
                        ZTAutofillShimmerBar()
                    }
                    Spacer()
                    if ZTAIModelBadgeKind.isAppleVisionOCRAvailable {
                        ZTAIModelBadge(kind: .appleVisionOCR)
                    }
                }
            }
            .padding(10)
            .background(
                LinearGradient(
                    colors: [Color(hex: "#f5f9ff"), Color(hex: "#eef5ff")],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color(hex: "#d5e4fb"), lineWidth: 1)
            )

            cancelButton
        }
        .padding(.horizontal, panelHorizontalPadding)
        .padding(.top, 32)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var scanningThumb: some View {
        ZStack {
            if let img = coordinator.selectedImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 74, height: 74)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "#dfe6f0"), Color(hex: "#eef2f7")],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 74, height: 74)
            }
            ZTScanSweepOverlay()
                .frame(width: 74, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            ZTScanCornerBrackets()
                .frame(width: 74, height: 74)
        }
        .frame(width: 74, height: 74)
    }

    // MARK: - Extracting

    private var extractingView: some View {
        VStack(spacing: 10) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    ZTSparklesIcon()
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ZTAutofillStrings.extracting)
                            .font(.headline)
                            .foregroundStyle(Color(hex: "#10121A"))
                        Text(ZTAutofillStrings.matchingFields)
                            .font(.subheadline)
                            .foregroundStyle(Color(hex: "#5a6070"))
                    }
                    Spacer()
                    if ZTAIModelBadgeKind.isAppleFoundationModelsAvailable {
                        ZTAIModelBadge(kind: .appleFoundationModels)
                    }
                }
                ZTAutofillShimmerBar()
            }
            .padding(10)
            .background(
                LinearGradient(
                    colors: [Color(hex: "#f5f9ff"), Color(hex: "#eef5ff")],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color(hex: "#d5e4fb"), lineWidth: 1)
            )

            cancelButton
        }
        .padding(.horizontal, panelHorizontalPadding)
        .padding(.top, 32)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    // MARK: - Review

    private var reviewView: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(ZTAutofillStrings.foundDetails(coordinator.candidates.count))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color(hex: "#10121A"))
                Text("\(coordinator.sourceLabel) \(ZTAutofillStrings.reviewSubtitle)")
                    .font(.subheadline)
                    .foregroundStyle(Color(hex: "#5a6070"))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 32)
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
                            Divider().padding(.leading, 52)
                        }
                    }

                    HStack(spacing: 12) {
                        Circle()
                            .strokeBorder(
                                Color(hex: "#c6c6cc").opacity(0.8),
                                style: StrokeStyle(lineWidth: 1.6, dash: [4, 3])
                            )
                            .frame(width: 22, height: 22)
                        Text(ZTAutofillStrings.missingFields)
                            .font(.footnote)
                            .foregroundStyle(Color(hex: "#7a8090"))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button { coordinator.dismiss() } label: {
                    Text(ZTAutofillStrings.discard)
                        .font(.headline)
                        .foregroundStyle(Color(hex: "#3a3d45"))
                        .frame(height: 48)
                        .padding(.horizontal, 16)
                        .background(Color(hex: "#f2f2f7"))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                Button { coordinator.applySelected() } label: {
                    let count = coordinator.candidates.filter { $0.isSelected }.count
                    Text(ZTAutofillStrings.fillFields(count))
                        .font(.headline)
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
                    .font(.caption)
                    .foregroundStyle(Color(hex: "#7a8090"))
                Text(candidate.value)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color(hex: "#10121A"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 4)

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(Color(hex: "#E0364C"))
            Text(message)
                .font(.body)
                .foregroundStyle(Color(hex: "#5a6070"))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Button(ZTAutofillStrings.tryAgain) { coordinator.retryFromPicker() }
                .font(.headline)
                .foregroundStyle(Color(hex: "#0B6BEF"))
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(Color(hex: "#e8f1ff"))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(.top, 32)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private func checkmarkCircle(isOn: Bool) -> some View {
        ZStack {
            Circle().fill(isOn ? Color(hex: "#0B6BEF") : Color.white)
            Circle().strokeBorder(isOn ? Color(hex: "#0B6BEF") : Color(hex: "#c6c6cc"), lineWidth: 1.6)
            if isOn {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 22, height: 22)
        .animation(.easeInOut(duration: 0.15), value: isOn)
    }

    private var cancelButton: some View {
        Button(ZTAutofillStrings.cancel) { coordinator.dismiss() }
            .font(.headline)
            .foregroundStyle(Color(hex: "#3a3d45"))
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Color(hex: "#f2f2f7"))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .buttonStyle(.plain)
    }

    private var panelHorizontalPadding: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 32 : 16
    }

    private var pickerPanelHeight: CGFloat {
        if UIDevice.current.userInterfaceIdiom == .phone{
            return 400
        }
        return 350
    }

    private var reviewPanelHeight: CGFloat {
        (presentedPopoverHeight() ?? UIScreen.main.bounds.height) * 0.7
    }

    private func presentedPopoverHeight() -> CGFloat? {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return nil }
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let keyWindow = scene.windows.first(where: { $0.isKeyWindow }),
              let topController = keyWindow.rootViewController?.ztTopMostPresentedController else {
            return nil
        }

        let isPopover = topController.modalPresentationStyle == .popover || topController.popoverPresentationController != nil
        guard isPopover else { return nil }

        let preferredHeight = topController.preferredContentSize.height
        if preferredHeight > 0 {
            return preferredHeight
        }

        let renderedHeight = topController.view.bounds.height
        return renderedHeight > 0 ? renderedHeight : nil
    }

    private func isPresentedAsPopover() -> Bool {
        presentedPopoverHeight() != nil
    }

    private func detentsForStep(_ step: ZTFormAutofillCoordinator.Step) -> Set<PresentationDetent> {
        let progressDetent: PresentationDetent = .height(UIDevice.current.userInterfaceIdiom == .pad ? 200 : 220)
        switch step {
        case .picking:                     return [.height(pickerPanelHeight)]
        case .review:                      return [.medium, .large]
        case .scanningPhoto:               return [progressDetent]
        case .extracting, .listening:      return [progressDetent]
        case .error:                       return [.height(300)]
        default:                           return [.medium]
        }
    }
}

private extension UIViewController {
    var ztTopMostPresentedController: UIViewController {
        presentedViewController?.ztTopMostPresentedController ?? self
    }
}

// MARK: - Applied banner (retained for API compatibility; no longer shown)

public struct ZTFormAutofillAppliedBannerView: View {
    public init(coordinator: ZTFormAutofillCoordinator) {}
    public var body: some View { EmptyView() }
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
// MARK: - Scan sweep overlay (animated line)

struct ZTScanSweepOverlay: View {
    @State private var offsetY: CGFloat = -34

    var body: some View {
        LinearGradient(
            colors: [
                Color(hex: "#0b6bef").opacity(0),
                Color(hex: "#0b6bef").opacity(0.28),
                Color(hex: "#0b6bef")
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 34)
        .offset(y: offsetY)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                offsetY = 74
            }
        }
    }
}

// MARK: - Scan corner brackets

struct ZTScanCornerBrackets: View {
    var body: some View {
        Canvas { ctx, size in
            let l: CGFloat = 14
            let t: CGFloat = 1.5
            let color = GraphicsContext.Shading.color(Color(hex: "#0b6bef").opacity(0.55))
            let corners: [(CGPoint, (CGFloat, CGFloat), (CGFloat, CGFloat))] = [
                (CGPoint(x: 5, y: 5),   (l, 0),   (0, l)),
                (CGPoint(x: size.width - 5, y: 5),  (-l, 0), (0, l)),
                (CGPoint(x: 5, y: size.height - 5), (l, 0),  (0, -l)),
                (CGPoint(x: size.width - 5, y: size.height - 5), (-l, 0), (0, -l))
            ]
            for (origin, h, v) in corners {
                var p = Path()
                p.move(to: CGPoint(x: origin.x + h.0, y: origin.y + h.1))
                p.addLine(to: origin)
                p.addLine(to: CGPoint(x: origin.x + v.0, y: origin.y + v.1))
                ctx.stroke(p, with: color, style: StrokeStyle(lineWidth: t, lineCap: .round))
            }
        }
    }
}

// MARK: - Sparkles icon

struct ZTSparklesIcon: View {
    @State private var pulse = false
    @State private var animateWhole = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(hex: "#0b6bef"))

            Image(systemName: "sparkles")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .scaleEffect(pulse ? 0.74 : 1.06, anchor: .center)
                .opacity(pulse ? 0.3 : 1.0)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)

            Image(systemName: "sparkle")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .offset(x: 7, y: -6)
                .scaleEffect(pulse ? 1.02 : 0.75, anchor: .center)
                .opacity(pulse ? 1.0 : 0.3)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true).delay(0.55), value: pulse)
        }
        .scaleEffect(animateWhole ? 1.12 : 1.0)
        .rotationEffect(.degrees(animateWhole ? 9 : 0))
        .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: animateWhole)
        .onAppear {
            animateWhole = true
            pulse = true
        }
    }
}

#if DEBUG
@MainActor
private func makeAutofillPickerPreviewCoordinator() -> ZTFormAutofillCoordinator {
    let coordinator = ZTFormAutofillCoordinator(documentType: .customer, fieldMapper: { _ in [] })
    coordinator.openSheet()
    return coordinator
}

@MainActor
private func makeAutofillReadingPreviewCoordinator() -> ZTFormAutofillCoordinator {
    let coordinator = ZTFormAutofillCoordinator(documentType: .customer, fieldMapper: { _ in [] })
    coordinator.openSheet()
    coordinator.debugSetState(
        step: .scanningPhoto,
        selectedImage: UIImage(systemName: "doc.text.viewfinder")
    )
    return coordinator
}

@MainActor
private func makeAutofillExtractingPreviewCoordinator() -> ZTFormAutofillCoordinator {
    let coordinator = ZTFormAutofillCoordinator(documentType: .customer, fieldMapper: { _ in [] })
    coordinator.openSheet()
    coordinator.debugSetState(step: .extracting)
    return coordinator
}

#Preview("Autofill Picker") {
    ZTFormAutofillBottomPanel(
        coordinator: makeAutofillPickerPreviewCoordinator(),
        title: "Autofill customer details"
    )
}

#Preview("Autofill Reading") {
    ZTFormAutofillBottomPanel(
        coordinator: makeAutofillReadingPreviewCoordinator(),
        title: "Autofill customer details"
    )
}

#Preview("Autofill Extracting") {
    ZTFormAutofillBottomPanel(
        coordinator: makeAutofillExtractingPreviewCoordinator(),
        title: "Autofill customer details"
    )
}
#endif
