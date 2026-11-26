import Foundation
import os

enum ScreenCaptureOCR {
    private static let logger = Logger(subsystem: "com.nahida.MoePeek", category: "OCRCapture")
    private static let accurateTimeout: TimeInterval = 8
    // CPU Vision initialization is ANE-independent but can still take about
    // ten seconds on a cold process. Keep the normal capture deadline short;
    // give the isolated compatibility helper enough time to initialize once.
    private static let recoveryTimeout: TimeInterval = 12

    /// Launch interactive screen capture, OCR the captured image, and return recognized text.
    static func captureAndRecognize() async throws -> String {
        // Generate a unique temp file path to avoid concurrency conflicts
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moepeek_ocr_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        // Run screencapture -i <tmpPath> (interactive selection → temp file, clipboard untouched)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", tmpURL.path]

        let status = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                let resumed = ProcessContinuationGate()

                process.terminationHandler = { proc in
                    guard resumed.claimOnce() else { return }
                    continuation.resume(returning: proc.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    guard resumed.claimOnce() else { return }
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.terminate()
        }

        guard !Task.isCancelled else { throw CancellationError() }

        guard status == 0 else {
            throw OCRError.captureCancelled
        }

        // Esc may exit successfully without creating a file. Decode only in the worker:
        // decoding here needlessly retains a full screenshot in the menu bar process.
        guard FileManager.default.fileExists(atPath: tmpURL.path) else {
            throw OCRError.captureCancelled
        }

        return try await recognize(
            accurate: {
                try await OCRWorkerClient.recognizeText(
                    at: tmpURL,
                    timeout: accurateTimeout
                )
            },
            recovery: {
                try await recoverText(at: tmpURL)
            }
        )
    }

    static func recognize(
        accurate: () async throws -> String,
        recovery: () async throws -> String
    ) async throws -> String {
        let text: String
        do {
            text = try await accurate()
        } catch OCRError.captureCancelled {
            throw OCRError.captureCancelled
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.warning("Accurate OCR failed or timed out; trying compatibility OCR: \(String(describing: error), privacy: .public)")
            return try await nonEmptyRecovery(recovery)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return try await nonEmptyRecovery(recovery)
        }
        return text
    }

    private static func nonEmptyRecovery(
        _ recovery: () async throws -> String
    ) async throws -> String {
        let text = try await recovery()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.error("OCR recovery returned no recognized text")
            throw OCRError.noTextRecognized
        }
        return text
    }

    private static func recoverText(at imageURL: URL) async throws -> String {
        let started = Date()
        logger.info("Starting CPU-compatible OCR recovery")
        do {
            let text = try await OCRWorkerClient.recognizeText(
                at: imageURL,
                timeout: recoveryTimeout,
                recoveryMode: true
            )
            logger.info("CPU-compatible OCR recovery completed in \(Date().timeIntervalSince(started), privacy: .public) seconds; result empty: \(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, privacy: .public)")
            return text
        } catch {
            logger.error("CPU-compatible OCR recovery failed after \(Date().timeIntervalSince(started), privacy: .public) seconds: \(String(describing: error), privacy: .public)")
            throw error
        }
    }
}

enum OCRError: LocalizedError {
    case captureCancelled
    case captureReadFailed
    case noTextRecognized
    case timeout
    case recognitionFailed(any Error)
    case workerUnavailable
    case workerFailed(Int32, reason: String = "")
    case workerResponseInvalid
    case warmupImageCreationFailed

    var errorDescription: String? {
        switch self {
        case .captureCancelled:  String(localized: "Screen capture was cancelled")
        case .captureReadFailed: String(localized: "Failed to read the captured image")
        case .noTextRecognized:  String(localized: "No text was recognized in the captured image")
        case .timeout:           String(localized: "Text recognition timed out")
        case .recognitionFailed(let error):
            String(localized: "Vision recognition failed: \(error.localizedDescription)")
        case .workerUnavailable: String(localized: "OCR helper is unavailable")
        case let .workerFailed(status, reason):
            reason.isEmpty
                ? String(localized: "OCR helper exited with status \(status)")
                : String(localized: "OCR helper exited with status \(status): \(reason)")
        case .workerResponseInvalid:
            String(localized: "OCR helper returned an invalid response")
        case .warmupImageCreationFailed:
            String(localized: "Could not create the OCR warmup image")
        }
    }
}
