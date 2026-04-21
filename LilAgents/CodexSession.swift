import Foundation

class CodexSession: AgentSession {
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var lineBuffer = ""
    private(set) var isRunning = false
    private(set) var isBusy = false
    private var turnFailureFired = false
    private static var binaryPath: String?

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

    // MARK: - Lifecycle

    func start() {
        if let cached = Self.binaryPath {
            isRunning = true
            onSessionReady?()
            return
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        ShellEnvironment.findBinary(name: "codex", fallbackPaths: [
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex"
        ]) { [weak self] path in
            guard let self = self, let binaryPath = path else {
                let msg = "hey! it looks like you don't have Codex installed yet. \(AgentProvider.codex.installInstructions)"
                self?.onNotice?(msg)
                self?.history.append(AgentMessage(role: .notice, text: msg))
                return
            }
            Self.binaryPath = binaryPath
            self.isRunning = true
            self.onSessionReady?()
        }
    }

    func send(message: String) {
        guard isRunning, let binaryPath = Self.binaryPath else { return }
        isBusy = true
        turnFailureFired = false
        history.append(AgentMessage(role: .user, text: message))
        lineBuffer = ""

        // Current Codex CLI: only `codex exec [OPTIONS] <PROMPT>` (resume/--last removed).
        let prompt = Self.execPrompt(priorMessages: history.dropLast(), latestUserMessage: message)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)

        proc.arguments = ["exec", "--json", "--full-auto", "--skip-git-repo-check", prompt]

        proc.currentDirectoryURL = GeminiSession.ensureWorkspaceDirectory()
        var env = ShellEnvironment.processEnvironment(extraPaths: [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".npm-global/bin").path
        ])
        if let apiKey = InstallFlow.storedApiKey(for: .codex) {
            env["OPENAI_API_KEY"] = apiKey
        }
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        var collectedStderr = ""
        var gotAnyText = false

        proc.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.process = nil
                // Flush remaining buffer
                if !self.lineBuffer.isEmpty {
                    self.parseLine(self.lineBuffer)
                    self.lineBuffer = ""
                }

                // If nothing visible came back AND the process failed, show a friendly
                // diagnostic instead of silently stopping — but only once per turn.
                let receivedAssistantText = self.history.contains { $0.role == .assistant } && gotAnyText
                if status != 0 && !receivedAssistantText && !self.turnFailureFired {
                    let hint = CodexSession.diagnose(stderr: collectedStderr, status: status)
                    self.fireTurnFailure(friendly: hint)
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
                    gotAnyText = true
                    self?.processOutput(text)
                }
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            // Collect stderr silently — only surfaced via diagnose() on failure.
            // Codex CLI writes harmless startup noise that shouldn't flash red.
            if let text = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    collectedStderr += text
                    // Bail out of Codex's retry loop on the first obviously fatal line.
                    // Without this, Codex retries 401/network 5+ times with backoff,
                    // making simple messages feel like they're doing heavy work.
                    if !self.turnFailureFired, self.isFatalStderrLine(text) {
                        let hint = CodexSession.diagnose(stderr: collectedStderr, status: 1)
                        self.fireTurnFailure(friendly: hint)
                    }
                }
            }
        }

        do {
            try proc.run()
            process = proc
            outputPipe = outPipe
            errorPipe = errPipe
        } catch {
            isBusy = false
            let msg = "i couldn't launch Codex right now. try again in a moment, or click the **install Codex** button up top to reinstall."
            onNotice?(msg)
            history.append(AgentMessage(role: .notice, text: msg))
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

    /// Line-level check on stderr chunks: is this the kind of error where
    /// Codex will never succeed on retry (auth, quota, missing model)? If so,
    /// terminate early so the user isn't left staring at a spinner.
    private func isFatalStderrLine(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("401 unauthorized")
            || lower.contains("403 forbidden")
            || lower.contains("invalid_api_key")
            || lower.contains("incorrect api key")
            || lower.contains("insufficient_quota")
            || lower.contains("model_not_found")
    }

    /// Emit the friendly notice once per turn, kill the retrying subprocess,
    /// and mark the turn done so the cat stops thinking.
    private func fireTurnFailure(friendly: String) {
        guard !turnFailureFired else { return }
        turnFailureFired = true
        onNotice?(friendly)
        history.append(AgentMessage(role: .notice, text: friendly))
        // Stop Codex from retrying the failed API call over and over
        process?.terminate()
        process = nil
        if isBusy {
            isBusy = false
            onTurnComplete?()
        }
    }

    // MARK: - Error Diagnostics

    static func diagnose(stderr: String, status: Int32) -> String {
        let lower = stderr.lowercased()

        if lower.contains("rate limit") || lower.contains("too many requests") || lower.contains("429") {
            return "OpenAI's rate limit kicked in. wait a minute and try again."
        }
        if lower.contains("quota") || lower.contains("exceeded your current quota") || lower.contains("insufficient_quota") {
            return "looks like you've run out of OpenAI credits. add more at [platform.openai.com/account/billing](https://platform.openai.com/account/billing) and try again."
        }
        if lower.contains("invalid_api_key") || lower.contains("invalid api key")
            || lower.contains("401") || lower.contains("403")
            || lower.contains("unauthorized") || lower.contains("incorrect api key") {
            return """
            OpenAI is refusing the key. a couple of common reasons:

            - it could just be wrong (typo or an extra space) — click **install Codex** up top and paste it again
            - your OpenAI account might not have billing set up yet at [platform.openai.com/account/billing](https://platform.openai.com/account/billing) — even valid keys get rejected until you add a payment method
            """
        }
        if lower.contains("model_not_found") || lower.contains("does not exist") || lower.contains("404") {
            return "Codex needs an update. click the **install Codex** button up top to reinstall the latest version."
        }
        if lower.contains("billing") || lower.contains("payment") {
            return "OpenAI is asking for billing info. set it up at [platform.openai.com/account/billing](https://platform.openai.com/account/billing), then try again."
        }
        if lower.contains("network") || lower.contains("unreachable") || lower.contains("econnrefused") {
            return "Codex couldn't reach the internet. check your connection and try again."
        }
        return "something went wrong while talking to Codex. try again in a minute — if it keeps happening, click the **install Codex** button up top to reset your API key."
    }

    // MARK: - Prompt (multi-turn without codex exec resume)

    private static func execPrompt(priorMessages: ArraySlice<AgentMessage>, latestUserMessage: String) -> String {
        guard !priorMessages.isEmpty else { return latestUserMessage }
        var parts: [String] = []
        for m in priorMessages {
            switch m.role {
            case .user:
                parts.append("User: \(m.text)")
            case .assistant:
                parts.append("Assistant: \(m.text)")
            case .toolUse:
                parts.append("Tool: \(m.text)")
            case .toolResult:
                parts.append("Tool result: \(m.text)")
            case .error:
                parts.append("Error: \(m.text)")
            case .notice:
                continue
            }
        }
        return """
        Conversation so far (for context; respond only to the follow-up):

        \(parts.joined(separator: "\n\n"))

        ---

        User (follow-up): \(latestUserMessage)
        """
    }

    // MARK: - JSONL Parsing

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
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let type = json["type"] as? String ?? ""

        switch type {
        case "thread.started":
            break // session tracking handled by codex internally

        case "item.started":
            if let item = json["item"] as? [String: Any] {
                let itemType = item["type"] as? String ?? ""
                if itemType == "command_execution" {
                    let command = item["command"] as? String ?? ""
                    history.append(AgentMessage(role: .toolUse, text: "Bash: \(command)"))
                    onToolUse?("Bash", ["command": command])
                }
            }

        case "item.completed":
            if let item = json["item"] as? [String: Any] {
                let itemType = item["type"] as? String ?? ""
                switch itemType {
                case "agent_message":
                    let text = item["text"] as? String ?? ""
                    if !text.isEmpty {
                        history.append(AgentMessage(role: .assistant, text: text))
                        onText?(text)
                    }
                case "command_execution":
                    let status = item["status"] as? String ?? ""
                    let command = item["command"] as? String ?? ""
                    let isError = status == "failed"
                    let summary = command.isEmpty ? status : String(command.prefix(80))
                    history.append(AgentMessage(role: .toolResult, text: isError ? "ERROR: \(summary)" : summary))
                    onToolResult?(summary, isError)
                case "file_change":
                    let path = item["file"] as? String ?? item["path"] as? String ?? "file"
                    history.append(AgentMessage(role: .toolUse, text: "FileChange: \(path)"))
                    onToolUse?("FileChange", ["file_path": path])
                    history.append(AgentMessage(role: .toolResult, text: path))
                    onToolResult?(path, false)
                default:
                    break
                }
            }

        case "turn.completed":
            isBusy = false
            onTurnComplete?()

        case "turn.failed":
            let raw = json["message"] as? String ?? "Turn failed"
            fireTurnFailure(friendly: CodexSession.diagnose(stderr: raw, status: 1))

        case "error":
            let raw = json["message"] as? String ?? json["error"] as? String ?? "Unknown error"
            fireTurnFailure(friendly: CodexSession.diagnose(stderr: raw, status: 1))

        default:
            break
        }
    }
}
