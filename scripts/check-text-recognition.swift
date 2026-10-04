import AppKit
import Foundation

// Renders text into images and runs them through the production OCR path, to
// pin down how recognised fragments are laid out as copied text.
@main
struct TextRecognitionChecks {
    static func main() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("framecho-ocr-check-\(UUID())")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        /// Draws each block of text into its rect (top-left origin, wrapping
        /// at the rect's width) on a white canvas and saves it as PNG.
        func render(
            _ name: String,
            size: CGSize = CGSize(width: 1200, height: 600),
            fontSize: CGFloat = 32,
            _ blocks: [(String, CGRect)]
        ) throws -> URL {
            // Rendered at 2x, like a Retina capture, so recognition errors in
            // the fixture do not mask layout behavior.
            let scale: CGFloat = 2
            let context = CGContext(
                data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.setFillColor(.white)
            context.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            context.translateBy(x: 0, y: size.height * scale)
            context.scaleBy(x: scale, y: -scale)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: NSColor.black,
            ]
            for (text, rect) in blocks {
                NSAttributedString(string: text, attributes: attributes).draw(in: rect)
            }
            NSGraphicsContext.current = nil

            let url = root.appendingPathComponent("\(name).png")
            let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
            try rep.representation(using: .png, properties: [:])!.write(to: url)
            return url
        }

        func expect(_ name: String, _ url: URL, _ predicate: (String) -> Bool) async {
            let text = await ImageTextRecognizer.recognizeText(at: url)
            guard predicate(text) else {
                print("FAIL \(name): \(text.debugDescription)")
                exit(1)
            }
            print("ok   \(name): \(text.debugDescription)")
        }

        // Chinese is recognised at all, mixed with English on one line.
        await expect("mixed line", try render("mixed", [
            ("截图文字识别测试 Hello 世界", CGRect(x: 40, y: 40, width: 1100, height: 60)),
        ])) { $0 == "截图文字识别测试 Hello 世界" }

        // CJK words in an English-led line: automatic detection alone reads
        // them with the Latin model ("Settings wE"). Pinned to an English
        // system language, as on CI, which is the case that needs the second
        // pass most.
        for line in ["Settings 设置", "Click 保存 to save your changes"] {
            let url = try render("mixed-\(line.count)", [(line, CGRect(x: 40, y: 40, width: 1100, height: 60))])
            let text = await ImageTextRecognizer.recognizeText(at: url, preferredLanguages: ["en-US"])
            guard text == line else {
                print("FAIL English-led mixed line: \(text.debugDescription)")
                exit(1)
            }
            print("ok   English-led mixed line: \(text.debugDescription)")
        }

        // Separate fragments on one visual line become one line of text.
        await expect("label and value", try render("row", [
            ("Name", CGRect(x: 40, y: 40, width: 200, height: 60)),
            ("张三", CGRect(x: 700, y: 40, width: 200, height: 60)),
        ])) { $0 == "Name 张三" }

        // A wrapped English paragraph is rejoined with spaces, and English is
        // read by the English model even though Chinese is a candidate.
        let english = "Framecho keeps every capture in a library so you can find, annotate, "
            + "and share screenshots later without digging through the desktop"
        await expect("wrapped English", try render("english", [
            (english, CGRect(x: 40, y: 40, width: 700, height: 400)),
        ])) { $0 == english }

        // A wrapped Chinese paragraph is rejoined without inserted spaces.
        let chinese = "截图会保存在资料库中，你可以随时查找、标注并分享这些截图，而不必在桌面上翻找文件，整理起来也更加方便快捷"
        await expect("wrapped Chinese", try render("chinese", [
            (chinese, CGRect(x: 40, y: 40, width: 600, height: 400)),
        ])) { !$0.contains("\n") && !$0.contains(" ") && $0.count >= chinese.count - 4 }

        // Short stacked labels are a list, not a paragraph: keep them apart.
        await expect("stacked labels", try render("labels", [
            ("General", CGRect(x: 40, y: 40, width: 400, height: 50)),
            ("Appearance", CGRect(x: 40, y: 90, width: 400, height: 50)),
            ("Privacy and Security", CGRect(x: 40, y: 140, width: 400, height: 50)),
        ])) { $0 == "General\nAppearance\nPrivacy and Security" }

        // A sentence that ends a line is a paragraph break even if it fills it.
        await expect("separate sentences", try render("sentences", [
            ("This first sentence fills up the whole line.", CGRect(x: 40, y: 40, width: 1100, height: 50)),
            ("This second one starts a new thought", CGRect(x: 40, y: 85, width: 1100, height: 50)),
        ])) { $0.split(separator: "\n").count == 2 }

        // A full 5K Retina screenshot of an ordinary window: read whole, its
        // 13 pt text falls below Vision's detection threshold and none of it
        // comes back. Tiling must find every line, including a sentence that
        // crosses several tile edges without being cut or repeated.
        let sidebar = ["Library", "Screenshots", "Recordings", "Favorites", "截图", "设置"]
        let sentence = "Framecho keeps every capture in a library so you can find, annotate, and share screenshots later without digging through the desktop"
        var screen = sidebar.enumerated().map { index, label in
            (label, CGRect(x: 30, y: 80 + CGFloat(index) * 40, width: 300, height: 30))
        }
        screen.append((sentence, CGRect(x: 420, y: 700, width: 2000, height: 30)))
        let settings = (1...24).map { "Setting \($0) is on" }
        screen += settings.enumerated().map { index, label in
            (label, CGRect(x: 1900, y: 80 + CGFloat(index) * 24, width: 400, height: 22))
        }
        await expect("5K screenshot", try render(
            "screen", size: CGSize(width: 2560, height: 1440), fontSize: 13, screen
        )) { text in
            // Labels level with each other share a visual line, so check
            // that each is present; the sentence stands alone on its line.
            (sidebar + settings).allSatisfy(text.contains)
                && text.components(separatedBy: "\n").contains(sentence)
        }

        print("All text recognition checks passed.")
    }
}
