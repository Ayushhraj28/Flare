import Foundation
import AVFoundation

/// A voice June can speak with, for the Settings picker.
public struct JuneVoice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
}

/// Speaks June's answers while they are still streaming in.
///
/// Text is cut into chunks at sentence ends: the first sentence on its own (so June starts talking
/// as early as possible), then about two sentences at a time. With the Gemini voice each chunk is
/// sent to Gemini text-to-speech as soon as it is complete, in parallel, and played strictly in
/// order, so sentence two is usually ready before sentence one has finished playing. Any chunk
/// that fails falls back to the Mac voice, and a rate limit switches to the Mac voice for a minute.
@MainActor
final class VoiceReply {
    private enum Item {
        case mac(String)
        case gemini(Task<(Data, Double)?, Never>, String)
    }

    private let synth = AVSpeechSynthesizer()
    private var settings = JuneSettings()
    private var apiKey: String?
    private var client: GeminiClient?
    private var active = false
    private var pending = ""
    private var chunksQueued = 0
    private var queue: [Item] = []
    private var consumer: Task<Void, Never>?
    private var generation = 0
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var engineRate = 0.0
    private var geminiPausedUntil = Date.distantPast
    private var firstAudioLogged = false
    private var startedAt = Date()
    /// No pause is added before the first piece of an answer, only between pieces.
    private var isFirstPiece = true

    /// True while anything is queued or being said.
    var isBusy: Bool { synth.isSpeaking || consumer != nil || !queue.isEmpty }

    /// Starts a new answer. Stops anything still being said.
    func begin(settings: JuneSettings, apiKey: String?, client: GeminiClient) {
        stop()
        self.settings = settings
        self.apiKey = apiKey
        self.client = client
        active = settings.speakReplies
        startedAt = Date()
        isFirstPiece = true
    }

    /// Streamed text arrives here; finished chunks start speaking right away.
    func feed(_ delta: String) {
        guard active else { return }
        pending += delta
        while let end = Self.lastSentenceEnd(in: pending) {
            let chunk = String(pending[..<end])
            // First chunk: one sentence, for speed. Later chunks: ~2 sentences, fewer voice requests.
            let minimum = chunksQueued == 0 ? 1 : (useGemini ? 140 : 1)
            guard chunk.count >= minimum else { break }
            pending = String(pending[end...])
            enqueue(chunk)
        }
    }

    /// The answer is complete: speak whatever is left.
    func finish() {
        guard active else { return }
        let rest = pending
        pending = ""
        enqueue(rest)
    }

    /// Speaks a whole text now, even when spoken replies are off ("read this", the voice preview).
    func say(_ text: String, settings: JuneSettings, apiKey: String?, client: GeminiClient) {
        var forced = settings
        forced.speakReplies = true
        begin(settings: forced, apiKey: apiKey, client: client)
        feed(text + " ")
        finish()
    }

    func stop() {
        generation += 1
        consumer?.cancel()
        consumer = nil
        for item in queue { if case .gemini(let task, _) = item { task.cancel() } }
        queue = []
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        if let node, let engine { Self.fadeOutAndStop(node: node, engine: engine) }
        node = nil
        engine = nil
        engineRate = 0
        pending = ""
        chunksQueued = 0
        active = false
        firstAudioLogged = false
    }

    /// Returns when June has finished talking (or after two minutes at most).
    func waitUntilDone() async {
        let deadline = Date().addingTimeInterval(120)
        try? await Task.sleep(nanoseconds: 80_000_000)
        while isBusy, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: Queue

    private var useGemini: Bool {
        settings.voiceEngine == .gemini && !(apiKey ?? "").isEmpty && Date() >= geminiPausedUntil && client != nil
    }

    private func enqueue(_ text: String) {
        let clean = Self.speakable(text)
        guard !clean.isEmpty else { return }
        chunksQueued += 1
        if useGemini, let client, let apiKey {
            let voiceName = settings.geminiVoice
            let task = Task { [weak self] () -> (Data, Double)? in
                do {
                    let audio = try await client.speech(text: clean, voice: voiceName, apiKey: apiKey)
                    return (audio.pcm, audio.sampleRate)
                } catch {
                    if !Task.isCancelled { self?.noteGeminiFailure(error) }
                    return nil
                }
            }
            queue.append(.gemini(task, clean))
        } else {
            queue.append(.mac(clean))
        }
        startConsumer()
    }

    private func startConsumer() {
        guard consumer == nil else { return }
        let myGeneration = generation
        consumer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == myGeneration, !self.queue.isEmpty else { break }
                let item = self.queue.removeFirst()
                await self.play(item)
            }
            guard let self, self.generation == myGeneration else { return }
            self.consumer = nil
        }
    }

    private func play(_ item: Item) async {
        switch item {
        case .mac(let text):
            await speakMacAndWait(text)
        case .gemini(let task, let text):
            let audio = await task.value
            if Task.isCancelled { return }
            if let audio, await playPCM(audio.0, sampleRate: audio.1) { return }
            if Task.isCancelled { return }
            await speakMacAndWait(text)
        }
    }

    private func noteGeminiFailure(_ error: Error) {
        let pause: TimeInterval
        if case JuneError.http(let code, _)? = error as? JuneError {
            pause = code == 429 ? 60 : (code == 404 || code == 400 || code == 403 ? 600 : 20)
        } else {
            pause = 20
        }
        geminiPausedUntil = Date().addingTimeInterval(pause)
        JuneLog.write("gemini voice failed (\(error)); Mac voice for \(Int(pause)) s")
    }

    private func logFirstAudio(_ engineName: String) {
        guard !firstAudioLogged else { return }
        firstAudioLogged = true
        JuneLog.write("voice \(engineName) first audio after \(Int(Date().timeIntervalSince(startedAt) * 1000))ms")
    }

    // MARK: Mac voice

    private func speakMacAndWait(_ text: String) async {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(id: settings.macVoiceID)
        utterance.rate = Float(min(max(settings.speechRate, 0.3), 0.7))
        logFirstAudio("mac")
        synth.speak(utterance)
        try? await Task.sleep(nanoseconds: 60_000_000)
        while synth.isSpeaking, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    static func voice(id: String?) -> AVSpeechSynthesisVoice? {
        if let id, let chosen = AVSpeechSynthesisVoice(identifier: id) { return chosen }
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let english = usableVoices().filter { $0.language.hasPrefix("en") }
        // June is a woman's voice: prefer female voices, then the best quality, then the user's region.
        let candidates = english.filter { $0.gender == .female }.isEmpty ? english : english.filter { $0.gender == .female }
        return candidates.sorted { a, b in
            if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue > b.quality.rawValue }
            return (a.language == language) && (b.language != language)
        }.first ?? AVSpeechSynthesisVoice(language: language)
    }

    nonisolated static func usableVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
    }

    nonisolated static func availableVoices() -> [JuneVoice] {
        let qualityName: (AVSpeechSynthesisVoiceQuality) -> String = { quality in
            switch quality {
            case .premium: return "Premium"
            case .enhanced: return "Enhanced"
            default: return "Standard"
            }
        }
        return usableVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { a, b in
                if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue > b.quality.rawValue }
                return a.name < b.name
            }
            .map { voice in
                let gender = voice.gender == .female ? "female" : (voice.gender == .male ? "male" : "voice")
                return JuneVoice(id: voice.identifier, name: voice.name, detail: "\(gender) · \(voice.language) · \(qualityName(voice.quality))")
            }
    }

    // MARK: Gemini voice playback

    /// Plays 16-bit little-endian mono PCM and returns once it has been heard (or playback stopped).
    private func playPCM(_ pcm: Data, sampleRate: Double) async -> Bool {
        let total = pcm.count / 2
        guard total > 0 else { return false }
        let bytes = [UInt8](pcm)
        var samples = [Float](repeating: 0, count: total)
        for i in 0..<total {
            let sample = Int16(bitPattern: UInt16(bytes[2 * i]) | (UInt16(bytes[2 * i + 1]) << 8))
            samples[i] = Float(sample) / 32768
        }
        // Each piece of the answer is synthesized separately and comes with a little noise and breath
        // before and after the words. Played back to back, those edges sound rough ("rusty") where
        // one sentence meets the next, so cut them off and put a clean short pause in their place.
        let speech = Self.speechRange(samples, sampleRate: sampleRate)
        let pause = isFirstPiece ? 0 : Int(sampleRate * 0.14)
        isFirstPiece = false
        let count = pause + speech.count
        guard count > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { return false }
        buffer.frameLength = AVAudioFrameCount(count)
        for i in 0..<pause { channel[i] = 0 }
        for (offset, index) in speech.enumerated() { channel[pause + offset] = samples[index] }
        // Short fades on the words themselves, so they never start or stop with a click.
        Self.applyFades(channel + pause, count: speech.count, sampleRate: sampleRate)
        var freshEngine = false
        if engine == nil || engineRate != sampleRate {
            if let node, let engine { Self.fadeOutAndStop(node: node, engine: engine) }
            freshEngine = true
            let newEngine = AVAudioEngine()
            let newNode = AVAudioPlayerNode()
            newEngine.attach(newNode)
            newEngine.connect(newNode, to: newEngine.mainMixerNode, format: format)
            do {
                try newEngine.start()
            } catch {
                JuneLog.write("voice output failed to start: \(error)")
                return false
            }
            newNode.play()
            engine = newEngine
            node = newNode
            engineRate = sampleRate
        }
        guard let node else { return false }
        if freshEngine, let lead = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate * 0.06)) {
            // A moment of silence first, so the output device has settled before the voice starts.
            lead.frameLength = lead.frameCapacity
            node.scheduleBuffer(lead, completionHandler: nil)
        }
        logFirstAudio("gemini")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in continuation.resume() }
        }
        return true
    }

    /// The part of a clip that has speech in it: from just before the first sound above the noise
    /// floor to just after the last, so leading and trailing hiss and breath are dropped.
    nonisolated static func speechRange(_ samples: [Float], sampleRate: Double) -> Range<Int> {
        let threshold: Float = 0.015                           // about -36 dB
        let window = max(1, Int(sampleRate * 0.01))            // 10 ms
        func loud(at start: Int) -> Bool {
            var peak: Float = 0
            for i in start..<min(samples.count, start + window) { peak = max(peak, abs(samples[i])) }
            return peak > threshold
        }
        var first = 0
        while first < samples.count, !loud(at: first) { first += window }
        var last = samples.count - window
        while last > first, !loud(at: max(0, last)) { last -= window }
        guard first < samples.count, last > first else { return 0..<samples.count }   // all quiet: play as is
        let lower = max(0, first - Int(sampleRate * 0.03))                  // keep 30 ms before the words
        let upper = min(samples.count, last + window + Int(sampleRate * 0.08))  // and 80 ms after
        return lower..<upper
    }

    /// Fade in over ~8 ms and out over ~15 ms (too short to hear, long enough to remove clicks).
    nonisolated static func applyFades(_ samples: UnsafeMutablePointer<Float>, count: Int, sampleRate: Double) {
        let fadeIn = min(count / 4, Int(sampleRate * 0.008))
        let fadeOut = min(count / 4, Int(sampleRate * 0.015))
        if fadeIn > 0 { for i in 0..<fadeIn { samples[i] *= Float(i) / Float(fadeIn) } }
        if fadeOut > 0 { for i in 0..<fadeOut { samples[count - 1 - i] *= Float(i) / Float(fadeOut) } }
    }

    /// Ramps the volume down over ~40 ms before stopping, so an interrupted reply doesn't pop.
    nonisolated static func fadeOutAndStop(node: AVAudioPlayerNode, engine: AVAudioEngine) {
        DispatchQueue.global(qos: .userInteractive).async {
            let start = node.volume
            for step in stride(from: 7, through: 0, by: -1) {
                node.volume = start * Float(step) / 8
                usleep(5_000)
            }
            node.stop()
            engine.stop()
        }
    }

    // MARK: Text shaping

    /// Index just past the last complete sentence in `text`, if any.
    nonisolated static func lastSentenceEnd(in text: String) -> String.Index? {
        var result: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            let next = text.index(after: i)
            if c == "\n" {
                result = next
            } else if c == "." || c == "!" || c == "?", next < text.endIndex, text[next] == " " || text[next] == "\n" {
                result = next
            }
            i = next
        }
        return result
    }

    /// Strips markdown and bullets so the voice doesn't read "asterisk asterisk".
    nonisolated static func speakable(_ text: String) -> String {
        var lines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while let first = line.first, "•-*#>".contains(first) {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            line = line.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
            guard !line.isEmpty else { continue }
            if let last = line.last, !".!?:;,".contains(last) { line += "." }
            lines.append(line)
        }
        return lines.joined(separator: " ")
    }
}
