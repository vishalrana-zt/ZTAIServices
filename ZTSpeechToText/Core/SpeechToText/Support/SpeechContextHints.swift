import Foundation
import Speech

/// Tells Apple's recognizer which words to expect (a form's field and option names), so a
/// name like "Fax" is preferred over a similar-sounding "Hex". It only biases the result.
/// Safe by construction: an empty list does nothing, the list is capped, and a failure to set
/// the context is ignored — it can never fail or change a transcription on its own.
@available(iOS 26.0, *)
enum SpeechContextHints {
    /// One switch to turn the feature off for A/B comparison.
    nonisolated(unsafe) static var isEnabled = true

    static let maxTerms = 50
    static let maxTermLength = 40

    static func apply(_ terms: [String], to analyzer: SpeechAnalyzer) async {
        guard isEnabled else { return }
        var seen = Set<String>()
        let cleaned = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= maxTermLength && seen.insert($0.lowercased()).inserted }
            .prefix(maxTerms)
        guard !cleaned.isEmpty else { return }

        let context = AnalysisContext()
        context.contextualStrings[.general] = Array(cleaned)
        do {
            try await analyzer.setContext(context)
            if CloudAPIConfiguration.isLoggingEnabled {
                ZTAutofillLogBuffer.log("[SPEECH] hints applied: \(cleaned.count) terms")
            }
        } catch {
            if CloudAPIConfiguration.isLoggingEnabled {
                ZTAutofillLogBuffer.log("[SPEECH] hints ignored: \(error.localizedDescription)")
            }
        }
    }
}
