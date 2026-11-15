import Foundation
import AVFoundation
import Speech

/// June's ears: one on-device speech recogniser fed from the audio hub.
///
/// - `.wake`: always listening for "Hey June". Nothing is sent anywhere; the recogniser runs on
///   this Mac (`requiresOnDeviceRecognition`). When the phrase is heard, whatever follows it is the
///   command, and the command ends at a pause.
/// - `.capture`: the command starts now (push-to-talk, a gesture, a follow-up). It ends at a pause,
///   or when `finish()` is called (push-to-talk released), or after `maxWait` with no speech.
///
/// Recognition tasks have a time limit, so in `.wake` the task is restarted at quiet moments and the
/// last 1.5 s of audio is replayed into the new task so a phrase on the boundary is not lost.
/// Events arrive on the main thread.
final class SpeechListener: @unchecked Sendable {
    enum Mode: Equatable {
        case wake
        case capture(maxWait: TimeInterval, manualEnd: Bool)
    }

    enum Event {
        case woke
        case partial(String)
        case command(String)
        case nothingHeard
        case failed(JuneError)
    }

    var onEvent: ((Event) -> Void)?

    private let queue = DispatchQueue(label: "june.listener")
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var taskStarted = Date()
    private var mode: Mode = .wake
    private var sensitivity = WakeSensitivity.normal
    private var silenceToEnd: TimeInterval = 1.1

    // Capture state (queue only).
    private var capturing = false
    private var commandOffset = 0
    /// Words before the command when it started (the wake phrase), and whether "Hey June" started it.
    private var commandWordIndex = 0
    private var wokeByPhrase = false
    private var latestTranscript = ""
    private var lastChange = Date()
    private var heardSpeech = false
    private var lastVoice = Date()
    private var captureStarted = Date()
    private var finishing = false
    private var generation = 0

    // Rolling audio for task restarts.
    private var recent: [AVAudioPCMBuffer] = []
    private var recentFrames = 0
    private let recentLimit = 24_000           // 1.5 s at 16 kHz

    // Voice activity, for endpointing and quiet restarts.
    private var noiseFloor: Float = 0.003
    private var voiced = false
    /// Tasks that died within a second of starting; several in a row means speech is unavailable.
    private var quickFailures = 0

    init() {}

    var isAvailable: Bool {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else { return false }
        return r.isAvailable && r.supportsOnDeviceRecognition
    }

    /// Starts (or restarts) listening in `mode`.
    func start(_ mode: Mode, sensitivity: WakeSensitivity) {
        queue.async {
            self.mode = mode
            self.sensitivity = sensitivity
            self.generation += 1
            self.capturing = false
            self.finishing = false
            if case .capture = mode { self.beginCapture(offset: 0, byWakePhrase: false) }
            self.newTask(replay: false)
        }
    }

    /// Stops listening entirely.
    func stop() {
        queue.async {
            self.generation += 1
            self.endTask()
            self.capturing = false
            self.recent = []
            self.recentFrames = 0
        }
    }

    /// Push-to-talk released: keep listening for a short tail, then deliver the command.
    func finish() {
        queue.asyncAfter(deadline: .now() + 0.35) {
            guard self.capturing, !self.finishing else { return }
            self.deliverCommand()
        }
    }

    /// Audio from the hub (audio thread).
    func append(_ buffer: AVAudioPCMBuffer) {
        queue.async { self.consume(buffer) }
    }

    // MARK: Internals (queue)

    #if DEBUG
    private var debugFrames = 0
    private var debugPeak: Float = 0
    private var debugLast = Date()
    #endif

    private func consume(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
        #if DEBUG
        debugFrames += Int(buffer.frameLength)
        if let samples = buffer.floatChannelData?[0] {
            for i in 0..<Int(buffer.frameLength) { debugPeak = max(debugPeak, abs(samples[i])) }
        }
        if Date().timeIntervalSince(debugLast) > 10 {
            JuneLog.write(String(format: "debug audio: %.1f s received, peak %.3f, task %@", Double(debugFrames) / 16000, debugPeak,
                                 task == nil ? "none" : "running"))
            debugFrames = 0
            debugPeak = 0
            debugLast = Date()
        }
        #endif
        recent.append(buffer)
        recentFrames += Int(buffer.frameLength)
        while recentFrames > recentLimit, let first = recent.first {
            recentFrames -= Int(first.frameLength)
            recent.removeFirst()
        }
        updateVoice(buffer)
        let now = Date()

        if capturing {
            // End at a pause: no voice for a moment AND the transcript has stopped changing (the
            // recogniser runs a little behind the audio, so the last word can still be on its way).
            if heardSpeech, !voiced, now.timeIntervalSince(lastVoice) > silenceToEnd,
               now.timeIntervalSince(lastChange) > 1.0, !manualEnd {
                deliverCommand()
            } else if !heardSpeech, case .capture(let maxWait, _) = mode, maxWait > 0,
                      now.timeIntervalSince(captureStarted) > maxWait {
                endCapture(heard: false)
            } else if !heardSpeech, mode == .wake, now.timeIntervalSince(captureStarted) > 5 {
                endCapture(heard: false)              // "Hey June" … and then nothing
            } else if now.timeIntervalSince(captureStarted) > 30 {
                deliverCommand()                      // never record forever
            }
        } else if mode == .wake {
            let age = now.timeIntervalSince(taskStarted)
            if (age > 40 && !voiced && now.timeIntervalSince(lastVoice) > 0.6) || age > 55 {
                newTask(replay: true)
            }
        }
    }

    private var manualEnd: Bool {
        if case .capture(_, let manual) = mode { return manual }
        return false
    }

    private func updateVoice(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        let n = Int(buffer.frameLength)
        for i in 0..<n { sum += samples[i] * samples[i] }
        let rms = (sum / Float(n)).squareRoot()
        let threshold = max(noiseFloor * 3.2, 0.012)
        voiced = rms > threshold
        if voiced {
            lastVoice = Date()
        } else {
            noiseFloor = noiseFloor * 0.95 + rms * 0.05
        }
    }

    private func newTask(replay: Bool) {
        endTask()
        guard let recognizer = recognizer ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            emit(.failed(.onDeviceSpeechMissing)); return
        }
        self.recognizer = recognizer
        guard recognizer.supportsOnDeviceRecognition else { emit(.failed(.onDeviceSpeechMissing)); return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true          // audio never leaves this Mac
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = ["Hey June", "June"]
        if #available(macOS 13.0, *) { request.addsPunctuation = true }
        self.request = request
        taskStarted = Date()
        latestTranscript = ""
        let myGeneration = generation
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            self.queue.async {
                guard myGeneration == self.generation, request === self.request else { return }
                if let result { self.handle(result.bestTranscription.formattedString, isFinal: result.isFinal) }
                #if DEBUG
                if let error { JuneLog.write("debug recogniser ended: \(error.localizedDescription)") }
                #endif
                if error != nil || (result?.isFinal ?? false) {
                    if error != nil, Date().timeIntervalSince(self.taskStarted) < 1.0 {
                        self.quickFailures += 1
                        if self.quickFailures >= 3 {
                            self.quickFailures = 0
                            self.generation += 1
                            self.endTask()
                            self.capturing = false
                            JuneLog.write("speech recogniser keeps failing: \(error.map { "\($0)" } ?? "")")
                            self.emit(.failed(.onDeviceSpeechMissing))
                            return
                        }
                    } else {
                        self.quickFailures = 0
                    }
                    if self.capturing { self.deliverCommand() }
                    else if self.mode == .wake { self.newTask(replay: true) }
                }
            }
        }
        if replay { for buffer in recent { request.append(buffer) } }
    }

    private func endTask() {
        task?.cancel()
        request?.endAudio()
        task = nil
        request = nil
    }

    private func handle(_ transcript: String, isFinal: Bool) {
        if transcript != latestTranscript {
            latestTranscript = transcript
            lastChange = Date()
            #if DEBUG
            JuneLog.write("debug heard: \(transcript.suffix(80))")
            #endif
        }
        if capturing {
            let command = commandText()
            if !command.isEmpty { heardSpeech = true }
            emit(.partial(command))
            return
        }
        guard mode == .wake, let match = WakePhrase.find(in: transcript, sensitivity: sensitivity) else { return }
        beginCapture(offset: match.end, byWakePhrase: true)
        emit(.woke)
        if !match.command.isEmpty { emit(.partial(match.command)) }
    }

    private func beginCapture(offset: Int, byWakePhrase: Bool) {
        capturing = true
        finishing = false
        commandOffset = offset
        wokeByPhrase = byWakePhrase
        commandWordIndex = Self.words(String(latestTranscript.prefix(offset))).count
        heardSpeech = false
        captureStarted = Date()
        lastChange = Date()
    }

    private func commandText() -> String {
        let trim = CharacterSet(charactersIn: " ,.:;!?-").union(.whitespacesAndNewlines)
        guard wokeByPhrase else {
            return String(latestTranscript.dropFirst(commandOffset)).trimmingCharacters(in: trim)
        }
        // The recognizer keeps rewriting what it heard ("hey june what" becomes "Hey June, what's"),
        // so a character offset from earlier can land in the middle of a word ("what's up" -> "t's up").
        // Find the wake phrase again in the latest text, or failing that skip the same number of words.
        if let match = WakePhrase.find(in: latestTranscript, sensitivity: sensitivity) { return match.command }
        return Self.words(latestTranscript).dropFirst(commandWordIndex).joined(separator: " ").trimmingCharacters(in: trim)
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private func deliverCommand() {
        guard capturing, !finishing else { return }
        finishing = true
        let command = commandText()
        endCapture(heard: !command.isEmpty, command: command)
    }

    private func endCapture(heard: Bool, command: String = "") {
        capturing = false
        finishing = false
        emit(heard ? .command(command) : .nothingHeard)
        // A fresh task for the next "Hey June" (or silence until June is told to listen again).
        recent = []
        recentFrames = 0
        if mode == .wake { newTask(replay: false) } else { endTask() }
    }

    private func emit(_ event: Event) {
        let handler = onEvent
        DispatchQueue.main.async { handler?(event) }
    }
}
