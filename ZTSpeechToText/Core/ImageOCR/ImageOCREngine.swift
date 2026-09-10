import Vision
import UIKit

// MARK: - Errors

public enum ImageOCRError: LocalizedError {
    case invalidImage
    case noTextFound
    case recognitionFailed(underlying: Error)

    public var errorDescription: String? {
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
public struct ImageOCREngine {
    public init() {}
    private final class OCRContinuation {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String, Error>?

        init(_ continuation: CheckedContinuation<String, Error>) {
            self.continuation = continuation
        }

        func resume(returning value: String) {
            lock.lock()
            guard let continuation else {
                lock.unlock()
                return
            }
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: value)
        }

        func resume(throwing error: Error) {
            lock.lock()
            guard let continuation else {
                lock.unlock()
                return
            }
            self.continuation = nil
            lock.unlock()
            continuation.resume(throwing: error)
        }
    }

    private enum VisionImageSource {
        case cgImage(CGImage)
        case ciImage(CIImage)
    }

    // Vision doesn't benefit from full-resolution camera photos — 1500px on the long edge
    // gives accurate text recognition while cutting processing time significantly for
    // typical 12–48 MP phone images.
    private func resizedForOCR(_ image: UIImage) -> UIImage {
        let maxDimension: CGFloat = 1500
        let size = image.size
        guard size.width > maxDimension || size.height > maxDimension else { return image }
        let scale = maxDimension / max(size.width, size.height)
        let newSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }

    // Recognizes all readable text in the given image.
    // languageHints: BCP-47 codes (e.g. "en-US") improve accuracy but are optional.
    // Returns the full extracted text with lines joined by newlines.
    public func recognizeText(in image: UIImage, languageHints: [String] = []) async throws -> String {
        let input = resizedForOCR(image)
        let source: VisionImageSource
        if let cgImage = input.cgImage {
            source = .cgImage(cgImage)
        } else if let ciImage = input.ciImage ?? CIImage(image: input) {
            source = .ciImage(ciImage)
        } else {
            throw ImageOCRError.invalidImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            let resumable = OCRContinuation(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest { request, error in
                    if let error {
                        resumable.resume(throwing: ImageOCRError.recognitionFailed(underlying: error))
                        return
                    }
                    let observations = request.results as? [VNRecognizedTextObservation] ?? []
                    let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                    if lines.isEmpty {
                        resumable.resume(throwing: ImageOCRError.noTextFound)
                    } else {
                        resumable.resume(returning: lines.joined(separator: "\n"))
                    }
                }

                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                if !languageHints.isEmpty {
                    request.recognitionLanguages = languageHints
                }

                do {
                    let handler: VNImageRequestHandler
                    switch source {
                    case .cgImage(let cgImage):
                        handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                    case .ciImage(let ciImage):
                        handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
                    }
                    try handler.perform([request])
                } catch {
                    resumable.resume(throwing: ImageOCRError.recognitionFailed(underlying: error))
                }
            }
        }
    }
}
