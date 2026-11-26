import CoreGraphics
import CoreText
import Foundation
import os

/// Warms Vision in MoePeek's long-lived process so real captures reuse that runtime.
@MainActor
enum OCRWarmupCoordinator {
    private static let logger = Logger(subsystem: "com.nahida.MoePeek", category: "OCRWarmup")
    private static var warmupTask: Task<Void, Never>?
    private(set) static var isReady = false

    static func warmUpIfNeeded() {
        guard warmupTask == nil, !isReady else { return }

        warmupTask = Task(priority: .utility) {
            defer { warmupTask = nil }
            do {
                let started = Date()
                let image = try makeWarmupImage()
                let text = try await AppleOCREngine.recognizeText(in: image, timeout: 120)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    logger.error("OCR warmup returned no text; the engine is not ready")
                    return
                }
                isReady = true
                logger.info("OCR warmup completed in \(Date().timeIntervalSince(started), privacy: .public) seconds")
            } catch is CancellationError {
                logger.info("OCR warmup was cancelled")
            } catch {
                logger.error("OCR warmup failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    static func requireReady() throws {
        guard !isReady else { return }
        warmUpIfNeeded()
        throw OCRError.engineWarmingUp
    }

    private static func makeWarmupImage() throws -> CGImage {
        let width = 640
        let height = 240
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw OCRError.warmupImageCreationFailed
        }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Keep scripts on separate lines so automatic detection exercises each
        // recognizer instead of classifying a mixed CJK line as just one script.
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String):
                CTFontCreateWithName("Helvetica" as CFString, 28, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(gray: 0, alpha: 1),
        ]
        for (index, text) in ["MoePeek OCR 123", "文字识别测试", "日本語の認識", "한국어 인식"].enumerated() {
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: attributes)
            )
            context.textPosition = CGPoint(x: 12, y: height - 44 - index * 48)
            CTLineDraw(line, context)
        }

        guard let image = context.makeImage() else { throw OCRError.warmupImageCreationFailed }
        return image
    }
}
