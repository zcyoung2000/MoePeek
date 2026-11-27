import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import MoePeek

@Suite(.timeLimit(.minutes(5)))
struct AppleOCREngineTests {
    @Test @MainActor func accurateVisionReusesTheWarmedProcess() async throws {
        OCRWarmupCoordinator.warmUpIfNeeded()
        let deadline = ContinuousClock.now + .seconds(150)
        while !OCRWarmupCoordinator.isReady, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(OCRWarmupCoordinator.isReady)

        // Change both image size and content to catch stale model resources and
        // accidentally returning the preceding request's observations.
        // A mixed-script warmup does not guarantee that Vision loads Korean.
        // Budget its first use for cold initialization, then check warmed reuse
        // with the same 20-second limit as other captures.
        for (width, height, marker, script, timeout) in [
            (140, 66, "234", "文字识别测试", 20.0),
            (530, 112, "123", "文字识别测试", 20.0),
            (1718, 204, "456", "文字识别测试", 20.0),
            (960, 240, "789", "日本語の認識", 20.0),
            (960, 240, "852", "한국어 인식", 120.0),
            (960, 240, "963", "한국어 인식", 20.0),
            (530, 112, "123", "文字识别测试", 20.0),
        ] {
            let image = try makeMixedLanguageImage(width: width, height: height, marker: marker, script: script)
            let text = try await AppleOCREngine.recognizeText(in: image, timeout: timeout)
            if width < 300 {
                #expect(text.contains(marker))
            } else {
                #expect(text.contains("Hello"))
                #expect(text.contains(marker))
                #expect(text.contains(script))
            }
        }
    }

    private func makeMixedLanguageImage(width: Int, height: Int, marker: String, script: String) throws -> CGImage {
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
        // Keep sample text legible across the different image sizes.
        let fontSize: CGFloat = width < 300 ? 12 : (width >= 1500 ? 44 : 28)
        let lineSpacing = width < 300 ? 20 : (width >= 1500 ? 64 : 44)
        let lines = ["Hello world \(marker)", script]
        for (index, text) in lines.enumerated() {
            let fontName = index == 0 ? "Helvetica" : "PingFangSC-Regular"
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String):
                    CTFontCreateWithName(fontName as CFString, fontSize, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: attributes)
            )
            context.textPosition = CGPoint(x: 28, y: height - Int(fontSize) - 8 - index * lineSpacing)
            CTLineDraw(line, context)
        }

        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return image
    }
}
