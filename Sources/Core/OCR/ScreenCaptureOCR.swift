import Foundation
import ImageIO

enum ScreenCaptureOCR {
    /// Capture a screen region, then run one accurate Vision request in the app process.
    static func captureAndRecognize() async throws -> String {
        try await OCRWarmupCoordinator.requireReady()

        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("moepeek_ocr_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", imageURL.path]

        let status = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                let gate = ProcessContinuationGate()
                process.terminationHandler = { child in
                    guard gate.claimOnce() else { return }
                    continuation.resume(returning: child.terminationStatus)
                }
                do {
                    guard !Task.isCancelled else {
                        guard gate.claimOnce() else { return }
                        process.terminationHandler = nil
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    try process.run()
                    if Task.isCancelled {
                        process.terminate()
                    }
                } catch {
                    guard gate.claimOnce() else { return }
                    process.terminationHandler = nil
                    continuation.resume(throwing: Task.isCancelled ? CancellationError() : error)
                }
            }
        } onCancel: {
            process.terminate()
        }

        guard !Task.isCancelled else { throw CancellationError() }
        guard status == 0, FileManager.default.fileExists(atPath: imageURL.path) else {
            throw OCRError.captureCancelled
        }
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw OCRError.captureReadFailed
        }

        return try await recognize {
            try await AppleOCREngine.recognizeText(in: image)
        }
    }

    static func recognize(accurate: () async throws -> String) async throws -> String {
        let text = try await accurate()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OCRError.noTextRecognized
        }
        return text
    }
}

enum OCRError: LocalizedError {
    case captureCancelled
    case captureReadFailed
    case engineWarmingUp
    case noTextRecognized
    case warmupImageCreationFailed

    var errorDescription: String? {
        switch self {
        case .captureCancelled:  String(localized: "Screen capture was cancelled")
        case .captureReadFailed: String(localized: "Failed to read the captured image")
        case .engineWarmingUp:   String(localized: "OCR is still initializing. Please try again shortly.")
        case .noTextRecognized:  String(localized: "No text was recognized in the captured image")
        case .warmupImageCreationFailed:
            String(localized: "Could not create the OCR warmup image")
        }
    }
}
