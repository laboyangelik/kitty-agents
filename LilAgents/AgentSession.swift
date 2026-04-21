import Foundation

// MARK: - Provider

enum AgentProvider: String, CaseIterable {
    case claude, codex, copilot, gemini, opencode, openclaw

    private static let defaultsKey = "selectedProvider"

    static var current: AgentProvider {
        get {
            let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? "claude"
            return AgentProvider(rawValue: raw) ?? .claude
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    var displayName: String {
        switch self {
        case .claude:   return "Claude"
        case .codex:    return "Codex"
        case .copilot:  return "Copilot"
        case .gemini:   return "Gemini"
        case .opencode: return "OpenCode"
        case .openclaw: return "OpenClaw"
        }
    }

    var inputPlaceholder: String {
        "Ask \(displayName)..."
    }

    /// Returns provider name styled per theme format.
    func titleString(format: TitleFormat) -> String {
        switch format {
        case .uppercase:      return displayName.uppercased()
        case .lowercaseTilde: return displayName.lowercased()
        case .capitalized:    return displayName
        }
    }

    var binaryName: String {
        switch self {
        case .claude:   return "claude"
        case .codex:    return "codex"
        case .copilot:  return "copilot"
        case .gemini:   return "gemini"
        case .opencode: return "opencode"
        case .openclaw: return "openclaw"
        }
    }

    /// Cache of provider availability, populated by `detectAvailableProviders`.
    private(set) static var availability: [AgentProvider: Bool] = [:]

    /// Scan PATH for all provider binaries and call completion when done.
    static func detectAvailableProviders(completion: @escaping () -> Void) {
        let all = AgentProvider.allCases
        let group = DispatchGroup()
        for provider in all {
            // OpenClaw is network-based, not a local binary
            if provider == .openclaw {
                availability[provider] = OpenClawConfig.load().authToken.isEmpty == false
                continue
            }
            group.enter()
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            ShellEnvironment.findBinary(name: provider.binaryName, fallbackPaths: [
                "\(home)/.local/bin/\(provider.binaryName)",
                "/usr/local/bin/\(provider.binaryName)",
                "/opt/homebrew/bin/\(provider.binaryName)"
            ]) { path in
                availability[provider] = path != nil
                group.leave()
            }
        }
        group.notify(queue: .main) {
            completion()
        }
    }

    var isAvailable: Bool {
        if self == .openclaw { return OpenClawConfig.load().authToken.isEmpty == false }
        return AgentProvider.availability[self] ?? false
    }

    /// Returns the first available provider, or `.claude` as fallback.
    static var firstAvailable: AgentProvider {
        allCases.first(where: { $0.isAvailable }) ?? .claude
    }

    var installInstructions: String {
        switch self {
        case .claude, .codex, .gemini:
            return "no worries — click the **install \(displayName)** button up top (right next to the hammer icon) and i'll walk you through making an account and setting everything up, right here in the chat."
        case .copilot:
            return "to get Copilot on your computer, open the Terminal app on your Mac, paste one of these lines, and press enter:\n\n  brew install copilot-cli\n\nor, if you have Node.js installed:\n\n  npm install -g @github/copilot-cli\n\nthen come back here and we'll pick up where we left off."
        case .opencode:
            return "to get OpenCode on your computer, open the Terminal app on your Mac, paste this line, and press enter:\n\n  curl -fsSL https://opencode.ai/install | bash\n\nthen come back here and we'll pick up where we left off."
        case .openclaw:
            return "OpenClaw is a self-hosted AI gateway — it lets you connect me to your own AI server. to set it up, open the Terminal app on your Mac, paste these two lines one at a time, and press enter after each:\n\n  npm install -g openclaw\n  openclaw gateway run\n\nyou can find more details at https://docs.openclaw.ai"
        }
    }

    func createSession() -> any AgentSession {
        switch self {
        case .claude:   return ClaudeSession()
        case .codex:    return CodexSession()
        case .copilot:  return CopilotSession()
        case .gemini:   return GeminiSession()
        case .opencode: return OpenCodeSession()
        case .openclaw: return OpenClawSession()
        }
    }
}

// MARK: - Title Format

enum TitleFormat {
    case uppercase       // "CLAUDE"
    case lowercaseTilde  // "claude ~"
    case capitalized     // "Claude"
}

// MARK: - Message

struct AgentMessage {
    enum Role { case user, assistant, error, notice, toolUse, toolResult }
    let role: Role
    let text: String
}

// MARK: - Session Protocol

protocol AgentSession: AnyObject {
    var isRunning: Bool { get }
    var isBusy: Bool { get }
    var history: [AgentMessage] { get set }

    var onText: ((String) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    var onNotice: ((String) -> Void)? { get set }
    var onToolUse: ((String, [String: Any]) -> Void)? { get set }
    var onToolResult: ((String, Bool) -> Void)? { get set }
    var onSessionReady: (() -> Void)? { get set }
    var onTurnComplete: (() -> Void)? { get set }
    var onProcessExit: (() -> Void)? { get set }

    func start()
    func send(message: String)
    func terminate()
    func cancelCurrentTurn()
}
