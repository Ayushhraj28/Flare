import Foundation
import AppKit
import AVFoundation
import ApplicationServices
import GauntletProtocol
import GauntletLink
import GauntletEngine

/// What a command asks for, decided on the Mac before anything is sent.
public enum JuneIntent: Equatable, Sendable {
    /// "stop", "be quiet", "never mind": stop talking.
    case stop
    /// "copy that": put the last answer on the clipboard.
    case copyAnswer
    /// "read this": read the text under the cursor aloud, no Gemini call.
    case readAloud
    /// "summarize this document", "what's this page about": read the whole document.
    case document
    /// "what's on my screen", "what's this chart": send a picture of the screen.
    case look
    /// "type see you at six": type the words into the focused text field.
    case type(String)
    /// "thanks", "that's all", "bye": end the conversation.
    case endConversation
    /// "close this window", "close all windows", "close this tab", "quit Spotify": close what the pointer is on.
    /// `app` is a named app, or nil for the one under the pointer.
    case close(scope: CloseScope, app: String?)
    /// "open this", "open the Projects folder", "open resume.pdf", "open Safari".
    /// `name` is nil for whatever the pointer is on.
    case open(name: String?, folder: Bool)
    /// "copy this file", "paste it here", "move this to Documents", "rename this to …", "put this in
    /// the Trash", "undo": file actions on what the pointer is on (or what's selected) in Finder.
    /// "select Projects and Portfolio", "delete Projects": the same on items named out loud.
    case files(FileCommand)
    /// Writing in the app in front: fix, rewrite or translate the selected text in place (⌘Z undoes it),
    /// type a reply into the reply box, or press Send when told to.
    case write(WriteCommand)
    /// Anything else goes to Gemini with what is under the cursor.
    case ask

    public enum CloseScope: Equatable, Sendable { case window, allWindows, tab, app }

    public indirect enum FileCommand: Equatable, Sendable {
        case copy, paste, trash, undo
        /// nil: "move this here" (the pointer is on the destination).
        case move(to: String?)
        case rename(to: String)
        /// "copy this to Documents": a copy goes straight into the named folder.
        case copyInto(String)
        /// "select Projects and Portfolio" (`then` is nil), or a command on items named out loud:
        /// "delete Projects" is `.select("Projects", then: .trash)`. `FileNames.everything` is "select all".
        case select(String, then: FileCommand?)
    }

    public enum WriteCommand: Equatable, Sendable {
        /// "fix the grammar", "proofread this", "fix this": the fewest changes that correct it.
        case fix
        /// "make this more professional", "shorter", "rewrite this as bullet points": the words are the instruction.
        case rewrite(String)
        /// "translate this to Spanish"; nil: the language set in Settings.
        case translate(String?)
        /// "reply to this saying I'll be late": what the reply should say ("" lets June choose).
        case reply(String)
        /// "click Send": press Send. June never sends anything unless told to.
        case send
    }
}

/// June, the voice assistant.
///
/// Ways in: say "Hey June …" (always-on, recognised on this Mac), hold Right Option or the watch's
/// June chip, a custom gesture, or keep talking after an answer (conversation mode).
/// Then: read what's under the pointer (selection, paragraph, whole document, or a picture of the
/// screen) → one streaming Gemini call (with Google Search when useful) → the answer appears in the
/// June window and is spoken sentence by sentence while it streams in.
///
/// Everything runs on the main thread except audio, which flows from the microphone through the
/// audio hub to the speech listener on their own queues.
@MainActor
public final class AssistantController {
    // MARK: Public API

    /// Always called on the main thread.
    public var onState: ((JuneState) -> Void)?
    public var onCaptureFrame: ((CGRect?) -> Void)?
    public var onPocketChipRequested: ((CGPoint?) -> Void)?
    /// Wired by AppModel to `SystemPointerSink.sendKeyCombo`.
    public var sendKeyCombo: ((UInt16, UInt64) -> Void)?
    /// Wired by AppModel: tells the watch what June is doing (ring, haptics).
    public var sendWatchState: ((AssistantWatchState) -> Void)?
    /// Wired by AppModel: the June window's gear button opens Settings › June.
    public var openSettings: (() -> Void)?

    public var settings: JuneSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            if !settings.enabled { cancel() }
            if !settings.speakReplies { voice.stop() }
            if !settings.showStatusHUD { panel.hide() }
            if settings.wakeWordEnabled != oldValue.wakeWordEnabled || settings.enabled != oldValue.enabled
                || settings.sensitivity != oldValue.sensitivity || settings.preferredSource != oldValue.preferredSource {
                speechUnavailable = false
                refreshListening()
            }
        }
    }

    public private(set) var state: JuneState = .off {
        didSet {
            onState?(state)
            let name = Self.stateName(state)
            if name != Self.stateName(oldValue) { JuneLog.write("state \(name)") }
            updatePanel()
        }
    }

    /// The June window's contents, for anyone who wants to mirror them.
    public var panelModel: JunePanelModel { panel.model }

    public private(set) var audioSources: [VoiceAudioSource]
    /// True while the microphone is open for "Hey June" (nothing leaves the Mac).
    public private(set) var handsFree = false
    public var wakeWordEnabled: Bool {
        get { settings.wakeWordEnabled }
        set { settings.wakeWordEnabled = newValue }
    }

    public init(apiKeyProvider: @escaping () -> String?) {
        self.apiKeyProvider = apiKeyProvider
        self.settings = JuneSettings.load()
        let mic = MacMicrophoneSource()
        self.macMic = mic
        self.audioSources = [mic]
        listener.onEvent = { [weak self] event in self?.handle(event) }
        panel.model.onStop = { [weak self] in self?.stopEverything() }
        panel.model.onCopy = { [weak self] in self?.copyAnswer() }
        panel.model.onSettings = { [weak self] in self?.openSettings?() }
        panel.model.onClose = { [weak self] in self?.closePanel() }
        panel.model.onUndo = { [weak self] in
            guard let self else { return }
            self.startTurn(utterance: "undo", point: Self.cursorLocation(), trigger: "undo button")
        }
    }

    /// Starts listening for "Hey June" if it's on. Call once the app has launched.
    public func start() {
        guard !started else { return }
        started = true
        refreshListening()
        // AirPods connecting or the watch starting to stream changes the best microphone.
        sourceTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSource() }
        }
    }

    public func registerSource(_ source: VoiceAudioSource) {
        audioSources.append(source)
        source.onAvailabilityChanged = { [weak self] _ in
            Task { @MainActor in self?.checkSource() }
        }
    }

    /// AirPods on the Mac → the watch's microphone (once it has really streamed) → the Mac's own microphone.
    public var activeSource: VoiceAudioSource? {
        if let preferred = settings.preferredSource,
           let match = audioSources.first(where: { $0.displayName == preferred && $0.isAvailable }) {
            return match
        }
        if macMic.isAirPods, macMic.isAvailable { return macMic }
        if let watch = audioSources.first(where: { $0 !== macMic && $0.isAvailable }),
           let verified = watchVerifiedAt, Date().timeIntervalSince(verified) < 30 * 60 {
            return watch
        }
        if macMic.isAvailable { return macMic }
        return audioSources.first(where: { $0 !== macMic && $0.isAvailable })
    }

    public func setPreferredSource(_ name: String?) {
        settings.preferredSource = name
    }

    /// Hold-to-talk (Right Option, the watch's June chip). `true` starts listening, `false` ends the command.
    public func pushToTalk(isDown: Bool) {
        guard settings.enabled else { return }
        if isDown {
            guard role != .pushToTalk else { return }
            pttHeld = true
            pttStarted = Date()
            beginCapture(.pushToTalk, maxWait: 0, manualEnd: true)
        } else {
            pttHeld = false
            guard role == .pushToTalk else { return }
            if Date().timeIntervalSince(pttStarted) < Self.minimumHold {
                listener.stop()
                role = .idle
                fail(.holdTooShort)
                return
            }
            listener.finish()
        }
    }

    /// Runs a command for a custom gesture: "Talk to June" listens; the others act on what's under the pointer.
    public func run(_ command: AssistantCommand, at screenPoint: CGPoint) {
        guard settings.enabled else { return }
        let utterance: String
        switch command {
        case .listen:
            beginCapture(.gesture, maxWait: 6, manualEnd: false)
            return
        case .summarize: utterance = "summarize this"
        case .explain: utterance = "explain this"
        case .translate: utterance = "translate this to \(settings.targetLanguage)"
        case .look: utterance = "what's this on my screen?"
        case .draftReply, .pastePocket, .saveToNotes:
            fail(.unsupported(command.title))
            return
        }
        startTurn(utterance: utterance, point: screenPoint, trigger: "gesture")
    }

    /// Runs a typed command as if it had been spoken. `point` is where June looks (nil = the pointer).
    public func ask(_ utterance: String, at point: CGPoint? = nil) {
        guard settings.enabled else { return }
        startTurn(utterance: utterance, point: point ?? Self.cursorLocation(), trigger: "typed")
    }

    /// Runs a recorded command (any audio file) through on-device speech, for testing without a microphone.
    public func listen(fileAt url: URL, at point: CGPoint? = nil) {
        guard settings.enabled else { return }
        stopEverything()
        listener.stop()
        let target = point ?? Self.cursorLocation()
        role = .processing
        setState(.listening(transcript: ""))
        work = Task { [weak self] in
            guard let self else { return }
            if Permissions.speechState() == .notDetermined { _ = await Permissions.requestSpeech() }
            guard Permissions.speechState() == .granted else { self.fail(.speechDenied); return }
            guard let transcriber = CommandTranscriber() else { self.fail(.onDeviceSpeechMissing); return }
            transcriber.start()
            do {
                try await Task.detached(operation: { try Self.feed(url, into: transcriber) }).value
            } catch {
                transcriber.cancel()
                self.fail(.unsupported("That audio file"))
                return
            }
            let transcript = await transcriber.finish()
            JuneLog.write("heard \"\(transcript)\" source=file \(url.lastPathComponent)")
            if Task.isCancelled { return }
            self.heard = transcript
            await self.process(utterance: transcript, speechEnded: Date(), point: target, trigger: "file")
            self.finishTurn()
        }
    }

    /// Says `text` with the current voice settings.
    public func say(_ text: String) {
        voice.say(text, settings: settings, apiKey: apiKeyProvider(), client: client)
    }

    public func stopSpeaking() { voice.stop() }

    /// Says a sample sentence with the current voice settings.
    public func previewVoice() {
        say("Hi, I'm June. Point at anything and ask me about it.")
    }

    /// English voices installed on this Mac, best first.
    public nonisolated static func availableVoices() -> [JuneVoice] { VoiceReply.availableVoices() }
    public nonisolated static let geminiVoices = GeminiClient.voices

    /// Checks the key and the model name. Returns a one-line result for Settings.
    public func testConnection() async -> String {
        guard let key = apiKeyProvider(), !key.isEmpty else {
            return "No API key. Paste one above and press Save."
        }
        let model = GeminiClient.model(override: settings.modelOverride)
        switch await client.checkModel(model, apiKey: key) {
        case .success:
            return "Connected ✓  \(model)"
        case .failure(let error):
            if case .http(404, _) = error { return "The key works, but there's no model called “\(model)”. Try gemini-flash-latest." }
            return [error.message, error.fix].compactMap { $0 }.joined(separator: " ")
        }
    }

    /// Opens the connection to Gemini ahead of the first command and checks the key.
    public func warmUp() {
        guard settings.enabled, let key = apiKeyProvider(), !key.isEmpty else { return }
        let model = GeminiClient.model(override: settings.modelOverride)
        let client = self.client
        Task {
            switch await client.checkModel(model, apiKey: key) {
            case .success: JuneLog.write("warm-up ok model=\(model)")
            case .failure(let error): JuneLog.write("warm-up failed model=\(model): \(error.message)")
            }
        }
    }

    public func pasteFromPocket() { fail(.unsupported("The pocket")) }
    public func confirmPendingAction() {}

    /// Stops whatever June is doing and goes back to waiting for "Hey June".
    public func cancel() {
        stopEverything()
        onCaptureFrame?(nil)
        setState(.off)
        panel.hide()
        refreshListening()
    }

    // MARK: State

    private enum Role: Equatable {
        /// Waiting for "Hey June" (or not listening at all when the wake word is off).
        case idle
        /// Heard "Hey June", recording the command.
        case wakeCommand
        case pushToTalk
        case gesture
        case followUp
        /// A command is being answered.
        case processing
    }

    private let apiKeyProvider: () -> String?
    private let macMic: MacMicrophoneSource
    private let client = GeminiClient()
    private let voice = VoiceReply()
    private let hub = AudioHub()
    private let listener = SpeechListener()
    private let panel = JunePanelController()
    private var role = Role.idle
    private var started = false
    private var hubToken: UUID?
    private var listenerMode: SpeechListener.Mode?
    private var speechUnavailable = false
    private var sourceTimer: Timer?
    private var levelTimer: Timer?
    private var work: Task<Void, Never>?
    private var watchdog: UUID?
    private var followUpTask: Task<Void, Never>?
    private var inConversation = false
    private var pttHeld = false
    private var pttStarted = Date()
    private var watchVerifiedAt: Date?
    private var lastAnswer: String?
    /// The file(s) June last read or acted on: "this" when the pointer isn't on a file.
    private var lastFiles: [URL] = [] { didSet { lastFilesAt = Date() } }
    private var lastFilesAt = Date.distantPast
    /// What June last wrote into another app: "shorter" right after reworks it, "undo" sends ⌘Z there.
    private var lastWrite: (text: String, pid: pid_t, at: Date)?
    /// What June selected by name ("select Projects and Portfolio"): "it" and "them" right after.
    private var juneSelection: (urls: [URL], at: Date, highlighted: Bool)?
    private let fileActions = FileActions(finder: FinderBridge())
    private var heard = ""
    private var answerSources: [String] = []
    private var statusLine = ""
    private var thinkingLevel: String? = "minimal"
    /// Earlier turns, sent with each request so follow-ups make sense. Cleared after 3 idle minutes.
    private var history: [JuneTurn] = []
    private var historyUpdated = Date.distantPast
    /// The last thing June read, reused when a follow-up points at nothing new.
    private var pinnedContext: (text: String, source: String)?

    /// Shorter presses are treated as an accidental tap, not a command.
    private static let minimumHold = 0.45

    private func setState(_ new: JuneState) { state = new }

    private var restingWatchState: AssistantWatchState { handsFree ? .waiting : .off }

    private static func cursorLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    // MARK: Listening

    /// Puts the microphone and the listener in the right state for the current role and settings.
    private func refreshListening() {
        guard started else { return }
        let wantWake = settings.enabled && settings.wakeWordEnabled && !speechUnavailable
            && Permissions.bundleHasUsageStrings && role == .idle
        if role == .idle {
            if wantWake {
                Task { [weak self] in
                    guard let self, await self.ensurePermissions(quiet: true), self.role == .idle else { return }
                    guard self.ensureAudio() else { return }
                    if self.listenerMode != .wake {
                        self.listener.start(.wake, sensitivity: self.settings.sensitivity)
                        self.listenerMode = .wake
                    }
                    self.setHandsFree(true)
                }
            } else {
                listener.stop()
                listenerMode = nil
                releaseAudio()
                setHandsFree(false)
            }
        }
    }

    private func setHandsFree(_ on: Bool) {
        guard handsFree != on else { return }
        handsFree = on
        JuneLog.write(on ? "listening for \"Hey June\" (on this Mac only)" : "stopped listening for \"Hey June\"")
        if role == .idle { sendWatchState?(restingWatchState) }
        if on, case .off = state { setState(.waitingForWakeWord) }
        if !on, case .waitingForWakeWord = state { setState(.off) }
    }

    @discardableResult
    private func ensureAudio() -> Bool {
        if hubToken != nil { return true }
        guard let source = activeSource else { fail(.noMicrophone); return false }
        let listener = self.listener
        do {
            hubToken = try hub.subscribe(source: source) { buffer in listener.append(buffer) }
            JuneLog.write("microphone on: \(source.displayName)")
            startLevelTimer()
            return true
        } catch {
            fail((error as? JuneError) ?? .noMicrophone)
            return false
        }
    }

    private func releaseAudio() {
        guard let token = hubToken else { return }
        hub.unsubscribe(token)
        hubToken = nil
        levelTimer?.invalidate()
        levelTimer = nil
        JuneLog.write("microphone off")
    }

    private func checkSource() {
        guard hubToken != nil, let best = activeSource else { return }
        if hub.runningSourceName != best.displayName { hub.switchTo(best, force: true) }
    }

    private func startLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.panel.isVisible else { return }
                let listening = [Role.wakeCommand, .pushToTalk, .gesture, .followUp].contains(self.role)
                let level = listening ? Double(self.hub.level) : 0
                if abs(level - self.panel.model.level) > 0.02 { self.panel.model.level = level }
                let speaking = self.voice.isBusy
                if speaking != self.panel.model.speaking { self.panel.model.speaking = speaking }
            }
        }
    }

    /// Starts recording a command right now (push-to-talk, a gesture, a follow-up).
    private func beginCapture(_ newRole: Role, maxWait: TimeInterval, manualEnd: Bool) {
        voice.stop()                          // talking to June interrupts her
        cancelWork()
        endConversation()
        role = newRole
        heard = ""
        lastAnswerShown = false
        Task { [weak self] in
            guard let self else { return }
            guard await self.ensurePermissions(quiet: false), self.role == newRole else {
                if self.role == newRole { self.role = .idle; self.refreshListening() }
                return
            }
            if newRole == .pushToTalk, !self.pttHeld { self.role = .idle; self.refreshListening(); return }
            guard self.ensureAudio() else { self.role = .idle; return }
            self.listener.start(.capture(maxWait: maxWait, manualEnd: manualEnd), sensitivity: self.settings.sensitivity)
            self.listenerMode = .capture(maxWait: maxWait, manualEnd: manualEnd)
            self.startedListening(chime: newRole == .followUp ? "Pop" : "Tink")
        }
    }

    private func startedListening(chime: String) {
        setState(.listening(transcript: ""))
        sendWatchState?(.listening)
        if settings.chimeEnabled { NSSound(named: NSSound.Name(chime))?.play() }
        JuneLog.write("listening role=\(role) source=\(hub.runningSourceName ?? "?")")
    }

    private func handle(_ event: SpeechListener.Event) {
        switch event {
        case .woke:
            guard role == .idle || role == .processing else { return }
            // "Hey June" while June is answering interrupts her.
            voice.stop()
            cancelWork()
            endConversation()
            role = .wakeCommand
            heard = ""
            lastAnswerShown = false
            JuneLog.write("wake phrase heard")
            startedListening(chime: "Tink")

        case .partial(let text):
            guard [Role.wakeCommand, .pushToTalk, .gesture, .followUp].contains(role) else { return }
            heard = text
            setState(.listening(transcript: text))

        case .command(let text):
            guard [Role.wakeCommand, .pushToTalk, .gesture, .followUp].contains(role) else { return }
            if role == .pushToTalk, hub.runningSourceName != macMic.displayName { watchVerifiedAt = Date() }
            let trigger: String = {
                switch role {
                case .wakeCommand: return "hey-june"
                case .pushToTalk: return "push-to-talk"
                case .gesture: return "gesture-listen"
                default: return "follow-up"
                }
            }()
            JuneLog.write("heard \"\(text)\" via \(trigger)")
            heard = text
            startTurn(utterance: text, point: Self.cursorLocation(), trigger: trigger)

        case .nothingHeard:
            let wasRole = role
            guard [Role.wakeCommand, .pushToTalk, .gesture, .followUp].contains(wasRole) else { return }
            role = .idle
            switch wasRole {
            case .pushToTalk:
                fail(.noSpeech)
            case .followUp:
                JuneLog.write("follow-up: silence, conversation over")
                endConversation()
                setState(.off)
                panel.hide(after: 1.5)
                sendWatchState?(.idle)
            default:
                setState(.notice("I'm here when you need me"))
                sendWatchState?(.idle)
            }
            refreshListening()

        case .failed(let error):
            speechUnavailable = true
            listenerMode = nil
            role = .idle
            releaseAudio()
            setHandsFree(false)
            fail(error)
        }
    }

    private func ensurePermissions(quiet: Bool) async -> Bool {
        guard Permissions.bundleHasUsageStrings else {
            if !quiet { fail(.notBundled) }
            return false
        }
        if Permissions.microphoneState() == .notDetermined { _ = await Permissions.requestMicrophone() }
        guard Permissions.microphoneState() == .granted else {
            if !quiet { fail(.micDenied) }
            return false
        }
        if Permissions.speechState() == .notDetermined { _ = await Permissions.requestSpeech() }
        guard Permissions.speechState() == .granted else {
            if !quiet { fail(.speechDenied) }
            return false
        }
        return true
    }

    // MARK: Turns

    private func startTurn(utterance: String, point: CGPoint, trigger: String) {
        panel.model.canUndo = false
        voice.stop()
        cancelWork()
        role = .processing
        heard = utterance
        setState(.thinking)
        sendWatchState?(.thinking)
        // Back to waiting for "Hey June" while this is answered, so "Hey June, stop" works.
        if listenerMode != .wake { listenerMode = nil }
        let started = Date()
        work = Task { [weak self] in
            guard let self else { return }
            await self.process(utterance: utterance, speechEnded: started, point: point, trigger: trigger)
            self.finishTurn()
        }
        resumeWakeWhileAnswering()
    }

    /// Keeps "Hey June" listening during an answer (so it can be interrupted).
    private func resumeWakeWhileAnswering() {
        guard settings.wakeWordEnabled, !speechUnavailable, hubToken != nil, listenerMode != .wake else {
            if hubToken != nil, listenerMode != .wake, !(settings.wakeWordEnabled && !speechUnavailable) {
                listener.stop()
                listenerMode = nil
            }
            return
        }
        listener.start(.wake, sensitivity: settings.sensitivity)
        listenerMode = .wake
    }

    private func finishTurn() {
        guard role == .processing else { return }
        role = .idle
        let answered: Bool = { if case .answer = state { return true }; return false }()
        if answered, settings.conversationMode, settings.speakReplies {
            inConversation = true
            scheduleFollowUp()
        }
        refreshListening()
        if !inConversation { sendWatchState?(restingWatchState) }
    }

    // MARK: Conversation

    private func scheduleFollowUp() {
        followUpTask?.cancel()
        followUpTask = Task { [weak self] in
            guard let self else { return }
            await self.voice.waitUntilDone()
            try? await Task.sleep(nanoseconds: 300_000_000)      // let the speaker's tail die away
            guard !Task.isCancelled, self.inConversation, self.role == .idle else { return }
            self.followUpTask = nil
            let keep = self.inConversation
            self.beginCapture(.followUp, maxWait: self.settings.followUpSeconds, manualEnd: false)
            self.inConversation = keep
        }
    }

    private func endConversation() {
        inConversation = false
        followUpTask?.cancel()
        followUpTask = nil
    }

    private func stopEverything() {
        voice.stop()
        cancelWork()
        endConversation()
        if [Role.wakeCommand, .pushToTalk, .gesture, .followUp, .processing].contains(role) {
            role = .idle
            listenerMode = nil
            listener.stop()
            refreshListening()
        }
        if case .answer(let text, true) = state { setState(.answer(text: text, streaming: false)) }
        if case .thinking = state { setState(.notice("Stopped")) }
        if case .listening = state { setState(.notice("Stopped")) }
        sendWatchState?(.idle)
    }

    private func closePanel() {
        stopEverything()
        panel.hide()
    }

    private func copyAnswer() {
        guard let lastAnswer else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastAnswer, forType: .string)
        panel.model.status = "Copied to the clipboard"
    }

    private func cancelWork() {
        watchdog = nil
        work?.cancel()
        work = nil
    }

    private func fail(_ error: JuneError) {
        watchdog = nil
        endConversation()
        JuneLog.write("error \(error.message) [\(error)]")
        onCaptureFrame?(nil)
        setState(.error(message: error.message, fix: error.fix))
        sendWatchState?(restingWatchState)
    }

    // MARK: The June window

    private var lastAnswerShown = false

    private func updatePanel() {
        let m = panel.model
        switch state {
        case .off:
            return
        case .waitingForWakeWord:
            return
        case .listening(let transcript):
            m.phase = .listening
            m.heard = transcript
            m.answer = ""
            m.detail = nil
            m.sources = []
            m.status = {
                switch role {
                case .pushToTalk: return "Listening… let go when you're done"
                case .followUp: return "Go ahead, I'm listening"
                default: return "Listening…"
                }
            }()
            m.hint = role == .followUp ? "Keep talking, or say “thanks” to finish." : "I'll answer when you pause."
        case .thinking:
            m.phase = .thinking
            m.heard = heard
            m.answer = ""
            m.detail = nil
            m.sources = []
            m.status = "Thinking…"
            m.hint = ""
        case .captured(let summary):
            m.phase = .thinking
            m.status = summary
        case .answer(let text, let streaming):
            m.phase = streaming ? .answering : .done
            m.heard = heard
            m.answer = text
            m.sources = answerSources
            if !statusLine.isEmpty { m.status = statusLine }
            m.hint = streaming ? "" : (handsFree ? "Say “Hey June” or hold ⌥ to ask again." : "Hold ⌥ to ask again.")
        case .confirm(let description):
            m.phase = .notice
            m.status = description
        case .pocketReady(let preview):
            m.phase = .notice
            m.status = "Reply ready"
            m.answer = preview
        case .notice(let text):
            m.phase = .notice
            m.status = text
            m.hint = ""
        case .error(let message, let fix):
            m.phase = .error
            m.status = message
            m.detail = fix
            m.hint = ""
        }

        guard settings.showStatusHUD else { return }
        switch state {
        case .off, .waitingForWakeWord:
            break
        case .listening, .thinking, .captured:
            panel.show(position: settings.panelPosition, at: Self.cursorLocation())
        case .answer(_, let streaming):
            panel.show(position: settings.panelPosition, at: Self.cursorLocation())
            if !streaming { lingerAfterSpeaking() }
        case .notice:
            panel.show(position: settings.panelPosition, at: Self.cursorLocation())
            panel.hide(after: 2.5)
        case .error:
            panel.show(position: settings.panelPosition, at: Self.cursorLocation())
            panel.hide(after: 7)
        case .confirm, .pocketReady:
            panel.show(position: settings.panelPosition, at: Self.cursorLocation())
        }
    }

    /// Keeps the answer on screen while June speaks it, then for `panelLingerSeconds`.
    private func lingerAfterSpeaking() {
        let linger = settings.panelLingerSeconds
        Task { [weak self] in
            guard let self else { return }
            await self.voice.waitUntilDone()
            guard case .answer(_, false) = self.state, !self.inConversation || self.role == .idle else { return }
            if self.followUpTask == nil, ![Role.followUp, .wakeCommand, .pushToTalk, .gesture].contains(self.role) {
                self.panel.hide(after: linger)
            }
        }
    }

    // MARK: Command pipeline

    private static let followUpWords = ["shorter", "longer", "simpler", "bullet", "bullets", "again", "more", "rephrase", "shorten"]

    private func isFollowUp(_ utterance: String) -> Bool {
        let lower = utterance.lowercased()
        return lastAnswer != nil && Self.followUpWords.contains { lower.contains($0) }
    }

    /// Decides what a command is without asking Gemini.
    public nonisolated static func intent(for utterance: String) -> JuneIntent {
        let lower = utterance.lowercased()
        let words = lower.split { !$0.isLetter && $0 != "'" }.map(String.init)
        guard let first = words.first else { return .ask }
        let bare = words.joined(separator: " ")
        // Before "thanks"/"stop": "reply no thanks" is a reply, not goodbye.
        if let request = Self.replyRequest(utterance) { return .write(.reply(request)) }

        let endings = ["thanks", "thank you", "that's all", "that's it", "that is all", "goodbye", "bye", "no thanks",
                       "i'm done", "i'm good", "all good", "we're done", "got it thanks", "perfect thanks"]
        if words.count <= 5, endings.contains(where: { bare == $0 || bare.hasPrefix($0 + " ") || bare.hasSuffix(" " + $0) }) {
            return .endConversation
        }
        let stopWords: Set<String> = ["stop", "quiet", "silence", "cancel", "enough", "shush"]
        if words.count <= 4, words.contains(where: { stopWords.contains($0) }) { return .stop }
        if lower.hasPrefix("never mind") || lower.hasPrefix("nevermind") || lower.hasPrefix("shut up") { return .stop }
        let fileWords = Array(words.drop(while: { ["can", "could", "would", "will", "you", "please", "june", "hey", "ok", "okay",
                                                   "just", "go", "ahead", "and", "now"].contains($0) }))
        if let files = Self.fileIntent(words: fileWords, original: utterance) { return files }
        if let named = Self.namedFileIntent(utterance) { return named }
        if first == "copy", words.count <= 4 { return .copyAnswer }
        if first == "read", !lower.contains("summar") { return .readAloud }

        // "could you please open …", "can you close …": look past the polite opening.
        let polite: Set<String> = ["can", "could", "would", "will", "you", "please", "june", "hey", "ok", "okay", "just", "go", "ahead", "and"]
        let command = Array(words.drop(while: { polite.contains($0) }))
        if let write = Self.writeIntent(words: command, original: utterance) { return write }
        if let close = Self.closeIntent(words: command) { return close }
        if let open = Self.openIntent(words: command) { return open }

        for prefix in ["type ", "dictate ", "write down ", "keyboard ", "keyboard, ", "keyboard: ", "type out "]
        where lower.hasPrefix(prefix) {
            let text = String(utterance.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return .type(Self.capitalizedFirst(text)) }
        }

        let lookWords = ["on my screen", "on the screen", "on screen", "what am i looking at", "what do you see", "look at this",
                         "this image", "this picture", "this photo", "this chart", "this graph", "this diagram", "this screenshot",
                         "this window", "describe what"]
        if lookWords.contains(where: { lower.contains($0) }) { return .look }

        let documentWords = ["document", "article", "this page", "the page", "whole page", "web page", "webpage", "this website",
                             "this file", "the file", "this pdf", "the pdf", "whole thing", "entire", "full text",
                             "this paper", "the paper", "this report", "the report", "this email", "the email", "this chapter"]
        if documentWords.contains(where: { lower.contains($0) }) { return .document }
        return .ask
    }

    /// Words that only point at the target ("close this window", "open the file").
    private nonisolated static let pointerWords: Set<String> = ["this", "that", "it", "the", "a", "my", "here", "up",
                                                               "please", "now", "for", "me", "one", "current", "front"]

    private nonisolated static func fileIntent(words: [String], original: String) -> JuneIntent? {
        guard let first = words.first, words.count <= 12 else { return nil }
        let rest = Array(words.dropFirst())
        let set = Set(rest)
        let targets: Set<String> = ["this", "that", "it", "these", "those", "them", "file", "files", "folder", "folders",
                                    "selected", "selection", "item", "items", "one", "the", "here", "please", "now", "for",
                                    "me", "all", "of", "my"]
        let onlyTargets = rest.allSatisfy { targets.contains($0) }

        if first == "undo", rest.allSatisfy({ ["that", "it", "this", "the", "last", "thing", "please", "move", "paste",
                                                 "rename", "trash", "change"].contains($0) }) {
            return .files(.undo)
        }
        if first == "put", rest.count == 2, rest[1] == "back", ["it", "that", "them", "this"].contains(rest[0]) { return .files(.undo) }

        let trashWords: Set<String> = ["trash", "bin", "garbage", "recycle"]
        let forGood: Set<String> = ["permanently", "forever", "completely", "for", "good", "right", "away"]
        let deleteRest = rest.filter { !forGood.contains($0) }
        if ["trash", "bin"].contains(first), onlyTargets { return .files(.trash) }
        if ["delete", "remove", "erase"].contains(first), !deleteRest.isEmpty, deleteRest.allSatisfy({ targets.contains($0) }) {
            return .files(.trash)
        }
        if first == "get", rest.starts(with: ["rid", "of"]), rest.count > 2, rest.dropFirst(2).allSatisfy({ targets.contains($0) }) {
            return .files(.trash)
        }
        if ["put", "move", "send", "drag", "throw"].contains(first),
           !set.isDisjoint(with: trashWords) || (first == "throw" && set.contains("away")) {
            // Only "this", "these", "the file"… before the Trash; a name ("move Projects to the Trash") is handled by name.
            let before = rest.prefix { !["to", "in", "into", "away", "out"].contains($0) && !trashWords.contains($0) }
            if before.allSatisfy({ targets.contains($0) }) { return .files(.trash) }
            return nil
        }
        if first == "paste", rest.allSatisfy({ targets.contains($0) || ["in", "into", "there", "over"].contains($0) }) {
            return .files(.paste)
        }
        // Plain "copy this" is decided by what's under the pointer; these always mean files.
        if first == "copy", onlyTargets,
           !set.isDisjoint(with: ["file", "files", "folder", "folders", "these", "those", "them", "selected"]) {
            return .files(.copy)
        }
        // "copy this to Documents": a copy straight into that folder.
        if first == "copy" || first == "duplicate", let index = rest.firstIndex(where: { ["to", "into"].contains($0) }),
           index > 0, rest[..<index].allSatisfy({ targets.contains($0) }) {
            let destination = rest[(index + 1)...]
                .filter { !["the", "my", "folder", "directory", "please", "now"].contains($0) }.joined(separator: " ")
            if !destination.isEmpty, destination != "here", destination != "clipboard" { return .files(.copyInto(destination)) }
        }
        if first == "move" {
            if let index = rest.firstIndex(where: { ["to", "into", "in"].contains($0) }) {
                // A name before "to" ("move Portfolio to Documents") is handled by name.
                guard rest[..<index].allSatisfy({ targets.contains($0) }) else { return nil }
                let destination = rest[(index + 1)...]
                    .filter { !["the", "my", "folder", "directory", "please", "now"].contains($0) }.joined(separator: " ")
                if destination.isEmpty || destination == "here" || destination == "over here" { return .files(.move(to: nil)) }
                return .files(.move(to: destination))
            }
            if set.contains("here"), rest.allSatisfy({ targets.contains($0) || $0 == "over" }) { return .files(.move(to: nil)) }
            return nil
        }
        if first == "rename" || (first == "change" && set.contains("name")) {
            if first == "rename", let index = rest.firstIndex(where: { $0 == "to" || $0 == "as" }),
               !rest[..<index].allSatisfy({ targets.contains($0) }) {
                return nil                                  // "rename Projects to Old Projects": by name
            }
            if let name = Self.renameTarget(in: original) { return .files(.rename(to: name)) }
        }
        return nil
    }

    /// File commands that name what they act on: "select Projects and Portfolio", "delete the
    /// Resume PDF", "copy Projects", "move Portfolio to Documents", "rename Projects to Old Projects",
    /// "select Projects and Portfolio and copy them". Works on the words as written so names keep
    /// their digits ("Report 2"). Nil when the words name text or screen things ("delete this sentence").
    nonisolated static func namedFileIntent(_ utterance: String) -> JuneIntent? {
        var tokens = FileNames.tokens(utterance)
        let opening: Set<String> = ["can", "could", "would", "will", "you", "please", "june", "hey", "ok", "okay", "just", "go",
                                    "ahead", "and", "now", "i", "i'd", "want", "wanna", "need", "like", "to", "let's", "lets", ","]
        while let first = tokens.first?.lowercased(), opening.contains(first) { tokens.removeFirst() }
        guard let verbToken = tokens.first, tokens.count <= 18 else { return nil }
        let verb = verbToken.lowercased()
        var rest = Array(tokens.dropFirst())
        let closing: Set<String> = ["please", "now", "for", "me", "thanks", "thank", "you", ",", "too", "right", "away"]
        while let last = rest.last?.lowercased(), closing.contains(last) { rest.removeLast() }
        let lower = rest.map { $0.lowercased() }
        let trashWords: Set<String> = ["trash", "bin", "garbage", "recycle"]

        /// "Projects from the Desktop permanently" → "Projects": June always uses the Trash.
        func trashTarget(_ words: [String]) -> [String] {
            var w = words
            if let from = w.firstIndex(where: { $0.lowercased() == "from" }), from > 0 { w = Array(w[..<from]) }
            let forGood: Set<String> = ["permanently", "forever", "completely", "for", "good"]
            while let last = w.last?.lowercased(), forGood.contains(last) { w.removeLast() }
            return w
        }
        func destination(_ words: ArraySlice<String>) -> String {
            words.map { $0.lowercased() }.filter { !["the", "my", "folder", "directory", "please", "now"].contains($0) }
                .joined(separator: " ")
        }

        switch verb {
        case "select", "highlight":
            return selectIntent(rest)
        case "delete", "remove", "trash", "erase", "bin":
            return named(trashTarget(rest), then: .trash)
        case "get":
            guard lower.starts(with: ["rid", "of"]) else { return nil }
            return named(trashTarget(Array(rest.dropFirst(2))), then: .trash)
        case "throw":
            let words = rest.filter { !["away", "out"].contains($0.lowercased()) }
            let cut = words.firstIndex { ["in", "into", "to"].contains($0.lowercased()) } ?? words.count
            return named(Array(words[..<cut]), then: .trash)
        case "put", "move", "send", "drag":
            guard let index = lower.firstIndex(where: { ["to", "into", "in", "onto"].contains($0) }) else {
                if verb == "move", lower.last == "here" { return named(Array(rest.dropLast()), then: .move(to: nil)) }
                return nil
            }
            let names = Array(rest[..<index])
            let place = destination(rest[(index + 1)...])
            if place.split(separator: " ").contains(where: { trashWords.contains(String($0)) }) { return named(names, then: .trash) }
            guard verb == "move" || verb == "put" else { return nil }          // "send this to Sam" is not a file move
            return named(names, then: .move(to: place.isEmpty || place == "here" ? nil : place))
        case "copy", "duplicate":
            if let index = lower.firstIndex(where: { ["to", "into"].contains($0) }) {
                let place = destination(rest[(index + 1)...])
                if !place.isEmpty, place != "here", place != "clipboard" {
                    return named(Array(rest[..<index]), then: .copyInto(place))
                }
                return named(Array(rest[..<index]), then: .copy)
            }
            return named(rest, then: .copy)
        case "rename":
            guard let index = lower.firstIndex(where: { $0 == "to" || $0 == "as" }), let newName = renameTarget(in: utterance) else {
                return nil
            }
            return named(Array(rest[..<index]), then: .rename(to: newName))
        default:
            return nil
        }
    }

    /// "select Projects and Portfolio", "select all", "select Projects and Portfolio and copy them".
    private nonisolated static func selectIntent(_ rest: [String]) -> JuneIntent? {
        let lower = rest.map { $0.lowercased() }
        guard let first = lower.first else { return nil }
        let actionVerbs: Set<String> = ["copy", "duplicate", "delete", "remove", "trash", "erase", "bin", "move", "put", "rename", "throw"]
        // A command after the names: "… and copy them", "… then delete them", "…, move them to Documents".
        var names = rest
        var then: JuneIntent.FileCommand?
        if let k = lower.indices.dropFirst().first(where: { actionVerbs.contains(lower[$0]) }) {
            let action = Array(rest[k...])
            switch action.count == 1 ? action[0].lowercased() : "" {
            case "copy", "duplicate": then = .copy
            case "delete", "remove", "trash", "erase", "bin": then = .trash
            default:
                let text = action.joined(separator: " ")
                let words = text.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init)
                if case .files(let command)? = fileIntent(words: words, original: text) { then = command }
            }
            if then != nil {
                names = Array(rest[..<k])
                while let last = names.last?.lowercased(), ["and", "then", ","].contains(last) { names.removeLast() }
            }
        }
        let all: Set<String> = ["all", "everything"]
        if all.contains(first), names.dropFirst().allSatisfy({
            ["files", "folders", "items", "of", "them", "the", "here", "in", "this", "folder", "window", "on", "desktop"].contains($0.lowercased())
        }) {
            return .files(.select(FileNames.everything, then: then))
        }
        return named(names, then: then)
    }

    private nonisolated static func named(_ words: [String], then: JuneIntent.FileCommand?) -> JuneIntent? {
        guard FileNames.namesSomething(words) else { return nil }
        return .files(.select(words.joined(separator: " "), then: then))
    }

    /// The new name in "rename this to Budget 2026", keeping how it was written.
    private nonisolated static func renameTarget(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)\b(?:rename|name)\b.*?\b(?:to|as)\b\s+(.+)$"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let name = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: " .!?,\"'“”"))
        return name.isEmpty ? nil : name
    }

    // MARK: Writing commands

    /// "fix the grammar", "make this more professional", "translate this to Spanish", "reply to this
    /// saying I'll be late", "click Send". Whether the text is replaced or the answer shown is decided
    /// later, by whether an editable text is selected.
    nonisolated static func writeIntent(words: [String], original: String) -> JuneIntent? {
        guard let first = words.first, words.count <= 40 else { return nil }
        let rest = Array(words.dropFirst())
        let set = Set(rest)

        // Send: "click Send", "hit send", "send it", "go ahead and send the email".
        let sendFillers: Set<String> = ["it", "this", "that", "the", "email", "message", "reply", "text", "now", "please", "off", "mail"]
        if ["click", "press", "hit", "tap", "push"].contains(first),
           rest.filter({ !["the", "on", "button", "now", "please"].contains($0) }) == ["send"] {
            return .write(.send)
        }
        if first == "send", rest.count <= 3, rest.allSatisfy({ sendFillers.contains($0) }) { return .write(.send) }

        // Reply.
        if let request = replyRequest(original) { return .write(.reply(request)) }

        guard words.count <= 16 else { return nil }
        let targets: Set<String> = ["this", "it", "that", "the", "my", "text", "selected", "selection", "sentence", "sentences",
                                    "paragraph", "paragraphs", "email", "message", "reply", "draft", "writing", "here", "all",
                                    "of", "in", "a", "bit", "please", "for", "me", "now", "up", "these", "lines", "line", "words"]

        // Translate: "translate this to Spanish", "translate it into French", "translate this".
        if first == "translate" {
            if let index = rest.lastIndex(where: { ["to", "into", "in"].contains($0) }), index + 1 < rest.count {
                let language = rest[(index + 1)...].filter { $0 != "please" && $0 != "now" }.map { $0.capitalized }.joined(separator: " ")
                return .write(.translate(language.isEmpty ? nil : language))
            }
            return rest.allSatisfy({ targets.contains($0) }) ? .write(.translate(nil)) : nil
        }

        // Fix: "fix the grammar", "proofread this", "fix the typos in this", "grammar check", "spell check this".
        let fixWords: Set<String> = ["grammar", "spelling", "typos", "typo", "punctuation", "mistakes", "errors", "capitalization",
                                     "capitalisation"]
        if ["fix", "correct", "proofread", "check"].contains(first) || (["grammar", "spell"].contains(first) && set.contains("check")) {
            let allowed = targets.union(fixWords).union(["check", "and", "any", "some"])
            guard rest.allSatisfy({ allowed.contains($0) }) else { return nil }
            if first == "check", set.isDisjoint(with: fixWords) { return nil }          // "check this" is a question
            return .write(.fix)
        }
        if ["clean", "tidy"].contains(first), set.contains("up"), rest.allSatisfy({ targets.contains($0) }) {
            return .write(.rewrite(original))
        }

        // Rewrite: the user's words are the instruction.
        let rewriteVerbs: Set<String> = ["rewrite", "rephrase", "reword", "simplify", "shorten", "lengthen", "expand", "polish",
                                         "soften", "paraphrase", "condense", "tighten", "formalize", "formalise", "restructure"]
        if rewriteVerbs.contains(first) { return .write(.rewrite(original)) }
        if first == "make", let target = rest.first, ["this", "it", "that", "the", "my", "these"].contains(target), rest.count >= 2 {
            return .write(.rewrite(original))
        }
        if ["turn", "convert", "change"].contains(first), let target = rest.first, ["this", "it", "that", "the", "my"].contains(target),
           !set.isDisjoint(with: ["into", "to", "tone"]) {
            return .write(.rewrite(original))
        }
        if first == "tone", set.contains("down") || set.contains("up") { return .write(.rewrite(original)) }
        // A bare style after a rewrite: "shorter", "more formal", "even friendlier", "less stiff".
        let styles: Set<String> = ["shorter", "longer", "simpler", "friendlier", "warmer", "politer", "clearer", "formal",
                                   "casual", "professional", "polite", "concise", "friendly", "persuasive", "confident",
                                   "stiff", "wordy", "direct", "fun", "funnier", "nicer", "gentler", "firmer", "punchier"]
        if words.count <= 4, words.contains(where: { styles.contains($0) }),
           words.allSatisfy({ styles.contains($0) || ["more", "less", "a", "bit", "little", "even", "much", "way", "please",
                                                     "slightly", "and", "too", "make", "it"].contains($0) }) {
            return .write(.rewrite(original))
        }
        return nil
    }

    /// What to say in "reply to this saying I'll be late", "respond to Sarah that I'm in",
    /// "write back yes sounds good". Nil if it isn't a reply request.
    nonisolated static func replyRequest(_ text: String) -> String? {
        let pattern = #"(?i)^\s*(?:(?:hey\s+)?june[,.!]?\s+)?(?:(?:can|could|would|will)\s+you\s+|please\s+|ok(?:ay)?[,]?\s+|just\s+|go\s+ahead\s+and\s+)*"#
            + #"(?:reply|respond|write\s+back|write\s+a\s+(?:reply|response)|draft\s+a\s+(?:reply|response)|send\s+a\s+reply|"#
            + #"answer\s+(?:this|that|the|his|her|their)\s+(?:email|message|text|mail))\b(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        var rest = String(text[range])
        // "back", then who or what it's to: "to this", "to this email", "to him", "to Sarah".
        let steps = [#"(?i)^\s*back\b"#,
                     #"(?i)^\s*to\s+(?:(?:the|his|her|their)\s+[\w'’-]+|(?:this|that)(?:\s+(?:email|message|text|mail|one|thread|chat))?|it|him|her|them|everyone|everybody|all)\b"#,
                     #"^\s*to\s+[A-Z][\w'’-]*(?:'s|’s)?(?:\s+(?:email|message|text|mail))?\b"#,
                     #"(?i)^\s*[,:;-]?\s*(?:saying|and\s+say|and\s+tell\s+(?:him|her|them)|telling\s+(?:him|her|them)|to\s+say|that|with|and\s+say\s+that)\b"#]
        for step in steps {
            if let r = try? NSRegularExpression(pattern: step),
               let m = r.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)), let whole = Range(m.range, in: rest) {
                rest.removeSubrange(whole)
            }
        }
        return rest.trimmingCharacters(in: CharacterSet(charactersIn: " ,:;-\n\t\"“”"))
    }

    private nonisolated static func closeIntent(words: [String]) -> JuneIntent? {
        guard let first = words.first, words.count <= 7 else { return nil }
        var rest = Array(words.dropFirst())
        if first == "quit" || first == "exit" {
            let name = rest.filter { !pointerWords.contains($0) && $0 != "app" && $0 != "application" }.joined(separator: " ")
            return .close(scope: .app, app: name.isEmpty ? nil : name)
        }
        guard first == "close" || first == "shut" else { return nil }
        if first == "shut" { guard rest.first == "down" else { return nil }; rest.removeFirst() }
        let set = Set(rest)
        if set.contains("tab") { return .close(scope: .tab, app: nil) }
        if set.contains("all") || set.contains("every") || set.contains("windows") {
            return .close(scope: .allWindows, app: nil)
        }
        if set.contains("app") || set.contains("application") || first == "shut" {
            return .close(scope: .app, app: nil)
        }
        let name = rest.filter { !pointerWords.contains($0) && $0 != "window" }.joined(separator: " ")
        if name.isEmpty { return .close(scope: .window, app: nil) }       // "close this window", "close it"
        // "close the Safari window" closes that app's windows; "close Spotify" quits it.
        return .close(scope: set.contains("window") ? .allWindows : .app, app: name)
    }

    private nonisolated static func openIntent(words: [String]) -> JuneIntent? {
        guard let first = words.first, words.count <= 9 else { return nil }
        var rest: [String]
        if first == "open" || first == "launch" {
            rest = Array(words.dropFirst())
        } else if first == "pull", words.dropFirst().first == "up" {
            rest = Array(words.dropFirst(2))                  // "pull up the resume folder"
        } else {
            return nil
        }
        rest = rest.filter { $0 != "for" && $0 != "me" && $0 != "on" && $0 != "screen" }
        let folder = rest.contains("folder") || rest.contains("directory")
        let fillers: Set<String> = ["folder", "directory", "file", "called", "named", "document", "app", "application"]
        let name = rest.filter { !pointerWords.contains($0) && !fillers.contains($0) }.joined(separator: " ")
        return .open(name: name.isEmpty ? nil : name, folder: folder)
    }

    /// Runs blocking work (Accessibility, file search) on a background thread and waits at most
    /// `seconds` for it. If another app stops responding, June carries on without it instead of
    /// staying on "Thinking…"; the slow call finishes (or times out) on its own in the background.
    private nonisolated static func result<T>(within seconds: Double, label: String,
                                              _ work: @escaping () -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = ResumeOnce(continuation)
            DispatchQueue.global(qos: .userInitiated).async { once.resume(work()) }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if once.resume(nil) { JuneLog.write("\(label) gave up after \(Int(seconds)) s") }
            }
        }
    }

    // MARK: Files

    /// What "this" is in Finder: the item under the pointer; otherwise what's selected in Finder (no
    /// need to open it); otherwise the folder of the Finder window (or the Desktop) under the pointer.
    /// The selection counts when the pointer is on Finder, or when Finder is in front and the request
    /// mentions a file, folder or selection, so asking about a web page isn't hijacked by a selection.
    /// `forAction`: a file command ("delete it"), which always means Finder's selection when Finder is in front.
    private func finderTarget(at point: CGPoint, utterance: String = "", forAction: Bool = false) async -> FinderTarget? {
        guard settings.fileAccess || settings.fileActions else { return nil }
        let overFinder = await Self.result(within: 2, label: "finder check") { FinderPointer.isFinder(at: point) } ?? false
        let lower = utterance.lowercased()
        let namesFiles = ["file", "folder", "selected", "selection", "these", "those", "document", "pdf", "image", "photo"]
            .contains { lower.contains($0) }
        guard overFinder || (FinderPointer.finderIsFrontmost && (namesFiles || forAction)) else { return nil }

        var pointed: FinderTarget?
        if overFinder {
            let folders = FinderScript.windowFolders()
            pointed = await Self.result(within: 3, label: "finder") { FinderPointer.resolve(at: point, windowFolders: folders) } ?? nil
            if case .item? = pointed { return pointed }
        }
        if FinderPointer.finderIsFrontmost {
            let selected = FinderScript.selection()
            if selected.count == 1 { return .item(selected[0]) }
            if selected.count > 1 { return .items(Array(selected.prefix(50))) }
        }
        return pointed
    }

    /// True when Finder is in front or the pointer is on a Finder window or the Desktop.
    private func inFinder(at point: CGPoint) async -> Bool {
        if FinderPointer.finderIsFrontmost { return true }
        return await Self.result(within: 2, label: "finder check") { FinderPointer.isFinder(at: point) } ?? false
    }

    /// What June selected by name a moment ago, if Finder still has it selected (a click elsewhere since wins).
    private func freshJuneSelection() -> [URL]? {
        guard let selection = juneSelection, Date().timeIntervalSince(selection.at) < 300 else { return nil }
        if selection.highlighted {
            let key: (URL) -> String = { $0.standardizedFileURL.path }
            guard Set(FinderScript.selection().map(key)) == Set(selection.urls.map(key)) else { return nil }
        }
        let existing = selection.urls.filter(FileActions.exists)
        return existing.isEmpty ? nil : existing
    }

    /// Copy, paste, move, rename, trash and undo. Everything is undoable and nothing is deleted for good.
    /// `explicit`: the items, when they were named out loud ("delete Projects").
    private func handleFiles(_ command: JuneIntent.FileCommand, point: CGPoint, utterance: String,
                             explicit: [URL]? = nil, note: String? = nil) async {
        guard settings.fileActions else {
            fail(.actionFailed("File actions are turned off in Settings › June."))
            return
        }
        if case .select(let phrase, let then) = command {
            await handleNamed(phrase, then: then, point: point, utterance: utterance)
            return
        }
        let lower = utterance.lowercased()
        let wantsSelection = ["these", "those", "them", "selected", "selection", "both"].contains { lower.contains($0) }
        var target: FinderTarget?
        if command != .undo { target = await finderTarget(at: point, utterance: utterance, forAction: true) }
        let finderInUse = await inFinder(at: point)
        let actions = fileActions

        func pointedItems() -> [URL] {
            if let explicit { return explicit }
            if let named = freshJuneSelection() { return named }
            if wantsSelection {
                let selected = FinderScript.selection()
                if !selected.isEmpty { return selected }
            }
            switch target {
            case .item(let url)?: return [url]
            case .items(let urls)?: return urls
            default:
                // What June just read or moved, but only while Finder is in use: "delete it" in another
                // app must never trash a file from earlier.
                guard finderInUse, Date().timeIntervalSince(lastFilesAt) < 300 else { return [] }
                return lastFiles
            }
        }
        func destination() -> URL? {
            switch target {
            case .folder(let folder)?: return folder
            case .item(let url)?: return FileActions.isFolder(url) ? url : url.deletingLastPathComponent()
            case .items(let urls)?: return urls.count == 1 && FileActions.isFolder(urls[0]) ? urls[0] : nil
            case nil: return nil
            }
        }
        func timeout(_ what: String) -> FileActions.Outcome {
            FileActions.Outcome(ok: false, message: "\(what) took too long; check the folder in Finder.", items: [])
        }

        var outcome: FileActions.Outcome
        switch command {
        case .copy:
            let items = pointedItems()
            guard !items.isEmpty else { fail(.actionFailed("Select a file or folder in Finder (or point at it), then say “copy this”.")); return }
            outcome = actions.copy(items)
            if outcome.ok {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(items as [NSURL])     // ⌘V in Finder works too
            }
        case .copyInto(let name):
            guard let folder = FileActions.folder(named: name) else {
                fail(.actionFailed("I couldn't find a folder called “\(name)”."))
                return
            }
            let items = pointedItems()
            guard !items.isEmpty else { fail(.actionFailed("Select what you want copied in Finder, then say where.")); return }
            outcome = await Self.result(within: 60, label: "copy") { actions.paste(items, into: folder) } ?? timeout("Copying")
            if outcome.ok { outcome.message = "Put a copy of \(FileActions.describe(items)) in \(folder.lastPathComponent)" }
        case .paste:
            guard let folder = destination() else {
                fail(.actionFailed("Point at a folder or an open Finder window, then say “paste it here”."))
                return
            }
            var items = actions.clipboard
            if items.isEmpty {
                items = (NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            }
            guard !items.isEmpty else { fail(.actionFailed("Nothing to paste yet. Point at a file and say “copy this” first.")); return }
            outcome = await Self.result(within: 60, label: "paste") { actions.paste(items, into: folder) } ?? timeout("Pasting")
        case .move(let name):
            if let name {
                guard let folder = FileActions.folder(named: name) else {
                    fail(.actionFailed("I couldn't find a folder called “\(name)”."))
                    return
                }
                let items = pointedItems()
                guard !items.isEmpty else { fail(.actionFailed("Select what you want moved in Finder, then say where.")); return }
                outcome = await Self.result(within: 60, label: "move") { actions.move(items, to: folder) } ?? timeout("Moving")
            } else {
                // "Move this here": the pointer is on the destination; "this" is what June last worked with.
                guard let folder = destination() else {
                    fail(.actionFailed("Point at the folder it should go in, then say “move it here”."))
                    return
                }
                let items = explicit ?? (!actions.clipboard.isEmpty ? actions.clipboard : (freshJuneSelection() ?? lastFiles))
                guard !items.isEmpty else {
                    fail(.actionFailed("First point at the file and say “copy this” (or ask about it), then point here and say “move it here”."))
                    return
                }
                outcome = await Self.result(within: 60, label: "move") { actions.move(items, to: folder) } ?? timeout("Moving")
                if outcome.ok { actions.clipboard = [] }
            }
        case .rename(let newName):
            let items = pointedItems()
            guard items.count == 1, let item = items.first else {
                fail(.actionFailed(items.isEmpty ? "Select the file you want renamed in Finder (or point at it)." : "Rename one item at a time."))
                return
            }
            outcome = await Self.result(within: 15, label: "rename") { actions.rename(item, to: newName) } ?? timeout("Renaming")
        case .trash:
            let items = pointedItems()
            guard !items.isEmpty else {
                fail(.actionFailed(finderInUse
                    ? "Select it in Finder (or point at it), then say “delete it”. Or say its name: “delete Projects”."
                    : "Click the Finder window (or the Desktop) with it first, then say “delete it”."))
                return
            }
            JuneLog.write("trash \(items.count) item(s): \(items.map(\.lastPathComponent).joined(separator: ", "))")
            outcome = await Self.result(within: 60, label: "trash") { actions.trash(items) } ?? timeout("Moving to the Trash")
        case .undo:
            outcome = await Self.result(within: 60, label: "undo") { actions.undo() } ?? timeout("Undoing")
        case .select:
            return                                       // handled above
        }

        if outcome.ok {
            if !outcome.items.isEmpty { lastFiles = outcome.items }
            if command == .trash { lastFiles = [] }
            if command != .copy { juneSelection = nil }
            if command != .copy { lastWrite = nil }
            if let note { outcome.message += ". " + note }
        }
        JuneLog.write("file \(command) ok=\(outcome.ok) \(outcome.message)")
        finishAction(ScreenActions.Outcome(ok: outcome.ok, message: outcome.message))
        panel.model.canUndo = outcome.ok && actions.canUndo && command != .copy
        if outcome.ok, settings.speakReplies { say(outcome.message) }
    }

    /// "select Projects and Portfolio", "delete Projects": finds the named items in the Finder window
    /// under the pointer, the other Finder windows and the Desktop, selects them in Finder, then does
    /// `then` to them. Never searches the whole disk, so a name can only act on something on screen.
    private func handleNamed(_ phrase: String, then: JuneIntent.FileCommand?, point: CGPoint, utterance: String) async {
        let places = await namePlaces(at: point)
        let listed = await listings(of: places)
        let whereLooked = Self.placesLabel(places)
        let found: [URL]
        var note: String?
        if phrase == FileNames.everything {
            found = listed.first ?? []
            guard !found.isEmpty else { fail(.actionFailed("There's nothing \(Self.placesLabel(Array(places.prefix(1)))) to select.")); return }
        } else {
            let resolution = FileNames.resolve(phrase, places: listed)
            if let unclear = resolution.ambiguous.first {
                let options = unclear.candidates.prefix(4).map(\.lastPathComponent)
                fail(.actionFailed("Which “\(unclear.name)” do you mean: \(Self.list(options, joiner: "or"))?"))
                return
            }
            found = resolution.found
            if !resolution.missing.isEmpty {
                let missing = Self.list(resolution.missing.map { "“\($0)”" }, joiner: "or")
                // Nothing goes in the Trash unless everything named was found.
                if found.isEmpty || then == .trash {
                    fail(.actionFailed("I couldn't find \(missing) \(whereLooked)."))
                    JuneLog.write("named: missing \(resolution.missing) in \(places.map(\.lastPathComponent))")
                    return
                }
                note = "I couldn't find \(missing)"
            }
        }
        lastFiles = found
        let highlighted = FinderScript.select(found)
        juneSelection = (found, Date(), highlighted)
        JuneLog.write("selected by name: \(found.map(\.lastPathComponent).joined(separator: ", ")) highlighted=\(highlighted)")

        // "select all and delete them" only selects: a whole folder goes in the Trash only when asked about what's selected.
        if let then, !(then == .trash && phrase == FileNames.everything) {
            await handleFiles(then, point: point, utterance: utterance, explicit: found, note: note)
            return
        }
        var message = "Selected \(FileActions.describe(found))"
        if let note { message += ". " + note }
        if then == .trash { message += ". Say “delete these” to put them in the Trash" }
        JuneLog.write("action ok=true \(message)")
        setState(.notice(message))
        sendWatchState?(.idle)
        if settings.speakReplies { say(message) }
    }

    /// Where a spoken name is looked for, most likely first: the Finder window (or Desktop) under the
    /// pointer, where the current selection is, the other Finder windows front to back, the Desktop.
    private func namePlaces(at point: CGPoint) async -> [URL] {
        let windows = FinderScript.windowFolders()
        var places: [URL] = []
        if let target = await Self.result(within: 3, label: "finder", { FinderPointer.resolve(at: point, windowFolders: windows) }) ?? nil {
            switch target {
            case .folder(let folder): places.append(folder)
            case .item(let url): places.append(url.deletingLastPathComponent())
            case .items(let urls): places += urls.map { $0.deletingLastPathComponent() }
            }
        }
        places += FinderScript.selection().map { $0.deletingLastPathComponent() }
        places += windows.map(\.url)
        places.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true))
        var seen = Set<String>()
        return places.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// The items in each place. Folders macOS hasn't let Gauntlet read yet are listed by Finder.
    private func listings(of places: [URL]) async -> [[URL]] {
        let unlisted: [[URL]?] = places.map { _ in nil }
        let direct: [[URL]?] = await Self.result(within: 5, label: "list folders") {
            places.map { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.isDirectoryKey],
                                                                      options: [.skipsHiddenFiles]) }
        } ?? unlisted
        return zip(places, direct).map { place, items in items ?? FinderScript.contents(of: place) ?? [] }
    }

    private static func placesLabel(_ places: [URL]) -> String {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").standardizedFileURL.path
        let names = places.prefix(3).map { $0.standardizedFileURL.path == desktop ? "on the Desktop" : "in \($0.lastPathComponent)" }
        return names.isEmpty ? "in Finder" : list(names, joiner: "or")
    }

    /// "A", "A and B", "A, B and C".
    private nonisolated static func list(_ items: [String], joiner: String = "and") -> String {
        guard let last = items.last else { return "" }
        return items.count == 1 ? last : items.dropLast().joined(separator: ", ") + " \(joiner) " + last
    }

    // MARK: Writing

    /// Fixes, rewrites or translates the text selected in the app in front and puts the result in its
    /// place by pasting, so the app's own ⌘Z (or "undo") brings the old text back. With nothing
    /// selected it uses what June just wrote ("shorter" right after), or the whole text box for an
    /// explicit command ("fix the grammar"). False when there's no editable text: June answers instead.
    private func editSelection(_ command: JuneIntent.WriteCommand, utterance: String) async -> Bool {
        guard AXIsProcessTrusted(), let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ContextCapture.ownPID else { return false }
        let pid = front.processIdentifier
        let appName = front.localizedName ?? "the app"
        ContextCapture.enableWebAccessibility(pid)
        guard let field = await Self.result(within: 3, label: "selection", { TextEditing.focusedField() }) ?? nil,
              field.pid == pid else { return false }

        var original = field.selected ?? ""
        var whole = false
        var checkSelection = field.selected != nil
        if original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            original = ""
            let recent = lastWrite.flatMap { $0.pid == pid && Date().timeIntervalSince($0.at) < 180 ? $0.text : nil }
            if let recent, await Self.result(within: 2, label: "reselect", { TextEditing.select(recent, in: field.element) }) == true {
                original = recent
            } else if field.selected == nil, let copied = await TextEditing.copySelection(sendKeyCombo: sendKeyCombo),
                      !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                original = copied                                  // the app doesn't report its selection
                checkSelection = false
            } else if wholeFieldAllowed(command, utterance: utterance), field.role == kAXTextAreaRole, let value = field.value,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 5000 {
                let selected = await Self.result(within: 2, label: "select all") { TextEditing.selectAll(in: field.element, value: value) } ?? false
                if !selected {
                    sendKeyCombo?(0, CGEventFlags.maskCommand.rawValue)          // ⌘A in the text box
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    checkSelection = false
                }
                original = value
                whole = true
            }
        }
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let key = apiKeyProvider(), !key.isEmpty else { fail(.noAPIKey); return true }

        let instruction: String
        let working: String
        let done: String
        let spoken: String
        switch command {
        case .fix:
            instruction = "Fix the grammar, spelling and punctuation (or the bugs, if it's code), changing as little as possible."
            working = "Fixing the grammar…"
            done = whole ? "Fixed the grammar of the whole text" : "Fixed the grammar"
            spoken = "Fixed it."
        case .translate(let language):
            let target = language ?? settings.targetLanguage
            instruction = "Translate it into \(target)."
            working = "Translating to \(target)…"
            done = "Translated to \(target)"
            spoken = "Translated."
        case .rewrite(let words):
            instruction = words
            working = "Rewriting…"
            done = whole ? "Rewrote the whole text" : "Rewrote it"
            spoken = "Done."
        case .reply, .send:
            return false
        }
        setState(.captured(summary: working))
        startWatchdog(seconds: 45)
        let output: String
        do {
            output = try await complete(system: GeminiRequest.editInstruction + preferenceSuffix(),
                                        userText: GeminiRequest.editText(instruction: instruction, text: original, app: appName),
                                        maxTokens: min(8192, max(400, original.count + 300)), key: key)
        } catch {
            handleWritingError(error)
            return true
        }
        watchdog = nil
        let replacement = TextEditing.cleaned(output, like: original)
        guard !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { fail(.emptyAnswer); return true }
        if replacement == original {
            setState(.notice(command == .fix ? "Nothing to fix" : "No changes needed"))
            sendWatchState?(.idle)
            if settings.speakReplies, command == .fix { say("Looks right to me. Nothing to fix.") }
            return true
        }

        // Paste only over the same text in the same box: if the user clicked elsewhere meanwhile, copy instead.
        let now = await Self.result(within: 2, label: "selection", { TextEditing.focusedField() }) ?? nil
        func same(_ a: String?, _ b: String) -> Bool {
            guard let a else { return true }
            let norm: (String) -> String = { $0.replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
            return norm(a) == norm(b)
        }
        let stillThere = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            && (now.map { CFEqual($0.element, field.element) } ?? false)
            && (!checkSelection || same(now?.selected, original))
        lastAnswer = replacement
        guard stillThere else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(replacement, forType: .string)
            statusLine = "The selection changed, so it's copied instead: press ⌘V where it goes"
            setState(.answer(text: replacement, streaming: false))
            sendWatchState?(.idle)
            JuneLog.write("edit: selection moved, copied instead")
            return true
        }
        _ = await TextEditing.paste(replacement, sendKeyCombo: sendKeyCombo)
        lastWrite = (replacement, pid, Date())
        statusLine = "\(done) · say “undo” or press ⌘Z to put it back"
        setState(.answer(text: replacement, streaming: false))
        panel.model.canUndo = true
        sendWatchState?(.idle)
        if settings.speakReplies { say(spoken) }
        JuneLog.write("edited \(command) chars=\(original.count)->\(replacement.count) whole=\(whole) app=\(appName)")
        return true
    }

    /// The whole text box is used only when asked about it ("fix the grammar", "make this shorter"),
    /// never for a bare "shorter" that follows one of June's answers.
    private func wholeFieldAllowed(_ command: JuneIntent.WriteCommand, utterance: String) -> Bool {
        if lastAnswer != nil, Date().timeIntervalSince(historyUpdated) < 120, isFollowUp(utterance) { return false }
        switch command {
        case .fix, .translate: return true
        default:
            let lower = utterance.lowercased()
            return Self.refersToSomething(utterance)
                || ["text", "email", "message", "draft", "paragraph", "reply"].contains { lower.contains($0) }
        }
    }

    /// "Reply to this saying I'll be late": reads the message under the pointer (and the conversation
    /// around it), has Gemini write the reply as the user, and types it into the reply box. In Mail
    /// and Outlook it opens a reply first. It never sends: that takes "click Send".
    private func draftReply(_ request: String, point: CGPoint) async {
        guard AXIsProcessTrusted() else { fail(.needsAccessibility); return }
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ContextCapture.ownPID else {
            fail(.actionFailed("Click the conversation you're replying to, then ask again."))
            return
        }
        let pid = front.processIdentifier
        let appName = front.localizedName ?? "the app"
        let bundle = front.bundleIdentifier ?? ""
        ContextCapture.enableWebAccessibility(pid)
        guard let key = apiKeyProvider(), !key.isEmpty else { fail(.noAPIKey); return }

        setState(.captured(summary: "Reading the message…"))
        let capture = await Self.result(within: 3, label: "capture") { ContextCapture.capture(at: point) }
        let document = await Self.result(within: 6, label: "document read") { DocumentReader.read(at: point) } ?? nil
        var parts: [String] = []
        let pointed = capture?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !pointed.isEmpty { parts.append("The message pointed at:\n" + String(pointed.prefix(3000))) }
        if let whole = document?.text.trimmingCharacters(in: .whitespacesAndNewlines), !whole.isEmpty, whole != pointed {
            let text = whole.count > 8000 ? String(whole.prefix(4000)) + "\n…\n" + String(whole.suffix(4000)) : whole
            parts.append("The whole conversation or email:\n" + text)
        }
        var image: Data?
        if parts.isEmpty, settings.screenVision, CGPreflightScreenCaptureAccess() {
            image = try? await ScreenGrab.capture(around: point, cursor: point).jpeg
        }
        guard !parts.isEmpty || image != nil else {
            fail(.actionFailed("I couldn't read the message. Point at it (or select it), then say “reply to this saying …”."))
            return
        }

        setState(.captured(summary: "Writing the reply…"))
        startWatchdog(seconds: 45)
        let output: String
        do {
            output = try await complete(system: GeminiRequest.replyInstruction + preferenceSuffix(),
                                        userText: GeminiRequest.replyText(request: request, conversation: parts.joined(separator: "\n\n"),
                                                                          app: appName),
                                        image: image, maxTokens: 800, key: key)
        } catch {
            handleWritingError(error)
            return
        }
        watchdog = nil
        let reply = TextEditing.cleaned(output, like: "")
        guard !reply.isEmpty else { fail(.emptyAnswer); return }
        lastAnswer = reply

        // The reply box: where the cursor is; in Mail and Outlook a new reply (⌘R); in chat apps the message box.
        func focusedBox() async -> TextEditing.Field? {
            guard let field = await Self.result(within: 2, label: "field", { TextEditing.focusedField() }) ?? nil,
                  field.pid == pid, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
            return field
        }
        var box = await focusedBox()
        if box == nil, TextEditing.replyShortcutApps.contains(bundle) {
            sendKeyCombo?(15, CGEventFlags.maskCommand.rawValue)                 // ⌘R: Reply
            for _ in 0..<15 where box == nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                box = await focusedBox()
            }
        } else if box == nil, !TextEditing.browsers.contains(bundle),
                  let found = await Self.result(within: 4, label: "reply box", { TextEditing.replyBox(pid: pid) }) ?? nil,
                  await Self.result(within: 2, label: "focus", { TextEditing.focus(found) }) == true {
            box = await focusedBox()
        }
        guard box != nil else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(reply, forType: .string)
            statusLine = "Copied: click in the reply box and press ⌘V"
            setState(.answer(text: reply, streaming: false))
            sendWatchState?(.idle)
            if settings.speakReplies { say("I wrote it and copied it. Click the reply box and paste it.") }
            JuneLog.write("reply: no reply box in \(appName), copied")
            return
        }
        _ = await TextEditing.paste(reply, sendKeyCombo: sendKeyCombo)
        lastWrite = (reply, pid, Date())
        statusLine = "Typed in \(appName), not sent · say “click Send” to send it"
        setState(.answer(text: reply, streaming: false))
        panel.model.canUndo = true
        sendWatchState?(.idle)
        if settings.speakReplies { say("It's in the reply box. Say click Send when it looks right.") }
        JuneLog.write("reply typed chars=\(reply.count) app=\(appName)")
    }

    /// "Click Send": presses the Send button in the front window (Mail, Outlook, Gmail…), or Return in
    /// chat apps that have none. Only ever done when the user says so.
    private func pressSend() async {
        guard AXIsProcessTrusted() else { fail(.needsAccessibility); return }
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ContextCapture.ownPID else {
            fail(.actionFailed("Click the message you want to send, then say “click Send”."))
            return
        }
        let pid = front.processIdentifier
        let appName = front.localizedName ?? "the app"
        ContextCapture.enableWebAccessibility(pid)
        var how = "Send button"
        let pressed = await Self.result(within: 5, label: "send") { TextEditing.pressSendButton(pid: pid) } ?? false
        if !pressed {
            let field = await Self.result(within: 2, label: "field") { TextEditing.focusedField() } ?? nil
            guard let bundle = front.bundleIdentifier, TextEditing.returnSendsApps.contains(bundle), field?.pid == pid else {
                fail(.actionFailed("I couldn't find a Send button in \(appName). Click Send yourself when it's ready."))
                return
            }
            sendKeyCombo?(36, 0)                                                 // Return sends in chat apps
            how = "Return"
        }
        lastWrite = nil
        panel.model.canUndo = false
        JuneLog.write("sent in \(appName) with \(how)")
        setState(.notice("Sent"))
        sendWatchState?(.idle)
        if settings.speakReplies { say("Sent.") }
    }

    /// "Undo" right after June wrote something: ⌘Z in that app.
    private func undoWriting(_ write: (text: String, pid: pid_t, at: Date)) {
        lastWrite = nil
        panel.model.canUndo = false
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == write.pid else {
            fail(.actionFailed("Go back to the app June wrote in and press ⌘Z there."))
            return
        }
        sendKeyCombo?(6, CGEventFlags.maskCommand.rawValue)                      // ⌘Z
        JuneLog.write("undid writing with ⌘Z")
        setState(.notice("Put the old text back"))
        sendWatchState?(.idle)
        if settings.speakReplies { say("Undone.") }
    }

    private func handleWritingError(_ error: Error) {
        if Task.isCancelled || error is CancellationError { return }
        voice.stop()
        fail(error as? JuneError ?? .noNetwork)
    }

    /// The user's own instructions from Settings › June, for the writing prompts.
    private func preferenceSuffix() -> String {
        let custom = settings.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? "" : "\n\nThe user's preferences (follow them unless they conflict with the rules above):\n"
            + String(custom.prefix(1000))
    }

    /// One Gemini call whose whole text is needed at once (no streaming to the screen), with the same
    /// model fallback as answers.
    private func complete(system: String, userText: String, image: Data? = nil, maxTokens: Int, key: String) async throws -> String {
        let models = GeminiClient.modelChain(override: settings.modelOverride)
        var index = 0
        var attempt = 0
        while true {
            attempt += 1
            let model = models[index]
            let body = try GeminiRequest.body(userText: userText, imageJPEG: image, functions: [], forced: nil,
                                              thinkingLevel: thinkingLevel, system: system, maxOutputTokens: maxTokens)
            var text = ""
            do {
                for try await event in client.stream(body: body, apiKey: key, model: model) {
                    if Task.isCancelled { throw CancellationError() }
                    switch event {
                    case .text(let delta): text += delta
                    case .blocked(let reason): throw JuneError.blocked(reason)
                    default: break
                    }
                }
                if GeminiClient.workingModel != model { GeminiClient.workingModel = model }
                return text
            } catch let error as JuneError where GeminiClient.shouldTryNextModel(error) && index + 1 < models.count {
                JuneLog.write("model \(model) unavailable (\(error)); trying \(models[index + 1])")
                index += 1
            } catch JuneError.http(let code, let detail) where code == 400 && attempt <= 4 && thinkingLevel != nil
                        && detail.lowercased().contains("thinking") {
                thinkingLevel = nil                                              // this model rejects thinkingLevel
            }
        }
    }

    /// Shows the result of a Mac-side action (close, open) as a toast or an error.
    private func finishAction(_ outcome: ScreenActions.Outcome) {
        JuneLog.write("action ok=\(outcome.ok) \(outcome.message)")
        if outcome.ok {
            setState(.notice(outcome.message))
            sendWatchState?(.idle)
        } else {
            fail(.actionFailed(outcome.message))
        }
    }

    private nonisolated static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private func process(utterance rawUtterance: String, speechEnded: Date, point: CGPoint, trigger: String) async {
        let utterance = Self.stripWakeWords(rawUtterance).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !utterance.isEmpty else { fail(.noSpeech); return }
        let intent = Self.intent(for: utterance)
        answerSources = []
        statusLine = ""

        // Commands handled on the Mac, instantly.
        switch intent {
        case .stop:
            voice.stop()
            onCaptureFrame?(nil)
            endConversation()
            setState(.notice("Okay"))
            sendWatchState?(.idle)
            return
        case .copyAnswer:
            // "Copy this" on a file or folder (pointed at or selected) copies the file, not June's answer.
            if settings.fileActions, let target = await finderTarget(at: point, utterance: utterance), !target.isWindowBackground {
                await handleFiles(.copy, point: point, utterance: utterance)
                return
            }
            guard lastAnswer != nil else { fail(.nothingToCopy); return }
            copyAnswer()
            setState(.notice("Copied the answer"))
            sendWatchState?(.idle)
            return
        case .files(let command):
            // "Undo" right after June wrote something: the app's own ⌘Z.
            if command == .undo, let write = lastWrite, Date().timeIntervalSince(write.at) < 300 {
                undoWriting(write)
                return
            }
            if case .select(_, let then) = command, !(await inFinder(at: point)) {
                // Named, but not in Finder: "copy the answer"-like words, or a question for Gemini.
                if then == .copy, lastAnswer != nil, utterance.split(separator: " ").count <= 4 {
                    copyAnswer()
                    setState(.notice("Copied the answer"))
                    sendWatchState?(.idle)
                    return
                }
                break
            }
            await handleFiles(command, point: point, utterance: utterance)
            return
        case .write(let command):
            guard settings.writingActions else { break }          // switched off: June answers in her window
            switch command {
            case .send:
                await pressSend()
                return
            case .reply(let request):
                await draftReply(request, point: point)
                return
            case .fix, .rewrite, .translate:
                // Nothing editable selected (text on a web page, a PDF): answer in the June window as before.
                if await editSelection(command, utterance: utterance) { return }
            }
        case .endConversation:
            onCaptureFrame?(nil)
            endConversation()
            setState(.notice("Anytime"))
            sendWatchState?(.idle)
            if settings.speakReplies { say(["Anytime.", "You got it.", "Happy to help."].randomElement() ?? "Anytime.") }
            return
        case .type(let text):
            guard AXIsProcessTrusted() else { fail(.needsAccessibility); return }
            guard TextInserter.focusedTextField() != nil else { fail(.noTextField); return }
            let ok = await TextInserter.insert(text, sendKeyCombo: sendKeyCombo)
            if ok {
                setState(.notice("Typed it"))
                sendWatchState?(.idle)
                JuneLog.write("typed chars=\(text.count)")
            } else {
                fail(.noTextField)
            }
            return
        case .close(let scope, let app):
            guard AXIsProcessTrusted() else { fail(.needsAccessibility); return }
            let actionScope: ScreenActions.CloseScope = {
                switch scope { case .window: return .window; case .allWindows: return .allWindows
                               case .tab: return .tab; case .app: return .app }
            }()
            let (outcome, needsCommandW) = await Self.result(within: 6, label: "close") {
                ScreenActions.close(actionScope, at: point, appName: app)
            } ?? (ScreenActions.Outcome(ok: false, message: "That app didn't respond."), false)
            if needsCommandW {
                try? await Task.sleep(nanoseconds: 250_000_000)          // let the app come forward
                sendKeyCombo?(13, CGEventFlags.maskCommand.rawValue)      // ⌘W
            }
            finishAction(outcome)
            return
        case .open(let name, let folder):
            let outcome = await Self.result(within: 8, label: "open") {
                ScreenActions.open(name: name, preferFolder: folder, at: point)
            } ?? ScreenActions.Outcome(ok: false, message: "Opening that took too long.")
            finishAction(outcome)
            return
        case .readAloud, .document, .look, .ask:
            break
        }
        if Date().timeIntervalSince(historyUpdated) > 180 {
            history = []
            pinnedContext = nil
        }

        let trusted = AXIsProcessTrusted()
        if !trusted, intent == .readAloud || intent == .document { fail(.needsAccessibility); return }

        // What is the user pointing at?
        var contextText: String?
        var sourceName = "none"
        var frame: CGRect?
        var image: Data?
        var appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown app"
        var editable = false
        var documentTitle: String?

        // Pointing at something in Finder or on the Desktop: read the real file or folder.
        var finderRead = false
        if settings.fileAccess, intent != .look, let target = await finderTarget(at: point, utterance: utterance) {
            let urls = target.urls
            setState(.captured(summary: "Looking at \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items")…"))
            if let report = await Self.result(within: 10, label: "file read", { FileReport.describe(urls) }) ?? nil {
                contextText = report.text
                image = report.imageJPEG
                sourceName = report.isFolder ? "folder: \(report.name)" : "file: \(report.name)"
                appName = "Finder"
                statusLine = report.isFolder ? "Looked inside \(report.name)" : "Read \(report.name)"
                documentTitle = report.isFolder ? nil : report.name
                lastFiles = urls
                finderRead = true
                JuneLog.write("read \(report.isFolder ? "folder" : "file") chars=\(report.text.count) image=\(report.imageJPEG != nil)")
            }
        }

        if finderRead {
            // Already have the file or folder.
        } else if intent == .look {
            guard settings.screenVision else { fail(.unsupported("Looking at the screen (turn it on in Settings › June)")); return }
            setState(.captured(summary: "Looking at your screen…"))
            let wholeScreen = utterance.lowercased().contains("screen")
            do {
                let shot = try await ScreenGrab.capture(around: wholeScreen ? nil : point, cursor: point)
                image = shot.jpeg
                frame = shot.frame
                sourceName = wholeScreen ? "screenshot of the screen" : "screenshot around the pointer"
                statusLine = "Looked at your screen"
            } catch let error as JuneError {
                fail(error); return
            } catch {
                fail(.screenRecordingDenied); return
            }
        } else if trusted {
            var document: DocumentContext?
            if intent == .document {
                setState(.captured(summary: "Reading the whole document…"))
                document = await Self.result(within: 8, label: "document read") { DocumentReader.read(at: point) } ?? nil
            }
            if let document {
                contextText = document.text
                sourceName = "document (\(document.kind)): \(document.title)"
                frame = document.frame
                appName = document.appName
                documentTitle = document.title
                statusLine = "Read \(document.title)"
            } else {
                let capture = await Self.result(within: 3, label: "capture") { ContextCapture.capture(at: point) }
                    ?? CaptureResult(text: nil, imageJPEG: nil, frame: nil, appName: appName, focusedEditable: false, source: .none)
                contextText = capture.text
                sourceName = capture.source.rawValue
                frame = capture.frame
                appName = capture.appName
                editable = capture.focusedEditable
                if contextText != nil {
                    statusLine = capture.source == .selection ? "Read your selection in \(appName)" : "Read what's under the pointer in \(appName)"
                }
            }
        }
        if Task.isCancelled { return }

        // Nothing readable, but the user asked about "this": look at the screen instead.
        if contextText == nil, image == nil, settings.screenVision, Self.refersToSomething(utterance),
           CGPreflightScreenCaptureAccess(), intent != .readAloud {
            if let shot = try? await ScreenGrab.capture(around: point, cursor: point) {
                image = shot.jpeg
                frame = shot.frame
                sourceName = "screenshot around the pointer"
                statusLine = "Looked at your screen"
            }
        }
        if let text = contextText {
            pinnedContext = (text, sourceName)
        } else if image == nil, !history.isEmpty, let pinned = pinnedContext {
            contextText = pinned.text
            sourceName = "earlier: \(pinned.source)"
        } else if image == nil, isFollowUp(utterance) {
            contextText = lastAnswer
            sourceName = "last answer"
        }
        onCaptureFrame?(frame)

        if intent == .readAloud {
            guard let text = contextText ?? lastAnswer else { fail(.emptyCapture); return }
            let spoken = String(text.prefix(3000))
            statusLine = "Reading aloud"
            setState(.answer(text: spoken, streaming: false))
            say(spoken)
            sendWatchState?(.idle)
            JuneLog.write("read aloud chars=\(spoken.count) source=\(sourceName)")
            return
        }

        guard let key = apiKeyProvider(), !key.isEmpty else { fail(.noAPIKey); return }

        if let documentTitle {
            setState(.captured(summary: "Reading the whole document: \(documentTitle)"))
        } else if let text = contextText {
            let preview = text.replacingOccurrences(of: "\n", with: " ").prefix(60)
            setState(.captured(summary: "Reading: \(preview)\(text.count > 60 ? "…" : "")"))
        } else if image != nil {
            setState(.captured(summary: "Looking at your screen…"))
        }

        let userText = GeminiRequest.userText(utterance: utterance, appName: appName, capturedText: contextText,
                                              captureSource: sourceName, focusedEditable: editable,
                                              pocket: nil, lastAnswer: lastAnswer, targetLanguage: settings.targetLanguage)
        let useSearch = settings.webSearch && image == nil
        let system = GeminiRequest.instruction(length: settings.answerLength, spoken: settings.speakReplies,
                                               custom: settings.customInstructions, webSearch: useSearch)
        let models = GeminiClient.modelChain(override: settings.modelOverride)
        var modelIndex = 0
        var model = models[0]
        let requestStarted = Date()
        var firstToken: Date?
        var answer = ""
        startWatchdog(seconds: documentTitle == nil && image == nil ? 30 : 50)
        voice.begin(settings: settings, apiKey: key, client: client)

        do {
            var attempt = 0
            var searchAllowed = useSearch
            while true {
                attempt += 1
                let body = try GeminiRequest.body(userText: userText, imageJPEG: image, functions: [], forced: nil,
                                                  thinkingLevel: thinkingLevel, system: system,
                                                  maxOutputTokens: settings.answerLength.maxOutputTokens,
                                                  history: history, webSearch: searchAllowed)
                do {
                    answer = ""
                    for try await event in client.stream(body: body, apiKey: key, model: model) {
                        if Task.isCancelled { return }
                        switch event {
                        case .text(let delta):
                            if firstToken == nil { firstToken = Date() }
                            answer += delta
                            setState(.answer(text: answer, streaming: true))
                            voice.feed(delta)
                        case .sources(let titles):
                            for title in titles where !answerSources.contains(title) { answerSources.append(title) }
                            statusLine = "Searched the web"
                        case .functionCall(let name, _):
                            throw JuneError.unsupported(name)
                        case .blocked(let reason):
                            throw JuneError.blocked(reason)
                        case .done:
                            break
                        }
                    }
                    break
                } catch let error as JuneError where GeminiClient.shouldTryNextModel(error) && answer.isEmpty
                                                     && modelIndex + 1 < models.count {
                    JuneLog.write("model \(model) unavailable (\(error)); trying \(models[modelIndex + 1])")
                    modelIndex += 1
                    model = models[modelIndex]
                    continue
                } catch JuneError.http(let code, let detail) where code == 400 && attempt <= 4 {
                    let lower = detail.lowercased()
                    if thinkingLevel != nil, lower.contains("thinking") {
                        thinkingLevel = nil          // this model rejects thinkingLevel; retry without it
                        continue
                    }
                    if searchAllowed, lower.contains("search") || lower.contains("tool") {
                        searchAllowed = false        // search grounding not available for this model or key
                        continue
                    }
                    throw JuneError.http(code, detail)
                }
            }
        } catch is CancellationError {
            return
        } catch let error as JuneError {
            if Task.isCancelled { return }
            voice.stop()
            fail(error)
            return
        } catch {
            if Task.isCancelled { return }
            voice.stop()
            fail(.noNetwork)
            return
        }
        watchdog = nil
        if GeminiClient.workingModel != model {
            GeminiClient.workingModel = model
            JuneLog.write("answer model: \(model)")
        }

        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { voice.stop(); fail(.emptyAnswer); return }
        lastAnswer = trimmed
        history.append(JuneTurn(role: "user", text: utterance))
        history.append(JuneTurn(role: "model", text: trimmed))
        if history.count > 12 { history.removeFirst(history.count - 12) }
        historyUpdated = Date()
        setState(.answer(text: trimmed, streaming: false))
        voice.finish()
        sendWatchState?(.idle)

        let now = Date()
        let toFirst = firstToken.map { Int($0.timeIntervalSince(speechEnded) * 1000) } ?? -1
        let request = firstToken.map { Int($0.timeIntervalSince(requestStarted) * 1000) } ?? -1
        JuneLog.write("done trigger=\(trigger) intent=\(intent) model=\(model) app=\(appName) source=\(sourceName) "
                      + "contextChars=\(contextText?.count ?? 0) image=\(image != nil) searched=\(!answerSources.isEmpty) "
                      + "answerChars=\(trimmed.count) voice=\(settings.speakReplies ? settings.voiceEngine.rawValue : "off") "
                      + "speechEnd->firstToken=\(toFirst)ms request->firstToken=\(request)ms total=\(Int(now.timeIntervalSince(speechEnded) * 1000))ms")
    }

    private nonisolated static func refersToSomething(_ utterance: String) -> Bool {
        let words = Set(utterance.lowercased().split { !$0.isLetter }.map(String.init))
        return !words.isDisjoint(with: ["this", "that", "it", "these", "here"])
    }

    /// June must never sit in "Thinking…": if no answer has finished in time, give up with an error.
    private func startWatchdog(seconds: Double) {
        let token = UUID()
        watchdog = token
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.watchdog == token else { return }
            self.watchdog = nil
            JuneLog.write("watchdog: no answer after \(Int(seconds)) s")
            self.work?.cancel()
            self.work = nil
            self.voice.stop()
            self.fail(.timeout)
            self.role = .idle
            self.refreshListening()
        }
    }

    // MARK: Helpers

    /// Reads an audio file, converts it to 16 kHz mono and feeds it to the transcriber.
    nonisolated static func feed(_ url: URL, into transcriber: CommandTranscriber) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let converter = AVAudioConverter(from: format, to: VoiceAudioFormat.format) else { throw JuneError.noMicrophone }
        let chunk: AVAudioFrameCount = 4096
        let ratio = VoiceAudioFormat.sampleRate / format.sampleRate
        while file.framePosition < file.length {
            guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
            try file.read(into: input, frameCount: chunk)
            if input.frameLength == 0 { break }
            guard let output = AVAudioPCMBuffer(pcmFormat: VoiceAudioFormat.format,
                                                frameCapacity: AVAudioFrameCount(Double(chunk) * ratio) + 64) else { break }
            var supplied = false
            converter.convert(to: output, error: nil) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return input
            }
            if output.frameLength > 0 { transcriber.append(output) }
        }
        // A little trailing silence so the recognizer finalises the last word.
        if let silence = AVAudioPCMBuffer(pcmFormat: VoiceAudioFormat.format, frameCapacity: 8000) {
            silence.frameLength = 8000
            if let channel = silence.floatChannelData?[0] { for i in 0..<8000 { channel[i] = 0 } }
            transcriber.append(silence)
        }
    }

    nonisolated static func stateName(_ state: JuneState) -> String {
        switch state {
        case .off: return "off"
        case .waitingForWakeWord: return "waiting"
        case .listening: return "listening"
        case .thinking: return "thinking"
        case .captured: return "captured"
        case .answer(_, let streaming): return streaming ? "answering" : "answered"
        case .confirm: return "confirm"
        case .pocketReady: return "pocket"
        case .notice(let text): return "notice(\(text))"
        case .error(let message, _): return "error(\(message))"
        }
    }

    /// Drops "hey june" / "june" from the start of a transcript (push-to-talk users sometimes say it anyway).
    public nonisolated static func stripWakeWords(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = result.lowercased()
        for prefix in ["hey june", "june"] where lower.hasPrefix(prefix) {
            let rest = result.dropFirst(prefix.count)
            if let next = rest.first, next.isLetter { break }      // "junebug" is not a wake word
            result = String(rest).trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!-"))
            break
        }
        return result
    }
}

/// Resumes a continuation exactly once, whichever of several callers gets there first.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }
    @discardableResult
    func resume(_ value: T?) -> Bool {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
        return c != nil
    }
}
