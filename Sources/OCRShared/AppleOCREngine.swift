import Foundation
import CoreML
import os
@preconcurrency import Vision

/// Accurate OCR for a one-shot worker. The parent owns serialization and the hard deadline.
/// Do not race a second request against a model load or silently replace CJK with English-only fast OCR.
public enum AppleOCREngine: Sendable {
    private static let logger = Logger(subsystem: "com.nahida.MoePeek", category: "OCR")
    private static let recoveryRecognitionRevision = 2

    public enum RecognitionError: LocalizedError, Sendable {
        case timeout
        case cpuRecoveryUnavailable
        case failed(any Error)

        public var errorDescription: String? {
            switch self {
            case .timeout: String(localized: "Text recognition timed out")
            case .cpuRecoveryUnavailable: String(localized: "CPU OCR recovery is unavailable")
            case .failed(let error):
                String(localized: "Vision recognition failed: \(error.localizedDescription)")
            }
        }
    }

    private static let preferredModernRecognitionLanguages = [
        Locale.Language(identifier: "zh-Hans"),
        Locale.Language(identifier: "zh-Hant"),
        Locale.Language(identifier: "en-US"),
        Locale.Language(identifier: "ja-JP"),
        Locale.Language(identifier: "ko-KR"),
    ]

    /// Match preferred languages to this system's actual modern Vision support.
    private static let supportedModernRecognitionLanguages: [Locale.Language] = {
        let request = RecognizeTextRequest()
        let supported = request.supportedRecognitionLanguages
        return preferredModernRecognitionLanguages.compactMap { preferred in
            supported.first { $0.isEquivalent(to: preferred) }
        }
    }()

    public static func recognizeText(
        in image: CGImage,
        recoveryMode: Bool = false
    ) async throws -> String {
        logger.info(
            "Starting Apple OCR (\(image.width)x\(image.height) px), recovery: \(recoveryMode, privacy: .public)"
        )
        let observations = recoveryMode
            ? try await performRecoveryVisionOCR(on: image)
            : try await performVisionOCR(on: image)
        let text = observations
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
        logger.info("Apple OCR finished with \(observations.count, privacy: .public) observations")
        return text
    }

    private static func performVisionOCR(on cgImage: CGImage) async throws -> [RecognizedLine] {
        if #available(macOS 26.0, *) {
            do {
                return try await performModernVisionOCR(on: cgImage, recognitionLevel: .accurate)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // On macOS 27, falling through to another accurate request can
                // pay the same ANE compilation cost a second time. The caller
                // owns the fast recovery policy and can bound this attempt.
                logger.error("Modern Vision OCR failed: \(String(describing: error), privacy: .public)")
                throw error
            }
        }
        return try await performLegacyVisionOCR(on: cgImage)
    }

    /// Compatibility path for the macOS 27 accurate-model regression.
    /// Revision 2 supports Chinese and Western languages and is explicitly pinned
    /// to CPU so a cold ANE model compile cannot stall the recovery request too.
    private static func performRecoveryVisionOCR(on cgImage: CGImage) async throws -> [RecognizedLine] {
        let accurateRequest = VNRecognizeTextRequest()
        accurateRequest.revision = recoveryRecognitionRevision
        accurateRequest.recognitionLevel = .accurate
        let accurateSupported = (try? accurateRequest.supportedRecognitionLanguages()) ?? []
        let accurateLanguages = ["zh-Hans", "zh-Hant", "en-US"].filter(accurateSupported.contains)

        logger.info(
            "Running OCR recovery with Vision revision 2, languages: \(accurateLanguages, privacy: .public)"
        )
        do {
            let accurateObservations = try await performSingleLegacyVisionOCR(
                on: cgImage,
                recognitionLanguages: accurateLanguages,
                automaticallyDetectsLanguage: false,
                recognitionLevel: .accurate,
                revision: recoveryRecognitionRevision,
                computeOnCPU: true
            )
            if !accurateObservations.isEmpty { return accurateObservations }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("Vision revision 2 recovery failed: \(String(describing: error), privacy: .public)")
            throw error
        }
        return []
    }

    // MARK: - Legacy API

    private static func performLegacyVisionOCR(on cgImage: CGImage) async throws -> [RecognizedLine] {
        let observations = try await performSingleLegacyVisionOCR(on: cgImage)

        // Easydict found Japanese samples that auto language detection misses entirely.
        if observations.isEmpty {
            return try await performSingleLegacyVisionOCR(
                on: cgImage,
                recognitionLanguages: ["ja-JP"],
                automaticallyDetectsLanguage: false
            )
        }
        return observations
    }

    private static func performSingleLegacyVisionOCR(
        on cgImage: CGImage,
        recognitionLanguages: [String] = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"],
        automaticallyDetectsLanguage: Bool = true,
        recognitionLevel: VNRequestTextRecognitionLevel = .accurate,
        revision: Int? = nil,
        computeOnCPU: Bool = false
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
            if let revision { request.revision = revision }
            request.recognitionLanguages = recognitionLanguages
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = automaticallyDetectsLanguage

            if computeOnCPU {
                do {
                    let availableDevices = try request.supportedComputeStageDevices[.main] ?? []
                    guard let cpuDevice = availableDevices.first(where: { device in
                        if case .cpu = device { return true }
                        return false
                    }) else {
                        continuationGate.resume(throwing: RecognitionError.cpuRecoveryUnavailable)
                        return
                    }
                    request.setComputeDevice(cpuDevice, for: .main)
                    logger.info("Pinned compatibility OCR to CPU to bypass ANE compilation")
                } catch {
                    continuationGate.resume(throwing: RecognitionError.failed(error))
                    return
                }
            }

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

    // MARK: - Modern API

    @available(macOS 26.0, *)
    private static func performModernVisionOCR(
        on cgImage: CGImage,
        recognitionLevel: RecognizeTextRequest.RecognitionLevel
    ) async throws -> [RecognizedLine] {
        let observations = try await performSingleModernVisionOCR(
            on: cgImage,
            recognitionLanguages: Self.supportedModernRecognitionLanguages,
            automaticallyDetectsLanguage: true,
            recognitionLevel: recognitionLevel
        )

        guard observations.isEmpty, recognitionLevel == .accurate else { return observations }

        // Easydict found Japanese samples that automatic language detection misses entirely.
        logger.info("No text recognized with automatic languages; retrying with Japanese")
        return try await performSingleModernVisionOCR(
            on: cgImage,
            recognitionLanguages: [.init(identifier: "ja-JP")],
            automaticallyDetectsLanguage: false,
            recognitionLevel: recognitionLevel
        )
    }

    private static func performSingleModernVisionOCR(
        on cgImage: CGImage,
        recognitionLanguages: [Locale.Language],
        automaticallyDetectsLanguage: Bool,
        recognitionLevel: RecognizeTextRequest.RecognitionLevel
    ) async throws -> [RecognizedLine] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = recognitionLevel
        let supportedLanguages = request.supportedRecognitionLanguages
        request.recognitionLanguages = recognitionLanguages.compactMap { preferred in
            supportedLanguages.first { supported in
                supported.isEquivalent(to: preferred)
            }
        }
        request.usesLanguageCorrection = recognitionLevel == .accurate
        request.automaticallyDetectsLanguage = automaticallyDetectsLanguage

        logger.info(
            "Performing modern Vision OCR with level: \(recognitionLevel == .fast ? "fast" : "accurate", privacy: .public), languages: \(request.recognitionLanguages.map(\.minimalIdentifier), privacy: .public), auto detect: \(request.automaticallyDetectsLanguage, privacy: .public)"
        )

        do {
            let observations = try await request.perform(on: cgImage)
            return observations.compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return RecognizedLine(text: candidate.string)
            }
        } catch {
            throw RecognitionError.failed(error)
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
