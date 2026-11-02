//
//  ScreenshotTranslationModel.swift
//  Framecho
//

import AppKit
import ImageIO
import Translation
import UniformTypeIdentifiers

/// Translates the text in a screenshot in place, like WeChat's screenshot
/// translation: the text is recognized with its position, translated on
/// device with Apple's Translation framework, and drawn back over the
/// original. A pin shows the result (`PinnedScreenshotController`), so a
/// translation lands where it was captured, with the pin's toolbar.
@MainActor
@Observable
final class ScreenshotTranslation {
    enum Phase: Equatable {
        case recognizing
        case translating
        case translated
        /// The text is already in the target language.
        case nothingToTranslate
        case failed(String)
    }

    /// Languages offered as targets; the planner may pick another (the user's
    /// own), which is then added.
    static let commonTargets = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "es"]

    let original: CGImage
    let originalImage: NSImage
    private(set) var translatedImage: NSImage?
    private(set) var phase: Phase = .recognizing
    private(set) var target = "en"
    var showsOriginal = false
    /// Set to start a translation; `.translationTask` runs on each change.
    private(set) var configuration: TranslationSession.Configuration?

    private var blocks: [RecognizedTextBlock] = []
    private var plan: ScreenshotTranslationPlanner.Plan?
    private var translations: [Int: String] = [:]
    private var translatedCGImage: CGImage?

    init(image: CGImage, pointSize: CGSize) {
        original = image
        originalImage = NSImage(cgImage: image, size: pointSize)
    }

    var displayedImage: NSImage {
        showsOriginal ? originalImage : (translatedImage ?? originalImage)
    }

    var targets: [String] {
        Self.commonTargets.contains(target) ? Self.commonTargets : Self.commonTargets + [target]
    }

    var isWorking: Bool { phase == .recognizing || phase == .translating }

    static func displayName(for language: String) -> String {
        Locale.current.localizedString(forIdentifier: language) ?? language
    }

    func start() async {
        let blocks = await Self.recognize(original)
        self.blocks = blocks
        guard !blocks.isEmpty else {
            phase = .failed(String(localized: "No text found in this image."))
            return
        }
        await translate(to: ScreenshotTranslationPlanner.defaultTarget(for: blocks.map(\.text)))
    }

    func translate(to target: String) async {
        self.target = target
        translations = [:]
        translatedImage = nil
        translatedCGImage = nil
        showsOriginal = false
        guard !blocks.isEmpty else { return }

        guard let plan = ScreenshotTranslationPlanner.plan(for: blocks.map(\.text), target: target) else {
            self.plan = nil
            phase = .nothingToTranslate
            return
        }
        self.plan = plan
        let source = Locale.Language(identifier: plan.source)
        let destination = Locale.Language(identifier: target)
        if await LanguageAvailability().status(from: source, to: destination) == .unsupported {
            phase = .failed(String(
                localized: "Translating \(Self.displayName(for: plan.source)) to \(Self.displayName(for: target)) isn't supported."
            ))
            return
        }
        phase = .translating
        let next = TranslationSession.Configuration(source: source, target: destination)
        if configuration == next {
            configuration?.invalidate()
        } else {
            configuration = next
        }
    }

    /// Runs inside `.translationTask`, which asks the user to download the
    /// languages first if they aren't installed.
    func run(_ session: TranslationSession) async {
        guard let plan, phase == .translating else { return }
        let requests = plan.blockIndices.map {
            TranslationSession.Request(sourceText: blocks[$0].text, clientIdentifier: String($0))
        }
        do {
            let responses = try await session.translations(from: requests)
            // A newer target may have been picked while this one ran.
            guard plan == self.plan else { return }
            for response in responses {
                guard let index = response.clientIdentifier.flatMap(Int.init) else { continue }
                translations[index] = response.targetText
            }
        } catch {
            guard plan == self.plan else { return }
            phase = .failed(error.localizedDescription)
            return
        }

        let replacements = translations.sorted { $0.key < $1.key }.map {
            TranslatedImageRenderer.Replacement(block: blocks[$0.key], text: $0.value)
        }
        guard let rendered = await Self.render(original, replacements: replacements, language: plan.target),
              plan == self.plan else { return }
        translatedCGImage = rendered
        translatedImage = NSImage(cgImage: rendered, size: originalImage.size)
        phase = .translated
    }

    /// The translation as text, in reading order, with the blocks that
    /// weren't translated as they were.
    var translatedText: String {
        blocks.indices.map { translations[$0] ?? blocks[$0].text }.joined(separator: "\n")
    }

    /// The image currently shown, as a PNG in the temporary folder: the
    /// clipboard, a pin and a save all take a file.
    func writeDisplayedImage() -> URL? {
        let image = showsOriginal ? original : (translatedCGImage ?? original)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(ScreenshotFileNaming.fileName())
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? url : nil
    }

    @concurrent
    private nonisolated static func recognize(_ image: CGImage) async -> [RecognizedTextBlock] {
        ImageTextRecognizer.recognizeBlocks(in: image)
    }

    @concurrent
    private nonisolated static func render(
        _ image: CGImage, replacements: [TranslatedImageRenderer.Replacement], language: String
    ) async -> CGImage? {
        TranslatedImageRenderer.render(image, replacements: replacements, language: language)
    }
}
