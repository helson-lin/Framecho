import Darwin
import Foundation

// Agent access without the app: the MCP session against a fake tool, the
// socket it travels over, and the clip-timeline mapping the editing tools
// rely on. See run-checks.sh for the files.
@main
struct AgentMCPChecks {
    static var checks = 0

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }

    static func near(_ actual: Double, _ expected: Double, _ message: String) {
        expect(abs(actual - expected) < 0.000_1, "\(message): expected \(expected), got \(actual)")
    }

    static func main() async {
        checkJSON()
        await checkSession()
        await checkSocket()
        checkSourceRanges()
        checkSettingSpeed()
        print("agent MCP: \(checks) checks passed")
    }

    // MARK: - JSON

    static func checkJSON() {
        let text = #"{"a":1,"b":1.5,"c":true,"d":null,"e":["x"],"f":{"g":"h/i"}}"#
        let value = try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        expect(value["a"] == .int(1), "integers stay integers")
        expect(value["b"]?.doubleValue == 1.5, "doubles decode")
        expect(value["a"]?.doubleValue == 1, "integers read as numbers")
        expect(value["c"] == .bool(true), "booleans aren't numbers")
        expect(value["d"] == .null, "null decodes")
        expect(JSONLine.encode(value) == text, "compact, sorted, slashes unescaped")
        expect(JSONLine.encode(JSONValue.string("a\nb"))?.contains("\n") == false, "a line never contains a raw newline")
        expect(JSONLine.encode(JSONValue.double(.nan)) == "null", "non-finite numbers encode as null")
    }

    // MARK: - Session

    struct FakeProvider: MCPToolProvider {
        let tools = [
            MCPToolDefinition(name: "echo", title: "Echo", description: "", inputSchema: ["type": "object"], isReadOnly: true),
            MCPToolDefinition(name: "fail", title: "Fail", description: "", inputSchema: ["type": "object"], isReadOnly: true),
            MCPToolDefinition(name: "slow", title: "Slow", description: "", inputSchema: ["type": "object"], isReadOnly: true),
        ]

        func callTool(_ name: String, arguments: [String: JSONValue], context: MCPRequestContext) async throws -> MCPToolResult {
            switch name {
            case "echo":
                context.reportProgress(0.5, total: 1)
                return .json(.object(arguments))
            case "fail":
                throw MCPToolError.failed("nope")
            default:
                try await Task.sleep(for: .seconds(10))
                return .json("late")
            }
        }
    }

    nonisolated final class Outbox: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func append(_ line: String) { lock.withLock { lines.append(line) } }

        var messages: [JSONValue] {
            lock.withLock { lines }.map { try! JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        }

        func reply(to id: Int) async -> JSONValue? {
            for _ in 0..<200 {
                if let message = messages.first(where: { $0["id"] == .int(id) }) { return message }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return nil
        }
    }

    nonisolated static let info = MCPServerInfo(name: "test", title: "Test", version: "1", instructions: "Use the tools.")

    static func checkSession() async {
        let outbox = Outbox()
        let session = MCPSession(info: info, provider: FakeProvider()) { outbox.append($0) }

        session.receive(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}"#)
        let initialize = await outbox.reply(to: 1)
        expect(initialize?["result"]?["protocolVersion"] == "2025-03-26", "a supported protocol version is echoed")
        expect(initialize?["result"]?["capabilities"]?["tools"] != nil, "tools capability is advertised")
        expect(initialize?["result"]?["instructions"] == "Use the tools.", "instructions are sent")

        session.receive(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        let fallback = await outbox.reply(to: 2)
        expect(fallback?["result"]?["protocolVersion"] == .string(MCPSession.supportedProtocolVersions[0]), "an unknown version gets the latest")

        session.receive(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        session.receive(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)
        let list = await outbox.reply(to: 3)
        let names = list?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        expect(names == ["echo", "fail", "slow"], "tools/list lists every tool")
        expect(list?["result"]?["tools"]?.arrayValue?.first?["annotations"]?["readOnlyHint"] == true, "annotations are sent")

        session.receive(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":{"x":2},"_meta":{"progressToken":"p"}}}"#)
        let echo = await outbox.reply(to: 4)
        expect(echo?["result"]?["isError"] == false, "a tool that returns is not an error")
        expect(echo?["result"]?["content"]?.arrayValue?.first?["text"] == #"{"x":2}"#, "tool content is text JSON")
        let progress = outbox.messages.first { $0["method"] == "notifications/progress" }
        expect(progress?["params"]?["progressToken"] == "p", "progress carries the client's token")

        session.receive(#"{"jsonrpc":"2.0","id":"five","method":"tools/call","params":{"name":"fail"}}"#)
        var failed: JSONValue?
        for _ in 0..<200 where failed == nil {
            failed = outbox.messages.first { $0["id"] == "five" }
            try? await Task.sleep(for: .milliseconds(10))
        }
        expect(failed?["result"]?["isError"] == true, "a throwing tool is a tool error, so the model sees it")
        expect(failed?["result"]?["content"]?.arrayValue?.first?["text"] == "nope", "the error message reaches the model")

        session.receive(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"missing"}}"#)
        expect(await outbox.reply(to: 6)?["error"]?["code"] == .int(MCPSession.ErrorCode.invalidParams), "an unknown tool is a protocol error")

        session.receive(#"{"jsonrpc":"2.0","id":7,"method":"resources/list"}"#)
        expect(await outbox.reply(to: 7)?["error"]?["code"] == .int(MCPSession.ErrorCode.methodNotFound), "unsupported methods are refused")

        session.receive(#"{"jsonrpc":"2.0","id":8,"method":"ping"}"#)
        expect(await outbox.reply(to: 8)?["result"] == .object([:]), "ping answers")

        session.receive("not json")
        try? await Task.sleep(for: .milliseconds(50))
        expect(outbox.messages.contains { $0["error"]?["code"] == .int(MCPSession.ErrorCode.parseError) }, "garbage gets a parse error")

        let before = outbox.messages.count
        session.receive(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"slow"}}"#)
        session.receive(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":9}}"#)
        try? await Task.sleep(for: .milliseconds(200))
        expect(outbox.messages.count == before, "a cancelled request gets no reply, and notifications get none either")
    }

    // MARK: - Socket

    static func checkSocket() async {
        let path = NSTemporaryDirectory() + "framecho-check-\(getpid()).sock"
        let listener = MCPSocketListener(path: path) { connection in
            let session = MCPSession(info: info, provider: FakeProvider()) { connection.send($0) }
            connection.readLines { session.receive($0) }
            session.close()
        }
        try! listener.start()
        defer { listener.stop() }

        var status = stat()
        stat(path, &status)
        expect(status.st_mode & 0o077 == 0, "the socket is owner-only")

        do {
            try MCPSocketListener(path: path) { _ in }.start()
            expect(false, "a second server must not take over a live socket")
        } catch {
            expect(error is MCPSocketError, "a live socket is reported as in use")
        }

        guard let fd = MCPSocketIO.connect(to: path) else {
            expect(false, "the client connects")
            return
        }
        defer { close(fd) }
        // Two requests in one write, split mid-line: framing must not care.
        let requests = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\n" + #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"# + "\n"
        let bytes = Data(requests.utf8)
        MCPSocketIO.writeAll(fd, bytes.prefix(20))
        try? await Task.sleep(for: .milliseconds(20))
        MCPSocketIO.writeAll(fd, bytes.dropFirst(20))

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let deadline = Date().addingTimeInterval(2)
        while received.filter({ $0 == 0x0A }).count < 2, Date() < deadline {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            received.append(contentsOf: buffer[0..<count])
        }
        let ids = String(decoding: received, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))["id"] }
        expect(Set(ids.compactMap(\.intValue)) == [1, 2], "both requests are answered over the socket")
    }

    // MARK: - Clip timeline

    /// 0–10 s, 15–20 s at 2× (2.5 s on screen), 25–30 s.
    static let cutTimeline = RecordingClipTimeline(segments: [
        RecordingClipSegment(sourceStart: 0, sourceEnd: 10),
        RecordingClipSegment(sourceStart: 15, sourceEnd: 20, speed: 2),
        RecordingClipSegment(sourceStart: 25, sourceEnd: 30),
    ])

    static func checkSourceRanges() {
        let inside = cutTimeline.sourceRanges(forEditorRange: 2...4)
        expect(inside.count == 1, "a range inside one clip maps to one range")
        near(inside[0].lowerBound, 2, "inside start")
        near(inside[0].upperBound, 4, "inside end")

        // Editor 8–13.5: the end of clip 1, all of the 2× clip, 1 s of clip 3.
        let across = cutTimeline.sourceRanges(forEditorRange: 8...13.5)
        expect(across.count == 3, "a range across cuts maps to one range per clip")
        near(across[0].lowerBound, 8, "first piece start")
        near(across[0].upperBound, 10, "first piece end")
        near(across[1].lowerBound, 15, "sped-up piece start")
        near(across[1].upperBound, 20, "sped-up piece covers twice its screen time")
        near(across[2].lowerBound, 25, "last piece start")
        near(across[2].upperBound, 26, "last piece end")

        for range in across {
            for time in [range.lowerBound, range.upperBound] {
                expect(cutTimeline.editorTime(forSourceTime: time) != nil, "every mapped source time still plays")
            }
        }
        expect(cutTimeline.sourceRanges(forEditorRange: 40...50).isEmpty, "past the end maps to nothing")

        // Cutting what an editor range shows removes exactly that much.
        let cut = cutTimeline.removingSourceRanges(cutTimeline.sourceRanges(forEditorRange: 8...13.5))!
        near(cut.duration, cutTimeline.duration - 5.5, "cutting an editor range shortens the edit by its length")
    }

    static func checkSettingSpeed() {
        let full = RecordingClipTimeline.full(sourceDuration: 10)
        let faster = full.settingSpeed(4, forEditorRange: 2...6)
        expect(faster.segments.count == 3, "speeding up the middle splits the clip in three")
        expect(faster.segments.map(\.speed) == [1, 4, 1], "only the middle is sped up")
        expect(faster.segments[0].id == full.segments[0].id, "the leading piece keeps the clip's identity")
        near(faster.duration, 2 + 1 + 4, "4 s at 4× plays in 1 s")
        near(faster.segments.reduce(0) { $0 + $1.duration }, 10, "no footage is lost")

        let sliver = full.settingSpeed(2, forEditorRange: 0.05...9.97)
        expect(sliver.segments.count == 1, "edges a sliver from a clip boundary snap to it")
        expect(sliver.segments[0].speed == 2, "the snapped clip takes the speed")

        let tiny = full.settingSpeed(2, forEditorRange: 5...5.05)
        near(tiny.segments.reduce(0) { $0 + $1.duration }, 10, "a range shorter than a clip never drops footage")

        let across = cutTimeline.settingSpeed(3, forEditorRange: 8...13.5)
        near(across.segments.reduce(0) { $0 + $1.duration }, 20, "speeding across cuts keeps every surviving second")
        expect(across.segments.filter { $0.speed == 3 }.count == 3, "every clip under the range is sped up")

        let restored = faster.settingSpeed(1, forEditorRange: 0...faster.duration)
        expect(restored.segments.allSatisfy { $0.speed == 1 }, "speed 1 returns a range to normal")
        near(restored.duration, 10, "back to the original length")
    }
}
