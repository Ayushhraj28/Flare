import Foundation

/// Gemini over plain REST. The key goes in a header, never in the URL or the log.
public final class GeminiClient: @unchecked Sendable {
    /// One place for the default model. Overridden by Settings or the GEMINI_MODEL environment variable.
    public static let defaultModel = "gemini-3.8-flash"

    public static func model(override: String?) -> String {
        if let override, !override.isEmpty { return override }
        if let env = ProcessInfo.processInfo.environment["GEMINI_MODEL"], !env.isEmpty { return env }
        return defaultModel
    }

    /// Models to try, in order, when one is rate-limited or not available to this key (free keys often
    /// have no quota for the newest model). The first that works is remembered for this run.
    public static func modelChain(override: String?) -> [String] {
        var chain = [model(override: override)]
        // The 2.5 models are retired for new keys (404), so they are not in the chain: falling back to them
        // hid the real error (usually a 429 quota error) behind "model not found".
        for fallback in ["gemini-flash-latest", "gemini-3.5-flash-lite"]
        where !chain.contains(fallback) {
            chain.append(fallback)
        }
        if let working = workingModel, let index = chain.firstIndex(of: working) {
            chain.remove(at: index)
            chain.insert(working, at: 0)
        }
        return chain
    }

    private static let stateLock = NSLock()
    private static var workingModelValue: String?
    private static var workingTTSModelValue: String?

    public static var workingModel: String? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return workingModelValue }
        set { stateLock.lock(); workingModelValue = newValue; stateLock.unlock() }
    }

    static var workingTTSModel: String? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return workingTTSModelValue }
        set { stateLock.lock(); workingTTSModelValue = newValue; stateLock.unlock() }
    }

    /// Errors that mean "try the next model": rate limit, quota, model missing or not allowed.
    public static func shouldTryNextModel(_ error: Error) -> Bool {
        guard case JuneError.http(let code, _)? = error as? JuneError else { return false }
        return code == 429 || code == 404 || code == 403
    }

    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        session = URLSession(configuration: config)
    }

    public func stream(body: Data, apiKey: String, model: String) -> AsyncThrowingStream<GeminiEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse") else {
                        throw JuneError.http(400, "Bad model name")
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.httpBody = body
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw JuneError.noNetwork }
                    if http.statusCode != 200 {
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count > 4000 { break }
                        }
                        throw Self.httpError(http.statusCode, data)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty || payload == "[DONE]" { continue }
                        for event in try GeminiSSE.parse(payload) { continuation.yield(event) }
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch let error as URLError {
                    continuation.finish(throwing: Self.map(error))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Model check (Settings › Test connection, and warming the connection at launch)

    /// Fetches the model's metadata: proves the key works and the model name exists, and opens the
    /// HTTPS connection so the first real command doesn't pay for the handshake.
    public func checkModel(_ model: String, apiKey: String) async -> Result<Void, JuneError> {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model)") else {
            return .failure(.http(400, "Bad model name"))
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return status == 200 ? .success(()) : .failure(Self.httpError(status, data))
        } catch let error as URLError {
            return .failure(Self.map(error))
        } catch {
            return .failure(.noNetwork)
        }
    }

    // MARK: Text to speech

    public static let defaultTTSModel = "gemini-3.8-flash-tts"
    static let ttsModels = ["gemini-3.8-flash-tts", "gemini-3.8-flash-lite-tts", "gemini-3.1-flash-tts-preview", "gemini-2.5-flash-preview-tts"]
    /// Female voices first. Aoede is June's default: warm and natural.
    public static let voices = ["Aoede", "Kore", "Leda", "Zephyr", "Puck", "Charon", "Fenrir", "Orus"]
    public static let femaleVoices: Set<String> = ["Aoede", "Kore", "Leda", "Zephyr"]

    public static func voiceLabel(_ name: String) -> String {
        switch name {
        case "Aoede": return "Aoede · warm, female"
        case "Kore": return "Kore · confident, female"
        case "Leda": return "Leda · youthful, female"
        case "Zephyr": return "Zephyr · bright, female"
        case "Puck": return "Puck · upbeat, male"
        case "Charon": return "Charon · calm, male"
        case "Fenrir": return "Fenrir · lively, male"
        case "Orus": return "Orus · steady, male"
        default: return name
        }
    }

    /// How June should sound, passed to text-to-speech.
    public static let speakingStyle = "warm, friendly and natural, like a real person chatting, with relaxed pacing"


    /// Speaks `text` with a Gemini voice. Returns 16-bit little-endian mono PCM and its sample rate.
    public func speech(text: String, voice: String, apiKey: String) async throws -> (pcm: Data, sampleRate: Double) {
        var models = Self.ttsModels
        if let working = Self.workingTTSModel, let index = models.firstIndex(of: working) {
            models.remove(at: index)
            models.insert(working, at: 0)
        }
        var lastError: Error = JuneError.emptyAnswer
        for model in models {
            do {
                let audio = try await speech(text: text, voice: voice, apiKey: apiKey, model: model)
                if Self.workingTTSModel != model {
                    Self.workingTTSModel = model
                    JuneLog.write("voice model: \(model)")
                }
                return audio
            } catch {
                lastError = error
                guard Self.shouldTryNextModel(error) else { throw error }
                JuneLog.write("voice model \(model) unavailable: \(error)")
            }
        }
        throw lastError
    }

    private func speech(text: String, voice: String, apiKey: String, model: String) async throws -> (pcm: Data, sampleRate: Double) {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            throw JuneError.http(400, "Bad voice model name")
        }
        // Gemini 3.8 TTS takes `voice` and a speaking style per turn; older TTS models take
        // `prebuiltVoiceConfig` and no style. Try the new shape first.
        let shapes: [[String: Any]] = [["voice": voice], ["voice": voice], ["prebuiltVoiceConfig": ["voiceName": voice]]]
        for (index, voiceConfig) in shapes.enumerated() {
            var part: [String: Any] = ["text": text]
            if index == 0 { part["speechMetadata"] = ["style": Self.speakingStyle] }
            let body: [String: Any] = [
                "contents": [["role": "user", "parts": [part]]],
                "generationConfig": ["responseModalities": ["AUDIO"], "speechConfig": ["voiceConfig": voiceConfig]],
            ]
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            let data: Data
            let status: Int
            do {
                let (d, response) = try await session.data(for: request)
                data = d
                status = (response as? HTTPURLResponse)?.statusCode ?? 0
            } catch let error as URLError {
                throw Self.map(error)
            }
            if status == 400, index < shapes.count - 1 { continue }
            guard status == 200 else { throw Self.httpError(status, data) }
            return try Self.audio(from: data)
        }
        throw JuneError.emptyAnswer
    }

    /// Pulls the audio out of a TTS response. MIME type looks like "audio/L16;codec=pcm;rate=24000".
    public static func audio(from data: Data) throws -> (pcm: Data, sampleRate: Double) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw JuneError.emptyAnswer }
        for candidate in (root["candidates"] as? [[String: Any]]) ?? [] {
            let parts = ((candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
            for part in parts {
                guard let inline = part["inlineData"] as? [String: Any], let b64 = inline["data"] as? String,
                      var pcm = Data(base64Encoded: b64), !pcm.isEmpty else { continue }
                var rate = 24_000.0
                if let mime = inline["mimeType"] as? String, let range = mime.range(of: "rate=") {
                    let digits = mime[range.upperBound...].prefix { $0.isNumber }
                    rate = Double(digits) ?? rate
                }
                // Some voice models send a WAV file instead of raw PCM. Its 44-byte header would
                // otherwise be played as a burst of noise at the start of every sentence.
                if let wav = wavPCM(pcm) { pcm = wav.pcm; rate = wav.sampleRate }
                if pcm.count % 2 == 1 { pcm.removeLast() }
                return (pcm, rate)
            }
        }
        throw JuneError.emptyAnswer
    }

    /// The samples and rate inside a 16-bit WAV file, or nil if `data` isn't one.
    static func wavPCM(_ data: Data) -> (pcm: Data, sampleRate: Double)? {
        let bytes = [UInt8](data.prefix(4096))
        guard bytes.count > 44, bytes[0...3] == [0x52, 0x49, 0x46, 0x46], bytes[8...11] == [0x57, 0x41, 0x56, 0x45] else { return nil }
        func u32(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24 }
        var rate = 24_000.0
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = String(bytes: bytes[offset..<offset + 4], encoding: .ascii) ?? ""
            let size = u32(offset + 4)
            if id == "fmt " { rate = Double(u32(offset + 12)) }
            if id == "data" {
                let start = offset + 8
                return (data.subdata(in: start..<min(data.count, start + size)), rate)
            }
            offset += 8 + size + (size % 2)
        }
        return nil
    }

    static func httpError(_ status: Int, _ data: Data) -> JuneError {
        var detail = ""
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            detail = String(message.prefix(160))
        }
        return .http(status, detail)
    }

    static func map(_ error: URLError) -> JuneError {
        switch error.code {
        case .timedOut: return .timeout
        case .cancelled: return .timeout
        default: return .noNetwork
        }
    }
}
