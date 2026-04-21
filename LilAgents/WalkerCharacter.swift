import AVFoundation
import AppKit
import RiveRuntime

private class ResizeHandleView: NSView {
    private var startWindowFrame: NSRect = .zero
    private var startMouseLocation: NSPoint = .zero

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.25).cgColor)
        let dotSize: CGFloat = 2
        let gap: CGFloat = 3
        for i in 0..<3 {
            let offset = CGFloat(i) * (dotSize + gap)
            let x = bounds.maxX - 4 - offset
            let y = bounds.minY + 4 + offset
            ctx.fillEllipse(in: CGRect(x: x - dotSize/2, y: y - dotSize/2, width: dotSize, height: dotSize))
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window = window else { return }
        startWindowFrame = window.frame
        startMouseLocation = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window = window else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - startMouseLocation.x
        let dy = current.y - startMouseLocation.y
        var frame = startWindowFrame
        frame.size.width = max(300, frame.size.width + dx)
        let newHeight = max(200, frame.size.height - dy)
        frame.origin.y = frame.origin.y + frame.size.height - newHeight
        frame.size.height = newHeight
        window.setFrame(frame, display: true)
    }
}

enum CharacterSize: String, CaseIterable {
    case large, medium, small
    var height: CGFloat {
        switch self {
        case .large: return 280
        case .medium: return 210
        case .small: return 140
        }
    }
    var displayName: String {
        switch self {
        case .large: return "Large"
        case .medium: return "Medium"
        case .small: return "Small"
        }
    }
}

enum CatAnimationState: Equatable {
    case idle
    case focusing       // Popover open — Fokus_lvl_1
    case questioning    // User just sent a message — Fokus_Transision 2
    case thinking       // Claude is working — Fokus_lvl_2
    case deepThinking   // Claude busy > 5 min — Fokus_lvl_3
    case drinkingCoffee // 30 min session
    case crying         // 2 hr session
    case sleepy         // 20 min idle
    case sleeping       // 30 min idle
    case done
}

class WalkerCharacter {
    let videoName: String
    let name: String

    // Rive support
    var riveName: String?
    var riveViewModel: RiveViewModel?
    var riveContentView: NSView?
    private var currentCatState: CatAnimationState = .idle
    private var idleCycleTimer: Timer?
    private static let idleVariants = ["Idle", "Idle 2", "Idle 3"]

    // Activity tracking
    private var lastActivityTime: CFTimeInterval = CACurrentMediaTime()
    private var sessionStartTime: CFTimeInterval = CACurrentMediaTime()
    private var agentBusyStartTime: CFTimeInterval = 0
    private let sleepyAfterSeconds:      CFTimeInterval = 2400  // 40 min idle
    private let sleepAfterSeconds:       CFTimeInterval = 3600  // 60 min idle
    private let deepThinkAfterSeconds:   CFTimeInterval = 300   // 5 min busy
    private let coffeeAfterSeconds:      CFTimeInterval = 1800  // 30 min session
    private let cryAfterSeconds:         CFTimeInterval = 7200  // 2 hr session

    var catColorAnimation: String {
        get { UserDefaults.standard.string(forKey: "\(name)CatColor") ?? "gray" }
        set { UserDefaults.standard.set(newValue, forKey: "\(name)CatColor") }
    }

    func applyCatColor(_ animName: String) {
        catColorAnimation = animName
        guard let rvm = riveViewModel else { return }
        // Bypass triggerCatAnimation's same-state guard — apply the new color immediately
        // by re-running the current body animation with the updated color fill.
        let bodyAnim: String
        switch currentCatState {
        case .idle, .done:    bodyAnim = Self.idleVariants.randomElement() ?? "Idle"
        case .focusing:       bodyAnim = "Fokus_lvl_1"
        case .questioning:    bodyAnim = "Fokus_Transision 2"
        case .thinking:       bodyAnim = "Fokus_lvl_2"
        case .deepThinking:   bodyAnim = "Fokus_lvl_3 "
        case .drinkingCoffee: bodyAnim = "Break"
        case .crying:         bodyAnim = "crying"
        case .sleepy:         bodyAnim = "Sleepy"
        case .sleeping:       bodyAnim = "Sleep"
        }
        playBodyAnimation(bodyAnim, rvm: rvm)
    }

    var provider: AgentProvider {
        get {
            let raw = UserDefaults.standard.string(forKey: "\(name)Provider") ?? "claude"
            return AgentProvider(rawValue: raw) ?? .claude
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "\(name)Provider")
        }
    }
    var claudeModel: String {
        get { UserDefaults.standard.string(forKey: "\(name)ClaudeModel") ?? "claude-sonnet-4-6" }
        set { UserDefaults.standard.set(newValue, forKey: "\(name)ClaudeModel") }
    }

    var geminiModel: String {
        get { UserDefaults.standard.string(forKey: "\(name)GeminiModel") ?? "gemini-2.5-flash" }
        set { UserDefaults.standard.set(newValue, forKey: "\(name)GeminiModel") }
    }

    /// Model identifier for the currently selected provider (if any).
    var currentProviderModel: String {
        switch provider {
        case .claude: return claudeModel
        case .gemini: return geminiModel
        default: return ""
        }
    }

    func setModelForCurrentProvider(_ full: String) {
        switch provider {
        case .claude: claudeModel = full
        case .gemini: geminiModel = full
        default: return
        }
    }

    private func makeSession() -> any AgentSession {
        let s = provider.createSession()
        if let cs = s as? ClaudeSession { cs.model = claudeModel }
        if let gs = s as? GeminiSession { gs.model = geminiModel }
        return s
    }

    var size: CharacterSize {
        get {
            let raw = UserDefaults.standard.string(forKey: "\(name)Size") ?? "big"
            return CharacterSize(rawValue: raw) ?? .large
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "\(name)Size")
            updateDimensions()
        }
    }
    var window: NSWindow!
    private var globalMouseMonitor: Any?
    private var lastPassThroughCheck: CFTimeInterval = 0
    var playerLayer: AVPlayerLayer!
    var queuePlayer: AVQueuePlayer!
    var looper: AVPlayerLooper!

    let videoWidth: CGFloat = 1080
    let videoHeight: CGFloat = 1920
    private(set) var displayHeight: CGFloat = 200
    var displayWidth: CGFloat { displayHeight * (videoWidth / videoHeight) }

    let videoDuration: CFTimeInterval = 10.0
    var accelStart: CFTimeInterval = 3.0
    var fullSpeedStart: CFTimeInterval = 3.75
    var decelStart: CFTimeInterval = 7.5
    var walkStop: CFTimeInterval = 8.25
    var walkAmountRange: ClosedRange<CGFloat> = 0.25...0.5
    var yOffset: CGFloat = 0
    var flipXOffset: CGFloat = 0
    var characterColor: NSColor = .gray

    var playCount = 0
    var walkStartTime: CFTimeInterval = 0
    var positionProgress: CGFloat = 0.0
    var isWalking = false
    var isPaused = true
    var pauseEndTime: CFTimeInterval = 0
    var goingRight = true
    var walkStartPos: CGFloat = 0.0
    var walkEndPos: CGFloat = 0.0
    var currentTravelDistance: CGFloat = 500.0
    var walkStartPixel: CGFloat = 0.0
    var walkEndPixel: CGFloat = 0.0

    var walksEnabled = true
    var isOnboarding = false
    private var welcomeShownInPopover = false
    var currentInstallFlow: InstallFlow?
    private weak var installButton: NSButton?
    private var clickCount = 0
    private var lastClickTime: CFTimeInterval = 0
    private var isQuitting = false
    var isIdleForPopover = false
    var popoverWindow: NSWindow?
    var terminalView: TerminalView?
    var session: (any AgentSession)?
    var clickOutsideMonitor: Any?
    var escapeKeyMonitor: Any?
    var currentStreamingText = ""
    weak var controller: LilAgentsController?
    var themeOverride: PopoverTheme?
    var isAgentBusy: Bool { session?.isBusy ?? false }
    var thinkingBubbleWindow: NSWindow?
    private(set) var isManuallyVisible = true
    private var environmentHiddenAt: CFTimeInterval?
    private var wasPopoverVisibleBeforeEnvironmentHide = false
    private var wasBubbleVisibleBeforeEnvironmentHide = false

    init(videoName: String = "", name: String, riveName: String? = nil) {
        self.videoName = videoName
        self.name = name
        self.riveName = riveName
        self.displayHeight = size.height
    }

    // MARK: - Setup

    func updateDimensions() {
        displayHeight = size.height
        let newWidth = displayWidth
        let newHeight = displayHeight

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let window = self.window else { return }
            let oldFrame = window.frame
            let newFrame = CGRect(x: oldFrame.origin.x, y: oldFrame.origin.y, width: newWidth, height: newHeight)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            window.setFrame(newFrame, display: true)
            if let rv = self.riveContentView {
                rv.frame = CGRect(x: 0, y: 0, width: newWidth, height: newHeight)
            } else {
                self.playerLayer.frame = CGRect(x: 0, y: 0, width: newWidth, height: newHeight)
            }
            if let hostView = window.contentView {
                hostView.frame = CGRect(x: 0, y: 0, width: newWidth, height: newHeight)
            }
            CATransaction.commit()

            self.updateFlip()
        }
    }

    func setup() {
        if let riveName = riveName {
            setupRive(fileName: riveName)
        } else {
            setupVideo()
        }
    }

    private func setupVideo() {
        guard let videoURL = Bundle.main.url(forResource: videoName, withExtension: "mov") else {
            print("Video \(videoName) not found")
            return
        }

        let asset = AVAsset(url: videoURL)
        queuePlayer = AVQueuePlayer()
        looper = AVPlayerLooper(player: queuePlayer, templateItem: AVPlayerItem(asset: asset))

        playerLayer = AVPlayerLayer(player: queuePlayer)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.clear.cgColor
        playerLayer.frame = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)

        let screen = NSScreen.main!
        let dockTopY = screen.visibleFrame.origin.y
        let bottomPadding = displayHeight * 0.15
        let y = dockTopY - bottomPadding + yOffset

        let contentRect = CGRect(x: 0, y: y, width: displayWidth, height: displayHeight)
        window = makeCharacterWindow(contentRect: contentRect)

        let hostView = CharacterContentView(frame: CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight))
        hostView.character = self
        hostView.wantsLayer = true
        hostView.layer?.backgroundColor = NSColor.clear.cgColor
        hostView.layer?.addSublayer(playerLayer)

        window.contentView = hostView
        window.orderFrontRegardless()
    }

    private func setupRive(fileName: String) {
        let rvm = RiveViewModel(
            fileName: fileName,
            animationName: "App Launch",
            autoPlay: true
        )
        riveViewModel = rvm

        let screen = NSScreen.main!
        let dockTopY = screen.visibleFrame.origin.y
        let bottomPadding = displayHeight * 0.15
        let y = dockTopY - bottomPadding + yOffset

        let contentRect = CGRect(x: 0, y: y, width: displayWidth, height: displayHeight)
        window = makeCharacterWindow(contentRect: contentRect)

        let hostView = CharacterContentView(frame: CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight))
        hostView.character = self
        hostView.wantsLayer = true
        hostView.layer?.backgroundColor = NSColor.clear.cgColor

        // RiveView is NSView on macOS — connect it to the view model
        let rv = RiveView()
        rv.frame = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)
        rv.autoresizingMask = [.width, .height]
        rv.wantsLayer = true
        rv.layer?.backgroundColor = NSColor.clear.cgColor
        rvm.setView(rv)
        hostView.addSubview(rv)
        riveContentView = rv

        window.contentView = hostView
        window.orderFrontRegardless()

        // After App Launch finishes, hide fish, apply saved color, start idle cycling
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self, weak rvm] in
            if let colorAnim = self?.catColorAnimation {
                rvm?.play(animationName: colorAnim)
            }
            self?.startIdleCycling()
        }
    }

    private func makeCharacterWindow(contentRect: CGRect) -> NSWindow {
        let win = NSWindow(
            contentRect: contentRect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = .statusBar
        win.ignoresMouseEvents = false
        win.collectionBehavior = [.canJoinAllSpaces, .stationary]
        return win
    }

    // MARK: - Cat Animation State

    func triggerCatAnimation(_ state: CatAnimationState) {
        guard let rvm = riveViewModel, state != currentCatState else { return }
        currentCatState = state

        switch state {
        case .idle, .done:
            startIdleCycling()
        case .focusing:
            idleCycleTimer?.invalidate(); idleCycleTimer = nil
            playBodyAnimation("Fokus_lvl_1", rvm: rvm)
        case .questioning:
            idleCycleTimer?.invalidate(); idleCycleTimer = nil
            playBodyAnimation("Fokus_Transision 2", rvm: rvm)
        case .thinking:
            idleCycleTimer?.invalidate(); idleCycleTimer = nil
            playBodyAnimation("Fokus_lvl_2", rvm: rvm)
        case .deepThinking:
            idleCycleTimer?.invalidate(); idleCycleTimer = nil
            playBodyAnimation("Fokus_lvl_3 ", rvm: rvm)
        case .drinkingCoffee:
            idleCycleTimer?.invalidate(); idleCycleTimer = nil
            playBodyAnimation("Break", rvm: rvm)
        case .crying:
            idleCycleTimer?.invalidate(); idleCycleTimer = nil
            playBodyAnimation("crying", rvm: rvm)
        case .sleepy:
            idleCycleTimer?.invalidate(); idleCycleTimer = nil
            playBodyAnimation("Sleepy", rvm: rvm)
        case .sleeping:
            idleCycleTimer?.invalidate(); idleCycleTimer = nil
            playBodyAnimation("Sleep", rvm: rvm)
        }
    }

    // Synchronously advance the color animation by 1ms so its fill keyframes are written to
    // the artboard, then immediately start the body animation looping. The body animation
    // does not key fill colors, so the artboard retains the color values from the color anim.
    private func playBodyAnimation(_ bodyAnim: String, rvm: RiveViewModel) {
        if let model = rvm.riveModel {
            try? model.setAnimation(catColorAnimation)
            if let anim = model.animation {
                let dur = Double(anim.effectiveDurationInSeconds())
                _ = anim.advance(by: dur > 0 ? dur : 0.1)
            }
        }
        rvm.play(animationName: bodyAnim, loop: .loop)
    }

    private func startIdleCycling() {
        idleCycleTimer?.invalidate()
        guard let rvm = riveViewModel else { return }
        let variant = Self.idleVariants.randomElement() ?? "Idle"
        playBodyAnimation(variant, rvm: rvm)
        let interval = Double.random(in: 8.0...14.0)
        idleCycleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self = self, self.currentCatState == .idle || self.currentCatState == .done else { return }
            self.currentCatState = .idle
            self.startIdleCycling()
        }
    }

    private func rivePlay() { riveViewModel?.play() }
    private func rivePause() { riveViewModel?.pause() }

    // MARK: - Visibility

    func setManuallyVisible(_ visible: Bool) {
        isManuallyVisible = visible
        if visible {
            if environmentHiddenAt == nil {
                window.orderFrontRegardless()
            }
        } else {
            if riveViewModel != nil { rivePause() } else { queuePlayer?.pause() }
            window.orderOut(nil)
            popoverWindow?.orderOut(nil)
            thinkingBubbleWindow?.orderOut(nil)
        }
    }

    func greetAfterReopen() {
        guard !isManuallyVisible else { return }
        setManuallyVisible(true)
        if riveViewModel != nil { rivePlay() }
        triggerCatAnimation(.idle)
        isQuitting = false
        clickCount = 0
        showingCompletion = true
        currentPhrase = "hi!"
        completionBubbleExpiry = CACurrentMediaTime() + 3.0
        showBubble(text: "hi!", isCompletion: true)
        playCompletionSound()
    }

    func hideForEnvironment() {
        guard environmentHiddenAt == nil else { return }

        environmentHiddenAt = CACurrentMediaTime()
        wasPopoverVisibleBeforeEnvironmentHide = popoverWindow?.isVisible ?? false
        wasBubbleVisibleBeforeEnvironmentHide = thinkingBubbleWindow?.isVisible ?? false

        if riveViewModel != nil { rivePause() } else { queuePlayer?.pause() }
        window.orderOut(nil)
        popoverWindow?.orderOut(nil)
        thinkingBubbleWindow?.orderOut(nil)
    }

    func showForEnvironmentIfNeeded() {
        guard let hiddenAt = environmentHiddenAt else { return }

        let hiddenDuration = CACurrentMediaTime() - hiddenAt
        environmentHiddenAt = nil
        walkStartTime += hiddenDuration
        pauseEndTime += hiddenDuration
        completionBubbleExpiry += hiddenDuration
        lastPhraseUpdate += hiddenDuration

        guard isManuallyVisible else { return }

        window.orderFrontRegardless()
        if riveViewModel != nil {
            rivePlay()
        } else if isWalking {
            queuePlayer?.play()
        }
        if isIdleForPopover && wasPopoverVisibleBeforeEnvironmentHide {
            updatePopoverPosition()
            popoverWindow?.orderFrontRegardless()
            popoverWindow?.makeFirstResponder(terminalView?.inputField)
        }

        if wasBubbleVisibleBeforeEnvironmentHide {
            updateThinkingBubble()
        }
    }

    // MARK: - Click Handling & Popover

    func handleClick() {
        guard !isQuitting else { return }

        let now = CACurrentMediaTime()
        if now - lastClickTime < 0.5 {
            clickCount += 1
        } else {
            clickCount = 1
        }
        lastClickTime = now

        if clickCount >= 3 {
            clickCount = 0
            triggerQuitSequence()
            return
        }

        lastActivityTime = now
        if isIdleForPopover {
            closePopover()
        } else {
            openPopover()
        }
    }

    private func triggerQuitSequence() {
        isQuitting = true
        if isIdleForPopover {
            popoverWindow?.orderOut(nil)
            isIdleForPopover = false
        }
        riveViewModel?.play(animationName: "angry")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.setManuallyVisible(false)
            self?.isQuitting = false
            self?.clickCount = 0
        }
    }

    private static let welcomeMessage = """
    # hey! i'm your kitty agent.

    i'm a little helper that helps you chat with AI coding assistants — AIs that can read the files in your project, write and edit the apps or websites you want to create, run commands on your computer, and answer any questions about what you're building.

    ### pick your AI

    do you prefer Anthropic, OpenAI, Google, or GitHub? i work with each of their coding AIs, so go with whichever you like. you can switch between them anytime by clicking the name at the top of this window:

    - **Claude** (by Anthropic)
    - **Codex** (by OpenAI)
    - **Gemini** (by Google)
    - **GitHub Copilot**
    - **OpenCode**
    - **OpenClaw** (connect to your own AI server)

    ### a note on cost

    most of these AIs aren't free to use. the companies charge for the AI's "thinking time" — measured in things called **tokens**, which are just bite-size chunks of text (a short message might be 20–50 tokens; a whole page of code a few hundred). you're billed a tiny fraction of a cent per token.

    rough idea of what each one costs:

    - **Claude**: $20/month for Claude Pro (easiest for regular use), or pay-per-use
    - **Codex** (OpenAI): pay-per-use, usually a few cents per message
    - **Gemini** (Google): has a free tier that's enough for casual use

    you'll set up billing with whichever company you pick when you make an account during install.

    ### getting started

    see the **install** button up top next to the hammer? click it and i'll walk you through everything. i'll open the sign-up page, wait for you to make an account, and then install the AI for you right here.

    (works for Claude, Codex, and Gemini right now. for the others, you can find install steps on each one's website.)

    ### tips

    - click the hammer icon above for shortcuts (like clearing the chat)
    - press esc while i'm working to stop what i'm doing
    - triple-click me to quit

    ---

    go ahead — type below and press enter.
    """

    func openPopover() {
        if let siblings = controller?.characters {
            for sibling in siblings where sibling !== self && sibling.isIdleForPopover {
                sibling.closePopover()
            }
        }

        isIdleForPopover = true
        isWalking = false
        isPaused = true
        lastActivityTime = CACurrentMediaTime()

        if riveViewModel != nil {
            triggerCatAnimation(.focusing)
            rivePlay()
        } else {
            queuePlayer?.pause()
            queuePlayer?.seek(to: .zero)
        }

        showingCompletion = false
        hideBubble()

        if session == nil {
            let newSession = makeSession()
            session = newSession
            wireSession(newSession)
            newSession.start()
        } else if let s = session, !s.isRunning, s.history.isEmpty {
            // Session exists but never connected (e.g. launch failed on a previous
            // open). Discard it and try fresh so the user isn't stuck on the error.
            session?.terminate()
            let newSession = makeSession()
            session = newSession
            wireSession(newSession)
            newSession.start()
        }

        if popoverWindow == nil {
            createPopoverWindow()
        }

        if let terminal = terminalView, let session = session, !session.history.isEmpty {
            terminal.resetState()
            if isOnboarding {
                terminal.appendStreamingText(Self.welcomeMessage)
                terminal.endStreaming()
            }
            for msg in session.history {
                switch msg.role {
                case .user: terminal.appendUser(msg.text)
                case .assistant: terminal.appendStreamingText(msg.text + "\n"); terminal.endStreaming()
                case .notice: terminal.appendStreamingText("\n" + msg.text + "\n"); terminal.endStreaming()
                case .error: terminal.appendError(msg.text)
                case .toolUse, .toolResult: break
                }
            }
            welcomeShownInPopover = true
            DispatchQueue.main.async { [weak self] in
                self?.terminalView?.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            }
        } else if isOnboarding && !welcomeShownInPopover {
            terminalView?.appendStreamingText(Self.welcomeMessage)
            terminalView?.endStreaming()
            DispatchQueue.main.async { [weak self] in
                self?.terminalView?.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            }
            welcomeShownInPopover = true
        }

        updatePopoverPosition()
        popoverWindow?.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self, let win = self.popoverWindow else { return }
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            win.makeFirstResponder(self.terminalView?.inputField)
        }

        removeEventMonitors()

        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, event.keyCode == 53 else { return event }
            if self.isAgentBusy {
                self.session?.cancelCurrentTurn()
                self.terminalView?.endStreaming()
                self.terminalView?.appendError("  cancelled\n")
                self.agentBusyStartTime = 0
                self.triggerCatAnimation(.focusing)
            } else {
                self.closePopover()
            }
            return nil
        }
    }

    func closePopover() {
        guard isIdleForPopover else { return }

        popoverWindow?.orderOut(nil)
        removeEventMonitors()

        isIdleForPopover = false

        if showingCompletion {
            completionBubbleExpiry = CACurrentMediaTime() + 3.0
            showBubble(text: currentPhrase, isCompletion: true)
        } else if isAgentBusy {
            currentPhrase = ""
            lastPhraseUpdate = 0
            updateThinkingPhrase()
            showBubble(text: currentPhrase, isCompletion: false)
        }

        if riveViewModel != nil {
            if !isAgentBusy {
                triggerCatAnimation(.idle)
            }
            // if busy, update() will keep/set the correct thinking animation
            rivePlay()
        }

        let delay = Double.random(in: 2.0...5.0)
        pauseEndTime = CACurrentMediaTime() + delay
    }

    private func removeEventMonitors() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyMonitor = nil
        }
    }

    var resolvedTheme: PopoverTheme {
        (themeOverride ?? PopoverTheme.current).withCharacterColor(characterColor).withCustomFont()
    }

    func createPopoverWindow() {
        let t = resolvedTheme
        let popoverWidth: CGFloat = 420
        let popoverHeight: CGFloat = 310

        let win = KeyableWindow(
            contentRect: CGRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .normal
        win.isMovable = false
        win.collectionBehavior = [.moveToActiveSpace, .stationary]
        let brightness = t.popoverBg.redComponent * 0.299 + t.popoverBg.greenComponent * 0.587 + t.popoverBg.blueComponent * 0.114
        win.appearance = NSAppearance(named: brightness < 0.5 ? .darkAqua : .aqua)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight))
        container.wantsLayer = true
        container.layer?.backgroundColor = t.popoverBg.cgColor
        container.layer?.cornerRadius = t.popoverCornerRadius
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = t.popoverBorderWidth
        container.layer?.borderColor = t.popoverBorder.cgColor
        container.autoresizingMask = [.width, .height]

        let titleBar = NSView(frame: NSRect(x: 0, y: popoverHeight - 28, width: popoverWidth, height: 28))
        titleBar.wantsLayer = true
        titleBar.layer?.backgroundColor = t.titleBarBg.cgColor
        container.addSubview(titleBar)

        let titleLabel = NSTextField(labelWithString: t.titleString(for: provider))
        titleLabel.font = t.titleFont
        titleLabel.textColor = t.titleText
        titleLabel.sizeToFit()
        titleLabel.frame.origin = NSPoint(x: 12, y: 6)
        titleBar.addSubview(titleLabel)

        let arrowBtn = NSButton(frame: NSRect(x: titleLabel.frame.maxX + 2, y: 5, width: 16, height: 16))
        arrowBtn.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Switch provider")
        arrowBtn.imageScaling = .scaleProportionallyDown
        arrowBtn.bezelStyle = .inline
        arrowBtn.isBordered = false
        arrowBtn.contentTintColor = t.titleText.withAlphaComponent(0.75)
        arrowBtn.target = self
        arrowBtn.action = #selector(showProviderMenu(_:))
        titleBar.addSubview(arrowBtn)

        let clickArea = NSButton(frame: NSRect(x: 0, y: 0, width: arrowBtn.frame.maxX + 4, height: 28))
        clickArea.isTransparent = true
        clickArea.target = self
        clickArea.action = #selector(showProviderMenu(_:))
        titleBar.addSubview(clickArea)

        if provider.supportsInstallFlow {
            let installTitle = "install \(provider.displayName)"
            let installFont = NSFont.systemFont(ofSize: 11, weight: .medium)
            let installTextWidth = (installTitle as NSString).size(withAttributes: [.font: installFont]).width
            let installBtnWidth = ceil(installTextWidth) + 18
            let installBtn = NSButton(frame: NSRect(x: popoverWidth - 68 - installBtnWidth - 6, y: 4, width: installBtnWidth, height: 20))
            installBtn.attributedTitle = NSAttributedString(string: installTitle, attributes: [
                .font: installFont,
                .foregroundColor: t.accentColor
            ])
            installBtn.bezelStyle = .inline
            installBtn.isBordered = true
            installBtn.target = self
            installBtn.action = #selector(startInstallFlow)
            titleBar.addSubview(installBtn)
            self.installButton = installBtn
        }

        if provider.showsHammerMenu {
            let toolsBtn = NSButton(frame: NSRect(x: popoverWidth - 68, y: 5, width: 16, height: 16))
            toolsBtn.image = NSImage(systemSymbolName: "hammer", accessibilityDescription: "Commands")
            toolsBtn.imageScaling = .scaleProportionallyDown
            toolsBtn.bezelStyle = .inline
            toolsBtn.isBordered = false
            toolsBtn.contentTintColor = t.titleText.withAlphaComponent(0.75)
            toolsBtn.target = self
            toolsBtn.action = #selector(showCommandsMenu(_:))
            titleBar.addSubview(toolsBtn)
        }

        let refreshBtn = NSButton(frame: NSRect(x: popoverWidth - 48, y: 5, width: 16, height: 16))
        refreshBtn.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshBtn.imageScaling = .scaleProportionallyDown
        refreshBtn.bezelStyle = .inline
        refreshBtn.isBordered = false
        refreshBtn.contentTintColor = t.titleText.withAlphaComponent(0.75)
        refreshBtn.target = self
        refreshBtn.action = #selector(refreshSessionFromButton)
        titleBar.addSubview(refreshBtn)

        let copyBtn = NSButton(frame: NSRect(x: popoverWidth - 28, y: 5, width: 16, height: 16))
        copyBtn.image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "Copy")
        copyBtn.imageScaling = .scaleProportionallyDown
        copyBtn.bezelStyle = .inline
        copyBtn.isBordered = false
        copyBtn.contentTintColor = t.titleText.withAlphaComponent(0.75)
        copyBtn.target = self
        copyBtn.action = #selector(copyLastResponseFromButton)
        titleBar.addSubview(copyBtn)

        let sep = NSView(frame: NSRect(x: 0, y: popoverHeight - 29, width: popoverWidth, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = t.separatorColor.cgColor
        container.addSubview(sep)

        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight - 29))
        terminal.characterColor = characterColor
        terminal.themeOverride = themeOverride
        terminal.provider = provider
        terminal.currentModel = claudeModel
        terminal.autoresizingMask = [.width, .height]
        terminal.onSendMessage = { [weak self] message in
            guard let self = self else { return }
            self.lastActivityTime = CACurrentMediaTime()
            if let flow = self.currentInstallFlow, flow.handleUserInput(message) {
                return
            }
            self.agentBusyStartTime = 0
            self.currentCatState = .focusing  // reset so .thinking always re-triggers below
            self.triggerCatAnimation(.thinking)
            if self.isOnboarding {
                self.isOnboarding = false
                self.controller?.completeOnboarding()
            }
            self.session?.send(message: message)
        }
        terminal.onClearRequested = { [weak self] in
            self?.resetSession()
        }
        terminal.onModelChange = { [weak self] model in
            guard let self = self else { return }
            self.claudeModel = model
            self.resetSession()
        }
        container.addSubview(terminal)

        let handleSize: CGFloat = 18
        let resizeHandle = ResizeHandleView(frame: NSRect(x: popoverWidth - handleSize, y: 0, width: handleSize, height: handleSize))
        resizeHandle.autoresizingMask = [.minXMargin, .maxYMargin]
        container.addSubview(resizeHandle)

        win.contentView = container
        popoverWindow = win
        terminalView = terminal
    }

    func resetSession() {
        session?.terminate()
        session = nil
        currentStreamingText = ""
        showingCompletion = false
        currentPhrase = ""
        completionBubbleExpiry = 0
        hideBubble()
        terminalView?.resetState()
        if isOnboarding {
            terminalView?.appendStreamingText(Self.welcomeMessage)
            terminalView?.endStreaming()
            DispatchQueue.main.async { [weak self] in
                self?.terminalView?.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            }
        } else {
            terminalView?.showSessionMessage()
        }
        let newSession = makeSession()
        session = newSession
        wireSession(newSession)
        newSession.start()
        triggerCatAnimation(.idle)
    }

    private func wireSession(_ session: any AgentSession) {
        session.onText = { [weak self] text in
            guard let self = self else { return }
            self.currentStreamingText += text
            self.terminalView?.appendStreamingText(text)
            if self.agentBusyStartTime == 0 {
                self.agentBusyStartTime = CACurrentMediaTime()
            }
        }

        session.onTurnComplete = { [weak self] in
            guard let self = self else { return }
            self.terminalView?.endStreaming()
            self.playCompletionSound()
            self.showCompletionBubble()
            self.agentBusyStartTime = 0
            self.lastActivityTime = CACurrentMediaTime()
            self.triggerCatAnimation(.done)
            // Return to idle after 3 s
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.triggerCatAnimation(.idle)
            }
        }

        session.onError = { [weak self] text in
            guard let self = self else { return }
            self.terminalView?.appendError(text)
            self.agentBusyStartTime = 0
            self.triggerCatAnimation(.idle)
        }

        session.onNotice = { [weak self] text in
            guard let self = self else { return }
            self.terminalView?.appendStreamingText("\n" + text + "\n")
            self.terminalView?.endStreaming()
            self.agentBusyStartTime = 0
            self.triggerCatAnimation(.idle)
        }

        session.onToolUse = { [weak self] toolName, input in
            guard let self = self else { return }
            let summary = self.formatToolInput(input)
            self.terminalView?.appendToolUse(toolName: toolName, summary: summary)
            if self.agentBusyStartTime == 0 {
                self.agentBusyStartTime = CACurrentMediaTime()
            }
        }

        session.onToolResult = { [weak self] summary, isError in
            self?.terminalView?.appendToolResult(summary: summary, isError: isError)
        }

        session.onProcessExit = { [weak self] in
            guard let self = self else { return }
            self.terminalView?.endStreaming()
            self.terminalView?.appendError("\(self.provider.displayName) session ended.")
            self.agentBusyStartTime = 0
            self.triggerCatAnimation(.idle)
        }

        session.onSessionReady = { }
    }

    @objc func showProviderMenu(_ sender: Any) {
        let menu = NSMenu()
        let menuFont = NSFont.systemFont(ofSize: 12, weight: .regular)
        for p in AgentProvider.allCases {
            let item = NSMenuItem(title: p.displayName, action: #selector(providerMenuItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.attributedTitle = NSAttributedString(string: p.displayName, attributes: [.font: menuFont])
            item.representedObject = p.rawValue
            if p == provider { item.state = .on }
            if !p.isAvailable { item.isEnabled = false }
            menu.addItem(item)
        }
        if let titleBar = popoverWindow?.contentView?.subviews.first(where: { $0.frame.origin.y > 0 && $0.frame.height == 28 }) {
            menu.popUp(positioning: nil, at: NSPoint(x: 10, y: 0), in: titleBar)
        }
    }

    @objc func providerMenuItemSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let newProvider = AgentProvider(rawValue: raw),
              newProvider != provider else { return }
        provider = newProvider
        currentInstallFlow?.cancel()
        currentInstallFlow = nil
        session?.terminate()
        session = nil
        popoverWindow?.orderOut(nil)
        popoverWindow = nil
        terminalView = nil
        welcomeShownInPopover = false
        thinkingBubbleWindow?.orderOut(nil)
        thinkingBubbleWindow = nil
        openPopover()
    }

    @objc func copyLastResponseFromButton() {
        terminalView?.handleSlashCommandPublic("/copy")
    }

    @objc func refreshSessionFromButton() {
        guard !isOnboarding else { return }
        resetSession()
    }

    @objc func startInstallFlow() {
        guard provider.supportsInstallFlow else { return }
        currentInstallFlow?.cancel()
        let flow = InstallFlow(provider: provider, character: self)
        currentInstallFlow = flow
        flow.start()
    }

    func retrySessionIfNeeded() {
        session?.terminate()
        session = nil
        let newSession = makeSession()
        session = newSession
        wireSession(newSession)
        newSession.start()
        // Keep the install button visible so the user can always re-run the flow
        // (paste a new API key, reinstall, etc.) without having to change providers.
        AgentProvider.detectAvailableProviders { }
    }

    @objc func showCommandsMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.font = NSFont.systemFont(ofSize: 13)

        let header = NSMenuItem(title: "Shortcuts", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let clearItem = NSMenuItem(title: "/clear  —  clear chat history", action: #selector(runCommandMenuItem(_:)), keyEquivalent: "")
        clearItem.representedObject = "/clear"
        clearItem.target = self
        menu.addItem(clearItem)

        let copyItem = NSMenuItem(title: "/copy  —  copy last response", action: #selector(runCommandMenuItem(_:)), keyEquivalent: "")
        copyItem.representedObject = "/copy"
        copyItem.target = self
        menu.addItem(copyItem)

        let models = provider.modelOptions
        if !models.isEmpty {
            let modelHeader = NSMenuItem(title: "switch model", action: nil, keyEquivalent: "")
            modelHeader.isEnabled = false
            menu.addItem(modelHeader)
            let currentFull = currentProviderModel
            for m in models {
                let isCurrent = currentFull == m.full
                let check = isCurrent ? "✓ " : "   "
                let item = NSMenuItem(title: "\(check)\(m.alias)  —  \(m.desc)", action: #selector(pickModelFromMenu(_:)), keyEquivalent: "")
                item.representedObject = m.full
                item.target = self
                item.indentationLevel = 1
                menu.addItem(item)
            }
        }

        if provider.supportsMCP {
            let mcpItem = NSMenuItem(title: "/mcp  —  list MCP servers", action: #selector(runCommandMenuItem(_:)), keyEquivalent: "")
            mcpItem.representedObject = "/mcp"
            mcpItem.target = self
            menu.addItem(mcpItem)
        }

        let pt = NSPoint(x: sender.frame.minX, y: sender.frame.minY - 2)
        menu.popUp(positioning: nil, at: pt, in: sender.superview)
    }

    @objc private func runCommandMenuItem(_ item: NSMenuItem) {
        guard let cmd = item.representedObject as? String else { return }
        terminalView?.handleSlashCommandPublic(cmd)
    }

    @objc private func pickModelFromMenu(_ item: NSMenuItem) {
        guard let full = item.representedObject as? String else { return }
        setModelForCurrentProvider(full)
        terminalView?.currentModel = full
        resetSession()
    }

    private func formatToolInput(_ input: [String: Any]) -> String {
        if let cmd = input["command"] as? String { return cmd }
        if let path = input["file_path"] as? String { return path }
        if let pattern = input["pattern"] as? String { return pattern }
        return input.keys.sorted().prefix(3).joined(separator: ", ")
    }

    func updatePopoverPosition() {
        guard let popover = popoverWindow, isIdleForPopover else { return }
        guard let screen = NSScreen.main else { return }

        let charFrame = window.frame
        let popoverSize = popover.frame.size
        var x = charFrame.midX - popoverSize.width / 2
        let y = charFrame.maxY - 15 - popoverSize.height * 0.20

        let screenFrame = screen.frame
        x = max(screenFrame.minX + 4, min(x, screenFrame.maxX - popoverSize.width - 4))
        let clampedY = min(y, screenFrame.maxY - popoverSize.height - 4)

        popover.setFrameOrigin(NSPoint(x: x, y: clampedY))
    }

    // MARK: - Thinking Bubble

    private static let thinkingPhrases = [
        "hmm...", "thinking...", "one sec...", "ok hold on",
        "let me check", "working on it", "almost...", "bear with me",
        "on it!", "gimme a sec", "brb", "processing...",
        "hang tight", "just a moment", "figuring it out",
        "crunching...", "reading...", "looking...",
        "cooking...", "vibing...", "digging in",
        "connecting dots", "give me a sec",
        "don't rush me", "calculating...", "assembling\u{2026}"
    ]

    private static let completionPhrases = [
        "done!", "all set!", "ready!", "here you go", "got it!",
        "finished!", "ta-da!", "voila!",
        "boom!", "there ya go!", "check it out!"
    ]

    private var lastPhraseUpdate: CFTimeInterval = 0
    var currentPhrase = ""
    var completionBubbleExpiry: CFTimeInterval = 0
    var showingCompletion = false

    private static let bubbleH: CGFloat = 26
    private var phraseAnimating = false

    func updateThinkingBubble() {
        let now = CACurrentMediaTime()

        if showingCompletion {
            if now >= completionBubbleExpiry {
                showingCompletion = false
                hideBubble()
                return
            }
            if isIdleForPopover {
                completionBubbleExpiry += 1.0 / 60.0
                hideBubble()
            } else {
                showBubble(text: currentPhrase, isCompletion: true)
            }
            return
        }

        if isAgentBusy && !isIdleForPopover {
            let oldPhrase = currentPhrase
            updateThinkingPhrase()
            if currentPhrase != oldPhrase && !oldPhrase.isEmpty && !phraseAnimating {
                animatePhraseChange(to: currentPhrase, isCompletion: false)
            } else if !phraseAnimating {
                showBubble(text: currentPhrase, isCompletion: false)
            }
        } else if !showingCompletion {
            hideBubble()
        }
    }

    private func hideBubble() {
        if thinkingBubbleWindow?.isVisible ?? false {
            thinkingBubbleWindow?.orderOut(nil)
        }
    }

    private func animatePhraseChange(to newText: String, isCompletion: Bool) {
        guard let win = thinkingBubbleWindow, win.isVisible,
              let label = win.contentView?.viewWithTag(100) as? NSTextField else {
            showBubble(text: newText, isCompletion: isCompletion)
            return
        }
        phraseAnimating = true

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            label.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            self?.showBubble(text: newText, isCompletion: isCompletion)
            label.alphaValue = 0.0
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.allowsImplicitAnimation = true
                label.animator().alphaValue = 1.0
            }, completionHandler: {
                self?.phraseAnimating = false
            })
        })
    }

    func showBubble(text: String, isCompletion: Bool) {
        let t = resolvedTheme
        if thinkingBubbleWindow == nil {
            createThinkingBubble()
        }

        let h = Self.bubbleH
        let padding: CGFloat = 16
        let font = t.bubbleFont
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let bubbleW = max(ceil(textSize.width) + padding * 2, 48)

        let charFrame = window.frame
        let x = charFrame.midX - bubbleW / 2
        let y = charFrame.origin.y + charFrame.height * 0.68
        thinkingBubbleWindow?.setFrame(CGRect(x: x, y: y, width: bubbleW, height: h), display: false)

        let borderColor = isCompletion ? t.bubbleCompletionBorder.cgColor : t.bubbleBorder.cgColor
        let textColor = isCompletion ? t.bubbleCompletionText : t.bubbleText

        if let container = thinkingBubbleWindow?.contentView {
            container.frame = NSRect(x: 0, y: 0, width: bubbleW, height: h)
            container.layer?.backgroundColor = t.bubbleBg.cgColor
            container.layer?.cornerRadius = t.bubbleCornerRadius
            container.layer?.borderColor = borderColor
            if let label = container.viewWithTag(100) as? NSTextField {
                label.font = font
                let lineH = ceil(textSize.height)
                let labelY = round((h - lineH) / 2) - 1
                label.frame = NSRect(x: 0, y: labelY, width: bubbleW, height: lineH + 2)
                label.stringValue = text
                label.textColor = textColor
            }
        }

        if !(thinkingBubbleWindow?.isVisible ?? false) {
            thinkingBubbleWindow?.alphaValue = 1.0
            thinkingBubbleWindow?.orderFrontRegardless()
        }
    }

    private func updateThinkingPhrase() {
        let now = CACurrentMediaTime()
        if currentPhrase.isEmpty || now - lastPhraseUpdate > Double.random(in: 3.0...5.0) {
            var next = Self.thinkingPhrases.randomElement() ?? "..."
            while next == currentPhrase && Self.thinkingPhrases.count > 1 {
                next = Self.thinkingPhrases.randomElement() ?? "..."
            }
            currentPhrase = next
            lastPhraseUpdate = now
        }
    }

    func showCompletionBubble() {
        currentPhrase = Self.completionPhrases.randomElement() ?? "done!"
        showingCompletion = true
        completionBubbleExpiry = CACurrentMediaTime() + 3.0
        lastPhraseUpdate = 0
        phraseAnimating = false
        if !isIdleForPopover {
            showBubble(text: currentPhrase, isCompletion: true)
        }
    }

    private func createThinkingBubble() {
        let t = resolvedTheme
        let w: CGFloat = 80
        let h = Self.bubbleH
        let win = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: w, height: h),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 5)
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.moveToActiveSpace, .stationary]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        container.wantsLayer = true
        container.layer?.backgroundColor = t.bubbleBg.cgColor
        container.layer?.cornerRadius = t.bubbleCornerRadius
        container.layer?.borderWidth = 1
        container.layer?.borderColor = t.bubbleBorder.cgColor

        let font = t.bubbleFont
        let lineH = ceil(("Xg" as NSString).size(withAttributes: [.font: font]).height)
        let labelY = round((h - lineH) / 2) - 1

        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = t.bubbleText
        label.alignment = .center
        label.drawsBackground = false
        label.isBordered = false
        label.isEditable = false
        label.frame = NSRect(x: 0, y: labelY, width: w, height: lineH + 2)
        label.tag = 100
        container.addSubview(label)

        win.contentView = container
        thinkingBubbleWindow = win
    }

    // MARK: - Completion Sound

    static var soundsEnabled = true

    private static let completionSounds: [(name: String, ext: String)] = [
        ("ping-aa", "mp3"), ("ping-bb", "mp3"), ("ping-cc", "mp3"),
        ("ping-dd", "mp3"), ("ping-ee", "mp3"), ("ping-ff", "mp3"),
        ("ping-gg", "mp3"), ("ping-hh", "mp3"), ("ping-jj", "m4a")
    ]
    private static var lastSoundIndex: Int = -1

    func playCompletionSound() {
        guard Self.soundsEnabled else { return }
        var idx: Int
        repeat {
            idx = Int.random(in: 0..<Self.completionSounds.count)
        } while idx == Self.lastSoundIndex && Self.completionSounds.count > 1
        Self.lastSoundIndex = idx

        let s = Self.completionSounds[idx]
        if let url = Bundle.main.url(forResource: s.name, withExtension: s.ext, subdirectory: "Sounds"),
           let sound = NSSound(contentsOf: url, byReference: true) {
            sound.play()
        }
    }

    // MARK: - Walking

    func startWalk() {
        isPaused = false
        isWalking = true
        playCount = 0
        walkStartTime = CACurrentMediaTime()

        if positionProgress > 0.85 {
            goingRight = false
        } else if positionProgress < 0.15 {
            goingRight = true
        } else {
            goingRight = Bool.random()
        }

        walkStartPos = positionProgress
        let referenceWidth: CGFloat = 500.0
        let walkPixels = CGFloat.random(in: walkAmountRange) * referenceWidth
        let walkAmount = currentTravelDistance > 0 ? walkPixels / currentTravelDistance : 0.3
        if goingRight {
            walkEndPos = min(walkStartPos + walkAmount, 1.0)
        } else {
            walkEndPos = max(walkStartPos - walkAmount, 0.0)
        }
        walkStartPixel = walkStartPos * currentTravelDistance
        walkEndPixel = walkEndPos * currentTravelDistance

        let minSeparation: CGFloat = 0.12
        if let siblings = controller?.characters {
            for sibling in siblings where sibling !== self {
                let sibPos = sibling.positionProgress
                if abs(walkEndPos - sibPos) < minSeparation {
                    if goingRight {
                        walkEndPos = max(walkStartPos, sibPos - minSeparation)
                    } else {
                        walkEndPos = min(walkStartPos, sibPos + minSeparation)
                    }
                }
            }
        }

        updateFlip()
        if riveViewModel != nil {
            rivePlay()
        } else {
            queuePlayer?.seek(to: .zero)
            queuePlayer?.play()
        }
    }

    func enterPause() {
        isWalking = false
        isPaused = true
        if riveViewModel == nil {
            queuePlayer?.pause()
            queuePlayer?.seek(to: .zero)
        }
        // Rive continues its idle animation during pause — no need to stop it
        let delay = Double.random(in: 5.0...12.0)
        pauseEndTime = CACurrentMediaTime() + delay
    }

    func updateFlip() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let transform = goingRight ? CATransform3DIdentity : CATransform3DMakeScale(-1, 1, 1)
        if let rv = riveContentView {
            rv.layer?.transform = transform
            rv.layer?.frame = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)
        } else {
            playerLayer?.transform = transform
            playerLayer?.frame = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)
        }
        CATransaction.commit()
    }

    var currentFlipCompensation: CGFloat {
        goingRight ? 0 : flipXOffset
    }

    func movementPosition(at videoTime: CFTimeInterval) -> CGFloat {
        let dIn = fullSpeedStart - accelStart
        let dLin = decelStart - fullSpeedStart
        let dOut = walkStop - decelStart
        let v = 1.0 / (dIn / 2.0 + dLin + dOut / 2.0)

        if videoTime <= accelStart {
            return 0.0
        } else if videoTime <= fullSpeedStart {
            let t = videoTime - accelStart
            return CGFloat(v * t * t / (2.0 * dIn))
        } else if videoTime <= decelStart {
            let easeInDist = v * dIn / 2.0
            let t = videoTime - fullSpeedStart
            return CGFloat(easeInDist + v * t)
        } else if videoTime <= walkStop {
            let easeInDist = v * dIn / 2.0
            let linearDist = v * dLin
            let t = videoTime - decelStart
            return CGFloat(easeInDist + linearDist + v * (t - t * t / (2.0 * dOut)))
        } else {
            return 1.0
        }
    }

    deinit {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Frame Update

    // Toggle ignoresMouseEvents based on whether the cursor is over visible cat pixels.
    // Transparent padding becomes click-through to Finder/Dock/apps beneath; cat body
    // absorbs the click so the popover opens without also activating the app below.
    private func updateClickPassThrough() {
        guard let win = window, win.isVisible else { return }
        let now = CACurrentMediaTime()
        if now - lastPassThroughCheck < 0.05 { return }
        lastPassThroughCheck = now

        let loc = NSEvent.mouseLocation
        let frame = win.frame
        let desired: Bool
        if !frame.contains(loc) {
            desired = true
        } else {
            let winPt = NSPoint(x: loc.x - frame.origin.x, y: loc.y - frame.origin.y)
            desired = (win.contentView?.hitTest(winPt) == nil)
        }
        if win.ignoresMouseEvents != desired {
            win.ignoresMouseEvents = desired
        }
    }

    func update(dockX: CGFloat, dockWidth: CGFloat, dockTopY: CGFloat) {
        updateClickPassThrough()
        currentTravelDistance = max(dockWidth - displayWidth, 0)
        guard riveViewModel != nil else { return }
        let now = CACurrentMediaTime()
        let idleTime = now - lastActivityTime
        let sessionTime = now - sessionStartTime
        let busyDuration = (isAgentBusy && agentBusyStartTime > 0) ? now - agentBusyStartTime : 0

        if !isIdleForPopover {
            if sessionTime > cryAfterSeconds {
                triggerCatAnimation(.crying)
            } else if isAgentBusy && busyDuration > deepThinkAfterSeconds {
                triggerCatAnimation(.deepThinking)
            } else if isAgentBusy {
                if currentCatState != .thinking && currentCatState != .deepThinking {
                    triggerCatAnimation(.thinking)
                }
            } else if idleTime > sleepAfterSeconds {
                triggerCatAnimation(.sleeping)
            } else if idleTime > sleepyAfterSeconds {
                triggerCatAnimation(.sleepy)
            } else if sessionTime > coffeeAfterSeconds && currentCatState == .idle {
                triggerCatAnimation(.drinkingCoffee)
            } else if !isAgentBusy && (currentCatState == .sleeping || currentCatState == .sleepy) && idleTime < sleepyAfterSeconds {
                triggerCatAnimation(.idle)
            }
        }

        if isIdleForPopover {
            let travelDistance = currentTravelDistance
            let x = dockX + travelDistance * positionProgress + currentFlipCompensation
            let bottomPadding = displayHeight * 0.15
            let y = dockTopY - bottomPadding + yOffset
            window.setFrameOrigin(NSPoint(x: x, y: y))
            updatePopoverPosition()
            updateThinkingBubble()
            return
        }

        if isPaused {
            if walksEnabled && now >= pauseEndTime {
                startWalk()
            } else {
                let travelDistance = max(dockWidth - displayWidth, 0)
                let x = dockX + travelDistance * positionProgress + currentFlipCompensation
                let bottomPadding = displayHeight * 0.15
                let y = dockTopY - bottomPadding + yOffset
                window.setFrameOrigin(NSPoint(x: x, y: y))
                updateThinkingBubble()
                return
            }
        }

        if isWalking {
            let elapsed = now - walkStartTime
            let videoTime = min(elapsed, videoDuration)
            let travelDistance = currentTravelDistance

            let walkNorm = elapsed >= videoDuration ? 1.0 : movementPosition(at: videoTime)
            let currentPixel = walkStartPixel + (walkEndPixel - walkStartPixel) * walkNorm

            if travelDistance > 0 {
                positionProgress = min(max(currentPixel / travelDistance, 0), 1)
            }

            if elapsed >= videoDuration {
                walkEndPos = positionProgress
                enterPause()
                return
            }

            let x = dockX + travelDistance * positionProgress + currentFlipCompensation
            let bottomPadding = displayHeight * 0.15
            let y = dockTopY - bottomPadding + yOffset
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        updateThinkingBubble()
    }

}
