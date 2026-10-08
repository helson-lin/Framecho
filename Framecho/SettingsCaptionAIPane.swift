//
//  SettingsCaptionAIPane.swift
//  Framecho
//
//  AI settings: which language model cleans up Studio captions. Apple's
//  on-device model needs no setup; an OpenAI-compatible endpoint takes a
//  base URL, model and the user's own API key (kept in the Keychain).
//

import SwiftUI

struct CaptionAISettingsPane: View {
    @Bindable private var store = CaptionAISettingsStore.shared

    @State private var keyRevealed = false
    @State private var testStatus: TestStatus = .idle

    private enum TestStatus: Equatable {
        case idle
        case testing
        case succeeded
        case failed(String)
    }

    private let onDeviceUnavailableReason = CaptionCleanupEngines.onDeviceUnavailableReason

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $store.provider) {
                    ForEach(CaptionAIProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .onChange(of: store.provider) { testStatus = .idle }
            } header: {
                Text("Caption Cleanup")
            } footer: {
                if store.provider == .appleOnDevice, let onDeviceUnavailableReason {
                    SettingsIssueText(onDeviceUnavailableReason)
                } else {
                    Text("Finds fillers like “嗯”, “那个” or “um” in Studio captions. Only the transcript text is sent; audio and video stay on this Mac.")
                        .foregroundStyle(.secondary)
                }
            }

            if store.provider == .openAICompatible {
                endpointSection
            }

            Section {
                HStack {
                    testStatusView
                    Spacer()
                    Button("Test Connection") {
                        Task { await testConnection() }
                    }
                    .disabled(testStatus == .testing)
                }
            }
        }
        .settingsFormStyle()
    }

    private var endpointSection: some View {
        Section {
            TextField("Base URL", text: $store.baseURL, prompt: Text("https://api.example.com/v1"))
                .onChange(of: store.baseURL) { testStatus = .idle }
            TextField("Model", text: $store.model, prompt: Text("deepseek-chat"))
                .onChange(of: store.model) { testStatus = .idle }
            HStack {
                Group {
                    if keyRevealed {
                        TextField("API Key", text: $store.apiKey, prompt: Text("sk-…"))
                    } else {
                        SecureField("API Key", text: $store.apiKey, prompt: Text("sk-…"))
                    }
                }
                .onChange(of: store.apiKey) { testStatus = .idle }

                Button {
                    keyRevealed.toggle()
                } label: {
                    Image(systemName: keyRevealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(store.apiKey.isEmpty)
                .help(keyRevealed ? "Hide key" : "Reveal key")
                .accessibilityLabel(keyRevealed ? "Hide key" : "Reveal key")
            }
        } header: {
            HStack {
                Text("Endpoint")
                Spacer()
                Menu("Presets") {
                    ForEach(CaptionAIEndpointPreset.all) { preset in
                        Button(preset.name) {
                            store.baseURL = preset.baseURL
                            store.model = preset.model
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        } footer: {
            Text("Works with any OpenAI-compatible chat API, such as OpenAI, DeepSeek, Qwen, Kimi or a local Ollama. The key is stored in your Keychain.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var testStatusView: some View {
        switch testStatus {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .succeeded:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .lineLimit(3)
        }
    }

    /// Runs a real filler request on a tiny sample, so a pass means the
    /// endpoint, key, model and JSON reply all work.
    private func testConnection() async {
        testStatus = .testing
        let sample = ["嗯", "这个", "功能", "很好用"].enumerated().map {
            RecordingTranscriptWord(text: $0.element, start: Double($0.offset), end: Double($0.offset) + 0.5)
        }
        let chunk = CaptionCleanupChunk(wordIndices: Array(sample.indices))
        do {
            let engine = try CaptionCleanupEngines.engine(for: store.snapshot())
            let reply = try await engine.respond(
                instructions: CaptionCleanupPlanner.fillerInstructions,
                prompt: CaptionCleanupPlanner.prompt(for: chunk, words: sample)
            )
            guard CaptionCleanupPlanner.parseFillerResponse(reply) != nil else {
                throw CaptionCleanupError.unreadable(reply)
            }
            testStatus = .succeeded
        } catch {
            testStatus = .failed(error.localizedDescription)
        }
    }
}
