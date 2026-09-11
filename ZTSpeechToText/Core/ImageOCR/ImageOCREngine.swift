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

// MARK: - Detailed OCR Models

public struct OCRBoundingBox: Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct OCRLine: Sendable {
    public let text: String
    /// Vision normalized rectangle in image coordinates.
    public let boundingBox: OCRBoundingBox
    public let confidence: Float

    public init(text: String, boundingBox: OCRBoundingBox, confidence: Float) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

public struct OCRResult: Sendable {
    public let fullText: String
    public let lines: [OCRLine]

    public init(fullText: String, lines: [OCRLine]) {
        self.fullText = fullText
        self.lines = lines
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
        private var continuation: CheckedContinuation<OCRResult, Error>?

        init(_ continuation: CheckedContinuation<OCRResult, Error>) {
            self.continuation = continuation
        }

        func resume(returning value: OCRResult) {
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
    // Returns full text plus per-line Vision metadata for downstream layout analysis.
    public func recognizeDetailedText(in image: UIImage, languageHints: [String] = []) async throws -> OCRResult {
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
                    let lines: [OCRLine] = observations.compactMap { observation in
                        guard let best = observation.topCandidates(1).first else { return nil }
                        let box = observation.boundingBox
                        return OCRLine(
                            text: best.string,
                            boundingBox: OCRBoundingBox(
                                x: Double(box.origin.x),
                                y: Double(box.origin.y),
                                width: Double(box.size.width),
                                height: Double(box.size.height)
                            ),
                            confidence: best.confidence
                        )
                    }
                    if lines.isEmpty {
                        resumable.resume(throwing: ImageOCRError.noTextFound)
                    } else {
                        let fullText = lines.map(\.text).joined(separator: "\n")
                        resumable.resume(returning: OCRResult(fullText: fullText, lines: lines))
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

    // Backward-compatible convenience API used by existing callers.
    public func recognizeText(in image: UIImage, languageHints: [String] = []) async throws -> String {
        let detailed = try await recognizeDetailedText(in: image, languageHints: languageHints)
        return detailed.fullText
    }
}
