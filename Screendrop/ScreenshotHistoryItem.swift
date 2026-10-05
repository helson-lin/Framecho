//
//  ScreenshotHistoryItem.swift
//  Screendrop
//
//  One row of History's history.json, and how the file is read back. Kept
//  apart from the store so scripts/check-history-metadata.swift can decode
//  files written by older builds without touching the disk.
//

import Foundation

nonisolated enum PreviewMediaKind: String, Equatable, Codable {
    case image
    case video
}

nonisolated struct ScreenshotHistoryItem: Identifiable, Codable, Equatable {
    let id: UUID
    var createdAt: Date
    var updatedAt: Date
    var fileName: String
    var pixelWidth: Int
    var pixelHeight: Int
    var kind: PreviewMediaKind
    var duration: Double?
    var cloudURL: String?
    /// Whether this screenshot has an editable annotation sidecar document.
    var hasEdits: Bool
    /// Absolute path to the non-destructive recording package, when this video
    /// belongs to the new Studio workflow. Older video items remain bare files.
    var recordingSessionPath: String?
    /// A Library title, kept separate from the file name and editable sidecars.
    var displayName: String?

    var isVideo: Bool { kind == .video }

    // Backward-compatible decoding: existing history.json entries have no
    // `kind` or `duration` fields, so they default to .image / nil.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        fileName = try container.decode(String.self, forKey: .fileName)
        pixelWidth = try container.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decode(Int.self, forKey: .pixelHeight)
        kind = try container.decodeIfPresent(PreviewMediaKind.self, forKey: .kind) ?? .image
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        cloudURL = try container.decodeIfPresent(String.self, forKey: .cloudURL)
        hasEdits = try container.decodeIfPresent(Bool.self, forKey: .hasEdits) ?? false
        recordingSessionPath = try container.decodeIfPresent(String.self, forKey: .recordingSessionPath)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
    }

    init(
        id: UUID,
        createdAt: Date,
        updatedAt: Date,
        fileName: String,
        pixelWidth: Int,
        pixelHeight: Int,
        kind: PreviewMediaKind = .image,
        duration: Double? = nil,
        cloudURL: String? = nil,
        hasEdits: Bool = false,
        recordingSessionPath: String? = nil,
        displayName: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.fileName = fileName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.kind = kind
        self.duration = duration
        self.cloudURL = cloudURL
        self.hasEdits = hasEdits
        self.recordingSessionPath = recordingSessionPath
        self.displayName = displayName
    }
}

/// What history.json held, read one row at a time so a single unreadable
/// entry (a media kind from a newer build, say) can't drop the whole list.
nonisolated struct ScreenshotHistoryMetadata {
    var items: [ScreenshotHistoryItem]
    /// Some rows couldn't be read; the original file should be kept aside
    /// before it's rewritten from `items`.
    var hasUnreadableRows: Bool

    /// - Throws: When the file isn't a JSON array at all.
    static func decode(_ data: Data) throws -> ScreenshotHistoryMetadata {
        let rows = try JSONDecoder().decode([LossyRow].self, from: data)
        return ScreenshotHistoryMetadata(
            items: rows.compactMap(\.item),
            hasUnreadableRows: rows.contains { $0.item == nil }
        )
    }

    private struct LossyRow: Decodable {
        let item: ScreenshotHistoryItem?

        init(from decoder: any Decoder) throws {
            item = try? ScreenshotHistoryItem(from: decoder)
        }
    }
}
