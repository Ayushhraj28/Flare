import Foundation

/// What June is doing right now. Published to the UI on the main thread.
public enum JuneState: Sendable, Equatable {
    /// June is switched off, or resting between commands (push-to-talk only).
    case off
    /// The mic is open for "Hey June" and nothing leaves the Mac.
    case waitingForWakeWord
    /// Recording a command; `transcript` is the live on-device transcription.
    case listening(transcript: String)
    case thinking
    /// What June is looking at (shown before the answer arrives).
    case captured(summary: String)
    case answer(text: String, streaming: Bool)
    /// A data-changing action waits for a physical confirm (pinch tap).
    case confirm(description: String)
    case pocketReady(preview: String)
    /// One-line success toast: "Typed", "Saved to Notes".
    case notice(String)
    case error(message: String, fix: String?)
}

public enum WakeSensitivity: String, Codable, CaseIterable, Sendable {
    case strict, normal, loose
}

/// How long June's answers are.
public enum AnswerLength: String, Codable, CaseIterable, Sendable {
    case brief, normal, detailed

    public var title: String {
        switch self {
        case .brief: return "Brief"
        case .normal: return "Normal"
        case .detailed: return "Detailed"
        }
    }

    var rule: String {
        switch self {
        case .brief: return "Keep answers short: at most 3 short bullets or about 60 words (for a whole document, up to 5 bullets)."
        case .normal: return "Keep answers compact: at most 6 bullets or about 120 words."
        case .detailed: return "Answer thoroughly but without padding: up to about 250 words, with short bullets where they help."
        }
    }

    var maxOutputTokens: Int {
        switch self {
        case .brief: return 400
        case .normal: return 800
        case .detailed: return 1600
        }
    }
}

/// Where the June window appears.
public enum PanelPosition: String, Codable, CaseIterable, Sendable {
    case nearCursor, topRight, topCenter

    public var title: String {
        switch self {
        case .nearCursor: return "Near the pointer"
        case .topRight: return "Top right"
        case .topCenter: return "Top center"
        }
    }
}

/// Who speaks June's answers.
public enum VoiceEngine: String, Codable, CaseIterable, Sendable {
    /// macOS speech: starts instantly, works offline.
    case mac
    /// Gemini text-to-speech: more natural, about a second slower, falls back to the Mac voice.
    case gemini

    public var title: String {
        switch self {
        case .mac: return "Mac voice (instant)"
        case .gemini: return "Gemini voice (natural)"
        }
    }
}

/// Everything the June settings page edits. Persisted in UserDefaults.
public struct JuneSettings: Codable, Equatable, Sendable {
    /// Master switch. Off: June ignores every trigger and the microphone stays closed.
    public var enabled = true
    /// Always listening for "Hey June", on this Mac only. Nothing leaves the Mac until the phrase is heard.
    public var wakeWordEnabled = true
    public var sensitivity = WakeSensitivity.normal
    /// Display name of the preferred audio source; nil = automatic (AirPods, then watch, then Mac mic).
    public var preferredSource: String?
    public var screenshotFallback = false
    public var targetLanguage = "Spanish"
    public var chimeEnabled = true
    /// Hold Right Option to talk; Control-Option-G arms custom gestures.
    public var hotkeysEnabled = true
    public var modelOverride: String?
    /// Show the June window when June listens or answers.
    public var showStatusHUD = true
    public var panelPosition = PanelPosition.nearCursor
    /// Seconds the June window stays after an answer (0 = until closed).
    public var panelLingerSeconds = 12.0
    /// Let Gemini search Google for current information (news, weather, prices, sports).
    public var webSearch = true
    /// Let June look at the screen around the pointer when there's no text to read (needs Screen Recording).
    public var screenVision = true
    /// Read files and folders pointed at in Finder or on the Desktop.
    public var fileAccess = true
    /// Copy, paste, move, rename and put files in the Trash (always undoable).
    public var fileActions = true
    /// Fix, rewrite and translate selected text in place, and type replies (sent only on "click Send").
    public var writingActions = true
    /// Read answers aloud.
    public var speakReplies = true
    public var voiceEngine = VoiceEngine.gemini
    /// AVSpeechSynthesisVoice identifier; nil = the best installed English voice.
    public var macVoiceID: String?
    /// 0.3 (slow) ... 0.65 (fast); 0.52 is natural.
    public var speechRate = 0.52
    public var geminiVoice = "Aoede"
    public var answerLength = AnswerLength.brief
    /// Extra instructions for June, e.g. "Answer in British English" or "I'm a CS student".
    public var customInstructions = ""
    /// Like Gemini Live: after June answers aloud, the mic opens again for a follow-up, no button needed.
    public var conversationMode = true
    /// How long June waits for a follow-up before the conversation ends.
    public var followUpSeconds = 7.0

    public init() {}

    /// Missing keys keep their defaults, so adding a setting never wipes the user's saved ones.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = JuneSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        wakeWordEnabled = try c.decodeIfPresent(Bool.self, forKey: .wakeWordEnabled) ?? d.wakeWordEnabled
        sensitivity = try c.decodeIfPresent(WakeSensitivity.self, forKey: .sensitivity) ?? d.sensitivity
        preferredSource = try c.decodeIfPresent(String.self, forKey: .preferredSource)
        screenshotFallback = try c.decodeIfPresent(Bool.self, forKey: .screenshotFallback) ?? d.screenshotFallback
        targetLanguage = try c.decodeIfPresent(String.self, forKey: .targetLanguage) ?? d.targetLanguage
        chimeEnabled = try c.decodeIfPresent(Bool.self, forKey: .chimeEnabled) ?? d.chimeEnabled
        hotkeysEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotkeysEnabled) ?? d.hotkeysEnabled
        modelOverride = try c.decodeIfPresent(String.self, forKey: .modelOverride)
        showStatusHUD = try c.decodeIfPresent(Bool.self, forKey: .showStatusHUD) ?? d.showStatusHUD
        panelPosition = try c.decodeIfPresent(PanelPosition.self, forKey: .panelPosition) ?? d.panelPosition
        panelLingerSeconds = try c.decodeIfPresent(Double.self, forKey: .panelLingerSeconds) ?? d.panelLingerSeconds
        webSearch = try c.decodeIfPresent(Bool.self, forKey: .webSearch) ?? d.webSearch
        screenVision = try c.decodeIfPresent(Bool.self, forKey: .screenVision) ?? d.screenVision
        fileAccess = try c.decodeIfPresent(Bool.self, forKey: .fileAccess) ?? d.fileAccess
        fileActions = try c.decodeIfPresent(Bool.self, forKey: .fileActions) ?? d.fileActions
        writingActions = try c.decodeIfPresent(Bool.self, forKey: .writingActions) ?? d.writingActions
        speakReplies = try c.decodeIfPresent(Bool.self, forKey: .speakReplies) ?? d.speakReplies
        voiceEngine = try c.decodeIfPresent(VoiceEngine.self, forKey: .voiceEngine) ?? d.voiceEngine
        macVoiceID = try c.decodeIfPresent(String.self, forKey: .macVoiceID)
        speechRate = try c.decodeIfPresent(Double.self, forKey: .speechRate) ?? d.speechRate
        geminiVoice = try c.decodeIfPresent(String.self, forKey: .geminiVoice) ?? d.geminiVoice
        answerLength = try c.decodeIfPresent(AnswerLength.self, forKey: .answerLength) ?? d.answerLength
        customInstructions = try c.decodeIfPresent(String.self, forKey: .customInstructions) ?? d.customInstructions
        conversationMode = try c.decodeIfPresent(Bool.self, forKey: .conversationMode) ?? d.conversationMode
        followUpSeconds = try c.decodeIfPresent(Double.self, forKey: .followUpSeconds) ?? d.followUpSeconds
    }

    static let key = "juneSettings"

    public static func load(from defaults: UserDefaults = .standard) -> JuneSettings {
        guard let data = defaults.data(forKey: key),
              let s = try? JSONDecoder().decode(JuneSettings.self, from: data) else { return JuneSettings() }
        return s
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: JuneSettings.key) }
    }
}

/// Every way June can fail, each with a one-line fix the UI shows.
public enum JuneError: Error, Equatable, Sendable {
    case noAPIKey
    case noNetwork
    case timeout
    case http(Int, String)
    case blocked(String)
    case emptyAnswer
    case emptyCapture
    case needsAccessibility
    case noMicrophone
    case micDenied
    case speechDenied
    case onDeviceSpeechMissing
    case noSpeech
    case holdTooShort
    case nothingToCopy
    case screenRecordingDenied
    case noTextField
    case notBundled
    case unsupported(String)
    /// A Mac-side action (close a window, open a file) couldn't be done; the text says why.
    case actionFailed(String)

    public var message: String {
        switch self {
        case .noAPIKey: return "No Gemini API key."
        case .noNetwork: return "No internet connection."
        case .timeout: return "Gemini took too long to answer."
        case .http(let code, let detail):
            switch code {
            case 400, 401, 403: return "Gemini rejected the request (\(code)). \(detail)"
            case 404: return "Gemini model not found. \(detail)"
            case 429:
                let lower = detail.lowercased()
                return lower.contains("quota") ? "Gemini quota used up for this API key." : "Gemini rate limit reached."
            default: return "Gemini error \(code). \(detail)"
            }
        case .blocked: return "Gemini declined to answer that."
        case .emptyAnswer: return "Gemini sent back an empty answer."
        case .emptyCapture: return "June couldn't read anything under the cursor."
        case .needsAccessibility: return "June needs the Accessibility permission to read what you point at."
        case .noMicrophone: return "No microphone is available."
        case .micDenied: return "Microphone access is off."
        case .speechDenied: return "Speech recognition access is off."
        case .onDeviceSpeechMissing: return "On-device speech recognition isn't installed."
        case .noSpeech: return "Didn't catch that."
        case .holdTooShort: return "That was a tap."
        case .nothingToCopy: return "There's no answer to copy yet."
        case .screenRecordingDenied: return "June needs Screen Recording permission to look at the screen."
        case .noTextField: return "Click into a text field first, then ask June to type."
        case .notBundled: return "Run the built Flare app, not the bare binary."
        case .unsupported(let what): return "\(what) isn't available yet."
        case .actionFailed(let why): return why
        }
    }

    public var fix: String? {
        switch self {
        case .noAPIKey: return "Set GEMINI_API_KEY or save a key in Settings › June."
        case .noNetwork: return "Check the connection and try again."
        case .timeout: return "Try again, or check the connection."
        case .http(let code, let detail):
            if code == 429 {
                return detail.lowercased().contains("quota")
                    ? "Check your limits at aistudio.google.com/rate-limit, use a new key, or turn on billing."
                    : "Wait a moment and try again."
            }
            return "Check the API key and model name in Settings › June."
        case .blocked: return "Try pointing at different text."
        case .emptyAnswer: return "Try again."
        case .emptyCapture: return "Point at some text, or select it first."
        case .needsAccessibility: return "System Settings › Privacy & Security › Accessibility › turn on Flare."
        case .noMicrophone: return "Connect or enable a microphone."
        case .micDenied: return "System Settings › Privacy & Security › Microphone › turn on Flare."
        case .speechDenied: return "System Settings › Privacy & Security › Speech Recognition › turn on Flare."
        case .onDeviceSpeechMissing: return "System Settings › Keyboard › Dictation: turn it on and download the language."
        case .noSpeech: return "Hold Right Option (or the June chip) the whole time you speak."
        case .holdTooShort: return "Keep holding while you speak, then let go."
        case .nothingToCopy: return "Ask June something first."
        case .screenRecordingDenied: return "System Settings › Privacy & Security › Screen Recording › turn on Flare."
        case .noTextField: return "Click where the text should go, then say \"type …\"."
        case .notBundled: return "Build with Scripts/build-app.sh and open the .app."
        case .unsupported: return nil
        case .actionFailed: return nil
        }
    }
}
