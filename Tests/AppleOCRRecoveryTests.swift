import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
@testable import MoePeek

@Suite(.timeLimit(.minutes(2)))
struct AppleOCRRecoveryTests {
    @Test func revisionTwoRecoveryRecognizesEnglishAndChineseWithoutTheAccurateDefaultModel() async throws {
        let image = try makeMixedLanguageImage()
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("moepeek-ocr-recovery-test-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: imageURL) }
        guard let destination = CGImageDestinationCreateWithURL(
            imageURL as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }

        let workerURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MoePeekOCRWorker")
        let client = OCRWorkerClient(executableURL: workerURL)
        let text = try await client.recognizeText(at: imageURL, timeout: 8, recoveryMode: true)

        #expect(text.contains("MoePeek OCR 123"))
        #expect(text.contains("文字识别"))
    }

    private func makeMixedLanguageImage() throws -> CGImage {
        let width = 1200
        let height = 260
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String):
                CTFontCreateWithName("PingFangSC-Regular" as CFString, 48, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]

        for (index, text) in ["MoePeek OCR 123", "文字识别 日本語 한국어"].enumerated() {
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: attributes)
            )
            context.textPosition = CGPoint(x: 28, y: 190 - index * 90)
            CTLineDraw(line, context)
        }

        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return image
    }
}
