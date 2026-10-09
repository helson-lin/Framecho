//
//  MCPProtocol.swift
//  Framecho
//
//  The Model Context Protocol, as much of it as a tools-only server needs:
//  JSON-RPC 2.0 over newline-delimited JSON, the initialize handshake,
//  tools/list, tools/call, ping, and cancellation. Transport-free, so the
//  same session serves the local socket and the standalone check.
//

import Foundation

nonisolated struct MCPServerInfo: Sendable {
    var name: String
    var title: String
    var version: String
    /// Shown to the agent once, at initialize: how the tools fit together.
    var instructions: String
}

nonisolated struct MCPToolDefinition: Sendable {
    var name: String
    var title: String
    var description: String
    var inputSchema: JSONValue
    var isReadOnly: Bool
    /// True when the tool can remove something from the project. Every edit
    /// is non-destructive to the footage, but agents still use this to
    /// decide what to confirm with the user.
    var isDestructive: Bool = false

    var json: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(isReadOnly),
                "destructiveHint": .bool(isDestructive),
                "openWorldHint": false,
            ],
        ]
    }
}

nonisolated enum MCPContent: Sendable, Equatable {
    case text(String)
    case image(Data, mimeType: String)

    var json: JSONValue {
        switch self {
        case .text(let text):
            ["type": "text", "text": .string(text)]
        case .image(let data, let mimeType):
            ["type": "image", "data": .string(data.base64EncodedString()), "mimeType": .string(mimeType)]
        }
    }
}

nonisolated struct MCPToolResult: Sendable, Equatable {
    var content: [MCPContent]
    var isError = false

    /// A reply carrying a JSON payload as text, which every client can show
    /// and every model can read.
    static func json(_ value: JSONValue) -> MCPToolResult {
        MCPToolResult(content: [.text(JSONLine.encode(value) ?? "null")])
    }

    static func error(_ message: String) -> MCPToolResult {
        MCPToolResult(content: [.text(message)], isError: true)
    }

    var json: JSONValue {
        ["content": .array(content.map(\.json)), "isError": .bool(isError)]
    }
}

nonisolated enum MCPToolError: LocalizedError, Equatable {
    case unknownTool(String)
    /// Arguments that don't fit the schema. Reported as a tool error, not a
    /// protocol error, so the model sees the message and can correct itself.
    case invalidArguments(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name): "Unknown tool: \(name)"
        case .invalidArguments(let message): "Invalid arguments: \(message)"
        case .failed(let message): message
        }
    }
}

/// What a tool can do besides return: report progress on a long render.
nonisolated struct MCPRequestContext: Sendable {
    var progressToken: JSONValue?
    var sendNotification: @Sendable (_ method: String, _ params: JSONValue) -> Void

    func reportProgress(_ progress: Double, total: Double? = nil, message: String? = nil) {
        guard let progressToken else { return }
        var params: [String: JSONValue] = [
            "progressToken": progressToken,
            "progress": .double(progress),
        ]
        if let total { params["total"] = .double(total) }
        if let message { params["message"] = .string(message) }
        sendNotification("notifications/progress", .object(params))
    }
}

nonisolated protocol MCPToolProvider: Sendable {
    var tools: [MCPToolDefinition] { get }
    func callTool(
        _ name: String,
        arguments: [String: JSONValue],
        context: MCPRequestContext
    ) async throws -> MCPToolResult
}

/// One client connection. Requests run concurrently - a long export must not
/// hold up a ping - and each can be cancelled by the client.
nonisolated final class MCPSession: @unchecked Sendable {
    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    enum ErrorCode {
        static let parseError = -32700
        static let invalidRequest = -32600
        static let methodNotFound = -32601
        static let invalidParams = -32602
    }

    private let info: MCPServerInfo
    private let provider: any MCPToolProvider
    private let send: @Sendable (String) -> Void
    private let lock = NSLock()
    /// Keyed by the request id's JSON text, since ids may be numbers or strings.
    private var running: [String: Task<Void, Never>] = [:]

    init(info: MCPServerInfo, provider: any MCPToolProvider, send: @escaping @Sendable (String) -> Void) {
        self.info = info
        self.provider = provider
        self.send = send
    }

    /// Handles one line from the client. Replies go out through `send`, in
    /// whatever order the requests finish.
    func receive(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let data = trimmed.data(using: .utf8),
              let message = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            reply(errorResponse(id: .null, code: ErrorCode.parseError, message: "Parse error"))
            return
        }
        guard case .object = message,
              message["jsonrpc"]?.stringValue == "2.0",
              let method = message["method"]?.stringValue else {
            // A response to something we never asked, or not JSON-RPC at all.
            if message["method"] == nil, message["id"] != nil, message["result"] != nil || message["error"] != nil {
                return
            }
            reply(errorResponse(id: message["id"] ?? .null, code: ErrorCode.invalidRequest, message: "Invalid request"))
            return
        }
        let params = message["params"] ?? .object([:])

        guard let id = message["id"], id != .null else {
            receiveNotification(method, params: params)
            return
        }

        let key = JSONLine.encode(id) ?? ""
        // Registered under the lock the task's own `finish` takes, so a
        // request that completes instantly can't leave a stale entry behind.
        lock.withLock {
            running[key] = Task { [weak self] in
                guard let self else { return }
                let response = await self.respond(id: id, method: method, params: params)
                self.finish(key)
                guard !Task.isCancelled else { return }
                self.reply(response)
            }
        }
    }

    /// Cancels every request still running, when the connection closes.
    func close() {
        let tasks = lock.withLock {
            let tasks = Array(running.values)
            running.removeAll()
            return tasks
        }
        tasks.forEach { $0.cancel() }
    }

    private func finish(_ key: String) {
        _ = lock.withLock { running.removeValue(forKey: key) }
    }

    private func receiveNotification(_ method: String, params: JSONValue) {
        guard method == "notifications/cancelled", let requestID = params["requestId"] else { return }
        let key = JSONLine.encode(requestID) ?? ""
        let task = lock.withLock { running.removeValue(forKey: key) }
        task?.cancel()
    }

    private func respond(id: JSONValue, method: String, params: JSONValue) async -> JSONValue {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue
            let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
                ?? Self.supportedProtocolVersions[0]
            return successResponse(id: id, result: [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": [
                    "name": .string(info.name),
                    "title": .string(info.title),
                    "version": .string(info.version),
                ],
                "instructions": .string(info.instructions),
            ])

        case "ping":
            return successResponse(id: id, result: [:])

        case "tools/list":
            return successResponse(id: id, result: ["tools": .array(provider.tools.map(\.json))])

        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return errorResponse(id: id, code: ErrorCode.invalidParams, message: "Missing tool name")
            }
            guard provider.tools.contains(where: { $0.name == name }) else {
                return errorResponse(id: id, code: ErrorCode.invalidParams, message: "Unknown tool: \(name)")
            }
            let arguments = params["arguments"]?.objectValue ?? [:]
            let context = MCPRequestContext(
                progressToken: params["_meta"]?["progressToken"],
                sendNotification: { [weak self] method, params in
                    self?.reply(["jsonrpc": "2.0", "method": .string(method), "params": params])
                }
            )
            let result: MCPToolResult
            do {
                result = try await provider.callTool(name, arguments: arguments, context: context)
            } catch is CancellationError {
                result = .error("Cancelled")
            } catch {
                result = .error(error.localizedDescription)
            }
            return successResponse(id: id, result: result.json)

        default:
            return errorResponse(id: id, code: ErrorCode.methodNotFound, message: "Method not found: \(method)")
        }
    }

    private func reply(_ message: JSONValue) {
        guard let line = JSONLine.encode(message) else { return }
        send(line)
    }

    private func successResponse(id: JSONValue, result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func errorResponse(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
    }
}

// MARK: - Arguments

/// Typed reads of tool arguments that fail with a message the model can act on.
nonisolated struct MCPArguments: Sendable {
    let values: [String: JSONValue]

    init(_ values: [String: JSONValue]) {
        self.values = values
    }

    func string(_ key: String) throws -> String {
        guard let value = values[key]?.stringValue, !value.isEmpty else {
            throw MCPToolError.invalidArguments("`\(key)` must be a non-empty string")
        }
        return value
    }

    func optionalString(_ key: String) throws -> String? {
        guard let value = values[key], value != .null else { return nil }
        guard let string = value.stringValue else {
            throw MCPToolError.invalidArguments("`\(key)` must be a string")
        }
        return string
    }

    func number(_ key: String) throws -> Double {
        guard let value = try optionalNumber(key) else {
            throw MCPToolError.invalidArguments("`\(key)` is required and must be a number")
        }
        return value
    }

    func optionalNumber(_ key: String) throws -> Double? {
        guard let value = values[key], value != .null else { return nil }
        guard let number = value.doubleValue, number.isFinite else {
            throw MCPToolError.invalidArguments("`\(key)` must be a finite number")
        }
        return number
    }

    func optionalInt(_ key: String) throws -> Int? {
        guard let value = values[key], value != .null else { return nil }
        guard let number = value.intValue else {
            throw MCPToolError.invalidArguments("`\(key)` must be an integer")
        }
        return number
    }

    func optionalBool(_ key: String) throws -> Bool? {
        guard let value = values[key], value != .null else { return nil }
        guard let bool = value.boolValue else {
            throw MCPToolError.invalidArguments("`\(key)` must be true or false")
        }
        return bool
    }

    func array(_ key: String) throws -> [JSONValue] {
        guard let array = values[key]?.arrayValue, !array.isEmpty else {
            throw MCPToolError.invalidArguments("`\(key)` must be a non-empty array")
        }
        return array
    }

    func optionalObject(_ key: String) throws -> [String: JSONValue]? {
        guard let value = values[key], value != .null else { return nil }
        guard let object = value.objectValue else {
            throw MCPToolError.invalidArguments("`\(key)` must be an object")
        }
        return object
    }

    /// `[{start, end}, …]` in seconds, each with `end > start`.
    func timeRanges(_ key: String) throws -> [ClosedRange<TimeInterval>] {
        try array(key).enumerated().map { index, item in
            guard let start = item["start"]?.doubleValue, let end = item["end"]?.doubleValue,
                  start.isFinite, end.isFinite else {
                throw MCPToolError.invalidArguments("`\(key)[\(index)]` needs numeric `start` and `end`")
            }
            guard end > start else {
                throw MCPToolError.invalidArguments("`\(key)[\(index)]` ends before it starts")
            }
            return start...end
        }
    }

    /// Accepts only the listed values, naming them in the error.
    func optionalChoice(_ key: String, in choices: [String]) throws -> String? {
        guard let value = try optionalString(key) else { return nil }
        guard choices.contains(value) else {
            throw MCPToolError.invalidArguments("`\(key)` must be one of: \(choices.joined(separator: ", "))")
        }
        return value
    }
}
