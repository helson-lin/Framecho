import CoreGraphics
import Foundation

// Checks how screenshot translation picks its languages and paints the
// translated text over the original.
@main
struct ScreenshotTranslationChecks {
    static func main() {
        var failures = 0
        func expect(_ condition: Bool, _ message: String) {
            print("\(condition ? "ok  " : "FAIL") \(message)")
            if !condition { failures += 1 }
        }
        typealias Planner = ScreenshotTranslationPlanner

        // Direction: Chinese to English for a Chinese speaker, and back.
        let english = ["Settings", "Open the file in a new window", "Cancel"]
        let chinese = ["设置", "在新窗口中打开文件", "取消"]
        expect(Planner.defaultTarget(for: english, preferredLanguages: ["zh-Hans-CN"]) == "zh-Hans", "English screenshot → Chinese")
        expect(Planner.defaultTarget(for: chinese, preferredLanguages: ["zh-Hans-CN"]) == "en", "Chinese screenshot → English")
        expect(Planner.defaultTarget(for: chinese, preferredLanguages: ["zh-Hant-TW"]) == "en", "Traditional speaker, Chinese screenshot → English")
        expect(Planner.defaultTarget(for: english, preferredLanguages: ["zh-TW"]) == "zh-Hant", "zh-TW → Traditional")
        expect(Planner.defaultTarget(for: english, preferredLanguages: ["en-US"]) == "zh-Hans", "English speaker, English screenshot → Chinese")
        expect(Planner.defaultTarget(for: chinese, preferredLanguages: ["en-US"]) == "en", "English speaker, Chinese screenshot → English")
        expect(Planner.defaultTarget(for: ["Einstellungen öffnen", "Datei speichern"], preferredLanguages: ["en-US"]) == "en", "German → home language")
        let names = ["SKHHOrOIC", "subTrack", "umamibar", "Remote Control", "jarin-floating-rain", "JarinHe", "截图支持截图翻译功能"]
        expect(Planner.plan(for: names, target: "zh-Hans")?.source == "en", "Names and identifiers read as English")
        expect(Planner.plan(for: ["Ouvrir le fichier", "Enregistrer"], target: "zh-Hans")?.source == "fr", "French is still French")

        // Which blocks: only the source language, leaving the rest alone.
        let mixed = ["截图支持截图翻译功能", "Framecho", "这台电脑", "12:30", "Remote Control", "工作树"]
        let toEnglish = Planner.plan(for: mixed, target: "en")
        expect(toEnglish?.source.hasPrefix("zh") == true, "Mixed → English translates Chinese: \(String(describing: toEnglish))")
        expect(toEnglish?.blockIndices == [0, 2, 5], "Only the Chinese blocks: \(String(describing: toEnglish?.blockIndices))")
        let toChinese = Planner.plan(for: mixed, target: "zh-Hans")
        expect(toChinese?.source == "en", "Mixed → Chinese translates English: \(String(describing: toChinese))")
        expect(toChinese?.blockIndices == [1, 4], "Only the English blocks: \(String(describing: toChinese?.blockIndices))")
        expect(Planner.plan(for: chinese, target: "zh-Hans") == nil, "Nothing to translate into the language it's in")
        expect(Planner.plan(for: ["12:30", "100%", "→"], target: "en") == nil, "Numbers and symbols are left alone")
        expect(Planner.plan(for: ["ファイルを開く"], target: "en")?.source == "ja", "Kana is Japanese")
        expect(Planner.sameLanguage("zh-Hant", "zh-Hans"), "Traditional and Simplified are one language")

        // Painting: the cover takes the background around the text, the new
        // text the colour of the old.
        let width = 400, height = 120
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.3, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // A "word": dark-red strokes in a 20x200 box at (40, 40) top-left.
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        for x in stride(from: 40, to: 240, by: 12) {
            context.fill(CGRect(x: x, y: height - 60, width: 6, height: 20))
        }
        let source = context.makeImage()!
        let block = RecognizedTextBlock(
            text: "设置", rect: CGRect(x: 40, y: 40, width: 200, height: 20), lineHeight: 20, lineCount: 1
        )
        let rendered = TranslatedImageRenderer.render(
            source, replacements: [.init(block: block, text: "Settings")], language: "en"
        )
        expect(rendered?.width == width && rendered?.height == height, "Keeps the image size")
        if let rendered {
            let pixels = rgba(rendered)
            func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
                let offset = (y * width + x) * 4
                return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
            }
            let reds = (40..<240).flatMap { x in (40..<60).map { pixel(x, $0) } }.filter { $0.0 > 150 && $0.2 < 100 }
            let stroke = pixel(226, 50) // The right of the last stroke, past where "Settings" ends.
            expect(abs(stroke.0 - 51) < 6 && abs(stroke.2 - 204) < 6, "Old strokes are covered: \(stroke)")
            expect(reds.count > 20, "New text is drawn in the old text's colour: \(reds.count) px")
            let outside = pixel(5, 5)
            expect(abs(outside.0 - 51) < 3 && abs(outside.2 - 204) < 3, "Untouched outside the block: \(outside)")
        }

        // A translation far longer than its box still fits on the image.
        let long = TranslatedImageRenderer.render(
            source,
            replacements: [.init(
                block: RecognizedTextBlock(text: "取消", rect: CGRect(x: 300, y: 40, width: 40, height: 20), lineHeight: 20, lineCount: 1),
                text: "Cancel the current operation"
            )],
            language: "en"
        )
        expect(long != nil, "Renders text too long for its box")

        if failures > 0 {
            print("\(failures) check(s) failed")
            exit(1)
        }
    }

    static func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }
}
