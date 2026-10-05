import Foundation

/// Single source of truth for every AI analytics event name.
/// Host apps and packages must reference these instead of using string literals.
public enum ZTAIAnalyticsEvent: String, CaseIterable {
    case autofillOpened = "AI_AUTOFILL_OPENED"
    case autofillSourcePhoto = "AI_AUTOFILL_SOURCE_PHOTO"
    case autofillSourceAudio = "AI_AUTOFILL_SOURCE_AUDIO"
    case autofillApplied = "AI_AUTOFILL_APPLIED"
    case micTapped = "AI_MIC_TAPPED"
    case cleanupTapped = "AI_CLEANUP_TAPPED"
    case summarizeTapped = "AI_SUMMARIZE_TAPPED"
    case feedbackSubmitted = "AI_FEEDBACK_SUBMITTED"
}
