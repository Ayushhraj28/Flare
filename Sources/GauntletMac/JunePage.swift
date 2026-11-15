import SwiftUI
import GauntletAI

/// Everything about June, the Gemini voice assistant: key, model, answers, voice, microphone, permissions.
struct JunePage: View {
    @ObservedObject var model: AppModel
    @LocalState private var keyDraft = ""
    @LocalState private var typedCommand = "summarize this"
    @FocusState private var keyFieldFocused: Bool

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: UI.spacing) {
                    PageHeader(title: "June", subtitle: "Your Gemini voice assistant. Point at anything and say “Hey June”.") {
                        HStack(spacing: 10) {
                            Text(model.juneSettings.enabled ? "June is on" : "June is off")
                                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(UI.ink)
                            FlareSwitch(isOn: $model.juneSettings.enabled)
                        }
                        .padding(.leading, 14)
                        .padding(.trailing, 6)
                        .frame(height: 34)
                        .background(.white, in: Capsule())
                        .overlay(Capsule().strokeBorder(UI.line, lineWidth: 0.75))
                    }

                    hero

                    if model.juneKeySource == nil {
                        Banner(symbol: "key", title: "One step left: add your Gemini API key",
                               text: "June can hear you, but needs a key before it can answer. Keys are free from Google AI Studio.",
                               action: "Add key") {
                            withAnimation { scroller.scrollTo("gemini", anchor: .top) }
                            keyFieldFocused = true
                        }
                    }

                    HStack(alignment: .top, spacing: UI.spacing) {
                        VStack(spacing: UI.spacing) {
                            heyJune
                            abilities
                            voice
                            listening
                        }
                        VStack(spacing: UI.spacing) {
                            gemini.id("gemini")
                            answers
                            window
                            permissions
                        }
                    }

                    commands
                }
                .padding(.horizontal, UI.pagePadding)
                .padding(.bottom, UI.pagePadding)
            }
            .scrollIndicators(.never)
        }
        .onAppear { model.refreshJunePermissions() }
    }

    // MARK: Hero

    private var hero: some View {
        Surface(padding: 0) {
            HStack(alignment: .center, spacing: 26) {
                JuneBadge(listening: isHearing, active: model.juneSettings.enabled)
                    .frame(width: 150, height: 150)
                VStack(alignment: .leading, spacing: 10) {
                    stateChip
                    Text("Say “Hey June”, then your question.")
                        .font(.system(size: 21, weight: .bold)).foregroundStyle(UI.ink)
                    Text("Or try it without speaking: point at something, then run a command as if you had said it.")
                        .font(UI.body).foregroundStyle(UI.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(UI.flare)
                            TextField("summarize this", text: $typedCommand)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .onSubmit { model.askJune(typedCommand) }
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(UI.line, lineWidth: 0.75))
                        Button { model.askJune(typedCommand) } label: {
                            HStack(spacing: 6) {
                                Text("Ask")
                                Image(systemName: "return").font(.system(size: 10, weight: .bold))
                            }
                        }
                        .buttonStyle(FlareButtonStyle(kind: .primary))
                    }
                    .frame(maxWidth: 560)
                    HStack(spacing: 6) {
                        ForEach(["summarize this", "translate this", "what's on my screen?"], id: \.self) { suggestion in
                            Button {
                                typedCommand = suggestion
                                model.askJune(suggestion)
                            } label: {
                                Text(suggestion)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(UI.ink2)
                                    .padding(.horizontal, 10)
                                    .frame(height: 24)
                                    .background(.white, in: Capsule())
                                    .overlay(Capsule().strokeBorder(UI.line, lineWidth: 0.75))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if let line = liveLine {
                        Text(line)
                            .font(UI.caption).foregroundStyle(UI.ink2)
                            .lineLimit(2)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .background(
                LinearGradient(colors: [UI.flare.opacity(0.10), UI.flare.opacity(0.03), .white],
                               startPoint: .leading, endPoint: .trailing))
            .clipShape(RoundedRectangle(cornerRadius: UI.cardRadius, style: .continuous))
        }
    }

    private var isHearing: Bool {
        if case .listening = model.june { return true }
        return false
    }

    private var stateChip: some View {
        let (text, tone, spinning): (String, StatusChip.Tone, Bool) = {
            guard model.juneSettings.enabled else { return ("June is off", .neutral, false) }
            switch model.june {
            case .off: return (model.juneKeySource == nil ? "Needs a key" : "Ready", model.juneKeySource == nil ? .amber : .green, false)
            case .waitingForWakeWord: return ("Listening", .green, false)
            case .listening: return ("Hearing you", .flare, false)
            case .thinking, .captured: return ("Thinking", .flare, true)
            case .answer: return ("Answering", .flare, false)
            case .confirm, .pocketReady, .notice: return ("Done", .green, false)
            case .error: return ("Needs attention", .red, false)
            }
        }()
        return StatusChip(text: text, tone: tone, dot: !spinning, spinning: spinning)
    }

    /// What June is doing right now, when there is something to say.
    private var liveLine: String? {
        guard model.juneSettings.enabled else { return nil }
        switch model.june {
        case .off, .waitingForWakeWord: return nil
        case .listening(let t): return t.isEmpty ? nil : "Heard: \(t)"
        case .thinking: return "Thinking…"
        case .captured(let summary): return summary
        case .answer(let text, _): return String(text.prefix(160))
        case .confirm(let d): return d
        case .pocketReady(let p): return "Reply ready: \(p)"
        case .notice(let n): return n
        case .error(let message, let fix): return [message, fix].compactMap { $0 }.joined(separator: " ")
        }
    }

    // MARK: Cards

    private var heyJune: some View {
        Panel("Hey June") {
            VStack(spacing: 0) {
                ToggleSetting(symbol: "mic", title: "Listen for “Hey June”",
                              detail: "Say it, then your question. June answers when you pause.", isOn: $model.juneSettings.wakeWordEnabled)
                SettingRow(symbol: "dial.medium", title: "Sensitivity",
                           detail: "Strict: fewer false starts. Loose: also answers to a plain “June”.", showsDivider: false) {
                    Segmented(selection: $model.juneSettings.sensitivity,
                              options: [(value: WakeSensitivity.strict, label: "Strict"),
                                        (value: WakeSensitivity.normal, label: "Normal"),
                                        (value: WakeSensitivity.loose, label: "Loose")],
                              disabled: !model.juneSettings.wakeWordEnabled)
                }
                footnote("lock", "“Hey June” is recognised on this Mac. No audio leaves your Mac; only what you say after it is sent to Gemini.")
            }
        }
    }

    private var abilities: some View {
        let screenGranted = model.junePermissions.screenRecording == .granted
        return Panel("What June can use") {
            VStack(spacing: 0) {
                ToggleSetting(symbol: "magnifyingglass", title: "Search the web",
                              detail: "Google Search for news, weather, scores and anything current", isOn: $model.juneSettings.webSearch)
                SettingRow(symbol: "eye", title: "Look at the screen",
                           detail: "“What's on my screen?”, charts and images.",
                           badge: screenGranted ? nil : "Needs Screen Recording") {
                    FlareSwitch(isOn: $model.juneSettings.screenVision)
                }
                ToggleSetting(symbol: "folder", title: "Read files and folders",
                              detail: "Point at something in Finder: “what's in this folder?”, “what's this file?”",
                              isOn: $model.juneSettings.fileAccess)
                ToggleSetting(symbol: "doc.on.doc", title: "Copy, move, rename and trash files",
                              detail: "Always undoable: say “undo”. June never deletes anything for good.",
                              isOn: $model.juneSettings.fileActions)
                ToggleSetting(symbol: "pencil.line", title: "Edit text and type replies",
                              detail: "Fixes, rewrites and translates selected text in place (⌘Z undoes it). Never sends until you say “click Send”.",
                              isOn: $model.juneSettings.writingActions, showsDivider: false)
            }
        }
    }

    private var gemini: some View {
        Panel("Gemini") {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 12) {
                        IconTile(symbol: "key")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("API key").font(.system(size: 13, weight: .medium)).foregroundStyle(UI.ink)
                            HStack(spacing: 5) {
                                Circle().fill(model.juneKeySource == nil ? UI.red : UI.green).frame(width: 6, height: 6)
                                Text(keyDetail).font(UI.small)
                                    .foregroundStyle(model.juneKeySource == nil ? Color(hex: 0xB42328) : Color(hex: 0x1E7B39))
                            }
                        }
                        Spacer()
                        if model.juneKeySource == "Keychain" {
                            Button("Remove") { model.removeGeminiKey() }
                                .buttonStyle(FlareButtonStyle(kind: .destructive, compact: true))
                        }
                    }
                    HStack(spacing: 8) {
                        SecureField(model.juneKeySource == nil ? "Paste your key" : "Replace key", text: $keyDraft)
                            .flareField()
                            .focused($keyFieldFocused)
                            .onSubmit(saveKey)
                        Button("Save", action: saveKey)
                            .buttonStyle(FlareButtonStyle(kind: .primary))
                            .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.leading, 38)
                }
                .padding(.vertical, 10)
                Rectangle().fill(UI.hairline).frame(height: 1)

                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 12) {
                        IconTile(symbol: "cpu")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Model").font(.system(size: 13, weight: .medium)).foregroundStyle(UI.ink)
                            Text("Leave empty for \(GeminiClient.defaultModel)").font(UI.caption).foregroundStyle(UI.ink2)
                        }
                    }
                    HStack(spacing: 8) {
                        TextField(GeminiClient.defaultModel, text: modelBinding).flareField()
                        Menu("Presets") {
                            Button(GeminiClient.defaultModel) { model.juneSettings.modelOverride = nil }
                            Button("gemini-flash-latest") { model.juneSettings.modelOverride = "gemini-flash-latest" }
                            Button("gemini-3.5-flash-lite (fastest)") { model.juneSettings.modelOverride = "gemini-3.5-flash-lite" }
                        }
                        .fixedSize()
                    }
                    .padding(.leading, 38)
                }
                .padding(.vertical, 10)
                Rectangle().fill(UI.hairline).frame(height: 1)

                SettingRow(symbol: "bolt", title: "Connection", detail: model.juneConnection ?? "Not tested yet", showsDivider: false) {
                    Button("Test connection") { model.testJuneConnection() }
                        .buttonStyle(FlareButtonStyle(kind: .secondary, compact: true))
                }
                footnote("lock", "The key is stored in your Mac's Keychain, never in a file. Get one free at aistudio.google.com/apikey")
            }
        }
    }

    private var answers: some View {
        Panel("Answers") {
            VStack(spacing: 0) {
                SettingRow(symbol: "text.alignleft", title: "Answer length",
                           detail: "Short on purpose: you read them on a projector or hear them aloud.") {
                    Segmented(selection: $model.juneSettings.answerLength,
                              options: AnswerLength.allCases.map { (value: $0, label: $0.title) })
                }
                SettingRow(symbol: "globe", title: "Translate into",
                           detail: "Used by translate gestures, and when you don't name a language") {
                    Picker("", selection: $model.juneSettings.targetLanguage) {
                        ForEach(languages, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        IconTile(symbol: "person.text.rectangle")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Custom instructions").font(.system(size: 13, weight: .medium)).foregroundStyle(UI.ink)
                            Text("For example: “I'm a computer science student” or “Answer in British English”")
                                .font(UI.caption).foregroundStyle(UI.ink2)
                        }
                    }
                    TextEditor(text: $model.juneSettings.customInstructions)
                        .font(UI.body)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(height: 70)
                        .background(UI.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(UI.line, lineWidth: 0.75))
                        .padding(.leading, 38)
                }
                .padding(.vertical, 10)
            }
        }
    }

    /// Common languages, plus whatever is set now.
    private var languages: [String] {
        var list = ["Spanish", "French", "German", "Italian", "Portuguese", "Dutch", "Hindi", "Japanese", "Korean",
                    "Chinese (Simplified)", "Arabic", "Russian", "Turkish", "English"]
        let current = model.juneSettings.targetLanguage
        if !current.isEmpty, !list.contains(current) { list.insert(current, at: 0) }
        return list
    }

    private var voice: some View {
        Panel("Voice") {
            VStack(spacing: 0) {
                ToggleSetting(symbol: "speaker.wave.2", title: "Speak answers aloud",
                              isOn: $model.juneSettings.speakReplies)
                if model.juneSettings.speakReplies {
                    ToggleSetting(symbol: "bubble.left.and.bubble.right", title: "Conversation mode",
                                  detail: "Like Gemini Live: after June answers, just keep talking. Silence or “thanks” ends it.",
                                  isOn: $model.juneSettings.conversationMode)
                    if model.juneSettings.conversationMode {
                        SliderSetting(symbol: "timer", title: "Wait for a follow-up",
                                      value: $model.juneSettings.followUpSeconds, range: 3...15) { String(format: "%.0f s", $0) }
                    }
                    SettingRow(symbol: "waveform", title: "Voice") {
                        Segmented(selection: $model.juneSettings.voiceEngine,
                                  options: VoiceEngine.allCases.map { (value: $0, label: $0.title) })
                    }
                    if model.juneSettings.voiceEngine == .mac {
                        SettingRow(symbol: "person.wave.2", title: "Mac voice") {
                            Picker("", selection: $model.juneSettings.macVoiceID) {
                                Text("Best available").tag(String?.none)
                                ForEach(model.juneVoices) { voice in
                                    Text("\(voice.name)  ·  \(voice.detail)").tag(String?.some(voice.id))
                                }
                            }
                            .labelsHidden()
                            .frame(width: 200)
                        }
                        SliderSetting(symbol: "gauge.with.dots.needle.50percent", title: "Speaking speed",
                                      value: $model.juneSettings.speechRate, range: 0.35...0.65) { String(format: "%.0f%%", $0 / 0.52 * 100) }
                    } else {
                        SettingRow(symbol: "person.wave.2", title: "Gemini voice",
                                   detail: "About a second slower to start; falls back to the Mac voice if it fails") {
                            Picker("", selection: $model.juneSettings.geminiVoice) {
                                ForEach(AssistantController.geminiVoices, id: \.self) { Text(GeminiClient.voiceLabel($0)).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 170)
                        }
                    }
                }
                SettingRow(symbol: "play", title: "Hear a sample",
                           detail: "The Mac voice starts speaking while the answer is still arriving.", showsDivider: false) {
                    Button("Play") { model.previewJuneVoice() }.buttonStyle(FlareButtonStyle(kind: .secondary, compact: true))
                }
            }
        }
    }

    private var window: some View {
        Panel("June window") {
            VStack(spacing: 0) {
                ToggleSetting(symbol: "macwindow", title: "Show the June window",
                              detail: "Pops up while June listens and answers", isOn: $model.juneSettings.showStatusHUD)
                SettingRow(symbol: "arrow.up.and.down.and.arrow.left.and.right", title: "Where it appears") {
                    Picker("", selection: $model.juneSettings.panelPosition) {
                        ForEach(PanelPosition.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                SliderSetting(symbol: "clock", title: "Keep the answer on screen",
                              value: $model.juneSettings.panelLingerSeconds, range: 0...60, showsDivider: false) {
                    $0 < 1 ? "Until closed" : String(format: "%.0f s", $0)
                }
            }
        }
    }

    private var listening: some View {
        Panel("Listening") {
            VStack(spacing: 0) {
                SettingRow(symbol: "mic", title: "Microphone", detail: "Automatic: AirPods, then the watch once it streams, then the Mac") {
                    Picker("", selection: $model.juneSettings.preferredSource) {
                        Text("Automatic").tag(String?.none)
                        ForEach(model.juneMicrophoneNames, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                ToggleSetting(symbol: "command", title: "Keyboard shortcuts",
                              detail: "Right Option to talk, Control-Option-G for gestures", isOn: $model.juneSettings.hotkeysEnabled)
                ToggleSetting(symbol: "bell", title: "Sound when June starts listening",
                              isOn: $model.juneSettings.chimeEnabled, showsDivider: false)
                footnote("hand.raised", "Hold Right Option, or hold the June chip on the watch, while you speak. Control-Option-G arms a custom gesture.")
            }
        }
    }

    private var permissions: some View {
        let p = model.junePermissions
        return Panel("Permissions", trailing: {
            Button("Re-check") { model.refreshJunePermissions() }.buttonStyle(FlareButtonStyle(kind: .secondary, compact: true))
        }) {
            VStack(spacing: 0) {
                permissionRow("Microphone", p.microphone == .granted, symbol: "mic")
                permissionRow("Speech recognition (on this Mac)", p.speech == .granted && p.onDeviceSpeechInstalled, symbol: "waveform",
                              detail: p.onDeviceSpeechInstalled ? nil : "Turn on Dictation in System Settings › Keyboard to install on-device speech")
                permissionRow("Accessibility (read what you point at)", p.accessibility == .granted, symbol: "hand.point.up.left")
                permissionRow("Screen Recording (look at the screen)", p.screenRecording == .granted, symbol: "rectangle.dashed",
                              detail: p.screenRecording == .granted ? nil : "Only needed for “what's on my screen”. macOS asks the first time.")
                HStack(spacing: 8) {
                    Button("Ask for mic and speech") { model.requestJuneMicrophoneAndSpeech() }
                        .buttonStyle(FlareButtonStyle(kind: .secondary, compact: true))
                    Button("Accessibility…") { model.requestAccessibility() }
                        .buttonStyle(FlareButtonStyle(kind: .secondary, compact: true))
                    Spacer()
                }
                .padding(.top, 12)
                if !p.runningFromBundle {
                    footnote("info.circle", "Run the built app (Scripts/build-app.sh) so macOS can ask for the microphone.")
                }
            }
        }
    }

    private var commands: some View {
        Panel("Things to say", subtitle: "Start with “Hey June”, hold Right Option, or use a gesture set to “Talk to June”.") {
            let columns = [GridItem(.flexible(), spacing: 10, alignment: .top), GridItem(.flexible(), spacing: 10, alignment: .top)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                hint("What's the weather in Tempe?", "anything at all, with Google Search for current facts")
                hint("Summarize this", "the paragraph or selection under the pointer")
                hint("Summarize this document", "the whole PDF, Word file, web page or email in front")
                hint("What does this mean?", "explains code, jargon or an error")
                hint("What's on my screen?", "June looks at the screen")
                hint("Type I'll be there at six", "types into the text field you clicked")
                hint("Fix the grammar · Make this more professional", "replaces the selected text; ⌘Z or “undo” puts it back")
                hint("Translate this to Spanish", "replaces selected text you're writing; otherwise shows the translation")
                hint("Reply to this saying I'll be late", "types a reply into the reply box; “click Send” sends it")
                hint("Shorter / as bullet points", "reworks the last answer")
                hint("Read this", "reads the text under the pointer aloud")
                hint("Copy that", "copies June's last answer")
                hint("What's in this folder?", "point at a folder or Finder window")
                hint("Copy this · Paste it here", "point at a file, then at a folder")
                hint("Move this to Documents · Rename this to …", "file actions, always undoable")
                hint("Select Projects and Portfolio · Copy them", "by name, in the Finder window you're in")
                hint("Delete it · Delete Projects · Undo", "it goes to the Trash; nothing is deleted for good")
                hint("Stop · Thanks", "June stops talking; “thanks” ends a conversation")
            }
        }
    }

    // MARK: Pieces

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        model.saveGeminiKey(key)
        keyDraft = ""
    }

    private func footnote(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(UI.hairline).frame(height: 1)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(UI.ink3)
                Text(text).font(UI.caption).foregroundStyle(UI.ink2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.top, 10)
        }
        .padding(.top, 4)
    }

    private func permissionRow(_ title: String, _ granted: Bool, symbol: String, detail: String? = nil) -> some View {
        SettingRow(symbol: symbol, title: title, detail: detail) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(granted ? UI.green : UI.amber)
        }
    }

    private func hint(_ phrase: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "quote.opening").font(.system(size: 11, weight: .semibold)).foregroundStyle(UI.flare)
                .frame(width: 16, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(phrase).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(UI.ink)
                Text(detail).font(UI.caption).foregroundStyle(UI.ink2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UI.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var modelBinding: Binding<String> {
        Binding(get: { model.juneSettings.modelOverride ?? "" },
                set: { model.juneSettings.modelOverride = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 })
    }

    private var keyDetail: String {
        switch model.juneKeySource {
        case "Keychain": return "Saved in the Keychain"
        case "GEMINI_API_KEY": return "Using the GEMINI_API_KEY environment variable"
        case .some(let other): return "Using \(other)"
        default: return "No key yet"
        }
    }
}

/// June's emblem on the page: a white disc with a waveform inside soft orange rings.
private struct JuneBadge: View {
    var listening: Bool
    var active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !listening)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3) { i in
                    Circle()
                        .strokeBorder(UI.flare.opacity(active ? 0.16 - Double(i) * 0.04 : 0.06), lineWidth: 1)
                        .frame(width: 90 + CGFloat(i) * 28, height: 90 + CGFloat(i) * 28)
                }
                Circle()
                    .fill(.white)
                    .frame(width: 78, height: 78)
                    .shadow(color: UI.flare.opacity(0.18), radius: 12, y: 4)
                    .overlay(Circle().strokeBorder(UI.line, lineWidth: 0.75))
                HStack(spacing: 3) {
                    ForEach(0..<7) { i in
                        let base: [CGFloat] = [10, 18, 28, 36, 26, 16, 10]
                        let wobble = listening ? CGFloat(sin(t * 7 + Double(i) * 0.9)) * 6 : 0
                        Capsule()
                            .fill(i == 3 ? UI.flare : UI.flare.opacity(0.75))
                            .frame(width: 3.5, height: max(6, base[i] + wobble))
                    }
                }
                .opacity(active ? 1 : 0.4)
            }
        }
    }
}
