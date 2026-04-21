import Foundation

class GeminiSession: AgentSession {
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var lineBuffer = ""
    private var currentResponseText = ""
    private(set) var isRunning = false
    private(set) var isBusy = false
    private var isFirstTurn = true
    private static var binaryPath: String?
    var model: String = "gemini-2.5-flash"

    static func clearBinaryCache() {
        binaryPath = nil
    }

    var onText: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onNotice: ((String) -> Void)?
    var onToolUse: ((String, [String: Any]) -> Void)?
    var onToolResult: ((String, Bool) -> Void)?
    var onSessionReady: (() -> Void)?
    var onTurnComplete: (() -> Void)?
    var onProcessExit: (() -> Void)?

    var history: [AgentMessage] = []

    // MARK: - Prompt Building

    private static func buildPromptWithHistory(priorMessages: ArraySlice<AgentMessage>, latestUserMessage: String) -> String {
        let conversationalPrior = priorMessages.filter { m in
            m.role == .user || m.role == .assistant
        }
        guard !conversationalPrior.isEmpty else { return latestUserMessage }

        var parts: [String] = []
        for m in conversationalPrior {
            switch m.role {
            case .user:      parts.append("User: \(m.text)")
            case .assistant: parts.append("Assistant: \(m.text)")
            default: break
            }
        }
        return """
        Here is our conversation so far (for your context). Respond only to the final follow-up at the bottom — do not re-answer earlier messages.

        \(parts.joined(separator: "\n\n"))

        ---

        User's follow-up: \(latestUserMessage)
        """
    }

    // MARK: - Error Diagnostics

    static func diagnose(stderr: String, status: Int32) -> String {
        let lower = stderr.lowercased()

        // Quota / rate limit
        if lower.contains("quota") || lower.contains("rate limit") || lower.contains("429") {
            return "looks like you've used up Gemini's free credits for the day. try again tomorrow, or add a paid plan at [aistudio.google.com](https://aistudio.google.com)."
        }
        // Auth / invalid key
        if lower.contains("api_key_invalid") || lower.contains("invalid api key")
            || lower.contains("401") || lower.contains("403")
            || lower.contains("permission_denied") || lower.contains("unauthorized") {
            return "your Google key didn't work. click the **install Gemini** button up top to set it up again with a fresh key."
        }
        // API not enabled (common with Cloud project keys)
        if lower.contains("api has not been used") || lower.contains("service_disabled")
            || lower.contains("generative language api") {
            return "this key is from a different kind of Google account that doesn't have Gemini turned on. click the **install Gemini** button up top and grab a fresh key from Google AI Studio — those work right out of the box."
        }
        // Model not found / unsupported
        if lower.contains("model not found") || lower.contains("does not exist") || lower.contains("not supported") {
            return "Gemini needs an update. click the **install Gemini** button up top to reinstall the latest version."
        }
        // Region restriction
        if lower.contains("location is not supported") || lower.contains("region") {
            return "Gemini isn't available in your region yet. Google's working on it."
        }
        // Talking to Gemini API (generic network/API failure)
        if lower.contains("error when talking to gemini api") || lower.contains("network") {
            return "Gemini couldn't reach the internet. check your connection and try again in a minute."
        }
        // Fallback — keep it short and offer the install button
        return "something went wrong while talking to Gemini. try again in a minute — if it keeps happening, click the **install Gemini** button up top to reset your API key."
    }

    // MARK: - Workspace

    /// Returns a dedicated folder Gemini can safely scan without hitting
    /// restricted locations like ~/.Trash. Creates it if it doesn't exist.
    static func ensureWorkspaceDirectory() -> URL {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let workspace = home.appendingPathComponent("Documents/kitty-agents-workspace", isDirectory: true)
        if !fm.fileExists(atPath: workspace.path) {
            try? fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        }
        return workspace
    }

    // MARK: - Lifecycle

    func start() {
        if Self.binaryPath != nil {
            isRunning = true
            onSessionReady?()
            return
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        ShellEnvironment.findBinary(name: "gemini", fallbackPaths: [
            "\(home)/.local/bin/gemini",
            "\(home)/.npm-global/bin/gemini",
            "/usr/local/bin/gemini",
            "/opt/homebrew/bin/gemini"
        ]) { [weak self] path in
            guard let self = self else { return }
            if let binaryPath = path {
                Self.binaryPath = binaryPath
                self.isRunning = true
                self.onSessionReady?()
            } else {
                let msg = "hey! it looks like you don't have Gemini installed yet. \(AgentProvider.gemini.installInstructions)"
                self.onNotice?(msg)
                self.history.append(AgentMessage(role: .notice, text: msg))
            }
        }
    }

    func send(message: String) {
        guard isRunning, let binaryPath = Self.binaryPath else { return }
        isBusy = true
        currentResponseText = ""
        history.append(AgentMessage(role: .user, text: message))
        lineBuffer = ""

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)

        // Gemini CLI's -p mode is one-shot; --resume doesn't actually preserve
        // context between -p invocations. Embed the prior history in the prompt
        // so each turn has full conversation context.
        let fullPrompt = GeminiSession.buildPromptWithHistory(
            priorMessages: history.dropLast(),
            latestUserMessage: message
        )
        proc.arguments = ["--yolo", "--model", model, "-p", fullPrompt]

        proc.currentDirectoryURL = GeminiSession.ensureWorkspaceDirectory()
        var env = ShellEnvironment.processEnvironment(extraPaths: [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".npm-global/bin").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        ])
        if let apiKey = InstallFlow.storedApiKey(for: .gemini) {
            env["GEMINI_API_KEY"] = apiKey
            env["GOOGLE_API_KEY"] = apiKey
        }
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        var collectedText = ""
        var collectedStderr = ""

        proc.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.process = nil

                // Process any remaining buffered content
                if !self.lineBuffer.isEmpty {
                    self.parseLine(self.lineBuffer)
                    self.lineBuffer = ""
                }

                let text = collectedText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty && self.isBusy {
                    // If we got text that wasn't streamed yet (non-streaming fallback)
                    let alreadyStreamed = self.history.last?.role == .assistant
                    if !alreadyStreamed && self.currentResponseText.isEmpty {
                        self.history.append(AgentMessage(role: .assistant, text: text))
                        self.onText?(text)
                    }
                }

                // Save final response text if we tracked it
                if !self.currentResponseText.isEmpty && self.history.last?.role != .assistant {
                    self.history.append(AgentMessage(role: .assistant, text: self.currentResponseText))
                }

                // Surface the actual reason if nothing came back
                let gotAnyResponse = !self.currentResponseText.isEmpty || !text.isEmpty
                if status != 0 && !gotAnyResponse {
                    let hint = GeminiSession.diagnose(stderr: collectedStderr, status: status)
                    self.onNotice?(hint)
                    self.history.append(AgentMessage(role: .notice, text: hint))
                } else if gotAnyResponse {
                    // Only mark first-turn as done if we actually got a real response,
                    // so subsequent sends don't try to --resume a session that never existed
                    self.isFirstTurn = false
                }

                if self.isBusy {
                    self.isBusy = false
                    self.onTurnComplete?()
                }
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    collectedText += text
                    // Try to parse as JSONL first, fall back to streaming plain text
                    self.processOutput(text)
                }
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            _ = self
            let data = handle.availableData
            guard !data.isEmpty else { return }
            // Collect stderr silently — it's used only if the process exits non-zero.
            // Gemini CLI writes chatty startup noise here ("YOLO mode enabled", key-in-use
            // notices, etc.) that shouldn't flash red in the chat on successful runs.
            if let text = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async { collectedStderr += text }
            }
        }

        do {
            try proc.run()
            process = proc
            outputPipe = outPipe
            errorPipe = errPipe
        } catch {
            isBusy = false
            let msg = "Failed to launch Gemini CLI: \(error.localizedDescription)"
            onError?(msg)
            history.append(AgentMessage(role: .error, text: msg))
        }
    }

    func terminate() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        isRunning = false
        isBusy = false
    }

    func cancelCurrentTurn() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        isRunning = false
        isBusy = false
        start()
    }

    // MARK: - Output Parsing

    // Gemini CLI may emit JSONL or plain text depending on version/flags.
    // We try JSONL first, fall back to treating output as plain streaming text.
    private var didReceiveJsonLine = false

    private func processOutput(_ text: String) {
        lineBuffer += text
        while let newlineRange = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[lineBuffer.startIndex..<newlineRange.lowerBound])
            lineBuffer = String(lineBuffer[newlineRange.upperBound...])
            if !line.isEmpty {
                parseLine(line)
            }
        }
    }

    private func parseLine(_ line: String) {
        // Attempt JSON parse
        if let rawData = line.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any] {
            didReceiveJsonLine = true
            handleJsonEvent(json)
            return
        }

        // Plain text fallback: stream each line as assistant text
        if !didReceiveJsonLine {
            let text = line + "\n"
            currentResponseText += text
            onText?(text)
        }
    }

    private func handleJsonEvent(_ json: [String: Any]) {
        let type = json["type"] as? String ?? json["event"] as? String ?? ""
        let data = json["data"] as? [String: Any] ?? json

        switch type {
        case "content", "text", "delta", "message":
            let text = data["text"] as? String ?? data["content"] as? String ?? json["text"] as? String ?? ""
            if !text.isEmpty {
                // Check for delta mode
                if let role = json["role"] as? String, role == "assistant",
                   let content = json["content"] as? String {
                    let isDelta = json["delta"] as? Bool ?? false
                    if isDelta {
                        currentResponseText += content
                        onText?(content)
                    } else if currentResponseText.isEmpty {
                        currentResponseText = content
                        onText?(content)
                    }
                } else {
                    onText?(text)
                }
            }

        case "tool_call", "function_call", "tool_use":
            let toolName = data["name"] as? String ?? json["tool_name"] as? String ?? "Tool"
            // Skip internal skill activation noise
            if toolName == "activate_skill" { return }
            let input = data["input"] as? [String: Any] ?? data["arguments"] as? [String: Any] ?? json["parameters"] as? [String: Any] ?? [:]
            let summary = formatToolSummary(toolName: toolName, params: input)
            history.append(AgentMessage(role: .toolUse, text: "\(toolName): \(summary)"))
            onToolUse?(toolName, input)

        case "tool_result", "function_result":
            let output = data["output"] as? String ?? data["result"] as? String ?? (json["output"] as? String) ?? ""
            let isError = (data["is_error"] as? Bool) ?? (json["status"] as? String == "error")
            let summary = String(output.prefix(80))
            history.append(AgentMessage(role: .toolResult, text: isError ? "ERROR: \(summary)" : summary))
            onToolResult?(summary, isError)

        case "done", "end", "complete", "turn_end", "result":
            if isBusy {
                isBusy = false
                if let result = json["result"] as? String ?? data["text"] as? String, !result.isEmpty {
                    history.append(AgentMessage(role: .assistant, text: result))
                } else if !currentResponseText.isEmpty {
                    history.append(AgentMessage(role: .assistant, text: currentResponseText))
                }
                onTurnComplete?()
            }

        case "error":
            let msg = data["message"] as? String ?? data["error"] as? String ?? "Unknown Gemini error"
            onError?(msg)
            history.append(AgentMessage(role: .error, text: msg))

        default:
            // Forward any text content we find
            if let text = json["text"] as? String ?? json["content"] as? String, !text.isEmpty {
                currentResponseText += text
                onText?(text)
            }
        }
    }

    private func formatToolSummary(toolName: String, params: [String: Any]) -> String {
        switch toolName {
        case "run_shell_command":
            return params["command"] as? String ?? ""
        case "read_file":
            return params["file_path"] as? String ?? ""
        case "replace", "write_file":
            return params["file_path"] as? String ?? ""
        case "glob":
            return params["pattern"] as? String ?? ""
        case "grep_search":
            return params["pattern"] as? String ?? ""
        default:
            return params.keys.sorted().prefix(3).joined(separator: ", ")
        }
    }
}
