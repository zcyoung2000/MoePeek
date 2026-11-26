import Foundation
import os
@preconcurrency import Vision

/// Accurate OCR hosted in MoePeek's long-lived process so Vision can reuse its initialized models.
public enum AppleOCREngine: Sendable {
    private static let logger = Logger(subsystem: "com.nahida.MoePeek", category: "OCR")
    private static let recognitionSlot = RecognitionSlot()

    public enum RecognitionError: LocalizedError, Sendable {
        case timeout
        case alreadyInProgress
        case failed(any Error)

        public var errorDescription: String? {
            switch self {
            case .timeout: String(localized: "Text recognition timed out")
            case .alreadyInProgress: String(localized: "Text recognition is still in progress")
            case .failed(let error):
                String(localized: "Vision recognition failed: \(error.localizedDescription)")
            }
        }
    }

    public static func recognizeText(
        in image: CGImage,
        timeout: TimeInterval = 20
    ) async throws -> String {
        guard recognitionSlot.claim() else {
            throw RecognitionError.alreadyInProgress
        }
        let lease = RecognitionLease(slot: recognitionSlot)

        let started = Date()
        logger.info("Starting Apple OCR (\(image.width)x\(image.height) px)")
        let observations: [RecognizedLine]
        do {
            observations = try await Task<Never, Never>.withTimeout(seconds: timeout) {
                guard lease.markStarted() else { throw CancellationError() }
                defer { lease.release() }
                return try await performVisionOCR(on: image)
            }
        } catch is TaskTimeoutError {
            lease.releaseIfNotStarted()
            logger.error("Apple OCR timed out after \(timeout, privacy: .public) seconds")
            throw RecognitionError.timeout
        } catch {
            lease.releaseIfNotStarted()
            logger.error("Apple OCR failed after \(Date().timeIntervalSince(started), privacy: .public) seconds: \(String(describing: error), privacy: .public)")
            throw error
        }
        let text = observations
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
        logger.info("Apple OCR finished in \(Date().timeIntervalSince(started), privacy: .public) seconds with \(observations.count, privacy: .public) observations")
        return text
    }

    private static func performVisionOCR(on cgImage: CGImage) async throws -> [RecognizedLine] {
        return try await performLegacyVisionOCR(on: cgImage)
    }

    // MARK: - Legacy API

    private static func performLegacyVisionOCR(on cgImage: CGImage) async throws -> [RecognizedLine] {
        try await performSingleLegacyVisionOCR(on: cgImage)
    }

    private static func performSingleLegacyVisionOCR(
        on cgImage: CGImage,
        recognitionLanguages: [String] = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"],
        automaticallyDetectsLanguage: Bool = true,
        recognitionLevel: VNRequestTextRecognitionLevel = .accurate
    ) async throws -> [RecognizedLine] {
        try await withCheckedThrowingContinuation { continuation in
            let continuationGate = ContinuationGate(continuation: continuation)
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuationGate.resume(throwing: RecognitionError.failed(error))
                    return
                }

                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                continuationGate.resume(
                    returning: observations.compactMap { observation in
                        guard let candidate = observation.topCandidates(1).first else { return nil }
                        return RecognizedLine(text: candidate.string)
                    }
                )
            }

            request.recognitionLevel = recognitionLevel
            request.revision = 2
            request.recognitionLanguages = recognitionLanguages
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = automaticallyDetectsLanguage

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuationGate.resume(throwing: RecognitionError.failed(error))
                }
            }
        }
    }

}

private struct RecognizedLine: Sendable {
    let text: String
}

/// Race-safe one-shot continuation wrapper for the legacy callback/perform API.
private final class ContinuationGate<T: Sendable, E: Error>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, E>?

    init(continuation: CheckedContinuation<T, E>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        takeContinuation()?.resume(returning: value)
    }

    func resume(throwing error: E) {
        takeContinuation()?.resume(throwing: error)
    }

    private func takeContinuation() -> CheckedContinuation<T, E>? {
        lock.lock()
        defer { lock.unlock() }
        let continuation = continuation
        self.continuation = nil
        return continuation
    }
}

private final class RecognitionSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var isClaimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isClaimed else { return false }
        isClaimed = true
        return true
    }

    func release() {
        lock.lock()
        isClaimed = false
        lock.unlock()
    }
}

private final class RecognitionLease: @unchecked Sendable {
    private let lock = NSLock()
    private let slot: RecognitionSlot
    private var started = false
    private var released = false

    init(slot: RecognitionSlot) {
        self.slot = slot
    }

    func markStarted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return false }
        started = true
        return true
    }

    func releaseIfNotStarted() {
        lock.lock()
        guard !started, !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        slot.release()
    }

    func release() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        slot.release()
    }
}
