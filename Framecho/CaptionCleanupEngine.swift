//
//  CaptionCleanupEngine.swift
//  Framecho
//
//  The language model behind caption cleanup: Apple's on-device model when
//  this Mac has one, or any OpenAI-compatible chat endpoint (OpenAI,
//  DeepSeek, Qwen, Kimi, a local Ollama...) with the user's own API key.
//  Only transcript text is sent; audio and video never leave the Mac.
//

import Foundation
import FoundationModels
import OSLog
import Security

nonisolated enum CaptionAIProvider: String, CaseIterable, Identifiable, Sendable {
    case appleOnDevice
    case openAICompatible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleOnDevice: String(localized: "Apple Intelligence (On This Mac)")
        case .openAICompatible: String(localized: "OpenAI-Compatible API")
        }
    }
}

/// Endpoints offered as starting points; any OpenAI-compatible URL works.
nonisolated struct CaptionAIEndpointPreset: Identifiable, Sendable {
    var name: String
    var baseURL: String
    var model: String

    var id: String { name }

    static let all: [CaptionAIEndpointPreset] = [
        CaptionAIEndpointPreset(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4.1-mini"),
        CaptionAIEndpointPreset(name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat"),
        CaptionAIEndpointPreset(
            name: "Qwen (DashScope)",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            model: "qwen-plus"
        ),
        CaptionAIEndpointPreset(name: "Kimi (Moonshot)", baseURL: "https://api.moonshot.cn/v1", model: "moonshot-v1-8k"),
        CaptionAIEndpointPreset(name: "Ollama", baseURL: "http://localhost:11434/v1", model: "qwen2.5:7b"),
    ]
}

/// Immutable snapshot of the AI settings for use off the main actor.
nonisolated struct CaptionAIConfiguration: Sendable {
    var provider: CaptionAIProvider
    var baseURL: String
    var model: String
    var apiKey: String

    /// Ollama and other local servers need no key.
    var isCloudConfigured: Bool {
        guard let url = URL(string: baseURL), url.host != nil, !model.isEmpty else { return false }
        return !apiKey.isEmpty || Self.isLocal(url)
    }

    var host: String? {
        URL(string: baseURL)?.host
    }

    private static func isLocal(_ url: URL) -> Bool {
        ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")
    }
}

@Observable
final class CaptionAISettingsStore {
    static let shared = CaptionAISettingsStore()

    private let defaults = UserDefaults.standard
    private static let keychainService = "com.jarinhe.Framecho"

    private enum Keys {
        static let provider = "captionAIProvider"
        static let baseURL = "captionAIBaseURL"
        static let model = "captionAIModel"
        static let apiKey = "caption_ai_api_key"
    }

    var provider: CaptionAIProvider {
        didSet { defaults.set(provider.rawValue, forKey: Keys.provider) }
    }

    var baseURL: String {
        didSet { defaults.set(baseURL, forKey: Keys.baseURL) }
    }

    var model: String {
        didSet { defaults.set(model, forKey: Keys.model) }
    }

    /// Kept in the Keychain, never in preferences.
    var apiKey: String {
        didSet { Self.setKeychainItem(apiKey) }
    }

    private init() {
        let onDeviceAvailable = CaptionCleanupEngines.onDeviceUnavailableReason == nil
        provider = defaults.string(forKey: Keys.provider).flatMap(CaptionAIProvider.init(rawValue:))
            ?? (onDeviceAvailable ? .appleOnDevice : .openAICompatible)
        baseURL = defaults.string(forKey: Keys.baseURL) ?? CaptionAIEndpointPreset.all[0].baseURL
        model = defaults.string(forKey: Keys.model) ?? CaptionAIEndpointPreset.all[0].model
        apiKey = Self.getKeychainItem() ?? ""
    }

    func snapshot() -> CaptionAIConfiguration {
        CaptionAIConfiguration(
            provider: provider,
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Keychain

    private static var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: Keys.apiKey,
            kSecAttrService as String: keychainService,
        ]
    }

    private static func setKeychainItem(_ value: String) {
        SecItemDelete(keychainQuery as CFDictionary)
        guard !value.isEmpty else { return }
        var query = keychainQuery
        query[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func getKeychainItem() -> String? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Engines

/// Sends one instruction + prompt pair and returns the model's reply text.
nonisolated protocol CaptionCleanupEngine: Sendable {
    func respond(instructions: String, prompt: String) async throws -> String
    /// Words per request; small for the on-device model's short context.
    var maximumWordsPerRequest: Int { get }
}

nonisolated enum CaptionCleanupError: LocalizedError {
    /// A reply that couldn't be read, trimmed to fit an error message.
    static func unreadable(_ reply: String) -> CaptionCleanupError {
        let flattened = reply
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .unreadableResponse(flattened.count > 160 ? String(flattened.prefix(160)) + "…" : flattened)
    }

    case notConfigured
    case onDeviceUnavailable(String)
    case requestFailed(String)
    /// The reply, shortened, so the user can see what came back.
    case unreadableResponse(String)
    case emptyResponse(finishReason: String?)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            String(localized: "Set up an AI provider in Settings › AI to find fillers in context.")
        case .onDeviceUnavailable(let reason):
            reason
        case .requestFailed(let message):
            String(localized: "The AI request failed: \(message)")
        case .unreadableResponse(let reply):
            reply.isEmpty
                ? String(localized: "The AI replied in a format Framecho couldn't read.")
                : String(localized: "The AI replied in a format Framecho couldn't read: “\(reply)”")
        case .emptyResponse(let finishReason) where finishReason == "length":
            String(localized: "The AI ran out of room before answering. Try a model without deep thinking, or a faster variant.")
        case .emptyResponse:
            String(localized: "The AI returned an empty reply.")
        }
    }
}

nonisolated enum CaptionCleanupEngines {
    /// Why Apple's on-device model can't run here; nil when it can.
    static var onDeviceUnavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return String(localized: "This Mac doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return String(localized: "Turn on Apple Intelligence in System Settings to use it here.")
        case .unavailable(.modelNotReady):
            return String(localized: "Apple Intelligence is still downloading its model. Try again later.")
        case .unavailable:
            return String(localized: "Apple Intelligence isn't available on this Mac.")
        }
    }

    static func engine(for configuration: CaptionAIConfiguration) throws -> any CaptionCleanupEngine {
        switch configuration.provider {
        case .appleOnDevice:
            if let reason = onDeviceUnavailableReason {
                throw CaptionCleanupError.onDeviceUnavailable(reason)
            }
            return OnDeviceCaptionEngine()
        case .openAICompatible:
            guard configuration.isCloudConfigured, let url = URL(string: configuration.baseURL) else {
                throw CaptionCleanupError.notConfigured
            }
            return OpenAICompatibleCaptionEngine(
                baseURL: url,
                model: configuration.model,
                apiKey: configuration.apiKey
            )
        }
    }
}

nonisolated struct OnDeviceCaptionEngine: CaptionCleanupEngine {
    var maximumWordsPerRequest: Int { 160 }

    func respond(instructions: String, prompt: String) async throws -> String {
        // A fresh session per request keeps the small context window clear.
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: prompt,
            options: GenerationOptions(sampling: .greedy)
        )
        return response.content
    }
}

nonisolated struct OpenAICompatibleCaptionEngine: CaptionCleanupEngine {
    let baseURL: URL
    let model: String
    let apiKey: String

    var maximumWordsPerRequest: Int { 400 }

    private static let logger = Logger(subsystem: "com.jarinhe.Framecho", category: "CaptionCleanup")

    /// Generous room for the answer: reasoning models spend part of it
    /// thinking, and a truncated reply is unreadable.
    private static let maximumOutputTokens = 8192

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                var content: Content?
                /// Reasoning models' thinking (DeepSeek and compatibles).
                var reasoningContent: String?

                enum CodingKeys: String, CodingKey {
                    case content
                    case reasoningContent = "reasoning_content"
                }
            }
            var message: Message
            var finishReason: String?

            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }
        var choices: [Choice]
    }

    /// Message content as a plain string, or as content parts
    /// (`[{"type": "text", "text": ...}]`) the way some gateways send it.
    private struct Content: Decodable {
        var text: String

        private struct Part: Decodable {
            var text: String?
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                text = string
            } else {
                text = try container.decode([Part].self).compactMap(\.text).joined()
            }
        }
    }

    private struct ErrorResponse: Decodable {
        struct Detail: Decodable {
            var message: String?
        }
        var error: Detail?
    }

    private struct RequestError: Error {
        var status: Int
        var message: String
    }

    func respond(instructions: String, prompt: String) async throws -> String {
        do {
            return try await send(instructions: instructions, prompt: prompt, strict: true)
        } catch let error as RequestError where error.status == 400 || error.status == 422 {
            // Not every compatible API takes JSON mode, temperature or an
            // output limit; retry with just the essentials before failing.
            Self.logger.info("Retrying caption request without optional parameters: \(error.message, privacy: .public)")
            do {
                return try await send(instructions: instructions, prompt: prompt, strict: false)
            } catch let retry as RequestError {
                throw CaptionCleanupError.requestFailed("\(retry.status) \(retry.message)")
            }
        } catch let error as RequestError {
            throw CaptionCleanupError.requestFailed("\(error.status) \(error.message)")
        }
    }

    private func send(instructions: String, prompt: String, strict: Bool) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": prompt],
            ],
        ]
        if strict {
            body["temperature"] = 0
            body["max_tokens"] = Self.maximumOutputTokens
            body["response_format"] = ["type": "json_object"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw CaptionCleanupError.requestFailed(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error?.message
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw RequestError(status: status, message: message)
        }

        let raw = String(decoding: data, as: UTF8.self)
        Self.logger.debug("Caption cleanup reply: \(raw, privacy: .private)")
        guard let choice = try? JSONDecoder().decode(ChatResponse.self, from: data).choices.first else {
            throw CaptionCleanupError.unreadable(raw)
        }
        let content = choice.message.content?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !content.isEmpty {
            return content
        }
        // Some reasoning models leave the answer at the end of their
        // thinking; the parser only takes the JSON it asked for.
        if let reasoning = choice.message.reasoningContent, !reasoning.isEmpty, choice.finishReason != "length" {
            return reasoning
        }
        throw CaptionCleanupError.emptyResponse(finishReason: choice.finishReason)
    }
}
