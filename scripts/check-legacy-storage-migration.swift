import Foundation

// Runs the launch-time rename of pre-Framecho documents on a scratch
// Application Support folder:
// xcrun swiftc -module-cache-path /tmp/framecho-migration-module-cache \
//   Framecho/LegacyStorageMigration.swift scripts/check-legacy-storage-migration.swift \
//   -o /tmp/framecho-migration-check && /tmp/framecho-migration-check
@main
struct LegacyStorageMigrationChecks {
    static var checks = 0
    static let fileManager = FileManager.default

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }

    static func exists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    static func write(_ text: String, to url: URL) {
        try! fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: url)
    }

    static func historyRows(_ support: URL) -> [[String: Any]] {
        let data = try! Data(contentsOf: support.appendingPathComponent("history.json"))
        return try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    }

    static func main() {
        let support = fileManager.temporaryDirectory
            .appendingPathComponent("framecho-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: support) }
        let history = support.appendingPathComponent("History", isDirectory: true)
        let recordings = support.appendingPathComponent("Recordings", isDirectory: true)

        // A sidecar to rename, and one whose new name is already taken.
        write("old", to: history.appendingPathComponent("A.png.screendrop"))
        write("old", to: history.appendingPathComponent("B.png.screendrop"))
        write("new", to: history.appendingPathComponent("B.png.framecho"))
        write("png", to: history.appendingPathComponent("A.png"))

        let legacyPackage = recordings.appendingPathComponent("Screendrop_1.screendroprec", isDirectory: true)
        write("mov", to: legacyPackage.appendingPathComponent("screen.mov"))
        let current = recordings.appendingPathComponent("Framecho_2.framechorec", isDirectory: true).path
        let rows: [[String: Any]] = [
            ["id": "1", "fileName": "A.png", "hasEdits": true, "createdAt": 780_000_000.5],
            ["id": "2", "fileName": "Screendrop_1.mov", "recordingSessionPath": legacyPackage.path],
            ["id": "3", "fileName": "Framecho_2.mov", "recordingSessionPath": current],
            ["id": "4", "kind": "hologram", "fileName": "Unknown.bin"],
        ]
        try! JSONSerialization.data(withJSONObject: rows).write(to: support.appendingPathComponent("history.json"))

        LegacyStorageMigration.run(in: support)

        expect(exists(history.appendingPathComponent("A.png.framecho")), "A legacy sidecar is renamed")
        expect(!exists(history.appendingPathComponent("A.png.screendrop")), "The legacy sidecar is gone after renaming")
        expect(exists(history.appendingPathComponent("A.png")), "The image itself is untouched")
        let kept = try! String(contentsOf: history.appendingPathComponent("B.png.framecho"), encoding: .utf8)
        expect(kept == "new", "An existing sidecar is never overwritten")
        expect(exists(history.appendingPathComponent("B.png.screendrop")), "A sidecar that can't be renamed is kept")

        let renamedPackage = recordings.appendingPathComponent("Screendrop_1.framechorec", isDirectory: true)
        expect(exists(renamedPackage.appendingPathComponent("screen.mov")), "A recording package is renamed with its contents")
        expect(!exists(legacyPackage), "The legacy package is gone after renaming")

        var migrated = historyRows(support)
        expect(migrated.count == 4, "Every history row survives, including ones this build can't read")
        expect(migrated[1]["recordingSessionPath"] as? String == renamedPackage.path, "History follows the renamed package")
        expect(migrated[2]["recordingSessionPath"] as? String == current, "Rows already on the new extension are untouched")
        expect(migrated[3]["kind"] as? String == "hologram", "Unknown fields are kept")
        expect(migrated[0]["createdAt"] as? Double == 780_000_000.5, "Dates keep their precision")

        // A launch interrupted after moving a package but before saving
        // history is repaired on the next run, and a second run is a no-op.
        migrated[1]["recordingSessionPath"] = legacyPackage.path
        try! JSONSerialization.data(withJSONObject: migrated).write(to: support.appendingPathComponent("history.json"))
        LegacyStorageMigration.run(in: support)
        expect(historyRows(support)[1]["recordingSessionPath"] as? String == renamedPackage.path, "An interrupted migration is completed")
        let before = try! Data(contentsOf: support.appendingPathComponent("history.json"))
        LegacyStorageMigration.run(in: support)
        expect(try! Data(contentsOf: support.appendingPathComponent("history.json")) == before, "Running again changes nothing")

        // No Application Support folder yet (a fresh install).
        LegacyStorageMigration.run(in: support.appendingPathComponent("Missing", isDirectory: true))

        print("Legacy storage migration checks passed (\(checks) assertions).")
    }
}
