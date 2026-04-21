import AppKit

class PaddedTextFieldCell: NSTextFieldCell {
    private let inset = NSSize(width: 8, height: 2)
    var fieldBackgroundColor: NSColor?
    var fieldCornerRadius: CGFloat = 4

    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        if let bg = fieldBackgroundColor {
            let path = NSBezierPath(roundedRect: cellFrame, xRadius: fieldCornerRadius, yRadius: fieldCornerRadius)
            bg.setFill()
            path.fill()
        }
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let base = super.drawingRect(forBounds: rect)
        return base.insetBy(dx: inset.width, dy: inset.height)
    }

    private func configureEditor(_ textObj: NSText) {
        if let color = textColor {
            textObj.textColor = color
        }
        if let tv = textObj as? NSTextView {
            tv.insertionPointColor = textColor ?? .textColor
            tv.drawsBackground = false
            tv.backgroundColor = .clear
        }
        textObj.font = font
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        configureEditor(textObj)
        super.edit(withFrame: rect.insetBy(dx: inset.width, dy: inset.height), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        configureEditor(textObj)
        super.select(withFrame: rect.insetBy(dx: inset.width, dy: inset.height), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

class TerminalView: NSView, NSTextFieldDelegate {
    let scrollView = NSScrollView()
    let textView = NSTextView()
    let inputField = NSTextField()
    var onSendMessage: ((String) -> Void)?
    var onClearRequested: (() -> Void)?
    var onModelChange: ((String) -> Void)?
    var currentModel: String = "claude-sonnet-4-6"
    var provider: AgentProvider = .claude {
        didSet {
            updatePlaceholder()
        }
    }

    private var currentAssistantText = ""
    private var lastAssistantText = ""
    private var isStreaming = false {
        didSet {
            if isStreaming { startStatusCycling() } else { stopStatusCycling() }
        }
    }
    private var showingSessionMessage = false

    private var statusTimer: Timer?
    private var statusPhraseIndex = 0
    private static let statusPhrases = [
        "thinking…", "analyzing…", "tinkering…", "one sec…",
        "working on it…", "reading…", "crunching…", "figuring it out…",
        "cooking…", "connecting dots…", "on it…", "processing…",
        "calculating…", "looking…", "hang tight…", "almost…",
        "bear with me…", "let me check…", "assembling…", "vibing…"
    ]

    private var modelPickerActive = false
    private var modelPickerIndex = 0
    private var modelPickerStartLocation = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    var characterColor: NSColor?
    var themeOverride: PopoverTheme?
    var theme: PopoverTheme {
        var t = themeOverride ?? PopoverTheme.current
        if let color = characterColor { t = t.withCharacterColor(color) }
        t = t.withCustomFont()
        return t
    }

    // MARK: - Setup

    private var statusTextLocation = -1
    private var spinnerFrame = 0
    private static let spinnerFrames = ["⣾","⣽","⣻","⢿","⡿","⣟","⣯","⣷"]
    private static let phraseAdvanceEvery = 18

    private func updatePlaceholder() {
        let t = theme
        inputField.placeholderAttributedString = NSAttributedString(
            string: provider.inputPlaceholder,
            attributes: [.font: t.font, .foregroundColor: t.textDim]
        )
    }

    private func startStatusCycling() {
        guard let storage = textView.textStorage else { return }
        statusPhraseIndex = Int.random(in: 0..<Self.statusPhrases.count)
        spinnerFrame = 0
        statusTextLocation = storage.length
        replaceStatusPhrase()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.spinnerFrame += 1
            if self.spinnerFrame % Self.phraseAdvanceEvery == 0 {
                self.statusPhraseIndex = (self.statusPhraseIndex + 1) % Self.statusPhrases.count
            }
            self.replaceStatusPhrase()
        }
    }

    private func stopStatusCycling() {
        statusTimer?.invalidate()
        statusTimer = nil
        removeStatusPhrase()
        statusTextLocation = -1
    }

    private func statusAttributedString() -> NSAttributedString {
        let t = theme
        let spinner = Self.spinnerFrames[spinnerFrame % Self.spinnerFrames.count]
        let phrase = Self.statusPhrases[statusPhraseIndex]
        let str = NSMutableAttributedString()
        str.append(NSAttributedString(
            string: "  \(spinner) ",
            attributes: [.font: t.fontBold, .foregroundColor: t.accentColor]
        ))
        str.append(NSAttributedString(
            string: "\(phrase)\n",
            attributes: [.font: t.font, .foregroundColor: t.accentColor.withAlphaComponent(0.7)]
        ))
        return str
    }

    private func replaceStatusPhrase() {
        guard let storage = textView.textStorage, statusTextLocation >= 0 else { return }
        let currentLen = storage.length
        if currentLen >= statusTextLocation {
            let range = NSRange(location: statusTextLocation, length: currentLen - statusTextLocation)
            storage.replaceCharacters(in: range, with: statusAttributedString())
        } else {
            storage.append(statusAttributedString())
        }
        scrollToBottom()
    }

    private func removeStatusPhrase() {
        guard let storage = textView.textStorage, statusTextLocation >= 0,
              statusTextLocation <= storage.length else { return }
        storage.deleteCharacters(in: NSRange(location: statusTextLocation, length: storage.length - statusTextLocation))
    }

    private func setupViews() {
        let t = theme
        let inputHeight: CGFloat = 30
        let padding: CGFloat = 10

        scrollView.frame = NSRect(
            x: padding, y: inputHeight + padding + 6,
            width: frame.width - padding * 2,
            height: frame.height - inputHeight - padding - 10
        )
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        textView.frame = scrollView.contentView.bounds
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textColor = t.textPrimary
        textView.font = t.font
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 2, height: 4)
        let defaultPara = NSMutableParagraphStyle()
        defaultPara.paragraphSpacing = 8
        textView.defaultParagraphStyle = defaultPara
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.linkTextAttributes = [
            .foregroundColor: t.accentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]

        scrollView.documentView = textView
        addSubview(scrollView)

        inputField.frame = NSRect(
            x: padding, y: 6,
            width: frame.width - padding * 2,
            height: inputHeight
        )
        inputField.autoresizingMask = [.width]
        inputField.focusRingType = .none
        let paddedCell = PaddedTextFieldCell(textCell: "")
        paddedCell.isEditable = true
        paddedCell.isScrollable = true
        paddedCell.font = t.font
        paddedCell.textColor = t.textPrimary
        paddedCell.drawsBackground = false
        paddedCell.isBezeled = false
        paddedCell.fieldBackgroundColor = nil
        paddedCell.fieldCornerRadius = 0
        inputField.cell = paddedCell
        updatePlaceholder()
        inputField.target = self
        inputField.action = #selector(inputSubmitted)
        inputField.delegate = self
        addSubview(inputField)
    }

    func resetState() {
        isStreaming = false
        currentAssistantText = ""
        lastAssistantText = ""
        showingSessionMessage = false
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
    }

    func showSessionMessage() {
        let t = theme
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: "  \u{2726} new session\n",
            attributes: [.font: t.font, .foregroundColor: t.accentColor]
        ))
        showingSessionMessage = true
    }

    // MARK: - Input

    @objc private func inputSubmitted() {
        if modelPickerActive {
            confirmModelPicker()
            return
        }
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputField.stringValue = ""

        if handleSlashCommand(text) { return }

        if showingSessionMessage {
            textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
            showingSessionMessage = false
        }
        appendUser(text)
        isStreaming = true
        currentAssistantText = ""
        onSendMessage?(text)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            modelPickerMove(-1); return modelPickerActive
        case #selector(NSResponder.moveDown(_:)):
            modelPickerMove(1); return modelPickerActive
        case #selector(NSResponder.cancelOperation(_:)):
            if modelPickerActive { cancelModelPicker(); return true }
            return false
        default:
            return false
        }
    }

    // MARK: - Slash Commands

    func handleSlashCommandPublic(_ text: String) {
        _ = handleSlashCommand(text)
    }

    private func handleSlashCommand(_ text: String) -> Bool {
        guard text.hasPrefix("/") else { return false }
        let cmd = text.lowercased().trimmingCharacters(in: .whitespaces)

        switch cmd {
        case "/clear":
            resetState()
            onClearRequested?()
            return true

        case "/copy":
            let toCopy = lastAssistantText.isEmpty ? "nothing to copy yet" : lastAssistantText
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(toCopy, forType: .string)
            let t = theme
            textView.textStorage?.append(NSAttributedString(
                string: "  ✓ copied to clipboard\n",
                attributes: [.font: t.font, .foregroundColor: t.successColor]
            ))
            scrollToBottom()
            return true

        case "/help":
            let t = theme
            let help = NSMutableAttributedString()
            help.append(NSAttributedString(string: "  kitty agents\n",
                attributes: [.font: t.fontBold, .foregroundColor: t.accentColor]))
            let cmds: [(String, String)] = [
                ("/clear",  "clear chat history"),
                ("/copy",   "copy last response"),
                ("/model",  "show or switch model  (e.g. /model opus)"),
                ("/mcp",    "list configured MCP servers"),
            ]
            for (cmd, desc) in cmds {
                let padded = cmd.padding(toLength: 10, withPad: " ", startingAt: 0)
                help.append(NSAttributedString(string: "  \(padded)", attributes: [.font: t.fontBold, .foregroundColor: t.textPrimary]))
                help.append(NSAttributedString(string: "\(desc)\n", attributes: [.font: t.font, .foregroundColor: t.textDim]))
            }
            textView.textStorage?.append(help)
            scrollToBottom()
            return true

        case "/mcp":
            showMCPServers()
            return true

        default:
            if cmd.hasPrefix("/model") {
                handleModelCommand(text)
                return true
            }
            return false
        }
    }

    private static let modelAliases: [(alias: String, full: String, desc: String)] = [
        ("opus",   "claude-opus-4-7",          "most capable"),
        ("sonnet", "claude-sonnet-4-6",         "balanced · default"),
        ("haiku",  "claude-haiku-4-5-20251001", "fastest"),
    ]

    private func handleModelCommand(_ text: String) {
        let parts = text.split(separator: " ", maxSplits: 1)
        if parts.count == 1 {
            modelPickerIndex = Self.modelAliases.firstIndex(where: { currentModel.contains($0.alias) }) ?? 1
            modelPickerStartLocation = textView.textStorage?.length ?? 0
            modelPickerActive = true
            renderModelPicker()
            inputField.stringValue = ""
            inputField.placeholderAttributedString = NSAttributedString(
                string: "  ↑↓ select · enter confirm · esc cancel",
                attributes: [.font: theme.font, .foregroundColor: theme.textDim])
        } else {
            let arg = String(parts[1]).trimmingCharacters(in: .whitespaces).lowercased()
            let resolved = Self.modelAliases.first(where: { $0.alias == arg })?.full ?? arg
            applyModel(resolved)
        }
        scrollToBottom()
    }

    private func renderModelPicker() {
        let t = theme
        guard let storage = textView.textStorage else { return }
        let len = storage.length
        if len > modelPickerStartLocation {
            storage.deleteCharacters(in: NSRange(location: modelPickerStartLocation, length: len - modelPickerStartLocation))
        }
        let info = NSMutableAttributedString()
        info.append(NSAttributedString(string: "  select model\n\n",
            attributes: [.font: t.fontBold, .foregroundColor: t.accentColor]))
        for (i, m) in Self.modelAliases.enumerated() {
            let isSelected = i == modelPickerIndex
            let cursor = isSelected ? "→ " : "  "
            let primaryAttr: [NSAttributedString.Key: Any] = isSelected
                ? [.font: t.fontBold, .foregroundColor: t.textPrimary]
                : [.font: t.font, .foregroundColor: t.textDim]
            let dimAttr: [NSAttributedString.Key: Any] = isSelected
                ? [.font: t.font, .foregroundColor: t.accentColor]
                : [.font: t.font, .foregroundColor: t.textDim]
            let descAttr: [NSAttributedString.Key: Any] = isSelected
                ? [.font: t.font, .foregroundColor: t.textPrimary]
                : [.font: t.font, .foregroundColor: t.textDim]
            let paddedAlias = m.alias.padding(toLength: 8, withPad: " ", startingAt: 0)
            let paddedFull  = m.full.padding(toLength: 28, withPad: " ", startingAt: 0)
            info.append(NSAttributedString(string: "  \(cursor)\(paddedAlias)", attributes: primaryAttr))
            info.append(NSAttributedString(string: "\(paddedFull)", attributes: dimAttr))
            info.append(NSAttributedString(string: "\(m.desc)\n", attributes: descAttr))
        }
        storage.append(info)
        scrollToBottom()
    }

    private func modelPickerMove(_ delta: Int) {
        guard modelPickerActive else { return }
        modelPickerIndex = (modelPickerIndex + delta + Self.modelAliases.count) % Self.modelAliases.count
        renderModelPicker()
    }

    private func confirmModelPicker() {
        guard modelPickerActive else { return }
        modelPickerActive = false
        let chosen = Self.modelAliases[modelPickerIndex].full
        let len = textView.textStorage?.length ?? 0
        if len > modelPickerStartLocation {
            textView.textStorage?.deleteCharacters(in: NSRange(location: modelPickerStartLocation, length: len - modelPickerStartLocation))
        }
        applyModel(chosen)
        updatePlaceholder()
        scrollToBottom()
    }

    private func cancelModelPicker() {
        guard modelPickerActive else { return }
        modelPickerActive = false
        let len = textView.textStorage?.length ?? 0
        if len > modelPickerStartLocation {
            textView.textStorage?.deleteCharacters(in: NSRange(location: modelPickerStartLocation, length: len - modelPickerStartLocation))
        }
        updatePlaceholder()
        scrollToBottom()
    }

    private func applyModel(_ resolved: String) {
        currentModel = resolved
        onModelChange?(resolved)
        textView.textStorage?.append(NSAttributedString(
            string: "  switching to \(resolved)…\n",
            attributes: [.font: theme.font, .foregroundColor: theme.textDim]))
    }

    private func showMCPServers() {
        let t = theme
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var mcpServers: [(name: String, detail: String)] = []

        let searchPaths = [
            "\(home)/.claude.json",
            "\(home)/.claude/settings.json",
            "\(home)/.claude/settings.local.json",
        ]
        for path in searchPaths {
            guard let data = FileManager.default.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = json["mcpServers"] as? [String: Any] else { continue }
            for (name, cfg) in servers.sorted(by: { $0.key < $1.key }) {
                guard !mcpServers.contains(where: { $0.name == name }) else { continue }
                let d = cfg as? [String: Any]
                let detail: String
                if let url = d?["url"] as? String {
                    detail = url
                } else {
                    let cmd = d?["command"] as? String ?? "?"
                    let args = (d?["args"] as? [String] ?? []).joined(separator: " ")
                    detail = args.isEmpty ? cmd : "\(cmd) \(args)"
                }
                mcpServers.append((name, detail))
            }
        }

        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: "  MCP servers\n",
            attributes: [.font: t.fontBold, .foregroundColor: t.accentColor]))
        if mcpServers.isEmpty {
            out.append(NSAttributedString(string: "  none configured\n",
                attributes: [.font: t.font, .foregroundColor: t.textDim]))
        } else {
            for s in mcpServers {
                out.append(NSAttributedString(string: "  \(s.name)\n", attributes: [.font: t.fontBold, .foregroundColor: t.textPrimary]))
                out.append(NSAttributedString(string: "  \(s.detail)\n", attributes: [.font: t.font, .foregroundColor: t.textDim]))
            }
        }
        textView.textStorage?.append(out)
        scrollToBottom()
    }

    // MARK: - Append Methods

    private var messageSpacing: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = 8
        return p
    }

    private func ensureNewline() {
        if let storage = textView.textStorage, storage.length > 0 {
            if !storage.string.hasSuffix("\n") {
                storage.append(NSAttributedString(string: "\n"))
            }
        }
    }

    func appendUser(_ text: String) {
        let t = theme
        ensureNewline()
        let para = messageSpacing
        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(string: "> ", attributes: [
            .font: t.fontBold, .foregroundColor: t.accentColor, .paragraphStyle: para
        ]))
        attributed.append(NSAttributedString(string: "\(text)\n", attributes: [
            .font: t.fontBold, .foregroundColor: t.textPrimary, .paragraphStyle: para
        ]))
        textView.textStorage?.append(attributed)
        scrollToBottom()
    }

    func appendStreamingText(_ text: String) {
        stopStatusCycling()
        var cleaned = text
        if currentAssistantText.isEmpty {
            cleaned = cleaned.replacingOccurrences(of: "^\n+", with: "", options: .regularExpression)
        }
        currentAssistantText += cleaned
        if !cleaned.isEmpty {
            textView.textStorage?.append(renderMarkdown(cleaned))
            scrollToBottom()
        }
    }

    func endStreaming() {
        if isStreaming {
            isStreaming = false
            if !currentAssistantText.isEmpty {
                lastAssistantText = currentAssistantText
            }
            currentAssistantText = ""
        }
    }

    func appendError(_ text: String) {
        let t = theme
        textView.textStorage?.append(NSAttributedString(string: text + "\n", attributes: [
            .font: t.font, .foregroundColor: t.errorColor
        ]))
        scrollToBottom()
    }

    func appendToolUse(toolName: String, summary: String) {
        let t = theme
        stopStatusCycling()
        endStreaming()
        let block = NSMutableAttributedString()
        block.append(NSAttributedString(string: "  \(toolName.uppercased()) ", attributes: [
            .font: t.fontBold, .foregroundColor: t.accentColor
        ]))
        block.append(NSAttributedString(string: "\(summary)\n", attributes: [
            .font: t.font, .foregroundColor: t.textDim
        ]))
        textView.textStorage?.append(block)
        scrollToBottom()
    }

    func appendToolResult(summary: String, isError: Bool) {
        let t = theme
        let color = isError ? t.errorColor : t.successColor
        let prefix = isError ? "  FAIL " : "  DONE "
        let block = NSMutableAttributedString()
        block.append(NSAttributedString(string: prefix, attributes: [
            .font: t.fontBold, .foregroundColor: color
        ]))
        block.append(NSAttributedString(string: "\(summary.isEmpty ? "" : summary)\n", attributes: [
            .font: t.font, .foregroundColor: t.textDim
        ]))
        textView.textStorage?.append(block)
        scrollToBottom()
    }

    func replayHistory(_ messages: [AgentMessage]) {
        let t = theme
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        for msg in messages {
            switch msg.role {
            case .user:
                appendUser(msg.text)
            case .assistant:
                textView.textStorage?.append(renderMarkdown(msg.text + "\n"))
            case .error:
                appendError(msg.text)
            case .toolUse:
                textView.textStorage?.append(NSAttributedString(string: "  \(msg.text)\n", attributes: [
                    .font: t.font, .foregroundColor: t.accentColor
                ]))
            case .toolResult:
                let isErr = msg.text.hasPrefix("ERROR:")
                textView.textStorage?.append(NSAttributedString(string: "  \(msg.text)\n", attributes: [
                    .font: t.font, .foregroundColor: isErr ? t.errorColor : t.successColor
                ]))
            }
        }
        scrollToBottom()
    }

    private func scrollToBottom() {
        textView.scrollToEndOfDocument(nil)
    }

    // MARK: - Markdown Rendering

    private func renderMarkdown(_ text: String) -> NSAttributedString {
        let t = theme
        let result = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        var inCodeBlock = false
        var codeBlockLang = ""
        var codeLines: [String] = []

        for (i, line) in lines.enumerated() {
            let suffix = i < lines.count - 1 ? "\n" : ""

            if line.hasPrefix("```") {
                if inCodeBlock {
                    let codeText = codeLines.joined(separator: "\n")
                    let codeFont = NSFont.monospacedSystemFont(ofSize: t.font.pointSize - 1, weight: .regular)
                    result.append(NSAttributedString(string: codeText + "\n", attributes: [
                        .font: codeFont, .foregroundColor: t.textPrimary, .backgroundColor: t.inputBg
                    ]))
                    inCodeBlock = false
                    codeLines = []
                } else {
                    inCodeBlock = true
                    codeBlockLang = String(line.dropFirst(3))
                }
                continue
            }

            if inCodeBlock {
                codeLines.append(line)
                continue
            }

            if line.hasPrefix("### ") {
                result.append(NSAttributedString(string: String(line.dropFirst(4)) + suffix, attributes: [
                    .font: NSFont.systemFont(ofSize: t.font.pointSize, weight: .bold), .foregroundColor: t.accentColor
                ]))
            } else if line.hasPrefix("## ") {
                result.append(NSAttributedString(string: String(line.dropFirst(3)) + suffix, attributes: [
                    .font: NSFont.systemFont(ofSize: t.font.pointSize + 1, weight: .bold), .foregroundColor: t.accentColor
                ]))
            } else if line.hasPrefix("# ") {
                result.append(NSAttributedString(string: String(line.dropFirst(2)) + suffix, attributes: [
                    .font: NSFont.systemFont(ofSize: t.font.pointSize + 2, weight: .bold), .foregroundColor: t.accentColor
                ]))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let content = String(line.dropFirst(2))
                result.append(NSAttributedString(string: "  \u{2022} ", attributes: [
                    .font: t.font, .foregroundColor: t.accentColor
                ]))
                result.append(renderInlineMarkdown(content + suffix, theme: t))
            } else {
                result.append(renderInlineMarkdown(line + suffix, theme: t))
            }
        }

        if inCodeBlock && !codeLines.isEmpty {
            let codeText = codeLines.joined(separator: "\n")
            let codeFont = NSFont.monospacedSystemFont(ofSize: t.font.pointSize - 1, weight: .regular)
            result.append(NSAttributedString(string: codeText + "\n", attributes: [
                .font: codeFont, .foregroundColor: t.textPrimary, .backgroundColor: t.inputBg
            ]))
        }

        return result
    }

    private func renderInlineMarkdown(_ text: String, theme t: PopoverTheme) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var i = text.startIndex

        while i < text.endIndex {
            if text[i] == "`" {
                let afterTick = text.index(after: i)
                if afterTick < text.endIndex, let closeIdx = text[afterTick...].firstIndex(of: "`") {
                    let code = String(text[afterTick..<closeIdx])
                    let codeFont = NSFont.monospacedSystemFont(ofSize: t.font.pointSize - 0.5, weight: .regular)
                    result.append(NSAttributedString(string: code, attributes: [
                        .font: codeFont, .foregroundColor: t.accentColor, .backgroundColor: t.inputBg
                    ]))
                    i = text.index(after: closeIdx)
                    continue
                }
            }
            if text[i] == "*",
               text.index(after: i) < text.endIndex, text[text.index(after: i)] == "*" {
                let start = text.index(i, offsetBy: 2)
                if start < text.endIndex, let range = text.range(of: "**", range: start..<text.endIndex) {
                    let bold = String(text[start..<range.lowerBound])
                    result.append(NSAttributedString(string: bold, attributes: [
                        .font: t.fontBold, .foregroundColor: t.textPrimary
                    ]))
                    i = range.upperBound
                    continue
                }
            }
            if text[i] == "[" {
                let afterBracket = text.index(after: i)
                if afterBracket < text.endIndex,
                   let closeBracket = text[afterBracket...].firstIndex(of: "]") {
                    let parenStart = text.index(after: closeBracket)
                    if parenStart < text.endIndex && text[parenStart] == "(" {
                        let afterParen = text.index(after: parenStart)
                        if afterParen < text.endIndex,
                           let closeParen = text[afterParen...].firstIndex(of: ")") {
                            let linkText = String(text[afterBracket..<closeBracket])
                            let urlStr = String(text[afterParen..<closeParen])
                            var attrs: [NSAttributedString.Key: Any] = [
                                .font: t.font,
                                .foregroundColor: t.accentColor,
                                .underlineStyle: NSUnderlineStyle.single.rawValue
                            ]
                            if let url = URL(string: urlStr) {
                                attrs[.link] = url
                                attrs[.cursor] = NSCursor.pointingHand
                            }
                            result.append(NSAttributedString(string: linkText, attributes: attrs))
                            i = text.index(after: closeParen)
                            continue
                        }
                    }
                }
            }
            if text[i] == "h" {
                let remaining = String(text[i...])
                if remaining.hasPrefix("https://") || remaining.hasPrefix("http://") {
                    var j = i
                    while j < text.endIndex && !text[j].isWhitespace && text[j] != ")" && text[j] != ">" {
                        j = text.index(after: j)
                    }
                    let urlStr = String(text[i..<j])
                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: t.font,
                        .foregroundColor: t.accentColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ]
                    if let url = URL(string: urlStr) {
                        attrs[.link] = url
                    }
                    result.append(NSAttributedString(string: urlStr, attributes: attrs))
                    i = j
                    continue
                }
            }
            result.append(NSAttributedString(string: String(text[i]), attributes: [
                .font: t.font, .foregroundColor: t.textPrimary
            ]))
            i = text.index(after: i)
        }
        return result
    }
}
