import Foundation

/// Values an agent config needs: where the gateway listens and how to call it.
struct AgentApplyContext {
    var baseURL: String
    var apiKey: String
    var model: String
    var effort: String = ""
}

/// One file the adapter rewrites: absolute path and its new text.
struct AgentFileEdit: Equatable {
    var path: String
    var text: String
}

enum AgentConfigError: LocalizedError {
    case invalidJSON(String)
    case emptyModel
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let path):
            return String(format: L("%@ is not valid JSON. Fix it first; Melon Tools will not overwrite it."), path)
        case .emptyModel:
            return L("Enter a model name before applying.")
        case .unsupported(let reason):
            return reason
        }
    }
}

/// Pure config transformations. Every adapter takes the current file text and
/// returns the new text, so the risky part (backup, atomic write) lives in one
/// place (`AgentStore`) and every transformation is unit-testable.
enum AgentAdapters {
    static func edits(
        definition: AgentDefinition,
        urls: [URL],
        files: [String: String],
        context: AgentApplyContext
    ) throws -> [AgentFileEdit] {
        let model = context.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let effort = context.effort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let primary = urls.first else {
            throw AgentConfigError.unsupported(L("This agent has no config file Melon Tools can edit safely."))
        }
        let current = files[primary.path] ?? ""

        switch definition.integration {
        case .codex:
            guard !model.isEmpty else { throw AgentConfigError.emptyModel }
            var updated = CodexConfigRoute.upsertRoute(
                in: current,
                baseURL: context.baseURL,
                token: context.apiKey
            )
            updated = CodexConfigRoute.upsertTopLevelKey("model", value: model, in: updated)
            if !effort.isEmpty {
                updated = CodexConfigRoute.upsertTopLevelKey("model_reasoning_effort", value: effort, in: updated)
            }
            return [AgentFileEdit(path: primary.path, text: updated)]

        case .claudeCode:
            guard !model.isEmpty else { throw AgentConfigError.emptyModel }
            let text = try updatingJSON(current, path: primary.path) { root in
                var env = root["env"] as? [String: Any] ?? [:]
                env["ANTHROPIC_BASE_URL"] = anthropicBase(context.baseURL)
                env["ANTHROPIC_AUTH_TOKEN"] = context.apiKey
                // Claude Code takes the model from ANTHROPIC_MODEL for every
                // session, and the effort from CLAUDE_CODE_EFFORT_LEVEL.
                env["ANTHROPIC_MODEL"] = model
                if effort.isEmpty {
                    env.removeValue(forKey: "CLAUDE_CODE_EFFORT_LEVEL")
                } else {
                    env["CLAUDE_CODE_EFFORT_LEVEL"] = effort
                }
                root["env"] = env
            }
            return [AgentFileEdit(path: primary.path, text: text)]

        case .geminiCLI:
            var text = current
            text = upsertEnvValue(in: text, key: "GOOGLE_GEMINI_BASE_URL", value: context.baseURL)
            text = upsertEnvValue(in: text, key: "GEMINI_API_KEY", value: context.apiKey)
            if !model.isEmpty {
                text = upsertEnvValue(in: text, key: "GEMINI_MODEL", value: model)
            }
            return [AgentFileEdit(path: primary.path, text: text)]

        case .openCode:
            guard !model.isEmpty else { throw AgentConfigError.emptyModel }
            let target = existingTarget(urls, fallback: primary)
            let text = try updatingJSON(files[target.path] ?? "", path: target.path) { root in
                var providers = root["provider"] as? [String: Any] ?? [:]
                providers["melon"] = [
                    "npm": "@ai-sdk/openai-compatible",
                    "name": "Melon Tools",
                    "options": [
                        "baseURL": context.baseURL,
                        "apiKey": context.apiKey
                    ],
                    "models": [model: ["name": model]]
                ]
                root["provider"] = providers
                root["model"] = "melon/\(model)"
            }
            return [AgentFileEdit(path: target.path, text: text)]

        case .crush:
            guard !model.isEmpty else { throw AgentConfigError.emptyModel }
            let text = try updatingJSON(current, path: primary.path) { root in
                var providers = root["providers"] as? [String: Any] ?? [:]
                providers["melon"] = [
                    "type": "openai",
                    "base_url": context.baseURL,
                    "api_key": context.apiKey,
                    "models": [["id": model, "name": model]]
                ]
                root["providers"] = providers
            }
            return [AgentFileEdit(path: primary.path, text: text)]

        case .continueConfig:
            guard !model.isEmpty else { throw AgentConfigError.emptyModel }
            let text = try updatingJSON(current, path: primary.path) { root in
                var models = root["models"] as? [[String: Any]] ?? []
                let entry: [String: Any] = [
                    "title": "Melon Tools",
                    "provider": "openai",
                    "model": model,
                    "apiBase": context.baseURL,
                    "apiKey": context.apiKey
                ]
                if let index = models.firstIndex(where: { ($0["title"] as? String) == "Melon Tools" }) {
                    models[index] = entry
                } else {
                    models.append(entry)
                }
                root["models"] = models
            }
            return [AgentFileEdit(path: primary.path, text: text)]

        case .antigravity:
            guard !model.isEmpty else { throw AgentConfigError.emptyModel }
            // Antigravity 2.30 reads ~/.gemini/config/config.json, older builds
            // ~/.antigravity/settings.json. Both get the same block, and both
            // are written when they exist, so an update does not drop the row.
            let targets = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            let all = targets.isEmpty ? [primary] : targets
            return try all.map { url in
                let text = try updatingJSON(files[url.path] ?? "", path: url.path) { root in
                    root["gateway"] = [
                        "enabled": true,
                        "url": context.baseURL,
                        "apiKey": context.apiKey,
                        "wireProtocol": "openai"
                    ]
                    var models = root["models"] as? [String: Any] ?? [:]
                    models["defaultModelId"] = model
                    models["listSource"] = context.baseURL + "/models?format=antigravity"
                    root["models"] = models
                }
                return AgentFileEdit(path: url.path, text: text)
            }

        case .cursorCLI:
            guard !model.isEmpty else { throw AgentConfigError.emptyModel }
            let text = try updatingJSON(current, path: primary.path) { root in
                var modelBlock = root["model"] as? [String: Any] ?? [:]
                modelBlock["modelId"] = model
                modelBlock["displayModelId"] = model
                modelBlock["displayName"] = model
                root["model"] = modelBlock
                root["hasChangedDefaultModel"] = true
            }
            return [AgentFileEdit(path: primary.path, text: text)]

        case .vscode:
            guard !model.isEmpty else { throw AgentConfigError.emptyModel }
            let settingsURL = primary
            let modelsURL = urls.count > 1 ? urls[1] : nil
            var edits: [AgentFileEdit] = []

            let settings = try updatingJSON(files[settingsURL.path] ?? "", path: settingsURL.path) { root in
                root["chat.defaultModel"] = model
            }
            edits.append(AgentFileEdit(path: settingsURL.path, text: settings))

            if let modelsURL {
                let models = try updatingVSCCatalog(
                    files[modelsURL.path] ?? "",
                    path: modelsURL.path,
                    model: model,
                    context: context
                )
                edits.append(AgentFileEdit(path: modelsURL.path, text: models))
            }
            return edits

        case .dsh:
            guard !model.isEmpty else { throw AgentConfigError.emptyModel }
            let target = existingTarget(urls, fallback: primary)
            return [AgentFileEdit(
                path: target.path,
                text: dshPatch(files[target.path] ?? "", context: context, model: model, effort: effort)
            )]

        case .manual:
            throw AgentConfigError.unsupported(L("This agent has no config file Melon Tools can edit safely."))
        }
    }

    /// The file an adapter edits: the first one that already exists, else the
    /// one it creates. Agents move their config between releases (OpenCode
    /// renamed `.json` to `.jsonc`), and creating the other name would leave
    /// the app reading a file nobody writes.
    private static func existingTarget(_ urls: [URL], fallback: URL) -> URL {
        urls.first { FileManager.default.fileExists(atPath: $0.path) } ?? fallback
    }

    // MARK: - Claude helper

    /// Claude Code expects the API root without the OpenAI `/v1` suffix: the
    /// SDK appends `/v1/messages` itself, and `ANTHROPIC_MODEL` names the model.
    static func anthropicBase(_ baseURL: String) -> String {
        var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        if value.hasSuffix("/v1") {
            value.removeLast(3)
        }
        return value
    }

    // MARK: - JSON

    /// VS Code's Chat catalog: a JSON(C) array with a group per provider. The
    /// group is replaced in place, so other providers and their order survive.
    static func updatingVSCCatalog(
        _ text: String,
        path: String,
        model: String,
        context: AgentApplyContext
    ) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var list: [[String: Any]] = []
        if !trimmed.isEmpty {
            let object = try parseJSONC(trimmed, path: path)
            guard let array = object as? [[String: Any]] else {
                throw AgentConfigError.invalidJSON(path)
            }
            list = array
        }
        let entry: [String: Any] = [
            "id": model,
            "name": model,
            "url": context.baseURL + "/chat/completions",
            "toolCalling": true,
            "requestHeaders": ["Authorization": "Bearer " + context.apiKey]
        ]
        let group: [String: Any] = [
            "name": "Melon Tools",
            "vendor": "customendpoint",
            "apiType": "chat-completions",
            "models": [entry]
        ]
        if let index = list.firstIndex(where: {
            ($0["name"] as? String) == "Melon Tools"
                && ($0["vendor"] as? String) == "customendpoint"
        }) {
            list[index] = group
        } else {
            list.append(group)
        }
        return try encodeJSON(list, path: path)
    }

    /// Loads a JSON (or JSONC) object, mutates it, and returns pretty printed
    /// JSON with a trailing newline. An empty file or "{}" starts a fresh
    /// object; an unparsable file throws instead of being replaced.
    static func updatingJSON(
        _ text: String,
        path: String,
        mutate: (inout [String: Any]) -> Void
    ) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var root: [String: Any] = [:]
        if !trimmed.isEmpty {
            let object = try parseJSONC(trimmed, path: path)
            guard let dictionary = object as? [String: Any] else {
                throw AgentConfigError.invalidJSON(path)
            }
            root = dictionary
        }
        mutate(&root)
        return try encodeJSON(root, path: path)
    }

    /// JSON with `//` and `/* */` comments and trailing commas, which VS Code
    /// and OpenCode write. Comments are dropped when the file is written back.
    static func parseJSONC(_ text: String, path: String) throws -> Any {
        let cleaned = strippingJSONComments(text)
        guard let data = cleaned.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            throw AgentConfigError.invalidJSON(path)
        }
        return object
    }

    static func strippingJSONComments(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var index = text.startIndex
        var inString = false
        var escaped = false

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)

            if inString {
                out.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = next
                continue
            }

            if character == "\"" {
                inString = true
                out.append(character)
                index = next
                continue
            }

            if character == "/", next < text.endIndex {
                let after = text[next]
                if after == "/" {
                    var cursor = next
                    while cursor < text.endIndex, text[cursor] != "\n" {
                        cursor = text.index(after: cursor)
                    }
                    index = cursor
                    continue
                }
                if after == "*" {
                    var cursor = text.index(after: next)
                    while cursor < text.endIndex {
                        if text[cursor] == "*" {
                            let closing = text.index(after: cursor)
                            if closing < text.endIndex, text[closing] == "/" {
                                cursor = text.index(after: closing)
                                break
                            }
                        }
                        cursor = text.index(after: cursor)
                    }
                    index = cursor
                    continue
                }
            }

            out.append(character)
            index = next
        }

        return removingTrailingCommas(out)
    }

    private static func removingTrailingCommas(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var inString = false
        var escaped = false
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if inString {
                out.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index += 1
                continue
            }
            if character == "\"" {
                inString = true
                out.append(character)
                index += 1
                continue
            }
            if character == "," {
                var cursor = index + 1
                while cursor < characters.count, characters[cursor].isWhitespace {
                    cursor += 1
                }
                if cursor < characters.count, characters[cursor] == "}" || characters[cursor] == "]" {
                    index += 1
                    continue
                }
            }
            out.append(character)
            index += 1
        }
        return out
    }

    static func encodeJSON(_ object: Any, path: String) throws -> String {
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .withoutEscapingSlashes]
            )
        } catch {
            throw AgentConfigError.invalidJSON(path)
        }
        guard var result = String(data: data, encoding: .utf8) else {
            throw AgentConfigError.invalidJSON(path)
        }
        if !result.hasSuffix("\n") { result += "\n" }
        return result
    }

    // MARK: - Env

    /// `KEY=value` in a dotenv file. Existing line is replaced in place, so
    /// comments and ordering survive.
    static func upsertEnvValue(in text: String, key: String, value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
        let line = "\(key)=\"\(escaped)\""
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var replaced = false
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { continue }
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let candidate = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
            if candidate == key {
                lines[index] = line
                replaced = true
                break
            }
        }
        if !replaced { lines.append(line) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Env snippet shown for manual agents and for "copy" actions.
    static func snippet(prefix: String, context: AgentApplyContext) -> String {
        "\(prefix)=\(context.baseURL)\nOPENAI_API_KEY=\(context.apiKey)"
    }

    // MARK: - DeepSeek Harness

    /// DSH's patch list is YAML, and the app documents two entries: the
    /// provider (`llm-deepseek`) and the model new sessions start on
    /// (`agent-default-model`). Both are text, so they are upserted as blocks
    /// marked with `# melon-tools`; a block of the user's stays untouched.
    static func dshPatch(
        _ text: String,
        context: AgentApplyContext,
        model: String,
        effort: String
    ) -> String {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        lines = removingMarkedBlock(lines, id: "llm-deepseek")
        lines = removingMarkedBlock(lines, id: "agent-default-model")
        let level = effort.isEmpty ? "high" : effort
        let block = [
            "- id: llm-deepseek # melon-tools",
            "  config:",
            "    apiKey: \(yamlQuote(context.apiKey))",
            "    baseURL: \(yamlQuote(context.baseURL))",
            "    thinking: enabled",
            "    reasoningEffort: \(yamlQuote(level))",
            "    models:",
            "      - id: \(yamlQuote(model))",
            "        name: \(yamlQuote(model))",
            "- id: agent-default-model # melon-tools",
            "  config:",
            "    provider: deepseek-official",
            "    model: \(yamlQuote(model))"
        ]
        if !lines.isEmpty, lines.last?.isEmpty == false { lines.append("") }
        lines.append(contentsOf: block)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Removes only one marked list entry: its marker line and the lines
    /// indented under it. A blank line or a top-level comment ends the entry,
    /// so unrelated YAML between two entries is never swallowed.
    private static func removingMarkedBlock(_ lines: [String], id: String) -> [String] {
        let marker = "- id: \(id) # melon-tools"
        guard let start = lines.firstIndex(where: { $0.hasPrefix(marker) }) else {
            return lines
        }
        var end = start + 1
        while end < lines.count {
            let line = lines[end]
            if line.hasPrefix("- ") { break }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            // Deeper indent belongs to the marked block; top-level content ends it.
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") { break }
            end += 1
        }
        var copy = lines
        copy.removeSubrange(start..<end)
        return copy
    }

    private static func yamlQuote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
