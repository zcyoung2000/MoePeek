import Foundation
import ImageIO

enum ScreenCaptureOCR {
    /// Capture a screen region, then run one accurate Vision request in the app process.
    static func captureAndRecognize() async throws -> String {
        try Task.checkCancellation()
        try await OCRWarmupCoordinator.requireReady()

        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("moepeek_ocr_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", imageURL.path]

        let status = try await runCaptureProcess(process)
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

    /// Wait for the child to exit before releasing its capture file, even on cancellation.
    static func runCaptureProcess(
        _ process: Process,
        launch: @Sendable (Process) throws -> Void = { try $0.run() }
    ) async throws -> Int32 {
        try Task.checkCancellation()
        let status = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                let gate = ProcessContinuationGate()
                process.terminationHandler = { child in
                    guard gate.claimOnce() else { return }
                    child.terminationHandler = nil
                    continuation.resume(returning: child.terminationStatus)
                }
                do {
                    guard !Task.isCancelled else {
                        guard gate.claimOnce() else { return }
                        process.terminationHandler = nil
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    try launch(process)
                    if Task.isCancelled, process.isRunning {
                        process.terminate()
                    }
                } catch {
                    guard gate.claimOnce() else { return }
                    process.terminationHandler = nil
                    continuation.resume(throwing: Task.isCancelled ? CancellationError() : error)
                }
            }
        } onCancel: {
            // terminate() raises an Objective-C exception before the first run().
            // A cancellation during launch is handled by the check after run().
            if process.isRunning {
                process.terminate()
            }
        }

        try Task.checkCancellation()
        return status
    }

    static func recognize(accurate: () async throws -> String) async throws -> String {
        try Task.checkCancellation()
        let text = try await accurate()
        try Task.checkCancellation()
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
