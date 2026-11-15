import AppKit
import Combine
import SwiftUI
import GauntletProtocol
import GauntletLink
import GauntletEngine
import GauntletDojo
import GauntletAI

public struct GestureLogEntry: Identifiable, Equatable {
    public let id = UUID()
    public let date = Date()
    public var title: String
    public var symbol: String
    public var detail: String
}

/// Fast-changing values, kept apart from `AppModel` so only the live widgets redraw at 15 Hz.
@MainActor
public final class Telemetry: ObservableObject {
    @Published public var snapshot = WristSnapshot()
    @Published public var tapHistory = [Double](repeating: 0, count: 90)
    @Published public var speedHistory = [Double](repeating: 0, count: 90)

    func push(_ s: WristSnapshot) {
        snapshot = s
        tapHistory.removeFirst()
        tapHistory.append(s.streaming ? s.tapEnvelope : 0)
        speedHistory.removeFirst()
        speedHistory.append((s.pointerVelocity.x * s.pointerVelocity.x + s.pointerVelocity.y * s.pointerVelocity.y).squareRoot())
    }
}

/// State shared with background queues.
private final class SharedFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var _sandbox = false
    private var _calibrated = false
    private var _watchConnected = false

    var sandbox: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _sandbox }
        set { lock.lock(); _sandbox = newValue; lock.unlock() }
    }
    var calibrated: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _calibrated }
        set { lock.lock(); _calibrated = newValue; lock.unlock() }
    }
    var watchConnected: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _watchConnected }
        set { lock.lock(); _watchConnected = newValue; lock.unlock() }
    }
}

/// Sits on the link queue: feeds the engine directly (no hop through the main thread,
/// so pointer latency is independent of UI work) and forwards state changes to the model.
private final class LinkBridge: LinkServerDelegate, @unchecked Sendable {
    let engine: WristEngine
    var onState: ((LinkServerState) -> Void)?
    /// Microphone frames from the watch go to June, not the engine.
    var onAudio: ((AudioFrame) -> Void)?

    init(engine: WristEngine) { self.engine = engine }

    func linkServer(_ server: LinkServer, didChange state: LinkServerState) {
        onState?(state)
    }

    func linkServer(_ server: LinkServer, didReceive message: WatchMessage) {
        if case .audio(let frame) = message {
            onAudio?(frame)
            return
        }
        engine.ingest(message)
    }
}

@MainActor
public final class AppModel: ObservableObject {
    public static let shared = AppModel()

    public let engine: WristEngine
    public let telemetry = Telemetry()
    public let dojoHost: DojoHost
    /// June, the voice assistant. The UI reads `june`, `captureFrame` and `pocketChipPoint` below.
    public let assistant: AssistantController

    @Published public private(set) var june: JuneState = .off
    /// June's settings, edited on the June page. Changes apply immediately and are saved.
    @Published public var juneSettings: JuneSettings {
        didSet { if juneSettings != oldValue { assistant.settings = juneSettings } }
    }
    /// Where the Gemini key comes from: "Keychain", "GEMINI_API_KEY", or nil (no key).
    @Published public private(set) var juneKeySource: String?
    /// Result of Settings › Test connection.
    @Published public private(set) var juneConnection: String?
    @Published public private(set) var junePermissions: PermissionStatus
    /// Asks the main window to show a page ("june" from the June window's gear button).
    @Published public var requestedPage: String?
    /// English voices installed on this Mac, best first.
    public let juneVoices: [JuneVoice] = AssistantController.availableVoices()
    /// What June is reading, in global top-left screen coordinates (nil = nothing to highlight).
    @Published public private(set) var captureFrame: CGRect?
    /// Where the "Paste reply?" chip should appear (nil = hidden).
    @Published public private(set) var pocketChipPoint: CGPoint?
    @Published public private(set) var link: LinkServerState = .waiting("Starting…")
    @Published public var settings: EngineSettings { didSet { applySettings(old: oldValue) } }
    @Published public private(set) var accessibilityGranted = SystemPointerSink.isTrusted
    @Published public private(set) var sandboxActive = false
    @Published public private(set) var bluetoothConfigured = true
    @Published public private(set) var trustedWatches: [TrustedWatch] = []
    @Published public private(set) var log: [GestureLogEntry] = []
    @Published public var typingGuardEnabled: Bool {
        didSet { UserDefaults.standard.set(typingGuardEnabled, forKey: "typingGuard"); configureTypingGuard() }
    }
    @Published public var developerLinkEnabled: Bool {
        didSet { UserDefaults.standard.set(developerLinkEnabled, forKey: "developerLink"); configureDeveloperLink() }
    }

    public var isConnected: Bool {
        if case .connected = link { return true }
        return false
    }

    private let linkQueue = DispatchQueue(label: "gauntlet.link", qos: .userInteractive)
    private let systemSink = SystemPointerSink()
    private let flags = SharedFlags()
    private let bridge: LinkBridge
    private let server: LinkServer
    private let trust: TrustStore
    private var observer: ObserverToken?
    private var tickTimer: DispatchSourceTimer?
    private var uiTimer: Timer?
    private var keyMonitor: Any?
    private let watchMic = WatchMicrophoneSource()
    private var hotkeyMonitors: [Any] = []
    private var rightOptionHeld = false
    private let urlHandler = JuneURLHandler()
    private var developerTransportAdded = false
    private var started = false
    private var uiTicks = 0

    private init() {
        let loaded = EngineSettings.load()
        settings = loaded
        engine = WristEngine(settings: loaded)
        engine.sink = systemSink
        dojoHost = DojoHost(engine: engine)
        bridge = LinkBridge(engine: engine)
        assistant = AssistantController(apiKeyProvider: { GeminiKey.load() })
        juneSettings = assistant.settings
        juneKeySource = GeminiKey.source
        junePermissions = Permissions.current()

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Gauntlet", isDirectory: true)
        trust = TrustStore(fileURL: support?.appendingPathComponent("trusted-watches.json"))
        server = LinkServer(identity: LinkIdentity.loadOrCreate(), trust: trust,
                            macName: Host.current().localizedName ?? "Mac", queue: linkQueue)

        let defaults = UserDefaults.standard
        typingGuardEnabled = defaults.object(forKey: "typingGuard") as? Bool ?? true
        developerLinkEnabled = defaults.bool(forKey: "developerLink")
            || CommandLine.arguments.contains("--dev-link")
        flags.calibrated = loaded.calibrated
        trustedWatches = trust.all
    }

    // MARK: Lifecycle

    public func start() {
        guard !started else { return }
        started = true

        bridge.onState = { [weak self] state in
            Task { @MainActor in self?.linkChanged(state) }
        }
        server.delegate = bridge

        // Engine events arrive on the link queue; talk to the watch from right there.
        let server = self.server
        let flags = self.flags
        let engine = self.engine
        observer = engine.addObserver { [weak self] event in
            switch event {
            case .haptic(let pattern):
                server.send(.haptic(pattern))
            case .engagedChanged, .draggingChanged, .scrollModeChanged, .pausedChanged:
                server.send(.state(AppModel.stateFlags(engine: engine, flags: flags)))
            case .gesture(let kind, let strength):
                Task { @MainActor in self?.record(kind, strength: strength) }
            case .voiceHold(let isDown):
                Task { @MainActor in self?.assistant.pushToTalk(isDown: isDown) }
            case .assistantRequested(let command):
                let point = CGEvent(source: nil)?.location ?? .zero
                Task { @MainActor in self?.assistant.run(command, at: point) }
            default:
                break
            }
        }

        // June: audio from the watch, state back to the watch, and the published state for the UI.
        bridge.onAudio = { [watchMic] frame in watchMic.ingest(frame) }
        watchMic.requestAudio = { on in server.send(.audioRequest(on)) }
        assistant.registerSource(watchMic)
        assistant.sendWatchState = { state in server.send(.assistantState(state)) }
        assistant.sendKeyCombo = { [systemSink] key, modifiers in
            systemSink.sendKeyCombo(keyCode: key, modifiers: modifiers)
        }
        assistant.onState = { [weak self] state in self?.june = state }
        assistant.openSettings = { [weak self] in self?.showJuneSettings() }
        assistant.onCaptureFrame = { [weak self] frame in self?.captureFrame = frame }
        assistant.onPocketChipRequested = { [weak self] point in self?.pocketChipPoint = point }
        installJuneHotkeys()
        if GeminiKey.importKeyFile(from: Self.developerKeyFiles) { juneKeySource = GeminiKey.source }
        assistant.warmUp()
        assistant.start()
        urlHandler.onURL = { [weak self] url in self?.handleTestURL(url) }
        urlHandler.install()

        // Bluetooth needs a usage description in the bundle's Info.plist; a bare binary has none.
        let hasBluetoothPlist = Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil
        bluetoothConfigured = hasBluetoothPlist && !CommandLine.arguments.contains("--no-bluetooth")
        if bluetoothConfigured { server.add(BLEPeripheralTransport(queue: linkQueue)) }
        configureDeveloperLink()
        server.start()

        let tick = DispatchSource.makeTimerSource(queue: linkQueue)
        tick.schedule(deadline: .now() + 0.2, repeating: 0.2)
        tick.setEventHandler { engine.tick() }
        tick.resume()
        tickTimer = tick

        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshUI() }
        }
        RunLoop.main.add(timer, forMode: .common)
        uiTimer = timer

        dojoHost.playHaptic = { server.send(.haptic($0)) }
        dojoHost.isRealWatchConnected = { flags.watchConnected }
        dojoHost.settingsDidChange = { [weak self] in
            Task { @MainActor in self?.adoptEngineSettings() }
        }
        dojoHost.setSandboxSink = { [weak self] sink in
            // Swap immediately (the Dojo may call from any thread), then update UI state.
            guard let self else { return }
            engine.sink = sink ?? self.systemSink
            flags.sandbox = sink != nil
            server.send(.state(AppModel.stateFlags(engine: engine, flags: flags)))
            Task { @MainActor in self.sandboxActive = sink != nil }
        }

        configureTypingGuard()
    }

    public func shutdown() {
        assistant.cancel()
        for monitor in hotkeyMonitors { NSEvent.removeMonitor(monitor) }
        hotkeyMonitors = []
        engine.linkDidDisconnect()
        systemSink.releaseAll()
        server.stop()
    }

    // MARK: Actions

    public func approvePairing() { server.approvePairing() }
    public func rejectPairing() { server.rejectPairing() }
    public func disconnectWatch() { server.disconnect() }
    public func togglePause() { engine.setPaused(!telemetry.snapshot.paused); refreshUI() }
    public func recenter() { engine.recenter() }

    public func forget(_ watch: TrustedWatch) {
        trust.forget(id: watch.id)
        trustedWatches = trust.all
        if case .connected(let name, _) = link, name == watch.name { server.disconnect() }
    }

    public func requestAccessibility() {
        SystemPointerSink.requestTrust()
        SystemPointerSink.openAccessibilitySettings()
    }

    /// Moves the real cursor a hair and back to prove the permission works. Nil until run.
    @Published public private(set) var pointerTestPassed: Bool?

    public func testPointer() {
        let sink = systemSink
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = sink.selfTest()
            Task { @MainActor in self.pointerTestPassed = ok }
        }
    }

    public func resetSettings() {
        var fresh = EngineSettings()
        fresh.forearmAxisFlipped = settings.forearmAxisFlipped       // keep what calibration learned about the wrist
        fresh.calibrated = settings.calibrated
        settings = fresh
    }

    // MARK: Internals

    nonisolated private static func stateFlags(engine: WristEngine, flags: SharedFlags) -> MacStateFlags {
        let s = engine.snapshot()
        var result: MacStateFlags = []
        if s.engaged { result.insert(.engaged) }
        if s.dragging { result.insert(.dragging) }
        if s.scrollMode { result.insert(.scrollMode) }
        if s.paused { result.insert(.paused) }
        if flags.sandbox { result.insert(.sandbox) }
        if !flags.calibrated { result.insert(.needsCalibration) }
        return result
    }

    private func linkChanged(_ state: LinkServerState) {
        let wasConnected = isConnected
        link = state
        flags.watchConnected = isConnected
        watchMic.setLinkConnected(isConnected)
        if isConnected, !wasConnected {
            server.send(.config(StreamConfig(sampleRateHz: 100, samplesPerPacket: 2)))
            server.send(.state(AppModel.stateFlags(engine: engine, flags: flags)))
            server.send(.haptic(.success))
            trustedWatches = trust.all
            if case .connected(let name, let via) = state {
                appendLog(GestureLogEntry(title: "\(name) connected", symbol: "applewatch.radiowaves.left.and.right", detail: via))
            }
        } else if wasConnected, !isConnected {
            systemSink.releaseAll()
            appendLog(GestureLogEntry(title: "Watch disconnected", symbol: "applewatch.slash", detail: ""))
        }
    }

    private func applySettings(old: EngineSettings) {
        guard settings != old else { return }
        let new = settings
        engine.updateSettings { $0 = new }
        flags.calibrated = new.calibrated
        new.save()
    }

    /// The Dojo wrote calibration results straight into the engine; mirror them here and persist.
    private func adoptEngineSettings() {
        let current = engine.currentSettings
        flags.calibrated = current.calibrated
        if current != settings { settings = current } else { current.save() }
        server.send(.state(AppModel.stateFlags(engine: engine, flags: flags)))
    }

    private func refreshUI() {
        telemetry.push(engine.snapshot())
        uiTicks += 1
        if uiTicks % 15 == 0 {
            let trusted = SystemPointerSink.isTrusted
            if trusted != accessibilityGranted {
                accessibilityGranted = trusted
                configureTypingGuard()
            }
        }
    }

    private func record(_ kind: GestureKind, strength: Double) {
        let action = settings.action(for: kind)
        appendLog(GestureLogEntry(title: kind.title, symbol: kind.symbol,
                                  detail: action == .none ? "" : action.title))
    }

    /// Empties the Recent list on the Control page.
    public func clearLog() { log.removeAll() }

    private func appendLog(_ entry: GestureLogEntry) {
        log.insert(entry, at: 0)
        if log.count > 40 { log.removeLast(log.count - 40) }
    }

    private func configureDeveloperLink() {
        guard started else { return }
        if developerLinkEnabled, !developerTransportAdded {
            server.add(TCPServerTransport(queue: linkQueue))
            developerTransportAdded = true
        } else if !developerLinkEnabled, developerTransportAdded {
            server.remove(named: "Developer link")
            developerTransportAdded = false
        }
    }

    // MARK: June test hooks

    /// `gauntlet://june/...` drives June from the terminal for automated testing. Only works when the
    /// developer link is on, or the app was started with --june-test or JUNE_TEST=1, so a web page
    /// can't trigger June.
    ///   open "gauntlet://june/ask?q=summarize%20this&x=600&y=400"
    ///   open "gauntlet://june/listen?file=/tmp/q.aiff"           (audio through on-device speech)
    ///   open "gauntlet://june/ptt?down=1"  …  "gauntlet://june/ptt?down=0"   (real microphone)
    ///   open "gauntlet://june/run?command=summarize"             (as a custom gesture would)
    ///   open "gauntlet://june/say?text=hello"   "gauntlet://june/stop"
    ///   open "gauntlet://june/set?speakReplies=0&voiceEngine=mac&conversationMode=1&answerLength=brief&model=…"
    private var testHooksAllowed: Bool {
        developerLinkEnabled || CommandLine.arguments.contains("--june-test")
            || ProcessInfo.processInfo.environment["JUNE_TEST"] == "1"
    }

    private func handleTestURL(_ url: URL) {
        guard url.scheme == "gauntlet", url.host == "june" else { return }
        guard testHooksAllowed else {
            JuneLog.write("test hook ignored (turn on Settings › Advanced › Developer link): \(url.path)")
            return
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        var point: CGPoint?
        if let x = value("x").flatMap(Double.init), let y = value("y").flatMap(Double.init) { point = CGPoint(x: x, y: y) }
        JuneLog.write("test hook \(url.path) \(items.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: " "))")

        switch url.path {
        case "/ask":
            if let q = value("q") { assistant.ask(q, at: point) }
        case "/listen":
            if let file = value("file") { assistant.listen(fileAt: URL(fileURLWithPath: file), at: point) }
        case "/ptt":
            assistant.pushToTalk(isDown: value("down") == "1")
        case "/run":
            if let name = value("command"), let command = AssistantCommand(rawValue: name) {
                assistant.run(command, at: point ?? (CGEvent(source: nil)?.location ?? .zero))
            }
        case "/say":
            if let text = value("text") { assistant.say(text) }
        case "/stop":
            assistant.cancel()
        case "/set":
            var s = juneSettings
            for item in items {
                let v = item.value ?? ""
                let on = v == "1" || v == "true"
                switch item.name {
                case "enabled": s.enabled = on
                case "speakReplies": s.speakReplies = on
                case "voiceEngine": s.voiceEngine = VoiceEngine(rawValue: v) ?? s.voiceEngine
                case "geminiVoice": s.geminiVoice = v
                case "conversationMode": s.conversationMode = on
                case "followUpSeconds": s.followUpSeconds = Double(v) ?? s.followUpSeconds
                case "answerLength": s.answerLength = AnswerLength(rawValue: v) ?? s.answerLength
                case "model": s.modelOverride = v.isEmpty ? nil : v
                case "showStatusHUD", "panel": s.showStatusHUD = on
                case "wakeWord": s.wakeWordEnabled = on
                case "webSearch": s.webSearch = on
                case "screenVision": s.screenVision = on
                case "panelPosition": s.panelPosition = PanelPosition(rawValue: v) ?? s.panelPosition
                case "chime": s.chimeEnabled = on
                case "language": s.targetLanguage = v
                default: break
                }
            }
            juneSettings = s
        default:
            JuneLog.write("test hook: unknown path \(url.path)")
        }
    }

    // MARK: June settings

    /// Debug builds also pick up a key from the project's git-ignored .june/ folder.
    private static var developerKeyFiles: [URL] {
        #if DEBUG
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return [repo.appendingPathComponent(".june/gemini-key.txt")]
        #else
        return []
        #endif
    }

    public func saveGeminiKey(_ key: String) {
        GeminiKey.save(key)
        juneKeySource = GeminiKey.source
        juneConnection = nil
        assistant.warmUp()
    }

    public func removeGeminiKey() {
        GeminiKey.save("")
        juneKeySource = GeminiKey.source
        juneConnection = nil
    }

    public func testJuneConnection() {
        juneConnection = "Testing…"
        Task { juneConnection = await assistant.testConnection() }
    }

    public func previewJuneVoice() { assistant.previewVoice() }

    /// Brings Flare forward on the June page.
    public func showJuneSettings() {
        requestedPage = "june"
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        }
        refreshJunePermissions()
    }

    /// Runs a typed command through June, as if spoken (Settings › Try it).
    public func askJune(_ text: String) { assistant.ask(text) }

    public func refreshJunePermissions() { junePermissions = Permissions.current() }

    public func requestJuneMicrophoneAndSpeech() {
        guard Permissions.bundleHasUsageStrings else { return }
        Task {
            _ = await Permissions.requestMicrophone()
            _ = await Permissions.requestSpeech()
            refreshJunePermissions()
        }
    }

    public var juneMicrophoneNames: [String] {
        assistant.audioSources.map(\.displayName)
    }

    /// Hold Right Option to talk to June; Control-Option-G arms custom gestures (for demos without the watch).
    private func installJuneHotkeys() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            Task { @MainActor in self?.handleHotkey(event) }
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: handler) {
            hotkeyMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { event in
            handler(event)
            return event
        }) {
            hotkeyMonitors.append(monitor)
        }
    }

    private func handleHotkey(_ event: NSEvent) {
        guard assistant.settings.enabled, assistant.settings.hotkeysEnabled else { return }
        switch event.type {
        case .flagsChanged:
            guard event.keyCode == 61 else { return }                       // Right Option
            let down = event.modifierFlags.rawValue & 0x40 != 0            // device-dependent "right alt" bit
            if down != rightOptionHeld {
                rightOptionHeld = down
                assistant.pushToTalk(isDown: down)
            }
        case .keyDown:
            if event.keyCode == 5, event.modifierFlags.contains([.control, .option]) { engine.armCustomGesture() }
        default:
            break
        }
    }

    /// Like a trackpad's palm rejection: while keys are going down, the pointer holds still.
    private func configureTypingGuard() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        guard typingGuardEnabled, started else { return }
        let engine = self.engine
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { _ in
            engine.suppressPointer(until: WristEngine.now() + 0.6)
        }
    }
}

/// Receives `gauntlet://` URLs (Apple Events need an Objective-C target).
final class JuneURLHandler: NSObject {
    var onURL: ((URL) -> Void)?

    func install() {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handle(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: text) else { return }
        DispatchQueue.main.async { self.onURL?(url) }
    }
}
