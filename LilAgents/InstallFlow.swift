import AppKit
import Foundation

class InstallFlow {
    enum Step {
        case notStarted
        case confirmingNodeInstall
        case confirmingSignup
        case installing
        case confirmingAdminRetry
        case awaitingApiKey
        case complete
        case cancelled
    }

    let provider: AgentProvider
    private(set) var step: Step = .notStarted
    weak var character: WalkerCharacter?
    private var process: Process?
    private var lastInstallOutput: String = ""

    private static let installLoadingPhrases = [
        "installing…", "downloading…", "fetching files…", "unpacking…",
        "setting up…", "working on it…", "almost there…", "hang tight…",
        "getting things ready…", "still going…", "crunching…", "one sec…"
    ]

    init(provider: AgentProvider, character: WalkerCharacter) {
        self.provider = provider
        self.character = character
    }

    func start() {
        ShellEnvironment.findBinary(name: binaryName, fallbackPaths: binaryFallbackPaths) { [weak self] path in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if path != nil {
                    // Binary installed — check whether we still need an API key
                    if self.providerNeedsApiKey && InstallFlow.storedApiKey(for: self.provider) == nil {
                        self.promptApiKeyDirectly()
                        return
                    }
                    self.append("looks like \(self.provider.displayName) is already installed! go ahead and type a message below to start chatting.")
                    self.step = .complete
                    return
                }
                if self.needsNpm {
                    self.checkNpm { hasNpm in
                        if hasNpm { self.promptSignup() } else { self.promptNodeInstall() }
                    }
                } else {
                    self.promptSignup()
                }
            }
        }
    }

    private var providerNeedsApiKey: Bool {
        switch provider {
        case .gemini, .codex: return true
        default: return false
        }
    }

    private func promptApiKeyDirectly() {
        switch provider {
        case .gemini:
            append("""
            looks like Gemini is installed, but i don't have your API key yet. i'm opening the API keys page now.

            1. click **Create API key** (or copy an existing one)
            2. paste the key here — it starts with **AIza**
            """)
            openURL("https://aistudio.google.com/app/apikey")
        case .codex:
            append("""
            looks like Codex is installed, but i don't have your API key yet. i'm opening the API keys page now.

            1. click **Create new secret key**
            2. copy it (you only get to see it once!)
            3. paste it here — it starts with **sk-**
            """)
            openURL("https://platform.openai.com/api-keys")
        default:
            return
        }
        step = .awaitingApiKey
    }

    func cancel() {
        character?.terminalView?.stopLoading()
        process?.terminate()
        process = nil
        step = .cancelled
    }

    func handleUserInput(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch step {
        case .notStarted, .complete, .cancelled:
            return false
        case .confirmingNodeInstall:
            character?.terminalView?.appendUser(text)
            if isReady(trimmed) {
                checkNpm { [weak self] hasNpm in
                    guard let self = self else { return }
                    if hasNpm {
                        self.promptSignup()
                    } else {
                        self.append("i still can't find Node.js. make sure you finished the installer, then type 'ready' again.")
                    }
                }
            } else {
                append("no rush — type 'ready' once you've installed Node.js.")
            }
            return true
        case .confirmingSignup:
            character?.terminalView?.appendUser(text)
            if isReady(trimmed) {
                beginInstall()
            } else {
                append("no rush — type 'ready' once you've made (or signed into) your account.")
            }
            return true
        case .installing:
            character?.terminalView?.appendUser(text)
            append("hold on, still installing — i'll let you know when it's done.")
            return true
        case .confirmingAdminRetry:
            character?.terminalView?.appendUser(text)
            if isReady(trimmed) {
                retryInstallWithAdmin()
            } else {
                append("no problem. you can also paste this in Terminal yourself:\n\n```\n\(installCommand)\n```")
                step = .cancelled
            }
            return true
        case .awaitingApiKey:
            character?.terminalView?.appendUser("[api key]")
            let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if isValidApiKey(key) {
                InstallFlow.saveApiKey(key, for: provider)
                append("got it — your API key is saved ✨ go ahead and type a message below to start chatting!")
                step = .complete
                character?.retrySessionIfNeeded()
            } else {
                append("hmm, that doesn't look like a \(provider.displayName) API key. it should start with **\(expectedKeyPrefix)**. paste it again?")
            }
            return true
        }
    }

    // MARK: - Steps

    private func promptNodeInstall() {
        append("""
        first, you'll need to install Node.js on your computer (it includes the installer that puts \(provider.displayName) on your machine).

        i'm opening the download page in your browser now. click the big download button, open the .pkg file it downloads, and follow the installer steps.

        when you're done, type **ready** below and press enter.
        """)
        openURL("https://nodejs.org/en/download")
        step = .confirmingNodeInstall
    }

    private func promptSignup() {
        let info = signupInfo
        append("""
        opening \(info.label) in your browser now.

        \(info.instruction)

        when you're done, type **ready** below and press enter and i'll install \(provider.displayName) for you.
        """)
        openURL(info.url)
        step = .confirmingSignup
    }

    private func beginInstall() {
        step = .installing
        append("installing \(provider.displayName)… this might take a minute or two. i'll keep you posted below.")
        character?.terminalView?.startLoading(phrases: Self.installLoadingPhrases)
        runInstall()
    }

    private func runInstall() {
        lastInstallOutput = ""
        runShellCommand(installCommand)
    }

    private func retryInstallWithAdmin() {
        step = .installing
        append("retrying with admin access — macOS will pop up a password prompt. type your login password to approve.")
        character?.terminalView?.startLoading(phrases: Self.installLoadingPhrases)
        let escaped = installCommand.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let osa = "osascript -e 'do shell script \"\(escaped)\" with administrator privileges'"
        lastInstallOutput = ""
        runShellCommand(osa)
    }

    private func runShellCommand(_ cmd: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-l", "-c", cmd]
        proc.environment = ShellEnvironment.processEnvironment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.lastInstallOutput += str
                self?.character?.terminalView?.appendStreamingText(str)
                self?.character?.terminalView?.endStreaming()
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.lastInstallOutput += str
                self?.character?.terminalView?.appendStreamingText(str)
                self?.character?.terminalView?.endStreaming()
            }
        }
        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                self?.process = nil
                if p.terminationStatus == 0 {
                    self?.onInstallSuccess()
                } else {
                    self?.onInstallFailure()
                }
            }
        }
        do {
            try proc.run()
            self.process = proc
        } catch {
            character?.terminalView?.stopLoading()
            append("couldn't start the install: \(error.localizedDescription). you can paste the command into Terminal manually:\n\n```\n\(installCommand)\n```")
            step = .cancelled
        }
    }

    private func onInstallSuccess() {
        character?.terminalView?.stopLoading()
        // The cached shell environment and per-session binary paths were captured
        // before the install ran, so PATH/binary lookups wouldn't see the newly
        // installed CLI. Clear them so the upcoming retrySessionIfNeeded() call
        // can discover the freshly installed binary.
        ShellEnvironment.clearCache()
        ClaudeSession.clearBinaryCache()
        CodexSession.clearBinaryCache()
        GeminiSession.clearBinaryCache()
        append("done — \(provider.displayName) is installed ✨")
        switch provider {
        case .claude:
            append("""

            now i'll sign you in. a Claude browser tab should pop up — sign in there (or sign up if you don't have an account yet) and then come right back here. once you're done, type any message below to start chatting!
            """)
            runClaudeSignIn()
            step = .complete
            // Brief delay so any in-flight symlink/file writes from the install
            // script have time to settle before we try to launch the binary.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.character?.retrySessionIfNeeded()
            }
        case .gemini:
            append("""

            last step — paste your Google AI API key below so i can talk to Gemini for you. i'm opening the API keys page now:

            1. click **Create API key** (or copy an existing one)
            2. paste the key here — it starts with **AIza**

            your key stays on your computer and is only used to talk to Gemini.
            """)
            openURL("https://aistudio.google.com/app/apikey")
            step = .awaitingApiKey
        case .codex:
            append("""

            last step — paste your OpenAI API key below so i can talk to Codex for you. i'm opening the API keys page now:

            1. click **Create new secret key**
            2. copy it (you only get to see it once!)
            3. paste it here — it starts with **sk-**

            your key stays on your computer and is only used to talk to OpenAI.
            """)
            openURL("https://platform.openai.com/api-keys")
            step = .awaitingApiKey
        default:
            append("\nyou're all set! type a message below to start chatting.")
            step = .complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.character?.retrySessionIfNeeded()
            }
        }
    }

    private func runClaudeSignIn() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-l", "-c", "claude"]
        proc.environment = ShellEnvironment.processEnvironment()
        try? proc.run()
    }

    private func onInstallFailure() {
        character?.terminalView?.stopLoading()
        let lower = lastInstallOutput.lowercased()
        let looksLikePermission = lower.contains("eacces")
            || lower.contains("permission denied")
            || lower.contains("operation not permitted")
            || lower.contains("need sudo")
            || lower.contains("must be run as root")
        if looksLikePermission && step != .confirmingAdminRetry {
            append("""

            looks like the install needs admin permission to put \(provider.displayName) on your computer (some Macs protect those folders).

            want me to try again with admin access? type **yes** below and macOS will pop up a password prompt — or type anything else to skip.
            """)
            step = .confirmingAdminRetry
        } else {
            append("""

            hmm, the install didn't finish. the most common reasons are that the network blocked the download, or Node.js isn't fully set up.

            you can try it yourself in the Terminal app:

            ```
            \(installCommand)
            ```
            """)
            step = .cancelled
        }
    }

    // MARK: - Helpers

    private func isReady(_ trimmed: String) -> Bool {
        ["ready", "done", "ok", "okay", "yes", "yep", "yeah", "y"].contains(trimmed)
    }

    private func append(_ text: String) {
        character?.terminalView?.appendStreamingText("\n" + text + "\n")
        character?.terminalView?.endStreaming()
    }

    private func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private var expectedKeyPrefix: String {
        switch provider {
        case .gemini: return "AIza"
        case .codex: return "sk-"
        default: return ""
        }
    }

    private func isValidApiKey(_ key: String) -> Bool {
        guard !expectedKeyPrefix.isEmpty, key.count >= 20 else { return false }
        return key.hasPrefix(expectedKeyPrefix)
    }

    static func apiKeyUserDefaultsKey(for provider: AgentProvider) -> String? {
        switch provider {
        case .gemini: return "geminiApiKey"
        case .codex: return "openaiApiKey"
        default: return nil
        }
    }

    static func saveApiKey(_ key: String, for provider: AgentProvider) {
        guard let defaultsKey = apiKeyUserDefaultsKey(for: provider) else { return }
        UserDefaults.standard.set(key, forKey: defaultsKey)
    }

    static func storedApiKey(for provider: AgentProvider) -> String? {
        guard let defaultsKey = apiKeyUserDefaultsKey(for: provider) else { return nil }
        let key = UserDefaults.standard.string(forKey: defaultsKey)
        return (key?.isEmpty == false) ? key : nil
    }

    private func checkNpm(completion: @escaping (Bool) -> Void) {
        ShellEnvironment.findBinary(name: "npm", fallbackPaths: [
            "/usr/local/bin/npm",
            "/opt/homebrew/bin/npm"
        ]) { path in
            DispatchQueue.main.async { completion(path != nil) }
        }
    }

    // MARK: - Per-provider config

    private var binaryName: String {
        switch provider {
        case .claude: return "claude"
        case .codex:  return "codex"
        case .gemini: return "gemini"
        default: return ""
        }
    }

    private var binaryFallbackPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let b = binaryName
        return [
            "\(home)/.local/bin/\(b)",
            "\(home)/.npm-global/bin/\(b)",
            "/usr/local/bin/\(b)",
            "/opt/homebrew/bin/\(b)"
        ]
    }

    private var needsNpm: Bool {
        switch provider {
        case .codex, .gemini: return true
        default: return false
        }
    }

    private var installCommand: String {
        switch provider {
        case .claude: return "curl -fsSL https://claude.ai/install.sh | sh"
        case .codex:  return "npm install -g @openai/codex"
        case .gemini: return "npm install -g @google/gemini-cli"
        default: return "echo 'no install command'"
        }
    }

    private var signupInfo: (url: String, label: String, instruction: String) {
        switch provider {
        case .claude:
            return (
                "https://claude.ai/login",
                "Claude's sign-up page",
                "create an Anthropic account (or sign in if you already have one)."
            )
        case .codex:
            return (
                "https://platform.openai.com/signup",
                "OpenAI's sign-up page",
                "create an OpenAI account (or sign in if you already have one). Codex will ask you for an API key the first time you chat — you can make one at platform.openai.com/api-keys."
            )
        case .gemini:
            return (
                "https://aistudio.google.com/",
                "Google AI Studio",
                "sign in with a Google account — that's where your Gemini access lives."
            )
        default:
            return ("", "", "")
        }
    }
}

extension AgentProvider {
    var supportsInstallFlow: Bool {
        switch self {
        case .claude, .codex, .gemini: return true
        default: return false
        }
    }

    /// True when the provider is both installed and has whatever credentials it needs.
    var isReadyToUse: Bool {
        guard isAvailable else { return false }
        switch self {
        case .gemini, .codex:
            return InstallFlow.storedApiKey(for: self) != nil
        default:
            return true
        }
    }

    /// Model options shown in the hammer menu. Empty array hides the section.
    var modelOptions: [(alias: String, full: String, desc: String)] {
        switch self {
        case .claude: return [
            ("opus",   "claude-opus-4-7",           "most capable"),
            ("sonnet", "claude-sonnet-4-6",         "balanced · default"),
            ("haiku",  "claude-haiku-4-5-20251001", "fastest")
        ]
        case .gemini: return [
            ("pro",        "gemini-2.5-pro",        "most capable · low free quota"),
            ("flash",      "gemini-2.5-flash",      "fast · default · generous free quota"),
            ("flash-lite", "gemini-2.5-flash-lite", "fastest · highest free quota")
        ]
        default: return []
        }
    }

    var supportsMCP: Bool {
        switch self {
        case .claude: return true
        default: return false
        }
    }

    /// Show the hammer button only when there's something useful behind it.
    var showsHammerMenu: Bool {
        return !modelOptions.isEmpty || supportsMCP
    }
}
