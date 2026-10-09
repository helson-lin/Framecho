//
//  MCPStdioBridge.swift
//  Framecho
//
//  `Framecho --mcp`: the command MCP clients launch. It relays the client's
//  stdio to the running app's agent socket, starting Framecho in the
//  background when it isn't running, so the edits happen in the app - live in
//  any open Studio window - rather than in a second copy of the editor.
//

import AppKit
import Darwin
import Foundation

nonisolated enum MCPStdioBridge {
    /// The argument that turns this launch into the bridge.
    static let argument = "--mcp"
    /// Passed when the bridge starts the app, so it stays in the menu bar
    /// instead of opening the Library in front of the user.
    static let launchArgument = "--agent-launch"

    static var isRequested: Bool {
        CommandLine.arguments.dropFirst().contains(argument)
    }

    static func run() -> Never {
        let path = MCPSocketLocation.url().path
        guard UserDefaults.standard.bool(forKey: FramechoPreferences.agentAccessEnabledKey) else {
            fail("Agent access is turned off. Turn it on in Framecho › Settings › AI › Agent Access.")
        }
        guard let fd = connectOrLaunch(path) else {
            fail("Framecho isn't answering on \(path). Open Framecho and check Settings › AI › Agent Access.")
        }

        // Replies until the app hangs up; requests until the client does.
        // Either side closing ends the bridge.
        let replies = Thread {
            relay(from: fd, to: STDOUT_FILENO)
            exit(0)
        }
        replies.start()
        relay(from: STDIN_FILENO, to: fd)
        exit(0)
    }

    private static func connectOrLaunch(_ path: String) -> Int32? {
        if let fd = MCPSocketIO.connect(to: path) { return fd }

        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else { return nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.arguments = [launchArgument]
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in }

        // A cold launch takes a few seconds before the server is listening.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            usleep(250_000)
            if let fd = MCPSocketIO.connect(to: path) { return fd }
        }
        return nil
    }

    private static func relay(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            guard MCPSocketIO.writeAll(destination, Data(buffer[0..<count])) else { return }
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("framecho: \(message)\n".utf8))
        exit(1)
    }
}
