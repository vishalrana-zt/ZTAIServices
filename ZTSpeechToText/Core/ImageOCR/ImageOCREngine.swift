import Vision
import UIKit

// MARK: - Errors

enum ImageOCRError: LocalizedError {
    case invalidImage
    case noTextFound
    case recognitionFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "The image could not be read."
        case .noTextFound:
            return "No readable text was found in the image."
        case .recognitionFailed(let error):
            return "Text recognition failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Engine

// Local, on-device text extraction using Apple Vision.
// The image is never sent to the network — only the resulting text string
// is passed to AI providers for further processing.
struct ImageOCREngine {

    // Recognizes all readable text in the given image.
    // languageHints: BCP-47 codes (e.g. "en-US") improve accuracy but are optional.
    // Returns the full extracted text with lines joined by newlines.
    func recognizeText(in image: UIImage, languageHints: [String] = []) async throws -> String {
        guard let cgImage = image.cgImage else {
            throw ImageOCRError.invalidImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: ImageOCRError.recognitionFailed(underlying: error))
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                if lines.isEmpty {
                    continuation.resume(throwing: ImageOCRError.noTextFound)
                } else {
                    continuation.resume(returning: lines.joined(separator: "\n"))
                }
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if !languageHints.isEmpty {
                request.recognitionLanguages = languageHints
            }

            do {
                try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            } catch {
                continuation.resume(throwing: ImageOCRError.recognitionFailed(underlying: error))
            }
        }
    }
}

