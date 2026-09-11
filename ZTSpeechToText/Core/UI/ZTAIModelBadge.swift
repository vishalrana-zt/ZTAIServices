import SwiftUI
import ZTAIServices
#if canImport(FoundationModels)
import FoundationModels
#endif

public enum ZTAIModelBadgeKind: Equatable {
    case appleSpeechAnalyzer
    case appleFoundationModels
    case appleVisionOCR

    public init?(provider: TextAIProviderID) {
        switch provider {
        case .appleFoundationModels:
            self = .appleFoundationModels
        case .cloudAPI:
            return nil
        }
    }

    var title: String {
        switch self {
        case .appleSpeechAnalyzer:
            return "On-device Speech"
        case .appleFoundationModels:
            return "On-device AI"
        case .appleVisionOCR:
            return "On-device OCR"
        }
    }

    /// Apple Vision OCR is always available on iOS — show this badge for all photo-scanning paths.
    public static var isAppleVisionOCRAvailable: Bool {
        true
    }

    /// Returns true when the device supports on-device speech via Apple SpeechAnalyzer
    /// (live-streaming or post-recording). False → Cloud API transcription, no badge shown.
    public static var isAppleSpeechAnalyzerAvailable: Bool {
        SpeechToTextManager.shared.isAppleSpeechAnalyzerAvailable
    }

    /// Returns true when Apple Foundation Models is available on this device.
    /// False → Cloud API extraction, no badge shown.
    public static var isAppleFoundationModelsAvailable: Bool {
        if #available(iOS 26.0, *) {
            #if canImport(FoundationModels)
            return SystemLanguageModel.default.isAvailable
            #else
            return false
            #endif
        }
        return false
    }

    var tint: Color {
        switch self {
        case .appleSpeechAnalyzer:
            return Color(hex: "#E0364C")
        case .appleFoundationModels:
            return Color(hex: "#0B6BEF")
        case .appleVisionOCR:
            return Color(hex: "#4B6BFB")
        }
    }
}

public struct ZTAIModelBadge: View {
    public let kind: ZTAIModelBadgeKind

    public init(kind: ZTAIModelBadgeKind) {
        self.kind = kind
    }

    public var body: some View {
        iconView
            .frame(width: 24, height: 24)
            .padding(4)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.black.opacity(0.15), lineWidth: 0.5)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(kind.title)
    }

    private var iconView: some View {
        Image("icn_apple_foundation", bundle: .module)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
    }
}
