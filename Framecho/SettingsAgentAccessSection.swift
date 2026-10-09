//
//  SettingsAgentAccessSection.swift
//  Framecho
//
//  The agent access switch in Settings › AI, and the setup an MCP client
//  needs to connect: a command for Claude Code, a JSON entry for the rest.
//

import AppKit
import SwiftUI

struct AgentAccessSettingsSections: View {
    @Bindable private var server = AgentAccessServer.shared
    @State private var copiedItem: CopiedItem?

    private enum CopiedItem {
        case command
        case configuration
    }

    var body: some View {
        Section {
            Toggle("Let AI agents edit recordings", isOn: $server.isEnabled)
            if server.isEnabled {
                statusRow
            }
        } header: {
            Text("Agent Access")
        } footer: {
            Text("Agents such as Claude Code connect over MCP to cut, speed up, zoom, caption and export your recordings. Their edits are saved right away and can be undone in Studio; the original footage is never changed. Only apps running under your account on this Mac can connect.")
                .foregroundStyle(.secondary)
        }

        if server.isEnabled {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: "Claude Code")
                    Text(AgentAccessServer.claudeCodeCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    copyButton("Copy Command", item: .command, text: AgentAccessServer.claudeCodeCommand)
                }
                .padding(.vertical, 2)

                LabeledContent {
                    copyButton("Copy JSON", item: .configuration, text: AgentAccessServer.clientConfiguration)
                } label: {
                    Text("Claude Desktop, Cursor and others")
                    Text("Add the copied entry to the client’s MCP configuration.")
                }
            } header: {
                Text("Connect a Client")
            } footer: {
                Text("The client starts Framecho in the menu bar if it isn’t running.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch server.state {
        case .running:
            Label("Ready for connections", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            SettingsIssueText(message)
        case .off:
            EmptyView()
        }
    }

    private func copyButton(_ title: LocalizedStringKey, item: CopiedItem, text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copiedItem = item
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if copiedItem == item { copiedItem = nil }
            }
        } label: {
            if copiedItem == item {
                Label("Copied", systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}
