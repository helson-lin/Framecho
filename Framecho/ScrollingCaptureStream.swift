//
//  ScrollingCaptureStream.swift
//  Framecho
//
//  Feeds the frames of one screen area to a ScrollingCaptureStitcher while
//  the user scrolls it.
//

import CoreMedia
import CoreVideo
import ScreenCaptureKit

nonisolated final class ScrollingCaptureStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Every frame's outcome and the image's height after it, on the
    /// stream's queue.
    var onUpdate: (@Sendable (ScrollingCaptureStitcher.Outcome, Int) -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    private let queue = DispatchQueue(label: "com.jarinhe.framecho.scrolling-capture", qos: .userInteractive)
    private var stream: SCStream?
    /// Touched only on `queue`.
    private var stitcher = ScrollingCaptureStitcher()

    func start(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    /// Stops capturing and returns the long screenshot, or nil when no
    /// frame arrived.
    func stop() async -> CGImage? {
        if let stream {
            self.stream = nil
            try? await stream.stopCapture()
            try? stream.removeStreamOutput(self, type: .screen)
        }
        // Queued after any frame still being stitched.
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.stitcher.makeImage()) }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferDataIsReady(sampleBuffer),
              Self.isCompleteFrame(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let image = Self.copyImage(from: pixelBuffer) else { return }
        // Stitching runs on the sample queue, so frames that arrive while
        // it works are dropped by the stream rather than piling up.
        let outcome = stitcher.add(image)
        onUpdate?(outcome, stitcher.height)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }

    /// Idle frames repeat the last one; only complete frames carry pixels.
    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return false }
        return status == .complete
    }

    /// Copies the pixels out: the stream reuses its buffers, and the
    /// stitcher keeps the last frame.
    private static func copyImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let context = CGContext(
            data: base,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        return context?.makeImage()
    }
}
