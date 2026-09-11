import UIKit
import CoreGraphics

public enum PunchHoleDetectionStrategy: Sendable {
    /// Hole punched through a year or month grid cell — reliable, consistent position.
    case gridCell
    /// Hole punched through an option-list checkbox — unreliable, position varies by tag design.
    case optionList
}

public struct PunchHoleDetectionResult: Sendable {
    public let lineText: String
    public let selected: Bool
    public let confidence: Float
    public let strategy: PunchHoleDetectionStrategy

    public init(lineText: String, selected: Bool, confidence: Float, strategy: PunchHoleDetectionStrategy) {
        self.lineText = lineText
        self.selected = selected
        self.confidence = confidence
        self.strategy = strategy
    }
}

/// Detects physically punched/marked option lines in fire-inspection tag images.
///
/// Two detection strategies run and are merged:
///
/// 1. **Left-margin scan** — for option lists (agent type, deficiency items, service type).
///    Scans the blank paper area strictly to the LEFT of each OCR line. A punch hole
///    in that margin creates a dark anomaly compared to unselected siblings.
///
/// 2. **Centre scan** — for year and month grids. The hole is punched THROUGH the
///    printed number/abbreviation itself, not to its left. Sibling cells in the same
///    horizontal row are compared; the darkest cell is flagged as selected.
public struct PunchHoleDetector {

    private let maxAnalysisDimension: CGFloat = 900

    private static let monthAbbreviations: Set<String> = [
        "JAN","FEB","MAR","APR","MAY","JUN","JUL","AUG","SEP","OCT","NOV","DEC"
    ]

    public init() {}

    public func detectSelections(
        in image: UIImage,
        ocrResult: OCRResult
    ) -> [PunchHoleDetectionResult] {
        guard !ocrResult.lines.isEmpty else { return [] }
        guard let cgImage = prepareCGImage(from: image) else { return [] }

        let imgW = Double(cgImage.width)
        let imgH = Double(cgImage.height)

        // Partition lines into grid tokens (years/months) vs regular option lines
        var gridLines: [OCRLine] = []
        var optionLines: [OCRLine] = []
        for line in ocrResult.lines {
            if isYearOrMonth(line.text) {
                gridLines.append(line)
            } else {
                optionLines.append(line)
            }
        }

        var results: [String: PunchHoleDetectionResult] = [:]

        // --- Strategy 1: circle-interior scan for regular option lines ---
        // Each option on a fire-inspection tag has a PRINTED black circle (○) to its left.
        // Non-punched: dark border ring + WHITE paper interior.
        // Punched:     dark border ring + DARK interior (hole reveals background behind paper).
        // Scanning only the INTERIOR of the circle avoids the confounding border darkness
        // shared by all printed circles, isolating only the punch-hole signal.
        let optionColumnGroups = groupByXAlignment(optionLines)
        for group in optionColumnGroups {
            let medianHeight = group.map { $0.boundingBox.height }.sorted()[group.count / 2]
            let circleRadius = medianHeight * 0.60
            let interiorHalf = circleRadius * 0.45  // sample inside the ring, not on it

            let circleScores: [(text: String, score: Float)] = group.compactMap { line in
                let bbox = line.boundingBox
                // Circle centre: ~2 radii to the left of text start, vertically centred
                let circleCenterX = max(interiorHalf, bbox.x - circleRadius * 2.0)
                let circleCenterY = bbox.y + bbox.height / 2.0

                let sX = max(0.0, circleCenterX - interiorHalf)
                let sW = min(1.0 - sX, interiorHalf * 2)
                let sY = max(0.0, circleCenterY - interiorHalf)
                let sH = min(1.0 - sY, interiorHalf * 2)
                guard sW > 0.002, sH > 0.002 else { return nil }

                let cropRect = CGRect(
                    x: sX  * imgW,
                    y: (1.0 - sY - sH) * imgH,
                    width: max(1, sW * imgW),
                    height: max(1, sH * imgH)
                )
                guard let crop = cgImage.cropping(to: cropRect), crop.width > 0 else { return nil }
                return (text: line.text, score: darknessFraction(of: crop))
            }

            let vals     = circleScores.map(\.score)
            let maxScore = vals.max() ?? 0
            let mean     = vals.reduce(0, +) / Float(vals.count)
            let floor: Float = 0.020
            if maxScore >= floor {
                let range = maxScore - mean
                for item in circleScores {
                    let isHeader   = isSectionHeader(item.text)
                    let isSelected = !isHeader
                        && item.score >= floor
                        && (range < 0.003 || item.score >= mean + range * 0.55)
                    let confidence: Float = isSelected && range > 0
                        ? min(0.95, 0.50 + 0.45 * ((item.score - mean) / range))
                        : 0
                    results[item.text] = PunchHoleDetectionResult(
                        lineText: item.text, selected: isSelected, confidence: confidence,
                        strategy: .optionList)
                }
            } else {
                for item in circleScores {
                    results[item.text] = PunchHoleDetectionResult(
                        lineText: item.text, selected: false, confidence: 0, strategy: .optionList)
                }
            }
        }


        // --- Strategy 2: centre scan for year/month grid rows ---
        // Group grid lines into horizontal rows (lines whose Y centres are within ~3% of each other)
        let gridGroups = groupByRow(gridLines)
        for group in gridGroups where group.count > 1 {
            let cellScores: [(line: OCRLine, score: Float)] = group.compactMap { line in
                let bbox = line.boundingBox
                // Scan the centre of the bounding box (where the hole would be punched)
                let pad  = 0.005
                let sX   = max(0.0, bbox.x + pad)
                let sW   = max(0.005, bbox.width - 2 * pad)
                let sY   = max(0.0, bbox.y + pad)
                let sH   = max(0.005, bbox.height - 2 * pad)
                let cropRect = CGRect(
                    x: sX * imgW,
                    y: (1.0 - sY - sH) * imgH,
                    width: max(1, sW * imgW),
                    height: max(1, sH * imgH)
                )
                guard let crop = cgImage.cropping(to: cropRect), crop.width > 0 else { return nil }
                return (line: line, score: darknessFraction(of: crop))
            }
            guard !cellScores.isEmpty else { continue }
            let vals     = cellScores.map(\.score)
            let maxScore = vals.max() ?? 0
            let mean     = vals.reduce(0, +) / Float(vals.count)
            let floor: Float = 0.025
            let range = maxScore - mean
            for cell in cellScores {
                let isSelected = cell.score >= floor && (range < 0.003 || cell.score >= mean + range * 0.60)
                let confidence: Float = isSelected && range > 0
                    ? min(0.95, 0.50 + 0.45 * ((cell.score - mean) / range))
                    : 0
                results[cell.line.text] = PunchHoleDetectionResult(
                    lineText: cell.line.text, selected: isSelected, confidence: confidence,
                    strategy: .gridCell)
            }
        }

        // Return in original OCR order
        return ocrResult.lines.map { line in
            results[line.text] ?? PunchHoleDetectionResult(
                lineText: line.text, selected: false, confidence: 0, strategy: .optionList)
        }
    }

    // MARK: - Helpers

    private func isYearOrMonth(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if t.count == 4, let year = Int(t), year >= 1990, year <= 2040 { return true }
        return Self.monthAbbreviations.contains(t)
    }

    /// Groups option lines into same-section, same-column clusters.
    /// First splits by Y-section (vertical sections of the tag separated by gaps > 12%),
    /// then within each section splits by X-column alignment.
    /// This prevents header-section punches (RECHARGE, FULL WT.) from contaminating
    /// the agent-type option list comparison.
    private func groupByXAlignment(_ lines: [OCRLine]) -> [[OCRLine]] {
        guard !lines.isEmpty else { return [] }

        // Step 1: sort top-to-bottom (Vision Y decreases going down)
        let byY = lines.sorted { $0.boundingBox.y > $1.boundingBox.y }

        // Step 2: split into Y-sections where gap between consecutive lines > 12%
        var ySections: [[OCRLine]] = []
        var section: [OCRLine] = [byY[0]]
        for line in byY.dropFirst() {
            let prevY = section.last!.boundingBox.y
            if abs(line.boundingBox.y - prevY) > 0.12 {
                ySections.append(section)
                section = []
            }
            section.append(line)
        }
        ySections.append(section)

        // Step 3: within each Y-section, split by X-column alignment
        var groups: [[OCRLine]] = []
        for ySection in ySections where ySection.count > 1 {
            let byX = ySection.sorted { $0.boundingBox.x < $1.boundingBox.x }
            var col: [OCRLine] = [byX[0]]
            for line in byX.dropFirst() {
                if abs(line.boundingBox.x - col.last!.boundingBox.x) < 0.08 {
                    col.append(line)
                } else {
                    if col.count > 1 { groups.append(col) }
                    col = [line]
                }
            }
            if col.count > 1 { groups.append(col) }
        }
        return groups
    }

    /// Groups OCR lines into horizontal rows by clustering their Y-centre positions.
    private func groupByRow(_ lines: [OCRLine]) -> [[OCRLine]] {
        guard !lines.isEmpty else { return [] }
        let sorted = lines.sorted { $0.boundingBox.y > $1.boundingBox.y } // top to bottom (Vision Y flipped)
        var groups: [[OCRLine]] = []
        var current: [OCRLine] = [sorted[0]]
        for line in sorted.dropFirst() {
            let prevY = current.last!.boundingBox.y + current.last!.boundingBox.height / 2
            let currY = line.boundingBox.y + line.boundingBox.height / 2
            if abs(prevY - currY) < 0.04 { // within 4% of image height = same row
                current.append(line)
            } else {
                groups.append(current)
                current = [line]
            }
        }
        groups.append(current)
        return groups
    }

    private func isSectionHeader(_ text: String) -> Bool {
        let connectors: Set<String> = ["BY", "FOR", "TO", "FROM", "AT", "IN", "OF", "AND", "OR"]
        let last = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .last?.uppercased() ?? ""
        return connectors.contains(last)
    }

    private func prepareCGImage(from image: UIImage) -> CGImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1.0, maxAnalysisDimension / max(size.width, size.height))
        let targetSize = CGSize(
            width:  (size.width  * scale).rounded(),
            height: (size.height * scale).rounded()
        )
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: targetSize)) }.cgImage
    }

    private func darknessFraction(of cgImage: CGImage, threshold: UInt8 = 85) -> Float {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return 0 }
        var pixels = [UInt8](repeating: 255, count: w * h)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        let darkCount = pixels.filter { $0 < threshold }.count
        return Float(darkCount) / Float(pixels.count)
    }
}
