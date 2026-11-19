import ImageIO
import UIKit
import Vision

/// 图片里识别出的一行文字。`box` 是归一化坐标（原点在左下角），可用来在图上定位。
struct RecognizedLine: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let box: CGRect
}

protocol TextRecognizing: Sendable {
    /// `languages` 是希望优先识别的语言（Vision 的语言代码），不支持的会被忽略。
    func recognize(_ image: UIImage, languages: [String]) async throws -> [RecognizedLine]
}

enum TextRecognitionError: LocalizedError {
    case invalidImage
    var errorDescription: String? { String(localized: "这张图片无法读取") }
}

/// 基于 Vision 的端侧文字识别（不联网）。
struct VisionTextRecognizer: TextRecognizing {
    func recognize(_ image: UIImage, languages: [String]) async throws -> [RecognizedLine] {
        guard let cgImage = image.cgImage else { throw TextRecognitionError.invalidImage }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                if let supported = try? request.supportedRecognitionLanguages() {
                    let wanted = languages.filter { supported.contains($0) }
                    if !wanted.isEmpty { request.recognitionLanguages = wanted }
                }
                do {
                    try VNImageRequestHandler(cgImage: cgImage, orientation: orientation).perform([request])
                    let lines = (request.results ?? [])
                        .compactMap { observation -> RecognizedLine? in
                            guard let candidate = observation.topCandidates(1).first else { return nil }
                            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                            return text.isEmpty ? nil : RecognizedLine(text: text, box: observation.boundingBox)
                        }
                        // 从上到下排列（归一化坐标里 y 越大越靠上）
                        .sorted { $0.box.maxY > $1.box.maxY }
                    continuation.resume(returning: lines)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

extension LanguageOption {
    /// Vision 文字识别用的语言代码
    var ocrCode: String { id == "zh-Hans" ? "zh-Hans" : speechLocale }
}
