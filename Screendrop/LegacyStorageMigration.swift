//
//  LegacyStorageMigration.swift
//  Framecho
//
//  Builds from before the Framecho rename wrote `.screendrop` edit sidecars
//  next to History images and `.screendroprec` recording packages. This
//  renames them once at launch and repoints history.json at the renamed
//  packages. It's free of the app so scripts/check-legacy-storage-migration.swift
//  can run it against a scratch directory.
//

import Foundation

/// File extensions of the documents Framecho keeps in Application Support.
nonisolated enum CaptureStorageExtension {
    /// The editable annotation sidecar: `<image>.png.framecho`.
    static let editDocument = "framecho"
    /// The recording package directory: `<name>.framechorec`.
    static let recordingPackage = "framechorec"

    static let legacyEditDocument = "screendrop"
    static let legacyRecordingPackage = "screendroprec"
}

nonisolated enum LegacyStorageMigration {
    /// Renames legacy documents under `supportDirectory` (the app's
    /// Application Support folder). Safe to run on every launch: when nothing
    /// is left to rename it only lists two directories. A file whose new name
    /// is already taken is left alone rather than overwritten.
    static func run(in supportDirectory: URL) {
        renameEditDocuments(in: supportDirectory.appendingPathComponent("History", isDirectory: true))
        renameRecordingPackages(in: supportDirectory.appendingPathComponent("Recordings", isDirectory: true))
        repointHistory(at: supportDirectory.appendingPathComponent("history.json"))
    }

    private static func renameEditDocuments(in directory: URL) {
        for url in contents(of: directory) where url.pathExtension == CaptureStorageExtension.legacyEditDocument {
            move(url, to: url.deletingPathExtension().appendingPathExtension(CaptureStorageExtension.editDocument))
        }
    }

    private static func renameRecordingPackages(in directory: URL) {
        for url in contents(of: directory) where url.pathExtension == CaptureStorageExtension.legacyRecordingPackage {
            move(url, to: renamedRecordingPackage(url))
        }
    }

    /// Rows still naming a legacy package whose renamed copy exists are
    /// repointed. Checking the disk rather than remembering what was moved
    /// also repairs a launch that was interrupted between the two steps.
    private static func repointHistory(at url: URL) {
        guard let data = try? Data(contentsOf: url),
              var rows = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return }

        let fileManager = FileManager.default
        var changed = false
        for index in rows.indices {
            guard var row = rows[index] as? [String: Any],
                  let path = row["recordingSessionPath"] as? String else { continue }
            let legacy = URL(fileURLWithPath: path, isDirectory: true)
            guard legacy.pathExtension == CaptureStorageExtension.legacyRecordingPackage,
                  !fileManager.fileExists(atPath: legacy.path) else { continue }
            let renamed = renamedRecordingPackage(legacy)
            guard fileManager.fileExists(atPath: renamed.path) else { continue }
            row["recordingSessionPath"] = renamed.path
            rows[index] = row
            changed = true
        }
        guard changed,
              let updated = try? JSONSerialization.data(withJSONObject: rows, options: [.withoutEscapingSlashes]) else { return }
        do {
            try updated.write(to: url, options: .atomic)
        } catch {
            NSLog("[Framecho] Failed to update history after renaming recordings: \(error)")
        }
    }

    private static func renamedRecordingPackage(_ url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension(CaptureStorageExtension.recordingPackage)
    }

    private static func contents(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    private static func move(_ source: URL, to destination: URL) {
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            NSLog("[Framecho] Failed to rename \(source.lastPathComponent): \(error)")
        }
    }
}
