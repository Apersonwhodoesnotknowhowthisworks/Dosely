import Foundation
import UIKit
import Vision

struct RecognizedTextLine: Equatable {
    let text: String
    let confidence: Float
    /// Vision's normalised coordinate space: (0,0) at bottom-left, (1,1) at top-right.
    let boundingBox: CGRect
}

enum OCRError: LocalizedError {
    case noImage
    case visionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noImage:               return "We couldn't read the photo."
        case .visionFailed(let e):   return "OCR failed: \(e.localizedDescription)"
        }
    }
}

enum OCRService {
    /// Runs Vision's `.accurate` text recognition on the supplied image and
    /// returns each observation as a `RecognizedTextLine`. Async; safe to
    /// call from the main actor — the underlying work is dispatched onto
    /// Vision's own queue.
    static func recognizeText(from image: UIImage) async throws -> [RecognizedTextLine] {
        guard let cgImage = image.cgImage else { throw OCRError.noImage }
        let orientation = CGImagePropertyOrientation(uiImage: image)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[RecognizedTextLine], Error>) in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    cont.resume(throwing: OCRError.visionFailed(error))
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines: [RecognizedTextLine] = observations.compactMap { obs in
                    guard let candidate = obs.topCandidates(1).first else { return nil }
                    return RecognizedTextLine(
                        text: candidate.string,
                        confidence: candidate.confidence,
                        boundingBox: obs.boundingBox
                    )
                }
                cont.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]
            if #available(iOS 16.0, *) {
                request.revision = VNRecognizeTextRequestRevision3
            }

            let handler = VNImageRequestHandler(cgImage: cgImage,
                                                orientation: orientation,
                                                options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    cont.resume(throwing: OCRError.visionFailed(error))
                }
            }
        }
    }
}

private extension CGImagePropertyOrientation {
    init(uiImage: UIImage) {
        switch uiImage.imageOrientation {
        case .up:            self = .up
        case .down:          self = .down
        case .left:          self = .left
        case .right:         self = .right
        case .upMirrored:    self = .upMirrored
        case .downMirrored:  self = .downMirrored
        case .leftMirrored:  self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default:    self = .up
        }
    }
}
