//
//  AgentAccessServer.swift
//  Framecho
//
//  Agent access: an MCP server that lets AI agents (Claude Code, Claude
//  Desktop, Cursor…) edit screen recordings. Off by default; the switch is
//  in Settings › AI. Only this user's processes can reach it - the socket is
//  owner-only - and it serves only the recording tools in AgentToolCatalog.
//

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AgentAccessServer {
    static let shared = AgentAccessServer()

    enum State: Equatable {
        case off
        case running
        case failed(String)
    }

    private(set) var state = State.off

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: FramechoPreferences.agentAccessEnabledKey)
            applyPreference()
        }
    }

    @ObservationIgnored private var listener: MCPSocketListener?

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: FramechoPreferences.agentAccessEnabledKey)
    }

    /// Starts or stops the server to match the switch. Called at launch and
    /// whenever the switch changes.
    func applyPreference() {
        if isEnabled {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard listener == nil else { return }
        let info = MCPServerInfo(
            name: "framecho",
            title: "Framecho",
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            instructions: AgentToolCatalog.instructions
        )
        let provider = AgentToolProvider()
        let listener = MCPSocketListener(path: MCPSocketLocation.url().path) { connection in
            let session = MCPSession(info: info, provider: provider) { connection.send($0) }
            connection.readLines { session.receive($0) }
            session.close()
        }
        do {
            try listener.start()
            self.listener = listener
            state = .running
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func stop() {
        listener?.stop()
        listener = nil
        state = .off
    }

    // MARK: - Client setup

    /// The command MCP clients run: this very binary, as the stdio bridge.
    static var bridgeExecutablePath: String {
        Bundle.main.executableURL?.path ?? "/Applications/Framecho.app/Contents/MacOS/Framecho"
    }

    private static var serverName: String {
        Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true ? "framecho-dev" : "framecho"
    }

    static var claudeCodeCommand: String {
        "claude mcp add \(serverName) -- \(shellQuoted(bridgeExecutablePath)) \(MCPStdioBridge.argument)"
    }

    /// The `mcpServers` entry Claude Desktop, Cursor and most other clients read.
    static var clientConfiguration: String {
        let entry: JSONValue = [
            "mcpServers": .object([
                serverName: [
                    "command": .string(bridgeExecutablePath),
                    "args": [.string(MCPStdioBridge.argument)],
                ],
            ]),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(entry)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private static func shellQuoted(_ path: String) -> String {
        guard path.contains(where: { " '\"$`\\".contains($0) }) else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
