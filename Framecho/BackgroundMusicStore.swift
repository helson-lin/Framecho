//
//  BackgroundMusicStore.swift
//  Framecho
//
//  Downloads library tracks into the shared cache on first use, and plays
//  short previews in the library - streamed, so browsing never downloads.
//

import AVFoundation
import Foundation
import Observation

@Observable
final class BackgroundMusicStore {
    static let shared = BackgroundMusicStore()

    /// Tracks downloading right now, by id.
    private(set) var downloading: Set<String> = []
    /// Tracks on disk, refreshed as downloads finish.
    private(set) var cachedTrackIDs: Set<String> = []
    /// The track the library is previewing, if any.
    private(set) var previewingTrackID: String?

    private var downloads: [String: Task<URL, Error>] = [:]
    private let previewPlayer = AVPlayer()
    private var previewEndObserver: NSObjectProtocol?

    enum DownloadError: LocalizedError {
        case unavailable(Int)

        var errorDescription: String? {
            switch self {
            case .unavailable(let status):
                String(localized: "The track couldn't be downloaded (HTTP \(status)).")
            }
        }
    }

    private init() {
        refreshCache()
    }

    func refreshCache() {
        cachedTrackIDs = Set(BackgroundMusicCatalog.tracks.compactMap { track in
            BackgroundMusicCatalog.cachedFileIfPresent(for: track) == nil ? nil : track.id
        })
    }

    func isCached(_ track: BackgroundMusicTrack) -> Bool {
        cachedTrackIDs.contains(track.id)
    }

    /// The track's local file, downloading it first when needed. Concurrent
    /// requests for one track share a single download.
    func localURL(for track: BackgroundMusicTrack) async throws -> URL {
        if let cached = BackgroundMusicCatalog.cachedFileIfPresent(for: track) {
            return cached
        }
        if let running = downloads[track.id] {
            return try await running.value
        }

        let task = Task.detached(priority: .userInitiated) {
            try await Self.download(track)
        }
        downloads[track.id] = task
        downloading.insert(track.id)
        defer {
            downloads[track.id] = nil
            downloading.remove(track.id)
        }
        let url = try await task.value
        cachedTrackIDs.insert(track.id)
        return url
    }

    private nonisolated static func download(_ track: BackgroundMusicTrack) async throws -> URL {
        let (temporaryURL, response) = try await URLSession.shared.download(from: track.remoteURL)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw DownloadError.unavailable(status)
        }
        let destination = BackgroundMusicCatalog.cachedURL(for: track)
        try FileManager.default.createDirectory(
            at: BackgroundMusicCatalog.cacheDirectory,
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    // MARK: Preview

    /// Plays a track, or stops it when it is already playing. A cached
    /// track plays from disk; anything else streams.
    func togglePreview(_ track: BackgroundMusicTrack) {
        if previewingTrackID == track.id {
            stopPreview()
            return
        }
        let url = BackgroundMusicCatalog.cachedFileIfPresent(for: track) ?? track.remoteURL
        let item = AVPlayerItem(url: url)
        previewPlayer.replaceCurrentItem(with: item)
        if let previewEndObserver {
            NotificationCenter.default.removeObserver(previewEndObserver)
        }
        previewEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopPreview()
            }
        }
        previewPlayer.play()
        previewingTrackID = track.id
    }

    func stopPreview() {
        previewPlayer.pause()
        previewPlayer.replaceCurrentItem(with: nil)
        previewingTrackID = nil
    }
}
