import Foundation

// Reads history.json rows the way the Library does, including rows written
// by older builds and rows this build can't understand:
// xcrun swiftc -module-cache-path /tmp/screendrop-history-module-cache \
//   Screendrop/ScreenshotHistoryItem.swift scripts/check-history-metadata.swift \
//   -o /tmp/screendrop-history-check && /tmp/screendrop-history-check
@main
struct HistoryMetadataChecks {
    static var checks = 0

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }

    /// Dates as the store writes them: JSONEncoder's default, seconds since 2001.
    static func row(_ fields: [String: Any]) -> [String: Any] {
        var row: [String: Any] = [
            "id": UUID().uuidString,
            "createdAt": 780_000_000.0,
            "updatedAt": 780_000_100.0,
            "fileName": "Framecho_2026-10-05-12-00-00.png",
            "pixelWidth": 3456,
            "pixelHeight": 2234,
        ]
        row.merge(fields) { _, new in new }
        return row
    }

    static func metadata(_ rows: [[String: Any]]) throws -> ScreenshotHistoryMetadata {
        try ScreenshotHistoryMetadata.decode(try JSONSerialization.data(withJSONObject: rows))
    }

    static func main() {
        checkOldRows()
        checkRoundTrip()
        checkUnreadableRows()
        print("History metadata checks passed (\(checks) assertions).")
    }

    static func checkOldRows() {
        // The first builds wrote only these six fields.
        let old = try! metadata([row([:])])
        expect(!old.hasUnreadableRows && old.items.count == 1, "An early row reads")
        let item = old.items[0]
        expect(item.kind == .image && !item.isVideo, "No kind means a screenshot")
        expect(item.duration == nil && item.cloudURL == nil, "No duration or share link")
        expect(!item.hasEdits && item.recordingSessionPath == nil && item.displayName == nil, "No edits, package or title")
        expect(item.pixelWidth == 3456 && item.fileName == "Framecho_2026-10-05-12-00-00.png", "Its own fields")
        expect(item.createdAt == Date(timeIntervalSinceReferenceDate: 780_000_000), "Dates in the store's encoding")

        let video = try! metadata([row(["kind": "video", "duration": 12.5])]).items[0]
        expect(video.isVideo && video.duration == 12.5, "A bare video file")
    }

    static func checkRoundTrip() {
        let item = ScreenshotHistoryItem(
            id: UUID(),
            createdAt: Date(timeIntervalSinceReferenceDate: 780_000_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 780_000_500),
            fileName: "Framecho_2026-10-05-12-00-00.mp4",
            pixelWidth: 1920,
            pixelHeight: 1080,
            kind: .video,
            duration: 42,
            cloudURL: "https://example.com/abc",
            hasEdits: true,
            recordingSessionPath: "/tmp/Recording.framecho",
            displayName: "Demo"
        )
        let data = try! JSONEncoder().encode([item])
        let reread = try! ScreenshotHistoryMetadata.decode(data)
        expect(reread.items == [item] && !reread.hasUnreadableRows, "Every field survives a save")
    }

    static func checkUnreadableRows() {
        // One row from a newer build (a kind this one doesn't know) and one
        // damaged row must not take the rest of the Library with them.
        let mixed = try! metadata([
            row(["fileName": "a.png"]),
            row(["kind": "gif"]),
            ["id": UUID().uuidString, "createdAt": 780_000_000.0],
            row(["fileName": "b.png", "hasEdits": true]),
        ])
        expect(mixed.items.map(\.fileName) == ["a.png", "b.png"], "Readable rows are kept, in order")
        expect(mixed.hasUnreadableRows, "The file is flagged to be kept aside before it's rewritten")

        let clean = try! metadata([row([:]), row([:])])
        expect(!clean.hasUnreadableRows, "A clean file isn't flagged")
        expect(try! metadata([]).items.isEmpty, "An empty history")

        var threw = false
        do {
            _ = try ScreenshotHistoryMetadata.decode(Data("{\"not\": \"a list\"}".utf8))
        } catch {
            threw = true
        }
        expect(threw, "A file that isn't a list is reported, not read as empty")
    }
}
