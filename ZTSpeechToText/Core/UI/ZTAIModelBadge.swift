import SwiftUI
import ZTAIServices

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

    var iconName: String {
        switch self {
        case .appleSpeechAnalyzer:
            return "waveform"
        case .appleFoundationModels:
            return "sparkles"
        case .appleVisionOCR:
            return "text.viewfinder"
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
        Image(systemName: kind.iconName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(kind.tint)
            .frame(width: 20, height: 20)
            .padding(6)
            .background(kind.tint.opacity(0.12), in: Circle())
            .overlay(
                Circle()
                    .stroke(kind.tint.opacity(0.35), lineWidth: 0.5)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(kind.title)
    }
}
