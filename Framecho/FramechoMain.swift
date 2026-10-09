//
//  FramechoMain.swift
//  Framecho
//
//  Process entry point. One binary serves two roles: the app, and the
//  `--mcp` stdio bridge that MCP clients launch. The bridge has to branch off
//  before SwiftUI creates the application, or every agent connection would
//  start a second copy of Framecho.
//

import SwiftUI

@main
enum FramechoMain {
    static func main() {
        if MCPStdioBridge.isRequested {
            MCPStdioBridge.run()
        }
        FramechoApp.main()
    }
}
